#Requires -Version 5.1
<#
.SYNOPSIS
    Thorium Zen5 build orchestrator.

.DESCRIPTION
    Personal Windows build of STOCK Chromium, tuned for AMD Ryzen 9 9950X
    (Zen 5) / AVX-512. Tracks the current Chromium *stable* release and
    applies this project's own Zen5 compiler-targeting patches to it.

    The project no longer overlays Thorium's sources (2026-09-14): Thorium's
    tree pinned Chromium 138 while stable was 154, and its release tags all
    pointed at one stale commit. The Zen5 work was always ours and applies to
    stock Chromium directly. The name is kept for continuity.
    See docs/BUILD.md and docs/ARCHITECTURE.md.

    Subcommands:
        audit       Inspect the synced source tree + toolchain, write build/audit.json
        sync        fetch Chromium, pin to current stable tag, gclient sync (long)
        configure   apply zen5 patches, write args.gn, gn gen (fast)
        build       autoninja the browser + installer for -Profile (long: hours)
        test        run Chromium's own fast unit/browser test subset
        analyze     disassemble the built binary, report real ISA usage
        benchmark   run local startup/Speedometer benchmarks
        package     stage a release folder + build-manifest.json
        installer   build the Inno Setup installer (Thorium Zen5 <version>.exe)
        publish     upload the packaged release to GitHub Releases (private repo)
        all         audit -> sync -> configure -> build -> test -> analyze ->
                    benchmark -> package -> installer -> publish, for one
                    profile, and STOP at the first failure (no partial releases).

.PARAMETER Command
    One of: audit, sync, configure, build, test, analyze, benchmark, package,
    installer, publish, all.

.PARAMETER Profile
    One of: baseline, zen5, generic-avx512. Default: zen5.

.PARAMETER Target
    Build only these ninja targets instead of chrome + mini_installer. Turns
    the ~59,000-step full build into a ~2,500-step (~2 min) canary, which is
    what makes toolchain bisection practical. See docs/TOOLCHAIN-BUGS.md.

.EXAMPLE
    .\build.ps1 all
    .\build.ps1 build -Profile generic-avx512
    .\build.ps1 analyze -Profile zen5

.EXAMPLE
    # Fast canary for toolchain problems: links base under ThinLTO in ~2 min.
    .\build.ps1 build -Profile zen5 -Target root_store_tool
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("audit", "sync", "configure", "build", "test", "analyze", "benchmark", "package", "installer", "publish", "all")]
    [string]$Command,

    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",

    [int]$Jobs = 0,                      # 0 = auto (logical processors)
    [switch]$TrainPgo,                   # opt-in: attempt a local PGO retrain instead of Google's generic profile (NOT implemented by default -- see docs/BUILD.md)
    [switch]$SkipTests,
    [string]$SpeedometerDir = $null,
    [switch]$Force,

    # Build only these ninja targets instead of chrome + mini_installer.
    #
    # This exists because diagnosing a toolchain miscompile needs a FAST loop,
    # and the full build is ~59,000 steps. net/tools/root_store_tool is ~2,500
    # steps (~2 min) and still links base with ThinLTO + PGO + WPD, which is
    # where this class of bug actually lives -- it is what isolated the
    # -mtune=znver* bug in docs/TOOLCHAIN-BUGS.md. A canary that does not link
    # under LTO is worthless here: the same files compile cleanly standalone
    # under every -march/-mtune combination tested.
    #
    #   .\build.ps1 build -Profile zen5 -Target root_store_tool
    #
    # Skips the manifest step, since a partial build is not a release.
    [string[]]$Target = @(),

    # Priority class for every child process the build spawns. Defaults to
    # BelowNormal so a multi-hour build leaves the machine usable: the build
    # still gets all 32 threads and every idle cycle, but any foreground work
    # preempts it instantly. Expect CPU to still read ~100% -- that is correct
    # and harmless; it means no core is idling. Use Idle if you want the build
    # to yield even harder, or Normal for the old behaviour.
    [ValidateSet("Idle", "BelowNormal", "Normal")]
    [string]$Priority = "BelowNormal"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$RepoRoot     = $PSScriptRoot
$DepotTools   = Join-Path $RepoRoot "depot_tools"
$SrcDir       = Join-Path $RepoRoot "src"
$BuildDir     = Join-Path $RepoRoot "build"
$LogsDir      = Join-Path $BuildDir "logs"
$ScriptsDir   = Join-Path $RepoRoot "scripts"
$GnDir        = Join-Path $RepoRoot "gn"
$PatchesDir   = Join-Path $RepoRoot "patches\zen5"
$ReleasesDir  = Join-Path $RepoRoot "releases"

New-Item -ItemType Directory -Force -Path $BuildDir, $LogsDir, $ReleasesDir | Out-Null

# ---------------------------------------------------------------------------
# Logging (every major operation logs to build/logs/<command>.log, timestamped)
# ---------------------------------------------------------------------------
function Open-LogFile([string]$Path) {
    <#
    Hold ONE StreamWriter open for the life of a step instead of reopening the
    file per line.

    The previous implementation called Add-Content for every line. Across a
    72,670-edge Chromium build that is a file open/close per line, and any
    concurrent reader -- someone running `Get-Content -Wait` on the log, or a
    monitoring tool -- causes a sharing violation. Because this script runs with
    $ErrorActionPreference = "Stop", that trivial logging failure became a
    TERMINATING error and killed the build outright:

        Add-Content : The process cannot access the file
        'C:\thorium\build\logs\build.log' because it is being used by another
        process.

    FileShare.ReadWrite lets others read (and tail) the log while we write, and
    every write below is wrapped so that a logging problem can never again take
    down a multi-hour build.
    #>
    Close-LogFile
    $script:LogFile = $Path
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $fs = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite)
        $script:LogWriter = New-Object System.IO.StreamWriter($fs)
        $script:LogWriter.AutoFlush = $true
    } catch {
        $script:LogWriter = $null
        Write-Host "WARNING: could not open log file '$Path' ($($_.Exception.Message)). Continuing with console output only."
    }
}

function Close-LogFile {
    if ($script:LogWriter) {
        try { $script:LogWriter.Flush(); $script:LogWriter.Dispose() } catch { }
        $script:LogWriter = $null
    }
}

