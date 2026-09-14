#Requires -Version 5.1
<#
.SYNOPSIS
    Thorium Zen5 build orchestrator.

.DESCRIPTION
    Personal Windows Chromium/Thorium build pipeline tuned for AMD Ryzen 9
    9950X (Zen 5) / AVX-512. See docs/BUILD.md and docs/ARCHITECTURE.md.

    Subcommands:
        audit       Inspect the synced source tree + toolchain, write build/audit.json
        sync        fetch/checkout Chromium + pull Thorium meta-repo (long: hours)
        configure   Overlay Thorium sources, apply zen5 patches, gn gen (fast)
        build       autoninja the browser + installer for -Profile (long: hours)
        test        run Chromium's own fast unit/browser test subset
        analyze     disassemble the built binary, report real ISA usage
        benchmark   run local startup/Speedometer benchmarks
        package     stage a release folder + build-manifest.json
        installer   build the Inno Setup installer (Thorium Zen5 <version>.exe)
        all         audit -> sync -> configure -> build -> test -> analyze ->
                    benchmark -> package -> installer, for one profile, and
                    STOP at the first failure (no partial releases).

.PARAMETER Command
    One of: audit, sync, configure, build, test, analyze, benchmark, package,
    installer, all.

.PARAMETER Profile
    One of: baseline, zen5, generic-avx512. Default: zen5.

.EXAMPLE
    .\build.ps1 all
    .\build.ps1 build -Profile generic-avx512
    .\build.ps1 analyze -Profile zen5
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("audit", "sync", "configure", "build", "test", "analyze", "benchmark", "package", "installer", "all")]
    [string]$Command,

    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",

    [int]$Jobs = 0,                      # 0 = auto (logical processors)
    [switch]$TrainPgo,                   # opt-in: attempt a local PGO retrain instead of Google's generic profile (NOT implemented by default -- see docs/BUILD.md)
    [switch]$SkipTests,
    [string]$SpeedometerDir = $null,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$RepoRoot     = $PSScriptRoot
$DepotTools   = Join-Path $RepoRoot "depot_tools"
$ThoriumMeta  = Join-Path $RepoRoot "upstream\Thorium"
$SrcDir       = Join-Path $RepoRoot "src"
$BuildDir     = Join-Path $RepoRoot "build"
$LogsDir      = Join-Path $BuildDir "logs"
$ScriptsDir   = Join-Path $RepoRoot "scripts"
$GnDir        = Join-Path $RepoRoot "gn"
$PatchesDir   = Join-Path $RepoRoot "patches\zen5"
$ReleasesDir  = Join-Path $RepoRoot "releases"
$OverlayMarker = Join-Path $BuildDir "current-overlay.txt"

New-Item -ItemType Directory -Force -Path $BuildDir, $LogsDir, $ReleasesDir | Out-Null

# ---------------------------------------------------------------------------
# Logging (every major operation logs to build/logs/<command>.log, timestamped)
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $script:LogFile -Value $line
}

function Start-Log([string]$Name) {
    $script:LogFile = Join-Path $LogsDir "$Name.log"
    Add-Content -Path $script:LogFile -Value ("=" * 78)
    Write-Log "Starting '$Name' (profile=$Profile)"
}

