#Requires -Version 5.1
<#
.SYNOPSIS
    Automated upstream update pipeline for Thorium Zen5.

.DESCRIPTION
    upstream update detected -> fetch source -> rebase patches -> configure
    -> build -> test -> ISA analysis -> benchmark -> package -> installer ->
    release candidate.

    Never silently discards upstream changes and never packages a release
    from a partially successful run: each stage must succeed before the
    next runs, and the whole script stops (non-zero exit) on first failure,
    per docs/UPDATES.md.

.PARAMETER CheckOnly
    Only check for new Thorium/Chromium revisions; do not fetch or build.
    Useful for Windows Task Scheduler polling (see docs/UPDATES.md).

.PARAMETER Profile
    Profile to update/rebuild. Default: zen5.

.PARAMETER Yes
    Skip the confirmation prompt before starting the (long) full pipeline.
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$ThoriumMeta = Join-Path $RepoRoot "upstream\Thorium"
$SrcDir = Join-Path $RepoRoot "src"
$BuildDir = Join-Path $RepoRoot "build"
$LogsDir = Join-Path $BuildDir "logs"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
$LogFile = Join-Path $LogsDir "update.log"

function Log([string]$m, [string]$lvl = "INFO") {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$lvl] $m"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Log "=== update.ps1 starting (profile=$Profile, CheckOnly=$CheckOnly) ==="

# 1. Detect new Thorium version
if (-not (Test-Path (Join-Path $ThoriumMeta ".git"))) {
    throw "Thorium meta-repo not found at $ThoriumMeta. Run '.\build.ps1 sync' at least once first."
}
$localRev = & git -C $ThoriumMeta rev-parse HEAD
& git -C $ThoriumMeta fetch origin main --quiet
$remoteRev = & git -C $ThoriumMeta rev-parse origin/main
$thoriumChanged = ($localRev -ne $remoteRev)
Log "Thorium meta-repo: local=$localRev remote=$remoteRev changed=$thoriumChanged"

# 2. Detect Chromium version changes (compare src/chrome/VERSION to what's recorded
#    in the last build manifest, if any -- a lightweight local check that does not
#    require fetching Chromium just to poll).
$chromiumChanged = $true
$lastManifest = Join-Path $BuildDir "build-manifest-$Profile.json"
if ((Test-Path $lastManifest) -and (Test-Path (Join-Path $SrcDir "chrome\VERSION"))) {
    $lastCommit = (Get-Content $lastManifest -Raw | ConvertFrom-Json).source_revisions.chromium_src_commit
    $currentCommit = & git -C $SrcDir rev-parse origin/main 2>$null
    $chromiumChanged = ($lastCommit -ne $currentCommit)
    Log "Chromium: last-built=$lastCommit current-origin-main=$currentCommit changed=$chromiumChanged"
} else {
    Log "No prior build-manifest for profile '$Profile' -- treating as changed (first build)."
}

# 3. Relevant Thorium build-system changes: did any of the files our zen5
#    patches touch change shape upstream since we last patched?
$watchedFiles = @(
    "src\build\config\compiler_opt.gni", "src\build\config\compiler\BUILD.gn",
    "src\build\config\win\BUILD.gn", "src\v8\BUILD.gn"
)
$buildSystemChanged = $false
foreach ($f in $watchedFiles) {
    $diff = & git -C $ThoriumMeta diff $localRev $remoteRev -- $f
    if ($diff) {
        $buildSystemChanged = $true
        Log "Upstream changed a file our zen5 patches touch: $f -- patch conflict risk." "WARN"
    }
}

if (-not ($thoriumChanged -or $chromiumChanged -or $buildSystemChanged)) {
    Log "No upstream changes detected. Nothing to do."
    exit 0
}

if ($CheckOnly) {
    Log "CheckOnly: changes detected (thorium=$thoriumChanged chromium=$chromiumChanged build-system=$buildSystemChanged). Exiting without fetching/building."
    exit 10   # distinct code: "update available" for Task Scheduler / scripts to key off of
}

