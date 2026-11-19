#Requires -Version 5.1
<#
.SYNOPSIS
    Build stock Chromium stable with the Zen 5 targeting patch.

.DESCRIPTION
    Subcommands, each one stage of the pipeline update.ps1 runs in order:

        sync       pin the Chromium checkout to the current stable tag, gclient sync
        configure  apply the zen5 patch, write args.gn, gn gen
        build      autoninja chrome + mini_installer, write the build manifest
        test       base_unittests (via scripts\Run-Tests.ps1) and a headless smoke test
        analyze    count the instructions actually in chrome.dll (ISA report)
        package    copy mini_installer + manifest + ISA report into releases\
        publish    upload the newest release to GitHub Releases (private repo)

    Not a pipeline stage:

        canary     re-test the toolchain workarounds in gn\win_zen5_args.gn
                   against the current clang; results in build\toolchain-canary.json

    See docs/BUILD.md. Incident history behind the odd-looking parts is in
    docs/HISTORY.md.

.PARAMETER Profile
    zen5 (default) or baseline. baseline is unpatched stock Chromium with the
    same shared args, as a comparison point.

.PARAMETER Target
    Build only these ninja targets. root_store_tool links base under ThinLTO
    in about two minutes, which is the fast loop for toolchain problems
    (docs/TOOLCHAIN-BUGS.md). No manifest is written for a partial build.
    canary links root_store_tool unless -Target says otherwise.

.PARAMETER Priority
    Priority class for everything the build spawns. BelowNormal keeps the
    machine usable; CPU still reads ~100%, which is correct.

.EXAMPLE
    .\build.ps1 configure -Profile zen5 -Force
    .\build.ps1 build -Profile zen5 -Target root_store_tool
    .\build.ps1 canary
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("sync", "configure", "build", "test", "analyze", "package", "publish", "canary")]
    [string]$Command,

    [ValidateSet("baseline", "zen5")]
    [string]$Profile = "zen5",

    [int]$Jobs = 0,                    # 0 = derive from cores and available commit
    [switch]$Force,                    # configure: re-download the PGO profile
    [string[]]$Target = @(),
    [ValidateSet("Idle", "BelowNormal", "Normal")]
    [string]$Priority = "BelowNormal"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "scripts\Common.ps1")

$RepoRoot   = $PSScriptRoot
$DepotTools = Join-Path $RepoRoot "depot_tools"
$SrcDir     = Join-Path $RepoRoot "src"
$BuildDir   = $ThoriumBuild
$LogsDir    = $ThoriumLogs
$ScriptsDir = Join-Path $RepoRoot "scripts"
$GnDir      = Join-Path $RepoRoot "gn"
$OutRel     = "out\thorium-$Profile"
$OutDir     = Join-Path $SrcDir $OutRel
New-Item -ItemType Directory -Force -Path $ReleasesDir | Out-Null

# ---------------------------------------------------------------------------
# Logging: one StreamWriter per step, shared for reading. Reopening the file per
# line made any tail of the log a sharing violation, which under "Stop" killed
# a multi-hour build. Every write is best effort.
# ---------------------------------------------------------------------------
function Close-LogFile {
    if ($script:LogWriter) { try { $script:LogWriter.Dispose() } catch { }; $script:LogWriter = $null }
}