function Write-LogLine([string]$line) {
    # Best-effort by design: logging must never terminate the build.
    if ($script:LogWriter) {
        try { $script:LogWriter.WriteLine($line) } catch { }
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Write-LogLine $line
}

function Start-Log([string]$Name) {
    Open-LogFile (Join-Path $LogsDir "$Name.log")
    Write-LogLine ("=" * 78)
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

    # Set the priority class on the child we just started. Windows gives a new
    # process its parent's class at creation, so lowering the build driver
    # (siso/ninja/autoninja) automatically covers the hundreds of clang-cl
    # processes it goes on to spawn -- no need to chase them individually.
    if ($Priority -ne "Normal") {
        try {
            $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$Priority
        } catch {
            Write-Log "Could not set process priority to $Priority for '$Exe': $($_.Exception.Message)" "WARN"
        }
    }

    # Rolling tail kept only for the failure report; full output already
    # went to the log file as it streamed.
    $tail = New-Object System.Collections.Generic.List[string]
    function Add-TailLine([string]$line) {
        Write-Host $line
        Write-LogLine $line
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

function Invoke-NativeCapture {
    <#
    Run a native command and return its exit code + combined output WITHOUT
    letting it throw.

    Why this exists: with $ErrorActionPreference = "Stop" (set at the top of
    this script), `& somecmd 2>&1` turns anything the command writes to
    stderr into an ErrorRecord, which under "Stop" becomes a TERMINATING
    error. So the idiomatic-looking

        $out = & git apply --check $p 2>&1
        if ($LASTEXITCODE -eq 0) { ... } else { ...skip... }

    can never reach its own else-branch: git writes "error: patch failed..."
    to stderr and the script dies instead. Verified on rohansdesktopry
    2026-09-14 -- it threw System.Management.Automation.RemoteException with
    git's stderr text as the message.

    $ErrorActionPreference is assigned function-scoped here, so it shadows
    the script-level "Stop" for the duration of the call and reverts on
    return.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $null
    )
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0
    $pushed = $false
    try {
        if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $pushed = $true }
        $output = & $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    } finally {
        if ($pushed) { Pop-Location }
    }
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = (@($output) -join "`n")
    }
}

# Resolve-ChromiumStableTag / Test-ChromiumVersionIsNewer live in
# scripts/ChromiumVersion.ps1 and are shared with update.ps1. They used to be
# copy-pasted into both scripts; see that file for the downgrade bug that
# duplication concealed.
. (Join-Path $ScriptsDir "ChromiumVersion.ps1")

function Get-PythonExe {
    <#
    Full path to a python interpreter. Always a full path: Invoke-Logged
    starts processes via CreateProcess, which resolves a bare name against
    the parent's PATH and assumes a .exe extension -- so "python3" would
    miss depot_tools' python3.bat and any Store-alias shim.
    #>
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $cmd) { throw "No python interpreter found on PATH (looked for 'python' then 'python3')." }
    if (-not $cmd.Source) { throw "Resolved python command '$($cmd.Name)' has no file path (Store alias shim?). Install real CPython or put python.exe on PATH." }
    return $cmd.Source
}

function Get-ProgramFilesX86 {
    <#
    ${env:ProgramFiles(x86)} is NOT always present. Verified on rohansdesktopry:
    a PowerShell spawned with a stripped environment had only PROGRAMFILES set,
    so "${env:ProgramFiles(x86)}\Windows Kits\10" silently collapsed to
    "\Windows Kits\10" and every Test-Path against it returned false. That
    turns "tool not installed" into a wrong answer rather than an error, so
    resolve it defensively.
    #>
    $p = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not $p) { $p = Join-Path $env:SystemDrive "Program Files (x86)" }
    return $p
}

function Get-WindowsKitsRoot {
    <#
    Root of the Windows 10/11 SDK install. Registry first, then the
    conventional path -- never %ProgramFiles(x86)% expansion alone, see
    Get-ProgramFilesX86 for why that is unreliable.
    #>
    $root = $null
    try {
        $root = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0" -ErrorAction Stop).InstallationFolder
    } catch { }
    if (-not $root) { $root = Join-Path (Get-ProgramFilesX86) "Windows Kits\10" }
    return $root.TrimEnd('\')
}

function Get-RequiredWindowsSdkVersion {
    <#
    The exact Windows SDK version THIS Chromium requires, read out of
    Chromium's own build/vs_toolchain.py rather than hardcoded here, so it
    tracks automatically whenever `build.ps1 sync` pins a newer Chromium.

    Chromium pins one specific SDK (e.g. 154.0.8037.17 pins 10.0.28000.0) and
    setup_toolchain.py fails hard if it is absent. It is NOT "any recent SDK".
    #>
    $vsToolchain = Join-Path $SrcDir "build\vs_toolchain.py"
    if (-not (Test-Path $vsToolchain)) { return $null }
    $m = Select-String -Path $vsToolchain -Pattern "^SDK_VERSION\s*=\s*'([0-9][0-9.]*)'" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Assert-WindowsToolchain {
    <#
    Verify the Windows SDK Chromium pins is actually installed AND complete,
    before configure does any real work.

    Without this, a missing SDK surfaces only after the zen5 patches and a
    ~104MB PGO download, as a wall of GN/python traceback ending in
    'Path "...\include\<ver>\um" ... does not exist' -- which reads like a
    bug in this pipeline rather than a missing prerequisite. Checked here in
    about a second instead.
    #>
    $required = Get-RequiredWindowsSdkVersion
    if (-not $required) {
        Write-Log "Could not read SDK_VERSION from build\vs_toolchain.py -- skipping the SDK precheck (gn gen will still catch a bad toolchain)." "WARN"
        return
    }

    $kitsRoot = Get-WindowsKitsRoot

    $need = @(
        (Join-Path $kitsRoot "Include\$required\um"),
        (Join-Path $kitsRoot "Include\$required\shared"),
        (Join-Path $kitsRoot "Include\$required\ucrt"),
        (Join-Path $kitsRoot "Lib\$required\um\x64")
    )
    $missing = @($need | Where-Object { -not (Test-Path $_) })
    if ($missing.Count -eq 0) {
        Write-Log "Windows SDK $required present and complete (required by Chromium $(Get-PinnedChromiumTag))."
        return
    }

    # Report what IS installed, so the gap is obvious rather than a guess.
    $installed = @(
        Get-ChildItem (Join-Path $kitsRoot "Include") -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "um") } |
            ForEach-Object { $_.Name } | Sort-Object
    )
    $installedText = if ($installed.Count) { $installed -join ", " } else { "(none with usable headers)" }

    throw @"
Windows SDK $required is required by Chromium $(Get-PinnedChromiumTag) but is not installed (or is incomplete).

Chromium pins one exact SDK version in build\vs_toolchain.py (SDK_VERSION) and
build\toolchain\win\setup_toolchain.py. It will not fall back to an older one.

  Required : $required
  Installed: $installedText
  SDK root : $kitsRoot
  Missing  :
    $($missing -join "`n    ")

To fix, install that exact SDK, then re-run this command:
  * Visual Studio Installer -> Modify -> "Individual components" ->
    tick "Windows 11 SDK ($required)"  (search the version in the filter box), or
  * the standalone Windows SDK installer for $required from
    https://developer.microsoft.com/windows/downloads/windows-sdk/
Chromium also wants the SDK's "Debugging Tools for Windows" component.

Nothing has been built or modified -- this check runs before any real work.
"@
}