function ConvertTo-Win32ArgumentString {
    <#
    Builds a single Win32-CreateProcess-compatible argument string from a
    list of raw arguments, using the standard MSVCRT/CommandLineToArgvW
    escaping rules (backslashes before a literal quote are doubled, and
    the quote itself is backslash-escaped; a trailing run of backslashes
    right before the closing quote is doubled).

    We build this by hand instead of using ProcessStartInfo.ArgumentList
    because that property is NOT lazily initialized under Windows
    PowerShell 5.1's .NET Framework (unlike .NET Core/5+) -- it is $null
    until explicitly assigned, and Windows PowerShell has no public setter
    for it, so calling .Add() on a fresh ProcessStartInfo throws
    "You cannot call a method on a null-valued expression." Building the
    legacy .Arguments string works identically on every PowerShell/.NET
    version.
    #>
    param([string[]]$ArgumentList)
    $parts = foreach ($rawArg in $ArgumentList) {
        $arg = if ($null -eq $rawArg) { "" } else { $rawArg }
        if ($arg -eq "" -or $arg -match '[\s"]') {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('"')
            $backslashes = 0
            foreach ($ch in $arg.ToCharArray()) {
                if ($ch -eq '\') {
                    $backslashes++
                } else {
                    if ($ch -eq '"') {
                        [void]$sb.Append('\' * (($backslashes * 2) + 1))
                    } else {
                        [void]$sb.Append('\' * $backslashes)
                    }
                    [void]$sb.Append($ch)
                    $backslashes = 0
                }
            }
            [void]$sb.Append('\' * ($backslashes * 2))
            [void]$sb.Append('"')
            $sb.ToString()
        } else {
            $arg
        }
    }
    return ($parts -join ' ')
}

function Invoke-Logged {
    <#
    Run an external command, streaming its output line-by-line to the
    console and log file AS IT ARRIVES (not buffered until exit), and
    printing a periodic "still running" heartbeat with elapsed time so a
    long, quiet step (fetch, gclient sync, a link step) doesn't look hung.
    Fails loudly on a disallowed exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = $null,
        [hashtable]$EnvVars = $null,
        [int[]]$AllowedExitCodes = @(0),
        [int]$HeartbeatSeconds = 30   # 0 disables the heartbeat line
    )
    Write-Log "RUN: $Exe $($Arguments -join ' ')"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-Win32ArgumentString -ArgumentList $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($EnvVars) { foreach ($k in $EnvVars.Keys) { $psi.Environment[$k] = $EnvVars[$k] } }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        throw "Failed to start '$Exe' (is it installed and on PATH? full path expected): $_"
    }

    # Rolling tail kept only for the failure report; full output already
    # went to the log file as it streamed.
    $tail = New-Object System.Collections.Generic.List[string]
    function Add-TailLine([string]$line) {
        Write-Host $line
        Add-Content -Path $script:LogFile -Value $line
        $tail.Add($line)
        if ($tail.Count -gt 200) { $tail.RemoveAt(0) }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastBeat = [TimeSpan]::Zero
    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()

    while ($null -ne $outTask -or $null -ne $errTask) {
        [System.Threading.Tasks.Task[]]$pending = @($outTask, $errTask) | Where-Object { $null -ne $_ }
        [System.Threading.Tasks.Task]::WaitAny($pending, 500) | Out-Null

        if ($null -ne $outTask -and $outTask.IsCompleted) {
            $line = $outTask.Result
            if ($null -ne $line) { Add-TailLine $line; $outTask = $proc.StandardOutput.ReadLineAsync() }
            else { $outTask = $null }
        }
        if ($null -ne $errTask -and $errTask.IsCompleted) {
            $line = $errTask.Result
            if ($null -ne $line) { Add-TailLine $line; $errTask = $proc.StandardError.ReadLineAsync() }
            else { $errTask = $null }
        }

        if ($HeartbeatSeconds -gt 0 -and ($sw.Elapsed - $lastBeat).TotalSeconds -ge $HeartbeatSeconds) {
            $lastBeat = $sw.Elapsed
            Write-Log ("... still running ({0:hh\:mm\:ss} elapsed): $Exe" -f $sw.Elapsed)
        }
    }
    $proc.WaitForExit()
    $sw.Stop()

    if ($AllowedExitCodes -notcontains $proc.ExitCode) {
        Write-Log "FAILED (exit $($proc.ExitCode)) after $($sw.Elapsed.ToString('hh\:mm\:ss')): $Exe $($Arguments -join ' ')" "ERROR"
        Write-Log "--- last $($tail.Count) lines of output ---" "ERROR"
        $tail | ForEach-Object { Write-Log $_ "ERROR" }
        throw "Command failed (exit $($proc.ExitCode)): $Exe $($Arguments -join ' '). See $script:LogFile"
    }
    Write-Log "Done in $($sw.Elapsed.ToString('hh\:mm\:ss')): $Exe"
    # No return value: every call site invokes this as a bare statement, and
    # PowerShell auto-echoes an unconsumed return value to the console --
    # returning the tail here would print it a second time after it already
    # streamed live above. Nothing currently needs the captured text; if a
    # future caller does, capture it via `$script:LastCommandTail` instead of
    # widening this into a return value every other call site must suppress.
    $script:LastCommandTail = ($tail -join "`n")
}

function Resolve-ThoriumLatestStableTag {
    <#
    Returns the tag name of Thorium's current latest STABLE (non-prerelease,
    non-draft) GitHub release. We deliberately do NOT track the `main`
    branch: Alex313031/Thorium's own version-specific work (patches, GN
    args, win_scripts) lives on per-version branches (e.g. M150, M144) that
    get tagged releases roughly every 3-4 weeks, while `main` itself can go
    stale for months at a time (verified: main's last commit was 2026-05-08
    while M151 shipped 2026-08-03 and M152(beta) 2026-08-23 from other
    branches). GitHub's /releases/latest endpoint already excludes
    prereleases/drafts by definition, so this always resolves to the
    newest tagged release Thorium's maintainers consider stable -- not the
    newest beta, and not whatever main happens to contain.
    #>
    $uri = "https://api.github.com/repos/Alex313031/Thorium/releases/latest"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = "thorium-zen5-build.ps1" } -UseBasicParsing
    } catch {
        throw "Failed to resolve Thorium's latest stable release from $uri -- check network access and GitHub API rate limits (unauthenticated: 60 req/hr): $_"
    }
    if (-not $resp.tag_name) {
        throw "GitHub's releases/latest response for Alex313031/Thorium had no tag_name field: $($resp | ConvertTo-Json -Compress -Depth 3)"
    }
    if ($resp.prerelease) {
        Write-Log "WARNING: GitHub returned a prerelease as Thorium's 'latest' ($($resp.tag_name)) -- using it anyway since the API is the source of truth here." "WARN"
    }
    return [string]$resp.tag_name
}

