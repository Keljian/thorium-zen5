#Requires -Version 5.1
<#
.SYNOPSIS
    Automated upstream update pipeline: rebuild when Chromium stable moves.

.DESCRIPTION
    upstream update detected -> fetch source -> rebase patches -> configure
    -> build -> test -> ISA analysis -> benchmark -> package -> installer ->
    release candidate.

    Never silently discards upstream changes and never packages a release
    from a partially successful run: each stage must succeed before the
    next runs, and the whole script stops (non-zero exit) on first failure,
    per docs/UPDATES.md.

.PARAMETER CheckOnly
    Only check whether a newer Chromium stable exists; do not fetch or build.
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
$SrcDir = Join-Path $RepoRoot "src"
$BuildDir = Join-Path $RepoRoot "build"
$LogsDir = Join-Path $BuildDir "logs"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
$LogFile = Join-Path $LogsDir "update.log"

function Log([string]$m, [string]$lvl = "INFO") {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$lvl] $m"
    Write-Host $line
    # Best-effort: a locked log file must not abort the pipeline. build.ps1 was
    # killed mid-build exactly this way (sharing violation on Add-Content under
    # $ErrorActionPreference = "Stop").
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
}

Log "=== update.ps1 starting (profile=$Profile, CheckOnly=$CheckOnly) ==="

# Shared with build.ps1 -- no longer duplicated here. See that file for why
# "highest version" rather than "first entry" matters.
. (Join-Path $RepoRoot "scripts\ChromiumVersion.ps1")

# 1. Is there a newer Chromium stable release than the one we last synced?
#    build.ps1 sync pins the checkout to a Chromium stable tag and records it
#    in build/chromium-tag.txt, so that file vs chromiumdash IS the update
#    check. This is a cheap HTTP call -- we never fetch ~30GB just to poll.
if (-not (Test-Path $SrcDir)) {
    throw "No Chromium checkout at $SrcDir. Run '.\build.ps1 sync' at least once first."
}
$tagMarkerFile = Join-Path $BuildDir "chromium-tag.txt"
$localTag  = if (Test-Path $tagMarkerFile) { (Get-Content $tagMarkerFile -Raw).Trim() } else { $null }
$latestTag = Resolve-ChromiumStableTag

# Only ever move FORWARD. Previously this was `$localTag -ne $latestTag`, which
# treats "different" as "newer" -- so a resolution returning an older milestone
# (see ChromiumVersion.ps1) would have driven a full sync+rebuild BACKWARDS,
# discarding shipped security fixes. Equality is not the question; ordering is.
$chromiumChanged = Test-ChromiumVersionIsNewer -Candidate $latestTag -Current $localTag
Log "Chromium: synced=$localTag  latest-stable=$latestTag  newer=$chromiumChanged"
if ($localTag -and -not $chromiumChanged -and $localTag -ne $latestTag) {
    Log "Resolved stable ($latestTag) is NOT newer than the synced tag ($localTag). Refusing to downgrade; treating as up to date." "WARN"
}

# 2. Have we ever produced a build for this profile? If not, treat as changed
#    so a first run does something useful rather than reporting "up to date".
$lastManifest = Join-Path $BuildDir "build-manifest-$Profile.json"
$neverBuilt = -not (Test-Path $lastManifest)
if ($neverBuilt) {
    Log "No prior build-manifest for profile '$Profile' -- treating as changed (first build)."
}

# 3. A Chromium version bump is also the signal that our patch anchors may have
#    moved. We do not try to predict that: apply_zen5_patches.py re-verifies
#    every insertion anchor and exits 3 if one is missing or ambiguous, writing
#    nothing, and the configure stage below treats that as a hard stop. So warn,
#    and let the patcher be the authority.
if ($chromiumChanged -and $localTag) {
    Log "Chromium tag changing $localTag -> $latestTag. The zen5 patches anchor into build/config/compiler/BUILD.gn; apply_zen5_patches.py will verify those anchors and stop the pipeline if upstream moved them." "WARN"
}

$updateAvailable = ($chromiumChanged -or $neverBuilt)

if (-not $updateAvailable) {
    Log "Already on Chromium stable $localTag with a completed build for profile '$Profile'. Nothing to do."
    exit 0
}

if ($CheckOnly) {
    Log "CheckOnly: update available (chromium: $localTag -> $latestTag, never-built=$neverBuilt). Exiting without fetching/building."
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

# 12. publish to GitHub Releases.
#
# Deliberately NOT gated like the stages above. Everything before this line
# produced a good, installable build sitting in releases\; a GitHub outage or
# an expired gh token is a reason to say so, not a reason to mark a two-hour
# build as a failed pipeline. `build.ps1 publish` re-runs on its own.
Log "Stage: publish"
$published = $false
try {
    & "$RepoRoot\build.ps1" publish -Profile $Profile
    $published = $true
} catch {
    Log ("publish failed -- the build itself is fine and is packaged under releases\. " +
         "Re-run '.\build.ps1 publish -Profile $Profile' once the cause is fixed. Detail: $_") "WARN"
}

Copy-Item $curIsa $prevIsa -Force
Log "=== update.ps1 complete: release candidate produced for profile '$Profile' (published=$published) ==="

# 13. Offer it. The machine that builds and the machine being updated are the
#     same one, so this checks releases\ directly rather than making a round
#     trip through GitHub. See scripts/Check-ThoriumUpdate.ps1.
$notifier = Join-Path $RepoRoot "scripts\Check-ThoriumUpdate.ps1"
if (Test-Path $notifier) {
    try { & $notifier -Profile $Profile } catch { Log "Update notification failed (non-fatal): $_" "WARN" }
}

exit 0
