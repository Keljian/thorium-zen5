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

function Resolve-ThoriumLatestStableTag {
    # Kept in sync with the identical function in build.ps1 -- see the long
    # comment there for why we track the latest stable RELEASE TAG and not the
    # `main` branch (main goes stale for months while per-version branches ship).
    $uri = "https://api.github.com/repos/Alex313031/Thorium/releases/latest"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = "thorium-zen5-update.ps1" } -UseBasicParsing
    } catch {
        throw "Failed to resolve Thorium's latest stable release from $uri -- check network / GitHub rate limits: $_"
    }
    if (-not $resp.tag_name) { throw "GitHub releases/latest returned no tag_name for Alex313031/Thorium." }
    return [string]$resp.tag_name
}

# 1. Detect new Thorium version.
#    build.ps1 sync checks the meta-repo out at a release TAG (detached HEAD,
#    shallow) and records it in build/thorium-tag.txt. So the meaningful
#    comparison is "tag we last synced" vs "latest stable tag upstream" --
#    NOT HEAD vs origin/main, which on a `--depth 1 --branch <tag>` clone has
#    no origin/main ref to resolve at all.
if (-not (Test-Path (Join-Path $ThoriumMeta ".git"))) {
    throw "Thorium meta-repo not found at $ThoriumMeta. Run '.\build.ps1 sync' at least once first."
}
$tagMarkerFile = Join-Path $BuildDir "thorium-tag.txt"
$localTag = if (Test-Path $tagMarkerFile) { (Get-Content $tagMarkerFile -Raw).Trim() } else { $null }
$latestTag = Resolve-ThoriumLatestStableTag
$thoriumChanged = ($localTag -ne $latestTag)
Log "Thorium meta-repo: synced-tag=$localTag latest-stable-tag=$latestTag changed=$thoriumChanged"

# 2. Detect Chromium version changes (compare src/chrome/VERSION to what's recorded
#    in the last build manifest, if any -- a lightweight local check that does not
#    require fetching Chromium just to poll).
$chromiumChanged = $true
$lastManifest = Join-Path $BuildDir "build-manifest-$Profile.json"
if ((Test-Path $lastManifest) -and (Test-Path (Join-Path $SrcDir "chrome\VERSION"))) {
    $lastCommit = (Get-Content $lastManifest -Raw | ConvertFrom-Json).source_revisions.chromium_src_commit
    $ErrorActionPreference = "Continue"   # native stderr must not be terminating here
    $currentCommit = (& git -C $SrcDir rev-parse origin/main 2>$null | Select-Object -First 1)
    $ErrorActionPreference = "Stop"
    $chromiumChanged = ($lastCommit -ne $currentCommit)
    # Honest about what this does and doesn't tell us: origin/main here is
    # whatever the LAST sync fetched, not live upstream (we deliberately don't
    # fetch ~30GB just to poll). So this detects "we built older than what we
    # already have on disk"; genuinely new upstream Chromium arrives via the
    # Thorium tag bump above, which is what actually pins the Chromium version.
    Log "Chromium: last-built=$lastCommit last-fetched-origin/main=$currentCommit changed=$chromiumChanged"
} else {
    Log "No prior build-manifest for profile '$Profile' -- treating as changed (first build)."
}

# 3. Relevant Thorium build-system changes: did any of the files our zen5
#    patches touch change shape upstream?
#
#    This used to `git diff $localRev $remoteRev -- <path>`, which cannot work
#    now: the meta-repo is a --depth 1 tag checkout, so both revisions are not
#    present locally to diff, and the pathspecs were written with backslashes
#    which git does not match against its forward-slash index anyway -- so the
#    check silently reported "no change" every time.
#
#    A tag bump is itself the signal that the patch targets may have moved.
#    We don't guess: apply_zen5_patches.py verifies each insertion marker and
#    fails loudly (exit 3) if one is gone, and stage 5 below treats that as a
#    hard stop. So flag the risk, and let the patcher be the authority.
$watchedFiles = @(
    "src/build/config/compiler_opt.gni", "src/build/config/compiler/BUILD.gn",
    "src/build/config/win/BUILD.gn", "src/v8/BUILD.gn"
)
$buildSystemChanged = $thoriumChanged
if ($buildSystemChanged) {
    Log "Thorium tag changed ($localTag -> $latestTag). The zen5 patches target these files upstream:" "WARN"
    foreach ($f in $watchedFiles) { Log "    $f" "WARN" }
    Log "  apply_zen5_patches.py re-verifies every insertion marker during configure and stops the pipeline if any moved." "WARN"
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

function Invoke-Stage {
    <#
    Run one build.ps1 stage and stop the pipeline if it fails.

    The previous code did `& "$RepoRoot\build.ps1" <stage>` then checked
    $LASTEXITCODE. That check was meaningless: $LASTEXITCODE is only set by
    NATIVE commands, so after invoking a .ps1 it still holds whatever value
    the last native process left behind -- possibly from deep inside
    build.ps1, including an exit code that Invoke-Logged deliberately
    tolerated via -AllowedExitCodes. It could therefore both miss a real
    failure and invent one that did not happen.

    build.ps1 runs with $ErrorActionPreference = "Stop" and throws on any
    stage failure, so the exception IS the reliable signal.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$StageArgs,
        [string]$FailMessage = $null,
        [int]$FailExit = 1
    )
    Log "Stage: $Name"
    try {
        & "$RepoRoot\build.ps1" @StageArgs
    } catch {
        $msg = if ($FailMessage) { $FailMessage } else { "$Name failed -- stopping pipeline (no release will be produced)." }
        Log "$msg Detail: $_" "ERROR"
        exit $FailExit
    }
}

# 4. fetch source (build.ps1 sync handles both Chromium and the Thorium meta-repo)
Invoke-Stage -Name "sync" -StageArgs @("sync")

# 5. rebase / reapply zen5 patches -- build.ps1 configure calls
#    apply_zen5_patches.py, which exits 3 (and configure propagates the
#    failure) if a marker is no longer found. We surface that distinctly.
Invoke-Stage -Name "configure (reapplies zen5 patches; stops on patch conflict)" `
    -StageArgs @("configure", "-Profile", $Profile, "-Force") `
    -FailMessage "PATCH CONFLICT or configure failure. Upstream Thorium's compiler-flag files may have changed shape. See patches/zen5/README.md 'Regenerating after upstream changes'. STOPPING -- no build will be attempted from an unpatched/half-patched tree." `
    -FailExit 2

# 6. rebuild
Invoke-Stage -Name "build" -StageArgs @("build", "-Profile", $Profile)

# 7. test
Invoke-Stage -Name "test" -StageArgs @("test", "-Profile", $Profile) -FailMessage "tests failed -- stopping pipeline (no release will be produced)."

# 8. ISA analysis
Invoke-Stage -Name "analyze" -StageArgs @("analyze", "-Profile", $Profile) -FailMessage "ISA analysis failed -- stopping."

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
Invoke-Stage -Name "benchmark" -StageArgs @("benchmark", "-Profile", $Profile) -FailMessage "benchmark failed -- stopping (non-fatal data, but per spec we don't package without it)."

# 10. package only if everything above succeeded
Invoke-Stage -Name "package" -StageArgs @("package", "-Profile", $Profile) -FailMessage "package failed -- stopping."

# 11. installer -- only now, after full validation
Invoke-Stage -Name "installer" -StageArgs @("installer", "-Profile", $Profile) -FailMessage "installer build failed -- stopping."

Copy-Item $curIsa $prevIsa -Force
Log "=== update.ps1 complete: release candidate produced for profile '$Profile' ==="
exit 0