function Get-PinnedChromiumTag {
    $f = Join-Path $BuildDir "chromium-tag.txt"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
    return "<unpinned>"
}

function Get-UnknownGnArgs {
    <#
    Returns every argument assigned in args.gn that this Chromium checkout
    does not actually define.

    gn gen reports unknown arguments ONE AT A TIME, so porting an arg set
    (as we did moving off Thorium's non-stock use_sse41/use_avx512/... args)
    otherwise means one slow gn gen per bad line. This lists them all at once.

    `gn args --list` needs an existing build dir, so it is run against the
    same out dir gn gen just rejected -- gn still writes enough there to
    answer the query even when generation failed.
    #>
    param(
        [Parameter(Mandatory)][string]$ArgsGnPath,
        [Parameter(Mandatory)][string]$OutDirRelative
    )
    $assigned = @()
    foreach ($line in (Get-Content $ArgsGnPath)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') { $assigned += $matches[1] }
    }
    $listed = Invoke-NativeCapture -Exe (Join-Path $DepotTools "gn.bat") `
        -Arguments @("args", $OutDirRelative, "--list", "--short") -WorkingDirectory $SrcDir
    if ($listed.ExitCode -ne 0) {
        Write-Log "Could not enumerate gn's known args (exit $($listed.ExitCode)); falling back to gn's own message." "WARN"
        return @()
    }
    $known = @{}
    foreach ($line in ($listed.Output -split "`n")) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') { $known[$matches[1]] = $true }
    }
    if ($known.Count -eq 0) { return @() }
    return @($assigned | Where-Object { -not $known.ContainsKey($_) } | Select-Object -Unique)
}

function Get-JobCount {
    if ($Jobs -gt 0) { return $Jobs }
    $cpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

    # CAP BY AVAILABLE COMMIT, NOT JUST BY CORE COUNT.
    #
    # The 154.0.8037.44 build died at step 3029/66103 with
    #     exit=-1073741523   (0xC0000017 STATUS_NO_MEMORY)
    #     "Your system is low on virtual memory."
    # Nothing was wrong with the build or the toolchain. On this 63.4 GB machine
    # the commit LIMIT was 72.4 GB (63.4 GB RAM + a 9 GB pagefile), about 30 GB
    # was already committed by everyday apps (browser, Edge WebViews, Evernote,
    # a WSL VM), and 32 concurrent clang-cl / bindings-generator steps wanted
    # more than the ~42 GB that left. The two steps that actually died were
    # Python mojo/bindings generators, not compiles.
    #
    # Logical-processor count is the wrong budget for this: what runs out is
    # commit, and the peak consumers are heavy Blink translation units and the
    # generator actions rather than the average clang-cl. ~1.6 GB per job with
    # 8 GB held back for the rest of the system keeps a full build inside the
    # limit; raising the pagefile is what buys full parallelism back.
    #
    # Pass -Jobs explicitly to override this entirely.
    $os = Get-CimInstance Win32_OperatingSystem
    $availBytes = $os.FreeVirtualMemory * 1KB
    $budgetGB = [math]::Floor($availBytes / 1GB) - 8
    if ($budgetGB -lt 0) { $budgetGB = 0 }
    $byCommit = [math]::Floor($budgetGB / 1.6)
    if ($byCommit -lt 4) { $byCommit = 4 }   # never serialise the whole build

    if ($byCommit -lt $cpus) {
        Write-Log ("Using $byCommit parallel jobs instead of ${cpus}: only " +
                   "$([math]::Round($availBytes/1GB,1)) GB of commit is available and a -j$cpus build " +
                   "needs roughly $([math]::Round($cpus*1.6,0)) GB. Exceeding it fails with " +
                   "STATUS_NO_MEMORY mid-build (see Get-JobCount). Close memory-heavy apps or raise " +
                   "the pagefile for full parallelism, or pass -Jobs to override.") "WARN"
        return [int]$byCommit
    }
    return $cpus
}