function Get-JobCount {
    if ($Jobs -gt 0) { return $Jobs }
    return (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
}

function Get-DepotToolsEnv {
    return @{
        "PATH" = "$DepotTools;$env:PATH"
        "DEPOT_TOOLS_WIN_TOOLCHAIN" = "0"
        "NINJA_SUMMARIZE_BUILD" = "1"
        "NINJA_STATUS" = "[%r processes, %f/%t @ %o/s | %e sec] "
    }
}

function Assert-Prereqs {
    if (-not (Test-Path (Join-Path $DepotTools "gclient.py"))) {
        throw "depot_tools not found at $DepotTools. Clone https://chromium.googlesource.com/chromium/tools/depot_tools.git there first."
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git not found on PATH." }
    if (-not (Get-Command python3 -ErrorAction SilentlyContinue) -and -not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw "python not found on PATH."
    }
}

# ---------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------
function Invoke-Audit {
    Start-Log "audit"
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { $py = (Get-Command python3).Source }
    Invoke-Logged -Exe $py -Arguments @((Join-Path $ScriptsDir "audit_build.py"), "--repo-root", $RepoRoot)
    Write-Log "Audit written to $(Join-Path $BuildDir 'audit.json')"
}

# ---------------------------------------------------------------------------
# sync  (long-running: fetch Chromium via depot_tools, pull Thorium meta-repo)
# ---------------------------------------------------------------------------
function Invoke-Sync {
    Start-Log "sync"
    Assert-Prereqs
    $env = Get-DepotToolsEnv

    if (-not (Test-Path $SrcDir)) {
        Write-Log "No existing checkout at $SrcDir -- running 'fetch chromium'. This downloads ~20-30GB and can take hours depending on connection."
        New-Item -ItemType Directory -Force -Path $RepoRoot | Out-Null
        Invoke-Logged -Exe (Join-Path $DepotTools "fetch.bat") -Arguments @("--nohooks", "chromium") -WorkingDirectory $RepoRoot -EnvVars $env
        Rename-Item -Path (Join-Path $RepoRoot "chromium") -NewName "chromium-fetch-tmp" -ErrorAction SilentlyContinue
        if (Test-Path (Join-Path $RepoRoot "chromium-fetch-tmp\src")) {
            Move-Item (Join-Path $RepoRoot "chromium-fetch-tmp\src") $SrcDir
            Move-Item (Join-Path $RepoRoot "chromium-fetch-tmp\.gclient") (Join-Path $RepoRoot ".gclient") -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $RepoRoot "chromium-fetch-tmp") -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log "Existing checkout found at $SrcDir -- updating."
        Invoke-Logged -Exe "git" -Arguments @("checkout", "-f", "origin/main") -WorkingDirectory (Join-Path $SrcDir "v8") -EnvVars $env
        Invoke-Logged -Exe "git" -Arguments @("checkout", "-f", "origin/main") -WorkingDirectory $SrcDir -EnvVars $env
        Invoke-Logged -Exe (Join-Path $DepotTools "gclient.bat") -Arguments @("fetch", "--tags") -WorkingDirectory $SrcDir -EnvVars $env -AllowedExitCodes @(0,1)
    }

    Write-Log "Running gclient sync -D (this pulls all deps: V8, WebRTC, ANGLE, etc. Long.)"
    Invoke-Logged -Exe (Join-Path $DepotTools "gclient.bat") `
        -Arguments @("sync", "--with_branch_heads", "--with_tags", "-f", "-R", "-D") `
        -WorkingDirectory $SrcDir -EnvVars $env

    Write-Log "Running gclient runhooks (pulls pinned clang/Windows toolchain files)."
    Invoke-Logged -Exe (Join-Path $DepotTools "gclient.bat") -Arguments @("runhooks") -WorkingDirectory $SrcDir -EnvVars $env

    Write-Log "Resolving Thorium's latest stable (non-prerelease) release tag from GitHub..."
    $targetTag = Resolve-ThoriumLatestStableTag
    Write-Log "Target Thorium meta-repo tag: $targetTag"
    $tagMarkerFile = Join-Path $BuildDir "thorium-tag.txt"
    $currentTag = if (Test-Path $tagMarkerFile) { (Get-Content $tagMarkerFile -Raw).Trim() } else { $null }

    if (-not (Test-Path (Join-Path $ThoriumMeta ".git"))) {
        Write-Log "No existing Thorium meta-repo checkout -- cloning tag '$targetTag'."
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ThoriumMeta) | Out-Null
        Invoke-Logged -Exe "git" -Arguments @("clone", "--depth", "1", "--branch", $targetTag, "https://github.com/Alex313031/Thorium.git", $ThoriumMeta)
        Set-Content -Path $tagMarkerFile -Value $targetTag
    } elseif ($currentTag -ne $targetTag) {
        Write-Log "Thorium meta-repo is at '$currentTag' -- updating to newer stable tag '$targetTag'."
        Invoke-Logged -Exe "git" -Arguments @("fetch", "--depth", "1", "origin", "refs/tags/${targetTag}:refs/tags/${targetTag}") -WorkingDirectory $ThoriumMeta
        Invoke-Logged -Exe "git" -Arguments @("checkout", "--force", $targetTag) -WorkingDirectory $ThoriumMeta
        Set-Content -Path $tagMarkerFile -Value $targetTag
    } else {
        Write-Log "Thorium meta-repo already at latest stable tag '$targetTag' -- nothing to do."
    }

    Write-Log "Sync complete."
    Invoke-Audit
}

# ---------------------------------------------------------------------------
# configure (overlay Thorium source for the profile's flavor, apply zen5
# patches, write args.gn, gn gen). Fast (minutes), safe to re-run.
# ---------------------------------------------------------------------------
function Get-OverlayFlavorForProfile([string]$p) {
    if ($p -eq "baseline") { return "stock" } else { return "avx512" }
}

function Copy-DirOverlay([string]$SrcSub, [string]$DstSub) {
    $s = Join-Path $ThoriumMeta $SrcSub
    $d = Join-Path $SrcDir $DstSub
    if (-not (Test-Path $s)) { throw "Overlay source missing: $s" }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item -Path (Join-Path $s "*") -Destination $d -Recurse -Force
}

function Invoke-SourceOverlay([string]$Flavor) {
    $current = if (Test-Path $OverlayMarker) { Get-Content $OverlayMarker -Raw } else { $null }
    if ($current -eq $Flavor -and -not $Force) {
        Write-Log "Source overlay already applied for flavor '$Flavor' (use -Force to redo)."
        return
    }
    Write-Log "Applying '$Flavor' source overlay from Thorium meta-repo onto $SrcDir ..."

    # Mirrors win_scripts/setup.py's thorium_sources list exactly.
    New-Item -ItemType Directory -Force -Path (Join-Path $SrcDir "out\thorium") | Out-Null
    Copy-Item (Join-Path $ThoriumMeta "src\BUILD.gn") $SrcDir -Force
    foreach ($d in @("ash","build","chrome","chromeos","components","content","extensions",
                     "google_apis","media","net","sandbox","services","third_party","tools","ui","v8")) {
        Copy-DirOverlay "src\$d" $d
    }
    Copy-DirOverlay "thorium_shell" "out\thorium"
    Copy-Item (Join-Path $ThoriumMeta "pak_src\binaries\pak") (Join-Path $SrcDir "out\thorium") -Force
    Copy-DirOverlay "pak_src\binaries\pak-win" "out\thorium"

    # Thorium's standard misc/UX/crash-fix patches (win_scripts/setup.py's `patches` list).
    $patchList = @(
        "fix-policy-templates.patch","ftp-support-thorium.patch","thorium-2024-ui.patch","GPC.patch",
        "mini_installer.patch","open_in_same_tab.patch","thorium_webui.patch","disable-privacy-sandbox.patch",
        "win_updater.patch","keyboard_shortcuts.patch","partalloc.patch","multi-language-translate.patch",
        "fix_profile_selector_crash.patch","fix_getupdatesprocessor_crash.patch","fix_dangling_pointer_tooltip.patch",
        "fix_disable_aero_crash.patch","fix_file_dialog_crash.patch","fix_wayland_scale_crash.patch",
        "restore_download_shelf.patch","fix_absl_undefined_symbol.patch","fix_drag_and_drop_on_wayland.patch",
        "fix_touch_emulator_double_tap_zoom.patch","fix_setting_popover_invoker_crash.patch"
    )
    foreach ($p in $patchList) {
        $src = Join-Path $ThoriumMeta "other\$p"
        if (-not (Test-Path $src)) { Write-Log "  (skip, not present upstream: $p)" "WARN"; continue }
        $check = & git -C $SrcDir apply --check $src 2>&1
        if ($LASTEXITCODE -eq 0) {
            & git -C $SrcDir apply $src
            Write-Log "  applied $p"
        } else {
            Write-Log "  '$p' does not apply cleanly (already applied, or upstream changed) -- skipping. Detail: $check" "WARN"
        }
    }
    # ffmpeg patches (different cwd)
    $ffmpegDir = Join-Path $SrcDir "third_party\ffmpeg"
    foreach ($p in @("add-hevc-ffmpeg-decoder-parser.patch", "change-libavcodec-header.patch")) {
        Copy-Item (Join-Path $ThoriumMeta "other\$p") $ffmpegDir -Force
        $check = & git -C $ffmpegDir apply --check $p 2>&1
        if ($LASTEXITCODE -eq 0) { & git -C $ffmpegDir apply $p; Write-Log "  applied ffmpeg/$p" }
        else { Write-Log "  ffmpeg/$p does not apply cleanly -- skipping. Detail: $check" "WARN" }
    }

    Copy-Item (Join-Path $ThoriumMeta "infra\initial_preferences") (Join-Path $SrcDir "out\thorium") -Force
    Copy-Item (Join-Path $ThoriumMeta "infra\thor_ver") (Join-Path $SrcDir "out\thorium") -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $SrcDir "out\thorium\default_apps") | Out-Null
    Copy-Item (Join-Path $ThoriumMeta "infra\default_apps\*") (Join-Path $SrcDir "out\thorium\default_apps") -Recurse -Force -ErrorAction SilentlyContinue

    if ($Flavor -eq "avx512") {
        Write-Log "  applying AVX-512 flavor third_party overlay (other/AVX2/third_party -- reused by upstream for both AVX2 and AVX-512 flavors)"
        Copy-DirOverlay "other\AVX2\third_party" "third_party"
        Copy-Item (Join-Path $ThoriumMeta "other\AVX512\thor_ver") (Join-Path $SrcDir "out\thorium") -Force
        Copy-Item (Join-Path $ThoriumMeta "other\AVX512\thorium_version.txt") (Join-Path $SrcDir "ui\webui\resources\text") -Force

        Write-Log "  applying zen5 patches (patches/zen5 -- see that directory's README.md)"
        $py = (Get-Command python -ErrorAction SilentlyContinue).Source; if (-not $py) { $py = (Get-Command python3).Source }
        Invoke-Logged -Exe $py -Arguments @(
            (Join-Path $ScriptsDir "apply_zen5_patches.py"),
            "--src-dir", $SrcDir, "--capture-diffs", "--patches-dir", $PatchesDir
        )
    }

    Set-Content -Path $OverlayMarker -Value $Flavor -NoNewline
    Write-Log "Source overlay '$Flavor' applied."
}