function Start-Log([string]$Name) {
    Close-LogFile
    $script:LogFile = Join-Path $LogsDir "$Name.log"
    try {
        $fs = New-Object System.IO.FileStream($script:LogFile, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $script:LogWriter = New-Object System.IO.StreamWriter($fs)
        $script:LogWriter.AutoFlush = $true
    } catch {
        $script:LogWriter = $null
        Write-Host "WARNING: cannot open $script:LogFile; console output only."
    }
    Write-LogLine ("=" * 78)
    Write-Log "Starting '$Name' (profile=$Profile)"
}

function Write-LogLine([string]$line) {
    if ($script:LogWriter) { try { $script:LogWriter.WriteLine($line) } catch { } }
}

function Write-Log([string]$Message, [string]$Level = "INFO") {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    Write-LogLine $line
}

function ConvertTo-Win32ArgumentString([string[]]$ArgumentList) {
    # CommandLineToArgvW quoting. ProcessStartInfo.ArgumentList does not exist
    # on Windows PowerShell 5.1's .NET Framework.
    $parts = foreach ($raw in $ArgumentList) {
        $arg = if ($null -eq $raw) { "" } else { $raw }
        if ($arg -ne "" -and $arg -notmatch '[\s"]') { $arg; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $bs = 0
        foreach ($ch in $arg.ToCharArray()) {
            if ($ch -eq '\') { $bs++; continue }
            if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)) } else { [void]$sb.Append('\' * $bs) }
            [void]$sb.Append($ch); $bs = 0
        }
        [void]$sb.Append('\' * ($bs * 2)).Append('"')
        $sb.ToString()
    }
    return ($parts -join ' ')
}

function Invoke-Logged {
    <#
    Run a native command, streaming output to console and log as it arrives,
    with a heartbeat so a quiet link step does not look hung. Throws on an exit
    code outside -AllowedExitCodes; the last 200 lines are kept in
    $script:LastCommandTail for callers that need to inspect output.

    The child gets $Priority unless -PriorityOverride is given. An explicit
    "Normal" must still be set: children inherit this process's lowered class,
    and the test launcher fails to collect results at BelowNormal.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = $null,
        [hashtable]$EnvVars = $null,
        [ValidateSet("Idle", "BelowNormal", "Normal", "AboveNormal", "High")]
        [string]$PriorityOverride = $null,
        [int[]]$AllowedExitCodes = @(0),
        [int]$HeartbeatSeconds = 30
    )
    Write-Log "RUN: $Exe $($Arguments -join ' ')"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-Win32ArgumentString $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($EnvVars) { foreach ($k in $EnvVars.Keys) { $psi.Environment[$k] = $EnvVars[$k] } }

    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch { throw "Failed to start '$Exe': $_" }

    $prio = if ($PriorityOverride) { $PriorityOverride } else { $Priority }
    if ($PriorityOverride -or $prio -ne "Normal") {
        try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$prio }
        catch { Write-Log "Could not set priority $prio on '$Exe': $($_.Exception.Message)" "WARN" }
    }

    $tail = New-Object System.Collections.Generic.List[string]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastBeat = [TimeSpan]::Zero
    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()
    while ($null -ne $outTask -or $null -ne $errTask) {
        [System.Threading.Tasks.Task[]]$pending = @($outTask, $errTask) | Where-Object { $null -ne $_ }
        [void][System.Threading.Tasks.Task]::WaitAny($pending, 500)
        foreach ($which in 'out', 'err') {
            $t = if ($which -eq 'out') { $outTask } else { $errTask }
            if ($null -eq $t -or -not $t.IsCompleted) { continue }
            $line = $t.Result
            $next = $null
            if ($null -ne $line) {
                Write-Host $line; Write-LogLine $line
                $tail.Add($line); if ($tail.Count -gt 200) { $tail.RemoveAt(0) }
                $next = if ($which -eq 'out') { $proc.StandardOutput.ReadLineAsync() } else { $proc.StandardError.ReadLineAsync() }
            }
            if ($which -eq 'out') { $outTask = $next } else { $errTask = $next }
        }
        if ($HeartbeatSeconds -gt 0 -and ($sw.Elapsed - $lastBeat).TotalSeconds -ge $HeartbeatSeconds) {
            $lastBeat = $sw.Elapsed
            Write-Log ("... still running ({0:hh\:mm\:ss}): $Exe" -f $sw.Elapsed)
        }
    }
    $proc.WaitForExit()
    $script:LastCommandTail = ($tail -join "`n")
    $script:LastCommandExitCode = $proc.ExitCode
    if ($AllowedExitCodes -notcontains $proc.ExitCode) {
        Write-Log "FAILED (exit $($proc.ExitCode)) after $($sw.Elapsed.ToString('hh\:mm\:ss')): $Exe" "ERROR"
        $tail | ForEach-Object { Write-Log $_ "ERROR" }
        throw "Command failed (exit $($proc.ExitCode)): $Exe $($Arguments -join ' '). See $script:LogFile"
    }
    Write-Log "Done in $($sw.Elapsed.ToString('hh\:mm\:ss')): $Exe"
}

# ---------------------------------------------------------------------------
# Toolchain and environment
# ---------------------------------------------------------------------------
function Get-PythonExe {
    # A full path: CreateProcess resolves a bare name as <name>.exe only.
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $cmd -or -not $cmd.Source) { throw "No python.exe on PATH (a Store alias does not count)." }
    return $cmd.Source
}

function Get-ProgramFilesX86 {
    # Absent from a stripped environment, which silently empties every path built on it.
    $p = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not $p) { $p = Join-Path $env:SystemDrive "Program Files (x86)" }
    return $p
}