function Get-DepotToolsEnv {
    <#
    Environment for every depot_tools/gn/ninja child process.

    WINDOWSSDKDIR and ProgramFiles(x86) are set EXPLICITLY rather than
    inherited. With DEPOT_TOOLS_WIN_TOOLCHAIN=0 (local toolchain, which is
    what we use), Chromium's build/vs_toolchain.py does:

        if not 'WINDOWSSDKDIR' in os.environ:
            default = os.path.expandvars('%ProgramFiles(x86)%\\Windows Kits\\10')
            ...
        return NormalizePath(os.environ['WINDOWSSDKDIR'])

    so if ProgramFiles(x86) is absent from the environment the expansion
    yields nothing, the key is never set, and gn gen dies with a bare
    KeyError: 'WINDOWSSDKDIR' (observed on rohansdesktopry 2026-09-15 when
    build.ps1 ran from a shell with a stripped environment). Setting both
    makes the build independent of whatever environment it is launched from
    -- an interactive shell, a scheduled task, or a remote agent.
    #>
    $kits = Get-WindowsKitsRoot

    # Build a MINIMAL PATH instead of inheriting the caller's.
    #
    # vcvarsall.bat appends a lot of directories and then runs `set` through
    # cmd.exe, which has a hard 8191-character command-line limit. Inheriting a
    # bloated PATH blows it and Chromium surfaces it only as
    #   Exception: "[...vcvarsall.bat, amd64_x86, 10.0.28000.0, &&, set]"
    #   failed with error 255
    # whose actual cause ("The input line is too long.") is never shown.
    # Measured on rohansdesktopry 2026-09-15: the launching shell had a PATH of
    # 6798 chars / 143 entries (the real machine+user PATH is 3373 / 71 -- it
    # had accumulated duplicates), which was enough to fail.
    #
    # The build does not need the user's PATH: depot_tools brings its own
    # python/ninja/gn, and vcvarsall adds the VS and SDK directories itself.
    # Keeping this list short and explicit makes the build reproducible from
    # any shell rather than depending on how the launching environment looks.
    $sysRoot = $env:SystemRoot
    $pathParts = @(
        $DepotTools,
        (Join-Path $sysRoot "system32"),
        $sysRoot,
        (Join-Path $sysRoot "System32\Wbem"),
        (Join-Path $sysRoot "System32\WindowsPowerShell\v1.0")
    )
    # Keep git and python reachable by bare name for any script that expects it.
    foreach ($tool in @("git", "python")) {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            $dir = Split-Path -Parent $cmd.Source
            if ($pathParts -notcontains $dir) { $pathParts += $dir }
        }
    }
    $slimPath = ($pathParts | Where-Object { $_ -and (Test-Path $_) }) -join ';'
    if ($slimPath.Length -gt 3000) {
        Write-Log "Constructed PATH is $($slimPath.Length) chars -- unexpectedly long; vcvarsall may hit cmd's 8191-char limit." "WARN"
    }

    # Not named $env -- that reads as the env: PSDrive and is needlessly
    # confusing next to a "$env:..." reference.
    $envVars = @{
        "PATH" = $slimPath
        "DEPOT_TOOLS_WIN_TOOLCHAIN" = "0"
        "NINJA_SUMMARIZE_BUILD" = "1"
        "NINJA_STATUS" = "[%r processes, %f/%t @ %o/s | %e sec] "
        "WINDOWSSDKDIR" = $kits
        "ProgramFiles(x86)" = (Get-ProgramFilesX86)
    }

    # Chromium's build/toolchain/win/setup_toolchain.py parses the output of
    # `set` after vcvarsall and REQUIRES SYSTEMROOT, TEMP and TMP to be present,
    # raising 'Environment variable "TMP" required to be set to valid path'
    # otherwise. It additionally carries HOMEDRIVE/HOMEPATH/USERPROFILE/PATHEXT
    # through for vpython. Since we hand the child a constructed environment
    # rather than inheriting one, set them here instead of hoping the launching
    # shell had them (it may not -- see the PATH note above).
    $tempDir = $env:TEMP
    if (-not $tempDir) { $tempDir = [System.IO.Path]::GetTempPath() }
    $tempDir = $tempDir.TrimEnd('\')
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Force -Path $tempDir | Out-Null }

    $envVars["SYSTEMROOT"]  = $sysRoot
    $envVars["SystemDrive"] = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    $envVars["TEMP"]        = $tempDir
    $envVars["TMP"]         = $tempDir
    $envVars["PATHEXT"]     = if ($env:PATHEXT) { $env:PATHEXT } else { ".COM;.EXE;.BAT;.CMD" }
    $envVars["ComSpec"]     = if ($env:ComSpec) { $env:ComSpec } else { (Join-Path $sysRoot "system32\cmd.exe") }
    foreach ($passthrough in @("USERPROFILE", "HOMEDRIVE", "HOMEPATH", "LOCALAPPDATA", "APPDATA")) {
        $v = [Environment]::GetEnvironmentVariable($passthrough)
        if ($v) { $envVars[$passthrough] = $v }
    }
    if (-not $envVars.ContainsKey("USERPROFILE")) {
        $envVars["USERPROFILE"] = (Join-Path $envVars["SystemDrive"] "Users\Default")
    }

    return $envVars
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
    $py = Get-PythonExe
    Invoke-Logged -Exe $py -Arguments @((Join-Path $ScriptsDir "audit_build.py"), "--repo-root", $RepoRoot)
    Write-Log "Audit written to $(Join-Path $BuildDir 'audit.json')"
}

# ---------------------------------------------------------------------------
# sync  (long-running: fetch Chromium, pin to the current stable tag, sync deps)
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
        Write-Log "Existing checkout found at $SrcDir."
        # NOT `gclient fetch --tags` -- this depot_tools version's `gclient
        # fetch` subcommand doesn't accept --tags at all ("no such option",
        # exit 2, confirmed on rohansdesktopry 2026-09-14). Fetching tags
        # via plain git is unambiguous.
        Write-Log "Fetching Chromium release tags."
        Invoke-Logged -Exe "git" -Arguments @("fetch", "origin", "--tags") -WorkingDirectory $SrcDir -EnvVars $env
    }

    # Pin to the current Chromium STABLE release, never trunk. build/chromium-tag.txt
    # records what we're on so a re-sync with no upstream release is a cheap no-op.
    Write-Log "Resolving current Chromium stable version..."
    $targetTag = Resolve-ChromiumStableTag
    $tagMarkerFile = Join-Path $BuildDir "chromium-tag.txt"
    $currentTag = if (Test-Path $tagMarkerFile) { (Get-Content $tagMarkerFile -Raw).Trim() } else { $null }
    Write-Log "Chromium stable is $targetTag (checkout currently pinned at: $(if ($currentTag) { $currentTag } else { '<unpinned>' }))"

    $tagExists = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $SrcDir, "rev-parse", "--verify", "--quiet", "refs/tags/$targetTag")
    if ($tagExists.ExitCode -ne 0) {
        throw ("Chromium stable tag '$targetTag' is not present in $SrcDir even after fetching tags. " +
               "chromiumdash may have announced a release before the tag was pushed to chromium.googlesource.com -- retry shortly.")
    }

    Write-Log "Checking out Chromium tag $targetTag (this is the version that will be built)."
    Invoke-Logged -Exe "git" -Arguments @("checkout", "-f", "tags/$targetTag") -WorkingDirectory $SrcDir -EnvVars $env

    Write-Log "Running gclient sync -D against that tag's DEPS (pulls V8, WebRTC, ANGLE, etc. Long.)"
    Invoke-Logged -Exe (Join-Path $DepotTools "gclient.bat") `
        -Arguments @("sync", "--with_branch_heads", "--with_tags", "-f", "-R", "-D") `
        -WorkingDirectory $SrcDir -EnvVars $env

    Write-Log "Running gclient runhooks (pulls pinned clang/Windows toolchain files)."
    Invoke-Logged -Exe (Join-Path $DepotTools "gclient.bat") -Arguments @("runhooks") -WorkingDirectory $SrcDir -EnvVars $env

    Set-Content -Path $tagMarkerFile -Value $targetTag
    Write-Log "Sync complete -- Chromium $targetTag."
    Invoke-Audit
}