if (-not $Yes) {
    $resp = Read-Host "Upstream changes detected. Run the full fetch/build/test/package pipeline now? This can take hours. [y/N]"
    if ($resp -notin @("y", "Y", "yes", "Yes")) { Log "User declined. Exiting."; exit 0 }
}

# 4. fetch source (build.ps1 sync handles both Chromium and the Thorium meta-repo)
Log "Stage: sync"
& "$RepoRoot\build.ps1" sync
if ($LASTEXITCODE -ne 0) { Log "sync failed -- stopping pipeline." "ERROR"; exit 1 }

# 5. rebase / reapply zen5 patches -- build.ps1 configure calls
#    apply_zen5_patches.py, which exits 3 (and configure propagates the
#    failure) if a marker is no longer found. We surface that distinctly.
Log "Stage: configure (reapplies zen5 patches; stops on patch conflict)"
try {
    & "$RepoRoot\build.ps1" configure -Profile $Profile -Force
    if ($LASTEXITCODE -ne 0) { throw "configure exited $LASTEXITCODE" }
} catch {
    Log "PATCH CONFLICT or configure failure: $_. Upstream Thorium's compiler-flag files changed shape. See patches/zen5/README.md 'Regenerating after upstream changes'. STOPPING -- no build will be attempted from an unpatched/half-patched tree." "ERROR"
    exit 2
}

# 6. rebuild
Log "Stage: build"
& "$RepoRoot\build.ps1" build -Profile $Profile
if ($LASTEXITCODE -ne 0) { Log "build failed -- stopping pipeline." "ERROR"; exit 1 }

# 7. test
Log "Stage: test"
& "$RepoRoot\build.ps1" test -Profile $Profile
if ($LASTEXITCODE -ne 0) { Log "tests failed -- stopping pipeline (no release will be produced)." "ERROR"; exit 1 }

# 8. ISA analysis
Log "Stage: analyze"
& "$RepoRoot\build.ps1" analyze -Profile $Profile
if ($LASTEXITCODE -ne 0) { Log "ISA analysis failed -- stopping." "ERROR"; exit 1 }

# 8b. Regression check against the previous successful build's ISA report
$prevIsa = Join-Path $BuildDir "isa-report-$Profile.previous.json"
$curIsa = Join-Path $BuildDir "isa-report-$Profile.json"
if (Test-Path $prevIsa) {
    $prev = Get-Content $prevIsa -Raw | ConvertFrom-Json
    $cur = Get-Content $curIsa -Raw | ConvertFrom-Json
    if ($cur.avx512_total -lt $prev.avx512_total) {
        Log "REGRESSION FLAG: AVX-512 instruction count decreased ($($prev.avx512_total) -> $($cur.avx512_total)). Not auto-rejecting per spec -- review build/isa-report-$Profile.json and .txt before releasing." "WARN"
    }
}

# 9. benchmark
Log "Stage: benchmark"
& "$RepoRoot\build.ps1" benchmark -Profile $Profile
if ($LASTEXITCODE -ne 0) { Log "benchmark failed -- stopping (non-fatal data, but per spec we don't package without it)." "ERROR"; exit 1 }

# 10. package only if everything above succeeded
Log "Stage: package"
& "$RepoRoot\build.ps1" package -Profile $Profile
if ($LASTEXITCODE -ne 0) { Log "package failed -- stopping." "ERROR"; exit 1 }

# 11. installer -- only now, after full validation
Log "Stage: installer"
& "$RepoRoot\build.ps1" installer -Profile $Profile
if ($LASTEXITCODE -ne 0) { Log "installer build failed -- stopping." "ERROR"; exit 1 }

Copy-Item $curIsa $prevIsa -Force
Log "=== update.ps1 complete: release candidate produced for profile '$Profile' ==="
exit 0