function Get-WindowsKitsRoot {
    $root = $null
    try { $root = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0" -ErrorAction Stop).InstallationFolder } catch { }
    if (-not $root) { $root = Join-Path (Get-ProgramFilesX86) "Windows Kits\10" }
    return $root.TrimEnd('\')
}

function Get-PinnedChromiumTag {
    $f = Join-Path $BuildDir "chromium-tag.txt"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
    return $null
}

function Assert-WindowsToolchain {
    # Chromium pins one exact SDK in build\vs_toolchain.py. Checked up front so
    # a missing SDK is a one-line error, not a GN traceback after the PGO download.
    $vs = Join-Path $SrcDir "build\vs_toolchain.py"
    $m = if (Test-Path $vs) { Select-String -Path $vs -Pattern "^SDK_VERSION\s*=\s*'([0-9.]+)'" | Select-Object -First 1 }
    if (-not $m) { Write-Log "Could not read SDK_VERSION from $vs; gn gen will catch a bad SDK." "WARN"; return }
    $required = $m.Matches[0].Groups[1].Value
    $kits = Get-WindowsKitsRoot
    $missing = @("Include\$required\um", "Include\$required\shared", "Include\$required\ucrt", "Lib\$required\um\x64") |
               ForEach-Object { Join-Path $kits $_ } | Where-Object { -not (Test-Path $_) }
    if ($missing) {
        throw ("Windows SDK $required (required by Chromium $(Get-PinnedChromiumTag)) is missing or incomplete under $kits.`n" +
               "Install exactly that version (Visual Studio Installer > Individual components, or the standalone SDK), " +
               "including 'Debugging Tools for Windows'. Missing:`n  " + ($missing -join "`n  "))
    }
    Write-Log "Windows SDK $required present."
}

function Get-JobCount {
    <#
    Capped by available commit, not just cores: a -j32 build with ~42 GB of
    commit free died with STATUS_NO_MEMORY on 2026-09-18. ~1.6 GB per job with
    8 GB held back keeps a full build inside the limit.
    #>
    if ($Jobs -gt 0) { return $Jobs }
    $cpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $availGB = (Get-CimInstance Win32_OperatingSystem).FreeVirtualMemory * 1KB / 1GB
    $byCommit = [math]::Max(4, [math]::Floor(([math]::Max(0, [math]::Floor($availGB) - 8)) / 1.6))
    if ($byCommit -lt $cpus) {
        Write-Log ("Using $byCommit jobs instead of ${cpus}: only $([math]::Round($availGB,1)) GB of commit is free. " +
                   "Close memory-heavy apps, raise the pagefile, or pass -Jobs.") "WARN"
        return [int]$byCommit
    }
    return $cpus
}

function Get-DepotToolsEnv {
    <#
    Environment for depot_tools, gn and ninja. A short explicit PATH, because
    vcvarsall runs `set` through cmd.exe and a long inherited PATH overflows
    its 8191-character line (surfacing only as "error 255"). WINDOWSSDKDIR,
    TEMP/TMP and friends are set explicitly because Chromium's toolchain
    scripts require them and a scheduled task or remote shell may lack them.
    The GIT_HTTP_LOW_SPEED pair makes a stalled fetch fail after five minutes
    instead of hanging the nightly run.
    #>
    $sysRoot = $env:SystemRoot
    $pathParts = @($DepotTools, (Join-Path $sysRoot "system32"), $sysRoot,
                   (Join-Path $sysRoot "System32\Wbem"), (Join-Path $sysRoot "System32\WindowsPowerShell\v1.0"))
    foreach ($tool in "git", "python") {
        $c = Get-Command $tool -ErrorAction SilentlyContinue
        if ($c -and $c.Source) { $pathParts += (Split-Path -Parent $c.Source) }
    }
    $tempDir = if ($env:TEMP) { $env:TEMP.TrimEnd('\') } else { [IO.Path]::GetTempPath().TrimEnd('\') }
    $vars = @{
        "PATH"                      = (($pathParts | Select-Object -Unique | Where-Object { $_ -and (Test-Path $_) }) -join ';')
        "DEPOT_TOOLS_WIN_TOOLCHAIN" = "0"
        "NINJA_SUMMARIZE_BUILD"     = "1"
        "NINJA_STATUS"              = "[%r processes, %f/%t @ %o/s | %e sec] "
        "WINDOWSSDKDIR"             = (Get-WindowsKitsRoot)
        "ProgramFiles(x86)"         = (Get-ProgramFilesX86)
        "SYSTEMROOT"                = $sysRoot
        "SystemDrive"               = $(if ($env:SystemDrive) { $env:SystemDrive } else { "C:" })
        "TEMP"                      = $tempDir
        "TMP"                       = $tempDir
        "PATHEXT"                   = $(if ($env:PATHEXT) { $env:PATHEXT } else { ".COM;.EXE;.BAT;.CMD" })
        "ComSpec"                   = $(if ($env:ComSpec) { $env:ComSpec } else { Join-Path $sysRoot "system32\cmd.exe" })
        "GIT_HTTP_LOW_SPEED_LIMIT"  = "1000"
        "GIT_HTTP_LOW_SPEED_TIME"   = "300"
    }
    foreach ($p in "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "LOCALAPPDATA", "APPDATA") {
        $v = [Environment]::GetEnvironmentVariable($p)
        if ($v) { $vars[$p] = $v }
    }
    return $vars
}

function Assert-Prereqs {
    if (-not (Test-Path (Join-Path $DepotTools "gclient.py"))) {
        throw "depot_tools not found at $DepotTools. Clone https://chromium.googlesource.com/chromium/tools/depot_tools.git there first."
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git not found on PATH." }
    $null = Get-PythonExe
}

# ---------------------------------------------------------------------------
# sync
# ---------------------------------------------------------------------------
function Invoke-Sync {
    Start-Log "sync"
    Assert-Prereqs
    $toolEnv = Get-DepotToolsEnv

    if (-not (Test-Path $SrcDir)) {
        Write-Log "No checkout at $SrcDir; running 'fetch --nohooks chromium' (tens of GB, hours)."
        Invoke-Logged -Exe (Join-Path $DepotTools "fetch.bat") -Arguments @("--nohooks", "chromium") -WorkingDirectory $RepoRoot -EnvVars $toolEnv
    } else {
        # Plain git: this depot_tools' `gclient fetch` has no --tags.
        Invoke-Logged -Exe "git" -Arguments @("fetch", "origin", "--tags") -WorkingDirectory $SrcDir -EnvVars $toolEnv
    }

    $current = Get-PinnedChromiumTag
    $target  = Resolve-ChromiumStableTag
    Write-Log "Chromium stable is $target; checkout pinned at $(if ($current) { $current } else { 'nothing' })."
    if ($current -and $target -ne $current -and -not (Test-ChromiumVersionIsNewer -Candidate $target -Current $current)) {
        throw "Refusing to sync backwards from $current to $target. chromiumdash returned an older stable; nothing was changed."
    }

    $exists = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $SrcDir, "rev-parse", "--verify", "--quiet", "refs/tags/$target")
    if ($exists.ExitCode -ne 0) {
        throw "Tag $target is not in $SrcDir yet (announced before it was pushed?). Retry later."
    }

    Invoke-Logged -Exe "git" -Arguments @("checkout", "-f", "tags/$target") -WorkingDirectory $SrcDir -EnvVars $toolEnv
    Invoke-Logged -Exe (Join-Path $DepotTools "gclient.bat") `
        -Arguments @("sync", "--with_branch_heads", "--with_tags", "-f", "-R", "-D") -WorkingDirectory $SrcDir -EnvVars $toolEnv
    Invoke-Logged -Exe (Join-Path $DepotTools "gclient.bat") -Arguments @("runhooks") -WorkingDirectory $SrcDir -EnvVars $toolEnv

    Set-Content -Path (Join-Path $BuildDir "chromium-tag.txt") -Value $target
    Write-Log "Sync complete: Chromium $target. The zen5 patch is now reverted until configure runs."
}

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------
function Get-PgoProfile {
    # Two profiles, each refreshed on its own key.
    #
    # V8's builtins profile is keyed by the V8 version in v8-version.h, which
    # moves on most patch releases. mksnapshot runs with
    # --abort-on-bad-builtin-profile-data, so a stale one kills the build
    # (2026-10-07: profile for 15.5.35.14, checkout 15.5.35.20, mksnapshot
    # exited 0x80000003). download_profiles.py skips the download when
    # meta.json already matches, and --check-v8-revision fails with a clear
    # message if the profile was built for a different V8 revision.
    $toolEnv = Get-DepotToolsEnv
    $py = Get-PythonExe
    $v8Args = @("v8/tools/builtins-pgo/download_profiles.py", "--depot-tools=$DepotTools", "download", "--check-v8-revision")
    if ($Force) { $v8Args += "--force" }
    Invoke-Logged -Exe $py -Arguments $v8Args -WorkingDirectory $SrcDir -EnvVars $toolEnv

    # Chrome's profile is the one chrome\build\win64.pgo.txt names. Using it
    # (rather than the newest file on disk) is what stops a milestone bump
    # silently building with the previous milestone's profile.
    $pgoDir = Join-Path $SrcDir "chrome\build\pgo_profiles"
    $want = Get-Content (Join-Path $SrcDir "chrome\build\win64.pgo.txt") -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1
    $wantPath = if ($want) { Join-Path $pgoDir $want } else { $null }
    if ($wantPath -and (Test-Path $wantPath) -and -not $Force) { return $wantPath }

    Write-Log "Downloading Chromium's generic win64 PGO profile$(if ($want) { " ($want)" })."
    Invoke-Logged -Exe $py -Arguments @("tools/update_pgo_profiles.py", "--target=win64", "update",
        "--gs-url-base=chromium-optimization-profiles/pgo_profiles") -WorkingDirectory $SrcDir -EnvVars $toolEnv
    if ($wantPath -and (Test-Path $wantPath)) { return $wantPath }
    $got = Get-ChildItem $pgoDir -Filter "chrome-win64-*.profdata" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $got) { throw "PGO download produced no .profdata in $pgoDir." }
    Write-Log "win64.pgo.txt named no usable profile; using the newest, $($got.Name)." "WARN"
    return $got.FullName
}

function Get-ArgsText {
    # Shared block concatenated, so the profiles differ only in CPU targeting.
    # String.Replace, not -replace: a '$' in the path would be a regex token.
    $pgo = (Get-PgoProfile) -replace '\\', '/'
    $common = Get-Content (Join-Path $GnDir "_common_args.gni.txt") -Raw
    $own = Get-Content (Join-Path $GnDir "win_${Profile}_args.gn") -Raw
    return ($common + "`n" + $own).Replace('__PGO_DATA_PATH__', $pgo)
}

function Invoke-Configure {
    Start-Log "configure"
    Assert-Prereqs
    if (-not (Test-Path $SrcDir)) { throw "No checkout at $SrcDir. Run '.\build.ps1 sync' first." }
    Assert-WindowsToolchain

    $buildGn = Join-Path $SrcDir "build\config\compiler\BUILD.gn"
    if ($Profile -eq "baseline") {
        # Not patched. If an earlier zen5 configure left the patch in place the
        # output is still stock: use_znver5 defaults to false.
        Write-Log "Profile 'baseline': not applying the zen5 patch."
    } else {
        # Idempotent: the patcher detects its own marker. Exit 3 means upstream
        # moved an anchor, and nothing was written. The diff it captures is a
        # record of this tag's patch, written under build\ so the tracked
        # reference diff in patches\zen5 is not rewritten on every roll.
        Write-Log "Applying the zen5 patch to Chromium $(Get-PinnedChromiumTag)."
        Invoke-Logged -Exe (Get-PythonExe) -Arguments @((Join-Path $ScriptsDir "apply_zen5_patches.py"),
            "--src-dir", $SrcDir, "--capture-diffs", "--patches-dir", (Join-Path $BuildDir "patch-capture"))
    }

    $argsSrc = Join-Path $GnDir "win_${Profile}_args.gn"
    $commonSrc = Join-Path $GnDir "_common_args.gni.txt"
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $argsText = Get-ArgsText
    $argsGn = Join-Path $OutDir "args.gn"
    $oldArgs = if (Test-Path $argsGn) { Get-Content $argsGn -Raw } else { $null }
    Set-Content -Path $argsGn -Value $argsText -NoNewline
    Write-Log "Wrote $argsGn from $commonSrc + $argsSrc"
    # -mllvm flags are not part of the ThinLTO cache key, so after an args
    # change (a workaround retired, a flag added) the link would reuse the old
    # codegen and look unchanged. Any change clears it: a Chromium roll moves
    # the PGO path anyway, and the cache only pays off relinking the same tree.
    $ltoCache = Join-Path $OutDir "thinlto-cache"
    if ($null -ne $oldArgs -and $oldArgs -ne $argsText -and (Test-Path $ltoCache)) {
        Remove-Item -LiteralPath $ltoCache -Recurse -Force
        Write-Log "args.gn changed: cleared $ltoCache (-mllvm flags are not in the ThinLTO cache key)."
    }

    Invoke-Logged -Exe (Join-Path $DepotTools "gn.bat") -Arguments @("gen", $OutRel) `
        -WorkingDirectory $SrcDir -EnvVars (Get-DepotToolsEnv) -AllowedExitCodes @(0, 1)
    # gn errors on an unknown argument but only WARNS ("has no effect") when an
    # argument is never declared. Either way the build would not be what
    # args.gn says, so both stop here, with every offending arg listed.
    if ($script:LastCommandTail -match "Unknown build argument|Build argument has no effect") {
        $assigned = @(Get-Content $argsGn | Where-Object { $_ -match '^\s*([A-Za-z_]\w*)\s*=' } | ForEach-Object { $Matches[1] })
        $listed = Invoke-NativeCapture -Exe (Join-Path $DepotTools "gn.bat") -Arguments @("args", $OutRel, "--list", "--short") -WorkingDirectory $SrcDir
        $known = @{}
        foreach ($l in ($listed.Output -split "`n")) { if ($l -match '^\s*([A-Za-z_]\w*)\s*=') { $known[$Matches[1]] = $true } }
        $bad = if ($known.Count) { @($assigned | Where-Object { -not $known.ContainsKey($_) } | Select-Object -Unique) } else { @() }
        throw ("gn does not recognise argument(s) in args.gn for Chromium $(Get-PinnedChromiumTag): " +
               $(if ($bad) { $bad -join ', ' } else { "see $script:LogFile" }) +
               ". For zen5 this usually means the patch's declare_args() block is missing.")
    }
    # Exit 1 is allowed above only so the unknown-argument case can be named.
    # Any OTHER gn error (a missing toolchain file, a BUILD.gn syntax error) must
    # stop here too: an earlier gen leaves build.ninja behind, so the check
    # below would otherwise pass and configure would report success over a
    # failed gen.
    if ($script:LastCommandExitCode -ne 0) { throw "gn gen failed (exit $script:LastCommandExitCode); see $script:LogFile" }
    if (-not (Test-Path (Join-Path $OutDir "build.ninja"))) { throw "gn gen produced no build.ninja; see $script:LogFile" }

    # What the generated ninja was produced from. verify-source.ps1 compares
    # this with BUILD.gn as it is now; a mismatch means configure has not run
    # since the source changed, and the ninja describes some other tree.
    [ordered]@{
        chromium_tag    = Get-PinnedChromiumTag
        build_gn_sha256 = Get-Sha256OrNull $buildGn
        configured_utc  = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json | Set-Content -Path (Join-Path $BuildDir "configured-$Profile.json") -Encoding ASCII
    Write-Log "Configure complete for '$Profile'."
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
function Invoke-Build {
    Start-Log "build"
    if (-not (Test-Path (Join-Path $OutDir "args.gn"))) { throw "'$Profile' is not configured. Run '.\build.ps1 configure -Profile $Profile'." }
    $toolEnv = Get-DepotToolsEnv
    $jobs = Get-JobCount
    $autoninja = Join-Path $DepotTools "autoninja.bat"
    if ($Target.Count -gt 0) {
        Write-Log "Building targets only: $($Target -join ', ') ($jobs jobs)."
        Invoke-Logged -Exe $autoninja -Arguments (@("-C", $OutRel) + $Target + "-j$jobs") -WorkingDirectory $SrcDir -EnvVars $toolEnv
        Write-Log "Target build complete. No manifest: a partial build is not a release."
        return
    }
    Write-Log "Building chrome + mini_installer for '$Profile' ($jobs jobs)."
    Invoke-Logged -Exe $autoninja -Arguments @("-C", $OutRel, "chrome", "mini_installer", "-j$jobs") -WorkingDirectory $SrcDir -EnvVars $toolEnv
    Invoke-Logged -Exe (Get-PythonExe) -Arguments @((Join-Path $ScriptsDir "generate_manifest.py"),
        "--repo-root", $RepoRoot, "--profile", $Profile)
    Write-Log "Build complete: $OutDir\mini_installer.exe"
}

# ---------------------------------------------------------------------------
# test
# ---------------------------------------------------------------------------
function Invoke-Test {
    Start-Log "test"
    Invoke-Logged -Exe (Join-Path $DepotTools "autoninja.bat") -Arguments @("-C", $OutRel, "base_unittests") `
        -WorkingDirectory $SrcDir -EnvVars (Get-DepotToolsEnv)
    # Gated by Run-Tests.ps1, not the exe's exit code: it caps the launcher so
    # a starved one cannot report every test as failed, and fails only on
    # failures missing from scripts\known-test-failures.txt. Normal priority,
    # explicitly; see Invoke-Logged.
    Invoke-Logged -Exe "powershell.exe" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ScriptsDir "Run-Tests.ps1"), "-Profile", $Profile) `
        -WorkingDirectory $RepoRoot -PriorityOverride "Normal"
    Invoke-Logged -Exe (Join-Path $OutDir "chrome.exe") -Arguments @("--headless=new", "--disable-gpu", "--dump-dom", "about:blank")
    Write-Log "Tests passed."
}

# ---------------------------------------------------------------------------
# analyze
# ---------------------------------------------------------------------------
function Invoke-Analyze {
    Start-Log "analyze"
    $binary = Join-Path $OutDir "chrome.dll"
    if (-not (Test-Path $binary)) { throw "No chrome.dll in $OutDir. Build first." }

    # Chromium's clang package omits llvm-objdump, so it is fetched separately,
    # into build\llvm-objdump and NOT into the clang directory. gclient owns
    # third_party\llvm-build\Release+Asserts and marks it with
    # .*_is_first_class_gcs files; update.py deletes any directory carrying
    # those markers before unpacking into it. Fetching objdump there removed
    # clang-cl after every build and left the tree unable to run gn until the
    # next sync downloaded clang again (which in turn removed objdump).
    # update.py is called every time: it returns at once when the stamp in
    # build\llvm-objdump matches the pinned clang, and refetches after a roll.
    $bin = Join-Path $SrcDir "third_party\llvm-build\Release+Asserts\bin"
    $objdumpDir = Join-Path $BuildDir "llvm-objdump"
    $objdump = Join-Path $objdumpDir "bin\llvm-objdump.exe"
    Invoke-Logged -Exe (Get-PythonExe) -Arguments @((Join-Path $SrcDir "tools\clang\scripts\update.py"),
        "--package=objdump", "--output-dir", $objdumpDir) -WorkingDirectory $SrcDir -EnvVars (Get-DepotToolsEnv)
    if (-not (Test-Path $objdump)) { throw "llvm-objdump missing at $objdump." }
    $a = @((Join-Path $ScriptsDir "analyze_isa.py"), "--binary", $binary, "--objdump", $objdump,
           "--symbolizer", (Join-Path $bin "llvm-symbolizer.exe"), "--label", $Profile,
           "--out-json", (Join-Path $BuildDir "isa-report-$Profile.json"),
           "--out-txt", (Join-Path $BuildDir "isa-report-$Profile.txt"))
    if (Test-Path "$binary.pdb") { $a += @("--pdb", "$binary.pdb") } else { Write-Log "No PDB; no function attribution." "WARN" }
    Invoke-Logged -Exe (Get-PythonExe) -Arguments $a
    Write-Log "ISA report written."
}

# ---------------------------------------------------------------------------
# package
# ---------------------------------------------------------------------------
function Invoke-Package {
    Start-Log "package"
    $mini = Join-Path $OutDir "mini_installer.exe"
    $mf = Join-Path $BuildDir "build-manifest-$Profile.json"
    if (-not (Test-Path $mini)) { throw "No mini_installer.exe in $OutDir. Build first." }
    if (-not (Test-Path $mf)) { throw "No $mf. Build first." }
    $m = Get-Content $mf -Raw | ConvertFrom-Json
    $sha = [string]$m.source_revisions.chromium_src_commit
    $short = if ($sha) { $sha.Substring(0, [Math]::Min(10, $sha.Length)) } else { "unknown" }
    $dir = Join-Path $ReleasesDir "thorium-zen5-$Profile-$short-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # Installer first, manifest LAST: Get-NewestRelease treats a folder as
    # complete only once both exist, and the deploy check can run mid-copy.
    Copy-Item $mini (Join-Path $dir "thorium_zen5_mini_installer_$Profile.exe") -Force
    foreach ($f in "isa-report-$Profile.json", "isa-report-$Profile.txt", "build-manifest-$Profile.json") {
        $p = Join-Path $BuildDir $f
        if (Test-Path $p) { Copy-Item $p $dir -Force }
    }
    Write-Log "Packaged $dir"
}

# ---------------------------------------------------------------------------
# publish
# ---------------------------------------------------------------------------
function Invoke-Publish {
    <#
    Upload the newest release to GitHub Releases, tagged from THAT release's
    own manifest so tag and assets cannot disagree. Writes published.json into
    the release folder on success; update.ps1 retries any newest release that
    lacks it.

    The repo is private on purpose: proprietary_codecs, ffmpeg_branding="Chrome"
    and enable_widevine are not ours to redistribute.
    #>
    Start-Log "publish"
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found on PATH." }
    $rel = Get-NewestRelease -Profile $Profile
    if (-not $rel) { throw "No complete release for '$Profile' under $ReleasesDir." }
    $m = $rel.Manifest
    $tag = "v$($rel.Version)-$Profile"
    $assets = @(Get-ChildItem $rel.Dir -File | Where-Object { $_.Name -ne "published.json" } | ForEach-Object { $_.FullName })

    $isaTxt = Join-Path $rel.Dir "isa-report-$Profile.txt"
    $fence = '```'
    $isa = if (Test-Path $isaTxt) { "$fence`n$((Get-Content $isaTxt -Raw).TrimEnd())`n$fence" } else { "(no ISA report)" }
    $notes = @"
Personal Zen 5 build. Not a redistribution.

| | |
|---|---|
| Chromium | ``$($rel.Version)`` |
| Chromium commit | ``$($m.source_revisions.chromium_src_commit)`` |
| Profile | ``$Profile`` |
| Repo commit | ``$($m.source_revisions.thorium_zen5_repo_commit)`` |
| chrome.dll SHA-256 | ``$($m.chrome_dll_sha256)`` |
| Compiler | ``$((([string]$m.compiler.clang_version_string) -split "`n")[0])`` |

Requires an AMD Zen 5 CPU; older CPUs fault on the first AVX-512 instruction.

ISA measured in the shipped chrome.dll:
$isa
"@
    $notesFile = Join-Path $env:TEMP "thorium-zen5-notes-$([guid]::NewGuid()).md"
    Set-Content -Path $notesFile -Value $notes -Encoding UTF8
    $slug = Get-RepoSlug
    try {
        $existing = Invoke-NativeCapture -Exe "gh" -Arguments @("release", "view", $tag, "--repo", $slug, "--json", "tagName")
        if ($existing.ExitCode -eq 0) {
            Write-Log "$tag already exists on $slug; replacing its assets." "WARN"
            Invoke-Logged -Exe "gh" -Arguments (@("release", "upload", $tag, "--repo", $slug, "--clobber") + $assets)
        } else {
            Invoke-Logged -Exe "gh" -Arguments (@("release", "create", $tag, "--repo", $slug,
                "--title", "Thorium Zen5 $($rel.Version) ($Profile)", "--notes-file", $notesFile) + $assets)
        }
    } finally {
        Remove-Item $notesFile -Force -ErrorAction SilentlyContinue
    }
    [ordered]@{ tag = $tag; repo = $slug; published_utc = (Get-Date).ToUniversalTime().ToString("o") } |
        ConvertTo-Json | Set-Content -Path (Join-Path $rel.Dir "published.json") -Encoding ASCII
    Write-Log "Published $tag from $($rel.Name)."
}

# ---------------------------------------------------------------------------
# canary: re-test the toolchain workarounds (docs/TOOLCHAIN-BUGS.md)
# ---------------------------------------------------------------------------
function Get-ClangRevision {
    $upd = Join-Path $SrcDir "tools\clang\scripts\update.py"
    $m = if (Test-Path $upd) { Select-String -Path $upd -Pattern "^CLANG_REVISION = '([^']+)'" | Select-Object -First 1 }
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Invoke-SlpProbe {
    <#
    The SLP cap works around an X86 instruction-selection abort in one Skia
    function, so the direct test is that one file: its compile command from
    the configured build, minus the ThinLTO flags so the backend runs in the
    compiler instead of at link, once with the cap and once without. Seconds.
    #>
    $obj = "obj/skia/skia_core_and_effects/SkPathRawShapes.obj"
    $ninja = Join-Path $SrcDir "third_party\ninja\ninja.exe"
    $r = Invoke-NativeCapture -Exe $ninja -Arguments @("-C", $OutRel, "-t", "commands", "-s", $obj) -WorkingDirectory $SrcDir
    $line = @($r.Output -split "`n" | Where-Object { $_ -match 'clang-cl\.exe' }) | Select-Object -Last 1
    if ($r.ExitCode -ne 0 -or $line -notmatch '^\s*(\S+clang-cl\.exe)\s+(.*)$') {
        Write-Log "No compile command for $obj in $OutRel; SLP probe skipped." "WARN"
        return [ordered]@{ status = "SKIPPED" }
    }
    $clang = [IO.Path]::GetFullPath((Join-Path $OutDir $Matches[1]))
    $rest = $Matches[2]
    foreach ($f in '-flto=thin', '-fwhole-program-vtables', '-fsplit-lto-unit', '/showIncludes\S*', '/Fo\S+') {
        $rest = $rest -replace "(?<=^|\s)$f(?=\s|$)", ''
    }
    $objdump = Join-Path $BuildDir "llvm-objdump\bin\llvm-objdump.exe"
    $res = [ordered]@{ file = "third_party/skia/src/core/SkPathRawShapes.cpp" }
    foreach ($v in @(@("capped", "-mllvm -slp-max-reg-size=256"), @("uncapped", ""))) {
        $o = Join-Path $env:TEMP "thorium-slp-probe-$($v[0]).obj"
        $rsp = "$o.rsp"
        Remove-Item $o, $rsp -ErrorAction SilentlyContinue
        Set-Content -Path $rsp -Value "$($v[1]) $rest `"/Fo$o`"" -Encoding ASCII
        $c = Invoke-NativeCapture -Exe $clang -Arguments @("@$rsp") -WorkingDirectory $OutDir
        $abort = $c.Output -match 'Cannot select'
        # zmm lines show whether SLP actually went 512-bit when uncapped.
        $zmm = $null
        if ($c.ExitCode -eq 0 -and (Test-Path $objdump) -and (Test-Path $o)) {
            $d = Invoke-NativeCapture -Exe $objdump -Arguments @("-d", "--no-show-raw-insn", $o)
            $zmm = @($d.Output -split "`n" | Where-Object { $_ -match 'zmm' }).Count
        }
        $res[$v[0]] = [ordered]@{ exit = $c.ExitCode; isel_abort = $abort; zmm_lines = $zmm }
        Write-Log ("SLP probe, $($v[0]): exit $($c.ExitCode)" + $(if ($abort) { ", Cannot select" }) + $(if ($null -ne $zmm) { ", $zmm zmm lines" }))
        if ($c.ExitCode -ne 0) { $c.Output -split "`n" | Select-Object -First 5 | ForEach-Object { Write-Log "  $_" "WARN" } }
        Remove-Item $o, $rsp -ErrorAction SilentlyContinue
    }
    $res.status = if ($res.capped.exit -ne 0) { "INVALID" }
                  elseif ($res.uncapped.isel_abort) { "STILL_BROKEN" }
                  elseif ($res.uncapped.exit -eq 0) { "FIXED" }
                  else { "OTHER_FAILURE" }
    return $res
}

function Invoke-Canary {
    <#
    Is each workaround in gn\win_zen5_args.gn still needed on this clang?
      1. SLP compile probe (above).
      2. Link canary: root_store_tool links base under ThinLTO + PGO + WPD,
         which is where the tail-merge miscompile shows. Four variants of
         args.gn, in out\thorium-zen5-canary so the real build is untouched.
         Each clears the ThinLTO cache (-mllvm flags are not in its key) and
         deletes the binary, so every variant really relinks. It is linked
         the way chrome.dll is: Chromium leaves it at /opt:lldlto=0, where
         the backend runs no IR optimizer and so no vectorizer at all.
    Both bugs are hard compile or link errors, never silent, so PASS here plus
    a full chrome build that links is enough to retire a workaround.
    #>
    Start-Log "canary"
    if ($Profile -ne "zen5") { throw "The workarounds are zen5 args; run canary with -Profile zen5." }
    if (-not (Test-Path (Join-Path $OutDir "build.ninja"))) { throw "'$Profile' is not configured. Run '.\build.ps1 configure -Profile $Profile'." }
    $clangRev = Get-ClangRevision
    Write-Log "Toolchain canary, clang $clangRev, Chromium $(Get-PinnedChromiumTag)."
    $result = [ordered]@{
        clang_revision = $clangRev
        chromium_tag   = Get-PinnedChromiumTag
        started_utc    = (Get-Date).ToUniversalTime().ToString("o")
    }
    $result.slp_compile_probe = Invoke-SlpProbe

    $tgt = if ($Target.Count -gt 0) { $Target } else { @("root_store_tool") }
    $canRel = "$OutRel-canary"
    $canDir = Join-Path $SrcDir $canRel
    New-Item -ItemType Directory -Force -Path $canDir | Out-Null
    $base = Get-ArgsText
    # Not on a comment line: the args file quotes the flag in its own notes.
    $tm  = '(?m)^([^#\r\n]*?)"-mllvm:-enable-tail-merge=false"\s*,?[ \t]*'
    $slp = '(?m)^(\s*)zen5_slp_max_reg_size\s*=\s*"[^"]*"'
    foreach ($pat in $tm, $slp) {
        $k = ([regex]::Matches($base, $pat)).Count
        if ($k -gt 1) { throw "args pattern $pat matches $k times; the canary cannot tell which to remove." }
    }
    # Link like chrome.dll: Chromium's /opt:lldlto=2 for its optimized
    # targets, then zen5_thinlto_max_ldflags on top, via the default-config
    # hook the patch provides for exactly this.
    if ($base -match '(?m)^\s*zen5_thinlto_default_ldflags\s*=') { throw "args.gn sets zen5_thinlto_default_ldflags; the canary sets it itself." }
    $maxItems = if ($base -match '(?ms)^\s*zen5_thinlto_max_ldflags\s*=\s*\[([^\]]*)\]') { $Matches[1].Trim() } else { "" }
    $base += "`n# build.ps1 canary: link root_store_tool the way chrome.dll is linked`n" +
             "zen5_thinlto_default_ldflags = [ `"/opt:lldlto=2`", $maxItems ]`n"
    $variants = [ordered]@{
        "as-configured"      = $base
        "without-tail-merge" = $base -replace $tm, '$1'
        "without-slp-cap"    = $base -replace $slp, '$1zen5_slp_max_reg_size = ""'
        "without-either"     = ($base -replace $tm, '$1') -replace $slp, '$1zen5_slp_max_reg_size = ""'
    }
    $toolEnv = Get-DepotToolsEnv
    $jobs = Get-JobCount
    $ran = @{}
    $out = [ordered]@{}
    foreach ($name in $variants.Keys) {
        $text = $variants[$name]
        if ($ran.ContainsKey($text)) {
            $same = $ran[$text]
            $out[$name] = [ordered]@{ status = $out[$same].status; same_as = $same }
            Write-Log "Variant '$name' is identical to '$same' (that workaround is not set)."
            continue
        }
        $ran[$text] = $name
        Write-Log "Link canary variant '$name' ($($tgt -join ' '), $jobs jobs)."
        Set-Content -Path (Join-Path $canDir "args.gn") -Value $text -NoNewline
        Remove-Item -LiteralPath (Join-Path $canDir "thinlto-cache") -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($t in $tgt) { Remove-Item -LiteralPath (Join-Path $canDir "$t.exe") -Force -ErrorAction SilentlyContinue }
        Invoke-Logged -Exe (Join-Path $DepotTools "gn.bat") -Arguments @("gen", $canRel) -WorkingDirectory $SrcDir -EnvVars $toolEnv
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-Logged -Exe (Join-Path $DepotTools "autoninja.bat") -Arguments (@("-C", $canRel) + $tgt + "-j$jobs") `
            -WorkingDirectory $SrcDir -EnvVars $toolEnv -AllowedExitCodes @(0, 1)
        $tail = $script:LastCommandTail
        $status = if ($script:LastCommandExitCode -eq 0) { "PASS" }
                  elseif ($tail -match 'Cannot select') { "FAIL_SLP_ISEL" }
                  elseif ($tail -match 'seh_endepilogue|vector deleting dtor') { "FAIL_TAIL_MERGE" }
                  else { "FAIL_OTHER" }
        $out[$name] = [ordered]@{ status = $status; seconds = [int]$sw.Elapsed.TotalSeconds }
        Write-Log "Variant '$name': $status ($([int]$sw.Elapsed.TotalSeconds)s)." $(if ($status -eq "PASS") { "INFO" } else { "WARN" })
    }
    $result.link_canary = [ordered]@{ target = ($tgt -join ' '); out_dir = $canRel; variants = $out }

    $verdict = [ordered]@{}
    if ($out["as-configured"].status -ne "PASS") {
        $verdict.overall = "INVALID: the as-configured link failed ($($out['as-configured'].status)), so the other variants mean nothing. See $script:LogFile"
    } else {
        $verdict.tail_merge_ldflag = if ($out["without-tail-merge"].status -eq "PASS") { "not needed on this canary" } else { "still needed ($($out['without-tail-merge'].status))" }
        $probe = $result.slp_compile_probe.status
        $verdict.slp_cap = if ($probe -eq "FIXED" -and $out["without-slp-cap"].status -eq "PASS") { "not needed (compile probe and link canary pass)" }
                           elseif ($probe -eq "STILL_BROKEN" -or $out["without-slp-cap"].status -eq "FAIL_SLP_ISEL") { "still needed" }
                           else { "inconclusive (probe $probe, link $($out['without-slp-cap'].status))" }
        $verdict.both_off = $out["without-either"].status
        $verdict.note = "root_store_tool does not contain the Skia code; a full chrome build that links is the last word."
    }
    $result.verdict = $verdict
    $result.finished_utc = (Get-Date).ToUniversalTime().ToString("o")
    $json = Join-Path $BuildDir "toolchain-canary.json"
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $json -Encoding ASCII
    foreach ($k in $verdict.Keys) { Write-Log "Verdict, ${k}: $($verdict[$k])" }
    Write-Log "Canary results: $json"
}
# ---------------------------------------------------------------------------
try {
    switch ($Command) {
        "sync"      { Invoke-Sync }
        "configure" { Invoke-Configure }
        "build"     { Invoke-Build }
        "test"      { Invoke-Test }
        "analyze"   { Invoke-Analyze }
        "package"   { Invoke-Package }
        "publish"   { Invoke-Publish }
        "canary"    { Invoke-Canary }
    }
} finally {
    Close-LogFile
}