# ---------------------------------------------------------------------------
# configure (apply zen5 patches, write args.gn, gn gen).
# Fast (minutes), safe to re-run.
# ---------------------------------------------------------------------------
function Invoke-Zen5Patches {
    <#
    Apply the Zen5 compiler-targeting patches to the stock Chromium tree.

    This replaces the old Thorium source overlay entirely. Stock Chromium has
    no use_avx512/use_znver5 GN args and no compiler_opt.gni -- those were
    Thorium's. apply_zen5_patches.py therefore DEFINES our own declare_args()
    and wires -march=znver5 -mtune=znver5 into the x64/Windows compiler and
    ThinLTO-backend flag sites, rather than rewriting somebody else's
    hardcoded -march=skylake-avx512. See patches/zen5/README.md.
    #>
    $marker = Join-Path $BuildDir "patched-chromium-tag.txt"
    $chromiumTag = if (Test-Path (Join-Path $BuildDir "chromium-tag.txt")) {
        (Get-Content (Join-Path $BuildDir "chromium-tag.txt") -Raw).Trim()
    } else { "unknown" }
    $alreadyFor = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { $null }

    if ($alreadyFor -eq $chromiumTag -and -not $Force) {
        Write-Log "Zen5 patches already applied for Chromium $chromiumTag (use -Force to redo)."
        return
    }

    Write-Log "Applying zen5 patches to stock Chromium $chromiumTag (patches/zen5)."
    $py = Get-PythonExe
    Invoke-Logged -Exe $py -Arguments @(
        (Join-Path $ScriptsDir "apply_zen5_patches.py"),
        "--src-dir", $SrcDir, "--capture-diffs", "--patches-dir", $PatchesDir
    )
    Set-Content -Path $marker -Value $chromiumTag -NoNewline
    Write-Log "Zen5 patches applied."
}


