#Requires -Version 5.1
<#
.SYNOPSIS
    Nightly pipeline: rebuild when Chromium stable moves, then deploy.

.DESCRIPTION
    sync -> configure -> verify -> build -> test -> analyze -> package ->
    publish -> deploy. Each gating stage must pass before the next runs, and
    no release is packaged from a partial run. See docs/UPDATES.md.

    Rebuild is needed when upstream stable is newer than the BUILT binary,
    when the checkout is ahead of the binary, or when the binary is newer than
    the newest packaged release (a run that compiled and then failed). The
    synced tag alone is not the test: a run that dies after sync would
    otherwise look up to date forever.

    Every run, even one with nothing to build, also:
      * publishes the newest release if it was never published (a failed
        publish is retried on the next run, not forgotten), and
      * deploys it (Check-ThoriumUpdate.ps1): installs if the browser is
        closed, otherwise flags it on the desktop.

    Failures raise a toast. A run that never finished (killed by the task's
    time limit, a crash, a reboot) is detected and reported by the next run.

.PARAMETER FromStage
    Resume from this stage, e.g. after a test failure is understood:
        .\update.ps1 -Yes -FromStage package
    Stages: sync configure verify build test analyze package publish.
    Skipping verify skips the check that stops a silently generic build.

.PARAMETER Force
    Run the pipeline even when everything is up to date (rebuilds the
    current tag).

.NOTES
    Exit codes:
        0   nothing to do, or the pipeline completed
        1   a stage failed (build\logs\update.log)
        2   the zen5 patch no longer applies, or configure failed
        3   verify failed: the CPU targeting did not reach the build files
        10  -CheckOnly: a rebuild is needed
        11  another run, or a build in the same out dir, is in progress
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [ValidateSet("baseline", "zen5")]
    [string]$Profile = "zen5",
    [switch]$Yes,
    [switch]$Force,
    [ValidateSet("sync", "configure", "verify", "build", "test", "analyze", "package", "publish")]
    [string]$FromStage = "sync"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "scripts\Common.ps1")

$RepoRoot = $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot "src"
$LogFile  = Join-Path $ThoriumLogs "update.log"
$RunState = Join-Path $ThoriumBuild "run-state.json"

function Log([string]$m, [string]$lvl = "INFO") { Write-Host (Add-LogLine -Path $LogFile -Message $m -Level $lvl) }

function Stop-Run([int]$Code, [string]$Failure = $null) {
    # Every exit after the lock goes through here, so run-state.json always
    # records how the run ended. A file left saying "running" means the
    # process died without reaching this.
    if ($Failure) {
        Log $Failure "ERROR"
        $short = if ($Failure.Length -gt 240) { $Failure.Substring(0, 240) + "..." } else { $Failure }
        $null = Show-ThoriumToast -Title "Chromium Zen 5 build failed" -Body "$short Log: build\logs\update.log"
    }
    if (-not $CheckOnly) {
        try {
            [ordered]@{ state = "finished"; exit = $Code; pid = $PID
                        started = $script:StartedAt; finished = (Get-Date).ToString("o") } |
                ConvertTo-Json | Set-Content -Path $RunState -Encoding ASCII
        } catch { }
    }
    exit $Code
}

Log "=== update.ps1 starting (profile=$Profile, CheckOnly=$CheckOnly, FromStage=$FromStage, Force=$Force) ==="