function Get-OrDownloadPgoProfile {
    $pgoDir = Join-Path $SrcDir "chrome\build\pgo_profiles"
    $existing = Get-ChildItem $pgoDir -Filter "chrome-win64-*.profdata" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($existing -and -not $Force) { return $existing.FullName }

    Write-Log "Downloading Chromium's official win64 PGO profile (generic, not Zen5-trained -- see docs/BUILD.md 'About PGO')."
    $env = Get-DepotToolsEnv
    Invoke-Logged -Exe "python3" -Arguments @(
        "tools/update_pgo_profiles.py", "--target=win64", "update",
        "--gs-url-base=chromium-optimization-profiles/pgo_profiles"
    ) -WorkingDirectory $SrcDir -EnvVars $env
    Invoke-Logged -Exe "python3" -Arguments @(
        "v8/tools/builtins-pgo/download_profiles.py",
        "--depot-tools=$DepotTools", "--force", "download"
    ) -WorkingDirectory $SrcDir -EnvVars $env

    $downloaded = Get-ChildItem $pgoDir -Filter "chrome-win64-*.profdata" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $downloaded) { throw "PGO profile download did not produce a .profdata file in $pgoDir" }
    return $downloaded.FullName
}

function Invoke-Configure {
    Start-Log "configure"
    Assert-Prereqs
    if (-not (Test-Path $SrcDir)) { throw "No source checkout at $SrcDir. Run '.\build.ps1 sync' first." }

    $flavor = Get-OverlayFlavorForProfile $Profile
    Invoke-SourceOverlay $flavor

    $pgoPath = Get-OrDownloadPgoProfile
    $pgoPathGn = $pgoPath -replace '\\', '/'

    $argsSrc = switch ($Profile) {
        "baseline"        { Join-Path $GnDir "win_baseline_args.gn" }
        "zen5"            { Join-Path $GnDir "win_zen5_args.gn" }
        "generic-avx512"  { Join-Path $GnDir "win_generic_avx512_args.gn" }
    }
    $outDir = Join-Path $SrcDir "out\thorium-$Profile"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    (Get-Content $argsSrc -Raw) -replace '__PGO_DATA_PATH__', $pgoPathGn |
        Set-Content -Path (Join-Path $outDir "args.gn") -NoNewline

    Write-Log "Wrote $(Join-Path $outDir 'args.gn') from $argsSrc"

    if ($Profile -ne "baseline") {
        $verify = Select-String -Path (Join-Path $outDir "args.gn") -Pattern "use_znver5" -Quiet
        if ($Profile -eq "zen5" -and -not $verify) {
            throw "gn/win_zen5_args.gn does not set use_znver5 -- configuration error."
        }
    }

    $env = Get-DepotToolsEnv
    Write-Log "Running gn gen out\thorium-$Profile"
    Invoke-Logged -Exe (Join-Path $DepotTools "gn.bat") -Arguments @("gen", "out\thorium-$Profile") -WorkingDirectory $SrcDir -EnvVars $env

    # Re-audit now that the tree is patched/configured, so build/audit.json
    # reflects what will actually be built, not just what was synced.
    Invoke-Audit
    Write-Log "Configure complete for profile '$Profile'."
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
function Invoke-Build {
    Start-Log "build"
    if (-not (Test-Path (Join-Path $SrcDir "out\thorium-$Profile\args.gn"))) {
        throw "Profile '$Profile' not configured. Run '.\build.ps1 configure -Profile $Profile' first."
    }
    $env = Get-DepotToolsEnv
    $jobs = Get-JobCount
    Write-Log "Building profile '$Profile' with $jobs jobs (autoninja thorium_all + thorium_installer)."

    Invoke-Logged -Exe (Join-Path $DepotTools "autoninja.bat") `
        -Arguments @("-C", "out\thorium-$Profile", "thorium_all", "-j$jobs") `
        -WorkingDirectory $SrcDir -EnvVars $env

    Invoke-Logged -Exe (Join-Path $DepotTools "autoninja.bat") `
        -Arguments @("-C", "out\thorium-$Profile", "thorium_installer", "-j$jobs") `
        -WorkingDirectory $SrcDir -EnvVars $env

    $py = (Get-Command python -ErrorAction SilentlyContinue).Source; if (-not $py) { $py = (Get-Command python3).Source }
    Invoke-Logged -Exe $py -Arguments @(
        (Join-Path $ScriptsDir "generate_manifest.py"),
        "--repo-root", $RepoRoot, "--profile", $Profile, "--build-status", "success"
    )
    Write-Log "Build complete for profile '$Profile'. Installer at out\thorium-$Profile\mini_installer.exe"
}

# ---------------------------------------------------------------------------
# test
# ---------------------------------------------------------------------------
function Invoke-Test {
    Start-Log "test"
    if ($SkipTests) { Write-Log "SkipTests set -- skipping."; return }
    $env = Get-DepotToolsEnv
    $outRel = "out\thorium-$Profile"
    Write-Log "Building + running base_unittests and a smoke test of the produced browser."
    Invoke-Logged -Exe (Join-Path $DepotTools "autoninja.bat") -Arguments @("-C", $outRel, "base_unittests") -WorkingDirectory $SrcDir -EnvVars $env
    Invoke-Logged -Exe (Join-Path $SrcDir "$outRel\base_unittests.exe") -Arguments @("--gtest_shuffle", "--gtest_brief=1") -WorkingDirectory $SrcDir -AllowedExitCodes @(0)

    $exe = Get-ChildItem (Join-Path $SrcDir $outRel) -Filter "thorium.exe" -ErrorAction SilentlyContinue
    if (-not $exe) { $exe = Get-ChildItem (Join-Path $SrcDir $outRel) -Filter "chrome.exe" -ErrorAction SilentlyContinue }
    if ($exe) {
        Write-Log "Smoke-testing $($exe.FullName) --headless=new --dump-dom about:blank"
        Invoke-Logged -Exe $exe.FullName -Arguments @("--headless=new", "--disable-gpu", "--dump-dom", "about:blank") -AllowedExitCodes @(0)
    }
    Write-Log "Tests passed."
}

# ---------------------------------------------------------------------------
# analyze
# ---------------------------------------------------------------------------
function Invoke-Analyze {
    Start-Log "analyze"
    $outDir = Join-Path $SrcDir "out\thorium-$Profile"
    $binary = Join-Path $outDir "chrome.dll"
    if (-not (Test-Path $binary)) { $binary = Join-Path $outDir "thorium.exe" }
    if (-not (Test-Path $binary)) { throw "No built binary found in $outDir. Run '.\build.ps1 build -Profile $Profile' first." }

    $objdump = Join-Path $SrcDir "third_party\llvm-build\Release+Asserts\bin\llvm-objdump.exe"
    $symbolizer = Join-Path $SrcDir "third_party\llvm-build\Release+Asserts\bin\llvm-symbolizer.exe"
    $pdb = [System.IO.Path]::ChangeExtension($binary, ".dll.pdb")

    $py = (Get-Command python -ErrorAction SilentlyContinue).Source; if (-not $py) { $py = (Get-Command python3).Source }
    Invoke-Logged -Exe $py -Arguments @(
        (Join-Path $ScriptsDir "analyze_isa.py"),
        "--binary", $binary, "--objdump", $objdump, "--symbolizer", $symbolizer, "--pdb", $pdb,
        "--label", $Profile,
        "--out-json", (Join-Path $BuildDir "isa-report-$Profile.json"),
        "--out-txt", (Join-Path $BuildDir "isa-report-$Profile.txt")
    )
    Write-Log "ISA report written for profile '$Profile'."
}

# ---------------------------------------------------------------------------
# benchmark
# ---------------------------------------------------------------------------
function Invoke-Benchmark {
    Start-Log "benchmark"
    $outDir = Join-Path $SrcDir "out\thorium-$Profile"
    $exe = Get-ChildItem $outDir -Filter "thorium.exe" -ErrorAction SilentlyContinue
    if (-not $exe) { $exe = Get-ChildItem $outDir -Filter "chrome.exe" -ErrorAction SilentlyContinue }
    if (-not $exe) { throw "No built browser executable in $outDir." }

    $py = (Get-Command python -ErrorAction SilentlyContinue).Source; if (-not $py) { $py = (Get-Command python3).Source }
    $cmdArgs = @(
        (Join-Path $ScriptsDir "benchmark.py"),
        "--binary", $exe.FullName, "--label", $Profile, "--runs", "5",
        "--out", (Join-Path $BuildDir "benchmark-$Profile.json")
    )
    if ($SpeedometerDir) { $cmdArgs += @("--speedometer-dir", $SpeedometerDir) }
    Invoke-Logged -Exe $py -Arguments $cmdArgs
    Write-Log "Benchmark results written for profile '$Profile'."
}

# ---------------------------------------------------------------------------
# package
# ---------------------------------------------------------------------------
function Invoke-Package {
    Start-Log "package"
    $outDir = Join-Path $SrcDir "out\thorium-$Profile"
    $installerExe = Join-Path $outDir "mini_installer.exe"
    if (-not (Test-Path $installerExe)) { throw "mini_installer.exe not found in $outDir. Run '.\build.ps1 build' first." }

    $manifestPath = Join-Path $BuildDir "build-manifest-$Profile.json"
    $manifest = if (Test-Path $manifestPath) { Get-Content $manifestPath -Raw | ConvertFrom-Json } else { $null }
    $chromiumSha = "unknown"
    if ($manifest -and $manifest.source_revisions.chromium_src_commit) {
        $chromiumSha = $manifest.source_revisions.chromium_src_commit
    }
    $shortSha = $chromiumSha.Substring(0, [Math]::Min(10, $chromiumSha.Length))
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $releaseName = "thorium-zen5-$Profile-$shortSha-$stamp"
    $releaseDir = Join-Path $ReleasesDir $releaseName
    New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

    Copy-Item $installerExe (Join-Path $releaseDir "thorium_zen5_mini_installer_$Profile.exe") -Force
    foreach ($f in @("audit.json", "isa-report-$Profile.json", "isa-report-$Profile.txt",
                     "benchmark-$Profile.json", "build-manifest-$Profile.json", "compare-report.json")) {
        $p = Join-Path $BuildDir $f
        if (Test-Path $p) { Copy-Item $p $releaseDir -Force }
    }
    Write-Log "Packaged release at $releaseDir"
}

# ---------------------------------------------------------------------------
# installer  (Inno Setup wrapper producing the real, distinct-branded installer)
# ---------------------------------------------------------------------------
function Get-Or-Install-7Zip {
    $candidates = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    $sevenZip = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($sevenZip) { return $sevenZip }
    Write-Log "7-Zip not found -- installing via winget." "WARN"
    Invoke-Logged -Exe "winget" -Arguments @("install", "--id", "7zip.7zip", "-e",
        "--accept-source-agreements", "--accept-package-agreements")
    $sevenZip = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sevenZip) { throw "7-Zip still not found after install attempt." }
    return $sevenZip
}