function Get-OrDownloadPgoProfile {
    $pgoDir = Join-Path $SrcDir "chrome\build\pgo_profiles"
    $existing = Get-ChildItem $pgoDir -Filter "chrome-win64-*.profdata" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($existing -and -not $Force) { return $existing.FullName }

    Write-Log "Downloading Chromium's official win64 PGO profile (generic, not Zen5-trained -- see docs/BUILD.md 'About PGO')."
    $env = Get-DepotToolsEnv
    # Resolve python to a full path like every other call site does. A bare
    # "python3" is resolved by CreateProcess against THIS process's PATH (the
    # EnvVars we hand the child are not used for locating the exe) and, with
    # no extension, it looks for python3.EXE specifically -- so depot_tools'
    # python3.BAT would not satisfy it.
    $py = Get-PythonExe
    Invoke-Logged -Exe $py -Arguments @(
        "tools/update_pgo_profiles.py", "--target=win64", "update",
        "--gs-url-base=chromium-optimization-profiles/pgo_profiles"
    ) -WorkingDirectory $SrcDir -EnvVars $env
    Invoke-Logged -Exe $py -Arguments @(
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

    # Before ANY real work: a missing Windows SDK otherwise only shows up after
    # the patches and a ~104MB PGO download, as a GN/python traceback.
    Assert-WindowsToolchain

    # zen5 and generic-avx512 both need our declare_args()/flag sites present
    # in the tree. baseline is deliberately stock: no patches at all, so it is
    # a true apples-to-apples comparison point.
    if ($Profile -eq "baseline") {
        Write-Log "Profile 'baseline' -- leaving the Chromium tree completely unpatched (that is the point of this profile)."
    } else {
        Invoke-Zen5Patches
    }

    $pgoPath = Get-OrDownloadPgoProfile
    $pgoPathGn = $pgoPath -replace '\\', '/'

    $argsSrc = switch ($Profile) {
        "baseline"        { Join-Path $GnDir "win_baseline_args.gn" }
        "zen5"            { Join-Path $GnDir "win_zen5_args.gn" }
        "generic-avx512"  { Join-Path $GnDir "win_generic_avx512_args.gn" }
    }
    $commonSrc = Join-Path $GnDir "_common_args.gni.txt"
    if (-not (Test-Path $commonSrc)) { throw "Missing $commonSrc -- every profile shares this block." }

    $outDir = Join-Path $SrcDir "out\thorium-$Profile"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    # The three profiles MUST differ only in their CPU-targeting lines, or the
    # comparison between them is meaningless -- so the shared block is
    # concatenated rather than duplicated per profile.
    $argsText = (Get-Content $commonSrc -Raw) + "`n" + (Get-Content $argsSrc -Raw)
    # Plain string Replace, NOT -replace: the latter treats the replacement as
    # a regex substitution where '$' is special, so a path containing one would
    # be silently mangled.
    $argsText = $argsText.Replace('__PGO_DATA_PATH__', $pgoPathGn)
    Set-Content -Path (Join-Path $outDir "args.gn") -Value $argsText -NoNewline

    Write-Log "Wrote $(Join-Path $outDir 'args.gn') from $commonSrc + $argsSrc"

    if ($Profile -eq "zen5") {
        $verify = Select-String -Path (Join-Path $outDir "args.gn") -Pattern "^\s*use_znver5\s*=\s*true" -Quiet
        if (-not $verify) { throw "gn/win_zen5_args.gn does not set use_znver5 = true -- configuration error." }
    }

    $env = Get-DepotToolsEnv
    Write-Log "Running gn gen out\thorium-$Profile"
    # Tolerate exit 1 so a bad arg can be diagnosed properly below instead of
    # surfacing as gn's one-unknown-arg-at-a-time error.
    Invoke-Logged -Exe (Join-Path $DepotTools "gn.bat") -Arguments @("gen", "out\thorium-$Profile") `
        -WorkingDirectory $SrcDir -EnvVars $env -AllowedExitCodes @(0, 1)
    $genOutput = $script:LastCommandTail
    if ($genOutput -match "Unknown build argument") {
        Write-Log "gn rejected an argument -- checking ALL of ours against this Chromium's real arg list." "WARN"
        $unknown = Get-UnknownGnArgs -ArgsGnPath (Join-Path $outDir "args.gn") -OutDirRelative "out\thorium-$Profile"
        if ($unknown.Count -gt 0) {
            throw ("args.gn contains argument(s) that do not exist in Chromium $(Get-PinnedChromiumTag):`n  " +
                   ($unknown -join "`n  ") +
                   "`nThese are most likely Thorium-only args. Remove them from gn\*.gn, or add them via patches/zen5 if they are meant to be ours.")
        }
        throw "gn gen failed with an unknown build argument, but every arg in args.gn matched gn's list -- see $script:LogFile"
    }
    if (-not (Test-Path (Join-Path $outDir "build.ninja"))) {
        throw "gn gen did not produce build.ninja in $outDir -- see $script:LogFile"
    }

    # Re-audit now that the tree is patched/configured, so build/audit.json
    # reflects what will actually be built, not just what was synced.
    # Invoke-Audit calls Start-Log "audit", which repoints $script:LogFile --
    # so re-point it back afterwards or "Configure complete" lands in audit.log.
    Invoke-Audit
    Open-LogFile (Join-Path $LogsDir "configure.log")

    # The zen5 profile is only meaningful if the pinned clang actually knows
    # -march=znver5. audit_build.py probes for this; fail loudly here rather
    # than letting the build silently fall back to a coarser -march.
    if ($Profile -eq "zen5") {
        $auditPath = Join-Path $BuildDir "audit.json"
        if (Test-Path $auditPath) {
            $auditJson = Get-Content $auditPath -Raw | ConvertFrom-Json
            if ($auditJson.compiler -and $auditJson.compiler.supports_znver5 -eq $false) {
                throw ("The pinned clang does not recognize -march=znver5, so a 'zen5' build would " +
                       "silently degrade to a coarser target. Probe output:`n$($auditJson.compiler.znver5_probe_output)`n" +
                       "Sync against a newer Chromium revision (newer pinned clang), or build -Profile generic-avx512 instead.")
            }
        }
    }

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
    # Stock Chromium targets. `thorium_all`/`thorium_installer` were Thorium's
    # own GN targets and do not exist here -- ninja would fail with "unknown
    # target". `chrome` builds the browser; `mini_installer` produces the
    # self-extracting installer our Inno Setup step unpacks.
    if ($Target.Count -gt 0) {
        Write-Log "Building profile '$Profile' with $jobs jobs -- TARGETS ONLY: $($Target -join ', ')"
        Invoke-Logged -Exe (Join-Path $DepotTools "autoninja.bat") `
            -Arguments (@("-C", "out\thorium-$Profile") + $Target + @("-j$jobs")) `
            -WorkingDirectory $SrcDir -EnvVars $env
        Write-Log "Target build complete. No manifest written -- a partial build is not a release."
        return
    }

    Write-Log "Building profile '$Profile' with $jobs jobs (autoninja chrome + mini_installer)."

    Invoke-Logged -Exe (Join-Path $DepotTools "autoninja.bat") `
        -Arguments @("-C", "out\thorium-$Profile", "chrome", "-j$jobs") `
        -WorkingDirectory $SrcDir -EnvVars $env

    Invoke-Logged -Exe (Join-Path $DepotTools "autoninja.bat") `
        -Arguments @("-C", "out\thorium-$Profile", "mini_installer", "-j$jobs") `
        -WorkingDirectory $SrcDir -EnvVars $env

    $py = Get-PythonExe
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
    # CAP THE TEST LAUNCHER, for the same reason Get-JobCount caps the build.
    #
    # base_unittests uses Chromium's test launcher, which shards across child
    # processes and collects each one's result through a temp "out-of-band
    # success data" file. Starve it and EVERY test reports as failed with
    #     Failed to get out-of-band test success data
    # because the launcher cannot read results back -- not because anything is
    # actually broken.
    #
    # That happened on 2026-09-18 for the .44 build: 9,032 tests "failed" in 620
    # seconds, immediately after a build that had itself exhausted the commit
    # limit. Re-run with --test-launcher-jobs=8 on the SAME binary: 0 out-of-band
    # errors, 52 seconds, 10 real failures. The 9,022 difference was entirely the
    # launcher, and it masked the 10 findings that were worth reading.
    #
    # Reuses Get-JobCount, so this follows available commit rather than core
    # count, then halves it: each launcher child is a whole test process, much
    # heavier than one clang-cl invocation.
    $testJobs = [math]::Max(4, [math]::Floor((Get-JobCount) / 2))
    Write-Log "Running base_unittests with --test-launcher-jobs=$testJobs (a starved launcher reports every test as failed)."
    Invoke-Logged -Exe (Join-Path $SrcDir "$outRel\base_unittests.exe") -Arguments @("--gtest_shuffle", "--gtest_brief=1", "--test-launcher-jobs=$testJobs") -WorkingDirectory $SrcDir -AllowedExitCodes @(0)

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
function Assert-LlvmObjdump {
    <#
    Returns a path to llvm-objdump.exe, fetching it if absent.

    Chromium's clang package does NOT ship llvm-objdump -- it is a separate
    download ("llvmobjdump"), and third_party/llvm-build/ is gitignored inside
    the Chromium checkout. Worse, tools/clang/scripts/update.py notes that
    "updating the main clang package nukes the output dir", so any clang roll
    during `build.ps1 sync` DELETES it again.

    That made `analyze` a step that worked exactly once, on the machine where
    someone had copied the binary in by hand, and broke silently on every
    subsequent update -- precisely the kind of rot this project exists to avoid.

    So fetch it the supported way, version-matched to the pinned clang, and do
    it every time it is missing rather than assuming a previous run left it.
    #>
    $objdump = Join-Path $SrcDir "third_party\llvm-build\Release+Asserts\bin\llvm-objdump.exe"
    if (Test-Path $objdump) { return $objdump }

    Write-Log "llvm-objdump not present (Chromium's clang package excludes it, and a clang roll wipes it). Fetching the matching 'objdump' package."
    $py = Get-PythonExe
    Invoke-Logged -Exe $py -Arguments @(
        (Join-Path $SrcDir "tools\clang\scripts\update.py"),
        "--package=objdump"
    ) -WorkingDirectory $SrcDir -EnvVars (Get-DepotToolsEnv)

    if (-not (Test-Path $objdump)) {
        throw ("llvm-objdump still missing at $objdump after running " +
               "tools/clang/scripts/update.py --package=objdump. Fetch it manually or skip 'analyze'.")
    }
    Write-Log "llvm-objdump fetched to $objdump"
    return $objdump
}