# ---------------------------------------------------------------------------
# One run at a time. Two runs collide on `git fetch` in the shared checkout.
# A named mutex is released by the OS if the process dies.
# ---------------------------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\ThoriumZen5-update')
$owned = try { $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $true }
if (-not $owned) {
    Log "Another update.ps1 is running; not starting a second. Follow it with: Get-Content build\logs\update.log -Wait" "WARN"
    exit 11
}
$builders = @(Get-CimInstance Win32_Process -Filter "Name='siso.exe' OR Name='ninja.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -match [regex]::Escape("thorium-$Profile") })
if ($builders.Count -gt 0) {
    # No update.ps1 holds the lock, so this is a hand-run build or an orphan
    # left by a killed run. Say so rather than skipping silently every night.
    $msg = "A build is already running in out\thorium-$Profile ($($builders[0].Name) pid $($builders[0].ProcessId)) outside update.ps1. Skipped this run."
    Log $msg "WARN"
    if (-not $CheckOnly) { $null = Show-ThoriumToast -Title "Chromium Zen 5 build skipped" -Body $msg }
    exit 11
}

trap { Stop-Run 1 "Unhandled failure: $_" }

if (-not $CheckOnly) {
    $prev = try { Get-Content $RunState -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
    if ($prev -and $prev.state -eq "running") {
        $msg = "The previous run (started $($prev.started), pid $($prev.pid)) never finished: it was killed, crashed, or the machine restarted. Its log is in build\logs\update.log."
        Log $msg "WARN"
        $null = Show-ThoriumToast -Title "Last Chromium Zen 5 build did not finish" -Body $msg
    }
    $script:StartedAt = (Get-Date).ToString("o")
    [ordered]@{ state = "running"; pid = $PID; started = $script:StartedAt } |
        ConvertTo-Json | Set-Content -Path $RunState -Encoding ASCII
}

# ---------------------------------------------------------------------------
# What exists: upstream, synced, built, released, installed
# ---------------------------------------------------------------------------
if (-not (Test-Path $SrcDir)) { throw "No Chromium checkout at $SrcDir. Run '.\build.ps1 sync' once first." }
$tagFile      = Join-Path $ThoriumBuild "chromium-tag.txt"
$localTag     = if (Test-Path $tagFile) { (Get-Content $tagFile -Raw).Trim() } else { $null }
$latestTag    = Resolve-ChromiumStableTag
$builtVersion = Get-FileVersionOrNull (Join-Path $SrcDir "out\thorium-$Profile\chrome.exe")
$release      = Get-NewestRelease -Profile $Profile
$released     = if ($release) { $release.Version } else { $null }
$installed    = Get-InstalledBuild
Log ("Versions: upstream=$latestTag synced=$localTag built=$builtVersion released=$released " +
     "installed=$(if ($installed) { $installed.Version } else { 'none' })")

if ($localTag -and $latestTag -ne $localTag -and -not (Test-ChromiumVersionIsNewer -Candidate $latestTag -Current $localTag)) {
    Log "Upstream stable $latestTag is older than the synced $localTag; not treating it as an update." "WARN"
}
$reasons = @()
if (-not $builtVersion -or -not (Test-Path (Join-Path $ThoriumBuild "build-manifest-$Profile.json"))) { $reasons += "no usable previous build" }
if ($builtVersion -and (Test-ChromiumVersionIsNewer -Candidate $latestTag -Current $builtVersion)) { $reasons += "upstream $latestTag is newer than built $builtVersion" }
if ($localTag -and $builtVersion -and (Test-ChromiumVersionIsNewer -Candidate $localTag -Current $builtVersion)) { $reasons += "checkout $localTag is ahead of built $builtVersion" }
if ($builtVersion -and (Test-ChromiumVersionIsNewer -Candidate $builtVersion -Current $released)) { $reasons += "built $builtVersion was never packaged" }
$explicit = $Force -or $PSBoundParameters.ContainsKey('FromStage')

# ---------------------------------------------------------------------------
# Clang roll reminder. The two toolchain workarounds are pinned to a clang;
# one bug is already fixed upstream. See docs/TOOLCHAIN-BUGS.md.
# ---------------------------------------------------------------------------
function Test-ClangRoll {
    $clangFile = Join-Path $ThoriumBuild "clang-revision.txt"
    $upd = Join-Path $SrcDir "tools\clang\scripts\update.py"
    $m = if (Test-Path $upd) { Select-String -Path $upd -Pattern "^CLANG_REVISION = '([^']+)'" | Select-Object -First 1 }
    if (-not $m) { Log "Could not read CLANG_REVISION; workaround re-test reminder disabled." "WARN"; return }
    $cur = $m.Matches[0].Groups[1].Value
    $prevClang = if (Test-Path $clangFile) { (Get-Content $clangFile -Raw).Trim() } else { $null }
    if ($prevClang -and $prevClang -ne $cur) {
        Log ("clang rolled $prevClang -> $cur. Re-test the workarounds in gn/win_zen5_args.gn (zen5_slp_max_reg_size, " +
             "the tail-merge ldflag) with the root_store_tool canary; delete thinlto-cache first. See docs/TOOLCHAIN-BUGS.md.") "WARN"
    }
    Set-Content -Path $clangFile -Value $cur
}

function Invoke-Publish {
    # Non-fatal: the build is fine and packaged; publish is retried next run.
    try {
        & (Join-Path $RepoRoot "build.ps1") publish -Profile $Profile
        return $true
    } catch {
        Log "publish failed; it will be retried on the next run. Detail: $_" "WARN"
        return $false
    }
}

function Invoke-Deploy {
    try {
        & (Join-Path $RepoRoot "scripts\Check-ThoriumUpdate.ps1") -Profile $Profile
        Log "deploy: Check-ThoriumUpdate exit $LASTEXITCODE (0 current/installed, 10 waiting for the browser to close)."
    } catch { Log "deploy failed: $_" "WARN" }
}

if ($reasons.Count -eq 0 -and -not $explicit) {
    if ($CheckOnly) { Log "CheckOnly: up to date."; exit 0 }
    Test-ClangRoll
    if ($release -and -not $release.Published) {
        Log "Newest release $($release.Name) was never published; publishing now."
        $null = Invoke-Publish
    }
    Invoke-Deploy
    Log "Up to date: upstream $latestTag, built $builtVersion, released $released."
    Stop-Run 0
}
if ($CheckOnly) { Log "CheckOnly: rebuild needed ($($reasons -join '; '))."; exit 10 }
if ($reasons) { Log "Rebuilding: $($reasons -join '; ')." "WARN" }

if (-not $Yes) {
    $resp = Read-Host "Run the full sync/build/test/package pipeline now? It takes hours. [y/N]"
    if ($resp -notmatch '^(y|yes)$') { Log "Declined."; Stop-Run 0 }
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
$StageOrder = @("sync", "configure", "verify", "build", "test", "analyze", "package", "publish")
$fromIndex = [array]::IndexOf($StageOrder, $FromStage)
if ($fromIndex -gt 0) { Log "Resuming from '$FromStage'; earlier stages are skipped." "WARN" }
function Test-Stage([string]$Name) {
    if ([array]::IndexOf($StageOrder, $Name) -ge $fromIndex) { Log "Stage: $Name"; return $true }
    Log "Skipping stage '$Name' (-FromStage $FromStage)."
    return $false
}

function Invoke-Stage {
    # -Params is a HASHTABLE splat. An array splat binds every element
    # positionally, so "-Profile" arrives as a value and build.ps1 rejects it.
    # build.ps1 throws on failure; $LASTEXITCODE is not meaningful after a .ps1.
    param([string]$Command, [hashtable]$Params = @{}, [string]$FailMessage, [int]$FailExit = 1)
    try { & (Join-Path $RepoRoot "build.ps1") $Command @Params }
    catch { Stop-Run $FailExit "$FailMessage Detail: $_" }
}

if (Test-Stage "sync") {
    Invoke-Stage "sync" -FailMessage "sync failed; nothing was built."
}
Test-ClangRoll

if (Test-Stage "configure") {
    Invoke-Stage "configure" -Params @{ Profile = $Profile } -FailExit 2 -FailMessage (
        "configure failed. If apply_zen5_patches.py exited 3, upstream Chromium moved the anchors the zen5 " +
        "patch inserts at (build/config/compiler/BUILD.gn); see patches/zen5/README.md. Nothing was built.")
}

if (Test-Stage "verify") {
    # A native powershell.exe, so $LASTEXITCODE is meaningful here.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "verify-source.ps1") -Profile $Profile
    if ($LASTEXITCODE -ne 0) {
        Stop-Run 3 ("verify failed (exit $LASTEXITCODE): the CPU targeting did not reach the generated build files, " +
                    "or the checkout differs from the tag unexpectedly. See build\source-verification.json. Nothing was built.")
    }
}

if (Test-Stage "build") {
    Invoke-Stage "build" -Params @{ Profile = $Profile } -FailMessage "build failed."
}
if (Test-Stage "test") {
    Invoke-Stage "test" -Params @{ Profile = $Profile } -FailMessage "tests failed; no release was produced."
}
if (Test-Stage "analyze") {
    Invoke-Stage "analyze" -Params @{ Profile = $Profile } -FailMessage "ISA analysis failed; no release was produced."
    $prevIsa = Join-Path $ThoriumBuild "isa-report-$Profile.previous.json"
    $curIsa  = Join-Path $ThoriumBuild "isa-report-$Profile.json"
    if ((Test-Path $prevIsa) -and (Test-Path $curIsa)) {
        $p = Get-Content $prevIsa -Raw | ConvertFrom-Json
        $c = Get-Content $curIsa -Raw | ConvertFrom-Json
        if ($c.avx512_total -lt $p.avx512_total) {
            Log "AVX-512 instruction count fell ($($p.avx512_total) -> $($c.avx512_total)). Not blocking; review build\isa-report-$Profile.txt." "WARN"
        }
    }
    if (Test-Path $curIsa) { Copy-Item $curIsa $prevIsa -Force }
}
if (Test-Stage "package") {
    Invoke-Stage "package" -Params @{ Profile = $Profile } -FailMessage "package failed."
}
$published = $false
if (Test-Stage "publish") { $published = Invoke-Publish }

Log "=== pipeline complete for '$Profile' (published=$published) ==="
Invoke-Deploy
Stop-Run 0