function Expand-MiniInstaller([string]$MiniInstallerPath) {
    <#
    mini_installer.exe is a self-extracting 7z archive containing setup.exe
    and chrome.7z (which itself contains the versioned application folder).
    This mirrors exactly the manual process Thorium's own docs describe for
    building a "portable" release (docs/WIN_INSTRUCTIONS.txt "Portable
    release" section: "Use 7-Zip to extract the contents of the new
    mini_installer... and then extract the chrome.7z that was inside it").
    We use it here to get raw application files that OUR OWN Inno Setup
    installer can place under a distinct "Thorium Zen5" identity, rather
    than relying on mini_installer's own hardcoded installer UI/paths.
    #>
    $sevenZip = Get-Or-Install-7Zip
    $stage1 = Join-Path $env:TEMP "thorium-zen5-mini-$([guid]::NewGuid())"
    $stage2 = Join-Path $env:TEMP "thorium-zen5-chrome7z-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force -Path $stage1, $stage2 | Out-Null

    Invoke-Logged -Exe $sevenZip -Arguments @("x", $MiniInstallerPath, "-o$stage1", "-y")
    $chrome7z = Get-ChildItem $stage1 -Filter "chrome.7z" -Recurse | Select-Object -First 1
    if (-not $chrome7z) { throw "chrome.7z not found inside mini_installer.exe -- extraction layout may have changed upstream." }
    Invoke-Logged -Exe $sevenZip -Arguments @("x", $chrome7z.FullName, "-o$stage2", "-y")

    # The extracted tree is normally <version>/ containing chrome.exe/thorium.exe
    # directly, or nested one level under "Chrome-bin"/"Thorium-bin". Find the
    # directory that actually contains the browser executable.
    $exeFile = Get-ChildItem $stage2 -Recurse -Include "thorium.exe","chrome.exe" | Select-Object -First 1
    if (-not $exeFile) { throw "Could not locate thorium.exe/chrome.exe inside extracted chrome.7z." }

    Remove-Item $stage1 -Recurse -Force -ErrorAction SilentlyContinue
    return @{ AppFilesDir = $exeFile.Directory.FullName; MainExeName = $exeFile.Name }
}

function Invoke-Installer {
    Start-Log "installer"
    $outDir = Join-Path $SrcDir "out\thorium-$Profile"
    $miniInstaller = Join-Path $outDir "mini_installer.exe"
    if (-not (Test-Path $miniInstaller)) { throw "mini_installer.exe not found. Run '.\build.ps1 build' first." }

    Write-Log "Extracting raw application files from mini_installer.exe (see installer/README.md for why)."
    $extracted = Expand-MiniInstaller $miniInstaller
    Write-Log "Extracted application files to $($extracted.AppFilesDir) (main exe: $($extracted.MainExeName))"

    $innoCandidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"   # winget's JRSoftware.InnoSetup installs per-user here on some machines
    )
    $iscc = $innoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) {
        Write-Log "Inno Setup (ISCC.exe) not found -- installing via winget." "WARN"
        Invoke-Logged -Exe "winget" -Arguments @("install", "--id", "JRSoftware.InnoSetup", "-e",
            "--accept-source-agreements", "--accept-package-agreements")
        $iscc = $innoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $iscc) { throw "Inno Setup still not found after install attempt." }
    }

    $manifestPath = Join-Path $BuildDir "build-manifest-$Profile.json"
    $version = "0.0.0"
    if (Test-Path $manifestPath) {
        $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
        if ($m.source_revisions.chromium_src_commit) { $version = $m.source_revisions.chromium_src_commit.Substring(0, 10) }
    }

    Invoke-Logged -Exe $iscc -Arguments @(
        (Join-Path $RepoRoot "installer\thorium-zen5.iss"),
        "/DAppFilesDir=$($extracted.AppFilesDir)",
        "/DMainExeName=$($extracted.MainExeName)",
        "/DThoriumZen5Version=$version",
        "/DProfileName=$Profile",
        "/DOutputDir=$ReleasesDir"
    )
    Write-Log "Installer built -- see $ReleasesDir\Thorium-Zen5-Setup-*.exe"
}

# ---------------------------------------------------------------------------
# all
# ---------------------------------------------------------------------------
function Invoke-All {
    Invoke-Audit
    Invoke-Sync
    Invoke-Configure
    Invoke-Build
    Invoke-Test
    Invoke-Analyze
    Invoke-Benchmark
    Invoke-Package
    Invoke-Installer
    Write-Host "`n=== .\build.ps1 all complete for profile '$Profile' ===" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
switch ($Command) {
    "audit"     { Invoke-Audit }
    "sync"      { Invoke-Sync }
    "configure" { Invoke-Configure }
    "build"     { Invoke-Build }
    "test"      { Invoke-Test }
    "analyze"   { Invoke-Analyze }
    "benchmark" { Invoke-Benchmark }
    "package"   { Invoke-Package }
    "installer" { Invoke-Installer }
    "all"       { Invoke-All }
}