function Invoke-Analyze {
    Start-Log "analyze"
    $outDir = Join-Path $SrcDir "out\thorium-$Profile"
    $binary = Join-Path $outDir "chrome.dll"
    if (-not (Test-Path $binary)) { $binary = Join-Path $outDir "thorium.exe" }
    if (-not (Test-Path $binary)) { throw "No built binary found in $outDir. Run '.\build.ps1 build -Profile $Profile' first." }

    $objdump = Assert-LlvmObjdump
    $symbolizer = Join-Path $SrcDir "third_party\llvm-build\Release+Asserts\bin\llvm-symbolizer.exe"
    # Chromium emits "<file>.<ext>.pdb" (chrome.dll.pdb, thorium.exe.pdb), so
    # append rather than ChangeExtension -- ChangeExtension($binary,".dll.pdb")
    # turned thorium.exe into thorium.dll.pdb, a file that never exists.
    $pdb = "$binary.pdb"
    if (-not (Test-Path $pdb)) {
        Write-Log "No PDB at $pdb -- ISA report will have no function attribution." "WARN"
        $pdb = $null
    }

    $py = Get-PythonExe
    $analyzeArgs = @(
        (Join-Path $ScriptsDir "analyze_isa.py"),
        "--binary", $binary, "--objdump", $objdump, "--symbolizer", $symbolizer,
        "--label", $Profile,
        "--out-json", (Join-Path $BuildDir "isa-report-$Profile.json"),
        "--out-txt", (Join-Path $BuildDir "isa-report-$Profile.txt")
    )
    if ($pdb) { $analyzeArgs += @("--pdb", $pdb) }
    Invoke-Logged -Exe $py -Arguments $analyzeArgs
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

    $py = Get-PythonExe
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
        (Join-Path $env:ProgramFiles "7-Zip\7z.exe"),
        (Join-Path (Get-ProgramFilesX86) "7-Zip\7z.exe")
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
    # Chrome's own layout is kept as chrome.7z ships it: chrome.exe at the top
    # with the payload in a <version>\ subfolder. An earlier revision flattened
    # this, on the theory that the nested form was why the installed browser
    # would not start. That theory was wrong and the change has been reverted;
    # see installer/README.md "Install location" for what the cause actually
    # was and how it was isolated.

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
        (Join-Path (Get-ProgramFilesX86) "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")   # winget's JRSoftware.InnoSetup installs per-user here
    )
    $iscc = $innoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) {
        Write-Log "Inno Setup (ISCC.exe) not found -- installing via winget." "WARN"
        Invoke-Logged -Exe "winget" -Arguments @("install", "--id", "JRSoftware.InnoSetup", "-e",
            "--accept-source-agreements", "--accept-package-agreements")
        $iscc = $innoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $iscc) { throw "Inno Setup still not found after install attempt." }
    }

    # Version and BuildId.
    #
    # This used to pass a 10-char commit sha as the version. That sha became
    # DisplayVersion in Add/Remove Programs, which meant the question the update
    # checker has to answer -- "is the build I just made newer than the one
    # installed?" -- had no answer, because shas do not order. So the version is
    # now the Chromium version, which does, and BuildId carries the identity a
    # version number cannot: two builds of the SAME Chromium version (a flag
    # change, a toolchain roll) differ in BuildId and nowhere else.
    $ids = Get-BuildIdentity
    Write-Log "Installer version=$($ids.Version)  BuildId=$($ids.BuildId)"

    Invoke-Logged -Exe $iscc -Arguments @(
        (Join-Path $RepoRoot "installer\thorium-zen5.iss"),
        "/DAppFilesDir=$($extracted.AppFilesDir)",
        "/DMainExeName=$($extracted.MainExeName)",
        "/DThoriumZen5Version=$($ids.Version)",
        "/DBuildId=$($ids.BuildId)",
        "/DProfileName=$Profile",
        "/DOutputDir=$ReleasesDir"
    )

    # Inno writes into $ReleasesDir, not into the timestamped folder Invoke-Package
    # made, because package runs BEFORE installer. Move it in, so one release
    # folder holds everything that describes a build and `publish` has a single
    # directory to upload.
    $setupExe = Join-Path $ReleasesDir "Thorium-Zen5-Setup-$Profile-$($ids.Version).exe"
    if (-not (Test-Path $setupExe)) {
        throw "Inno Setup reported success but $setupExe is missing -- OutputBaseFilename in installer\thorium-zen5.iss may no longer match what build.ps1 expects."
    }
    $releaseDir = Get-LatestReleaseDir
    if ($releaseDir) {
        # .FullName, not the DirectoryInfo itself. Join-Path stringifies a
        # DirectoryInfo via ToString(), which returns the path AS CONSTRUCTED --
        # relative, for a Get-ChildItem -Filter result -- so the destination
        # resolved against the caller's working directory instead, and Move-Item
        # failed with "Could not find a part of the path" AFTER a successful
        # 63-second compile. Observed on rohansdesktopry 2026-09-16.
        Move-Item $setupExe (Join-Path $releaseDir.FullName (Split-Path $setupExe -Leaf)) -Force
        Write-Log "Installer built and moved into $($releaseDir.FullName)"
    } else {
        Write-Log "Installer built at $setupExe (no packaged release folder found to move it into -- run 'package' first)." "WARN"
    }
}

# ---------------------------------------------------------------------------
# publish  (upload the packaged release to GitHub Releases)
# ---------------------------------------------------------------------------
function Get-BuildIdentity {
    <#
    The version and the unique build identity, both read from
    build/build-manifest-<profile>.json so that the installer, the published
    release and the update checker cannot disagree about what was built.

    Version  -- the Chromium version, e.g. "154.0.8037.17". Orderable, which is
                the whole point; see Invoke-Installer.
    BuildId  -- "<chromium_tag>+<repo_sha10>+<yyyyMMddHHmmss>". Distinguishes
                two builds of the same Chromium version.
    #>
    $manifestPath = Join-Path $BuildDir "build-manifest-$Profile.json"
    if (-not (Test-Path $manifestPath)) {
        throw "No build-manifest-$Profile.json in $BuildDir. Run '.\build.ps1 build -Profile $Profile' first -- a release with no manifest cannot be identified."
    }
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json

    $version = $m.source_revisions.chromium_tag
    if (-not $version -or $version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "build-manifest-$Profile.json has no usable chromium_tag (got '$version'). The installer version has to be orderable; refusing to fall back to a placeholder."
    }

    $repoSha = $m.source_revisions.thorium_zen5_repo_commit
    $repoShort = if ($repoSha) { $repoSha.Substring(0, [Math]::Min(10, $repoSha.Length)) } else { "nosha" }

    # generated_at_utc is ISO-8601; compact it so the id stays filename- and
    # tag-safe. Fall back to now rather than failing: the timestamp is a
    # tiebreaker, not an identity.
    $stamp = try { ([datetime]$m.generated_at_utc).ToUniversalTime().ToString("yyyyMMddHHmmss") }
             catch { (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss") }

    return @{
        Version  = $version
        BuildId  = "$version+$repoShort+$stamp"
        RepoSha  = $repoSha
        Manifest = $m
    }
}

function Get-LatestReleaseDir {
    Get-ChildItem $ReleasesDir -Directory -Filter "thorium-zen5-$Profile-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
}

function Get-RepoSlug {
    <#
    owner/name for gh, resolved from the git remote rather than left to gh's
    cwd inference. Every other stage here is callable from anywhere, and a
    scheduled task will not have its working directory inside this repo.
    #>
    $r = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $RepoRoot, "remote", "get-url", "origin")
    if ($r.ExitCode -ne 0) { throw "Could not read the 'origin' remote from $RepoRoot -- publish needs to know which repository to publish to." }
    $url = $r.Output.Trim()
    if ($url -notmatch '[:/]([^/:]+)/([^/]+?)(\.git)?\s*$') { throw "Unrecognized git remote URL: $url" }
    return "$($Matches[1])/$($Matches[2])"
}

function Invoke-Publish {
    <#
    Upload the newest packaged release for this profile to GitHub Releases.

    The repo is PRIVATE, and that is deliberate: this build sets
    proprietary_codecs, ffmpeg_branding="Chrome" and enable_widevine, none of
    which are ours to redistribute publicly. Publishing here is off-machine
    storage and version history for one person, not distribution. Do not make
    the repo public without first stripping those from the published artifacts.
    #>
    Start-Log "publish"

    $gh = (Get-Command gh -ErrorAction SilentlyContinue)
    if (-not $gh) { throw "GitHub CLI (gh) not found on PATH. Install it, or skip the publish stage." }

    $releaseDir = Get-LatestReleaseDir
    if (-not $releaseDir) { throw "No packaged release for profile '$Profile' under $ReleasesDir. Run '.\build.ps1 package' first." }

    # The install artifact is mini_installer.exe, copied here by Invoke-Package.
    # A release without it is a set of reports about a build nobody can install,
    # and publishing reports without the thing they describe is worse than not
    # publishing. The Inno setup.exe is uploaded too when the optional installer
    # stage produced one, but it is not required.
    $assets = Get-ChildItem $releaseDir.FullName -File
    $mini = $assets | Where-Object { $_.Name -like "thorium_zen5_mini_installer_*" } | Select-Object -First 1
    if (-not $mini) {
        throw "$($releaseDir.FullName) has no thorium_zen5_mini_installer_*.exe. Run '.\build.ps1 package -Profile $Profile' first."
    }

    $ids = Get-BuildIdentity
    $tag = "v$($ids.Version)-$Profile"

    # Release notes from the manifest and the ISA report, so what is published
    # always matches what was measured rather than being retyped.
    $isaTxt = Join-Path $releaseDir.FullName "isa-report-$Profile.txt"
    $fence = [string][char]0x60 * 3     # ``` -- spelled this way so the markdown
                                        # fence is not three escaped backticks
                                        # inside a double-quoted PowerShell string
    $nl = [Environment]::NewLine
    $isaBlock = if (Test-Path $isaTxt) {
        $fence + $nl + (Get-Content $isaTxt -Raw).TrimEnd() + $nl + $fence
    } else {
        "(no ISA report in this release)"
    }
    $clang = ($ids.Manifest.compiler.clang_version_string -split "`n")[0]

    $notes = @"
Personal Zen 5 build. Not a redistribution.

| | |
|---|---|
| Chromium | ``$($ids.Version)`` |
| Chromium commit | ``$($ids.Manifest.source_revisions.chromium_src_commit)`` |
| Profile | ``$Profile`` |
| Build id | ``$($ids.BuildId)`` |
| Repo commit | ``$($ids.RepoSha)`` |
| Compiler | ``$clang`` |

Requires an AMD Zen 5 CPU. This binary uses the full znver5 instruction set
and will fault with an illegal instruction on anything older.

ISA measured in the shipped chrome.dll:
$isaBlock
"@
    $notesFile = Join-Path $env:TEMP "thorium-zen5-notes-$([guid]::NewGuid()).md"
    Set-Content -Path $notesFile -Value $notes -Encoding UTF8

    $slug = Get-RepoSlug
    try {
        $existing = Invoke-NativeCapture -Exe "gh" -Arguments @("release", "view", $tag, "--repo", $slug, "--json", "tagName")
        if ($existing.ExitCode -eq 0) {
            Write-Log "Release $tag already exists on $slug -- uploading assets with --clobber rather than creating a second one." "WARN"
            Invoke-Logged -Exe "gh" -Arguments (@("release", "upload", $tag, "--repo", $slug, "--clobber") + ($assets | ForEach-Object { $_.FullName }))
        } else {
            Write-Log "Creating release $tag on $slug with $($assets.Count) asset(s)."
            Invoke-Logged -Exe "gh" -Arguments (@(
                "release", "create", $tag,
                "--repo", $slug,
                "--title", "Thorium Zen5 $($ids.Version) ($Profile)",
                "--notes-file", $notesFile
            ) + ($assets | ForEach-Object { $_.FullName }))
        }
    } finally {
        Remove-Item $notesFile -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Published $tag."
}

# ---------------------------------------------------------------------------
# all
# ---------------------------------------------------------------------------
function Invoke-All {
    # NOTE: no standalone Invoke-Audit first. audit_build.py requires a synced
    # checkout and exits 1 without one, so on a fresh machine `build.ps1 all`
    # died at step 1 before sync ever ran. Invoke-Sync calls Invoke-Audit at
    # its end (against a tree that actually exists), and Invoke-Configure
    # re-audits after patching -- so audit still runs twice, just at points
    # where it can succeed.
    Invoke-Sync
    Invoke-Configure
    Invoke-Build
    Invoke-Test
    Invoke-Analyze
    Invoke-Benchmark
    Invoke-Package
    # NO Invoke-Installer. mini_installer.exe is the install path: it installs to
    # %LOCALAPPDATA%\Chromium\Application, which is where the browser actually
    # lives on this machine. Invoke-Package already copies it into the release
    # folder, so `all` has an installable artifact without the Inno stage.
    #
    # The Inno stage still exists and still works -- run `.\build.ps1 installer`
    # for it -- but it builds a second, separately-branded install at a second
    # location, and having two install paths half-wired is how the update checker
    # ended up reading a registry key that nothing writes any more. One path.
    Invoke-Publish
    Write-Host "`n=== .\build.ps1 all complete for profile '$Profile' ===" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
try {
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
    "publish"   { Invoke-Publish }
    "all"       { Invoke-All }
}
} finally {
    Close-LogFile
}
