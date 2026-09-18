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

.PARAMETER Install
    After a successful build, silently install it on THIS machine with
    mini_installer.exe (user-level, no UI, does not launch the browser).
    Off by default: the pipeline's normal ending is to OFFER the update via
    scripts\Check-ThoriumUpdate.ps1 rather than to replace a running browser
    underneath you.

.PARAMETER SkipBenchmark
    Skip the benchmark stage entirely. The benchmark is non-gating either way
    (see the stage comment); this just saves the time.

.NOTES
    Exit codes:
        0   nothing to do, or the pipeline completed
        1   a stage failed (see build\logs\update.log)
        2   patch conflict -- upstream moved the zen5 patch anchors
        3   source verification failed: the CPU targeting did not reach the
            generated build files. Nothing is built from an unverified tree.
        10  -CheckOnly: a rebuild is needed
        11  another run (or a build in the same out dir) is already in progress
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",
    [switch]$Yes,
    [switch]$Install,
    [switch]$SkipBenchmark
)

$ErrorActionPreference = "Stop"

# See the same block in verify-source.ps1. MIMALLOC_VERBOSE=1 at user scope made
# every git call in this pipeline print ~70 lines of allocator statistics, which
# the verify stage then parsed as source modifications. Silenced for OUR child
# processes only; the user's environment is not modified.
$env:MIMALLOC_VERBOSE     = '0'
$env:MIMALLOC_SHOW_STATS  = '0'
$env:MIMALLOC_SHOW_ERRORS = '0'

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

# Toast + tray notification, shared with Check-ThoriumUpdate.ps1.
. (Join-Path $RepoRoot "scripts\ThoriumNotify.ps1")

# A FAILED BUILD USED TO TELL NOBODY ANYTHING.
#
# The success path notified; the failure path exited non-zero into a log that
# only gets read by someone who already suspects something is wrong. The worst
# case is the quietest one: a milestone bump breaks the zen5 patch anchors, the
# pipeline stops at configure exactly as designed, and from the outside that is
# indistinguishable from Chromium simply not having shipped a release. You
# would notice weeks later, having silently stopped taking security updates.
#
# This trap covers anything that throws OUTSIDE a stage -- chromiumdash being
# unreachable, a missing checkout, a bad tag. Stage failures are caught in
# Invoke-Stage, which exits directly and so never reaches a trap.
trap {
    Log "Unhandled failure: $_" "ERROR"
    try {
        Show-ThoriumFailureNotice -Stage "update.ps1" -Detail "$_" -LogPath $LogFile -TimeoutMinutes 5 | Out-Null
    } catch {
        Log "Could not raise the failure notification: $_" "WARN"
    }
    exit 1
}

# 0. ONE PIPELINE AT A TIME.
#
#    Two concurrent runs corrupt each other. Both call `git fetch` on the same
#    ~30 GB checkout and git fails the ref update outright:
#
#        error: fetching ref refs/remotes/origin/main failed:
#               incorrect old value provided
#
#    Observed 2026-09-18 11:38:52, when a second run started 22 seconds into the
#    first one's sync. The second died in sync; the first survived and went on to
#    build. Which one survives is a coin toss, and both write to the same
#    update.log, interleaved, which makes the outcome nearly unreadable
#    afterwards. Double-clicking update.cmd twice is all it takes.
#
#    A named mutex rather than a PID file: the OS releases it when the process
#    dies, so a crash or a kill cannot leave a stale lock behind.
$script:UpdateMutex = New-Object System.Threading.Mutex($false, 'Global\ThoriumZen5-update')
if (-not $script:UpdateMutex.WaitOne(0)) {
    Log ("Another update.ps1 is already running. Refusing to start a second one: concurrent runs " +
         "collide on 'git fetch' in the shared checkout and interleave into this log. Watch the " +
         "existing run with: Get-Content build\logs\update.log -Wait") "WARN"
    exit 11
}

#    The mutex only sees runs that carry this code. A build already in flight --
#    started before this lock existed, or by a hand-run of build.ps1 -- is
#    detected separately, by looking for the build driver working in our out dir.
$builders = @(Get-CimInstance Win32_Process -Filter "Name='siso.exe' OR Name='ninja.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape("thorium-$Profile") })
if ($builders.Count -gt 0) {
    Log ("A build is already running in out\thorium-$Profile ($($builders[0].Name) pid " +
         "$($builders[0].ProcessId)). Refusing to start a second pipeline on the same output " +
         "directory. Wait for it to finish, or stop it first.") "WARN"
    exit 11
}

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

# 2. WHAT WAS ACTUALLY BUILT -- which is NOT what was last synced.
#
#    THIS IS THE BUG THAT SILENCED THE PIPELINE. The up-to-date test used to be
#    chromium-tag.txt (written by the `sync` stage) versus chromiumdash. So a
#    run that synced successfully and then FAILED at any later stage had already
#    advanced the tag file -- and every subsequent run concluded "already up to
#    date, nothing to do", while the machine kept running the OLD build. The
#    pipeline goes permanently quiet, and from outside that is indistinguishable
#    from a quiet week upstream. It is exactly the silent-security-drift failure
#    the trap at the top of this file was written to prevent, and the trap could
#    not see it because nothing threw.
#
#    It happened for real on 2026-09-18: sync moved .17 -> .44, configure died
#    on the argument-splat bug above, and the next check reported nothing to do
#    with a .17 browser installed and .44 shipped.
#
#    Ground truth for "what is built" is the version resource of the binary we
#    produced. A marker file can drift from reality; the binary cannot.
$lastManifest = Join-Path $BuildDir "build-manifest-$Profile.json"
$builtExe = Join-Path $SrcDir "out\thorium-$Profile\chrome.exe"
$builtVersion = $null
if (Test-Path $builtExe) {
    $builtVersion = (Get-Item $builtExe).VersionInfo.FileVersion
}

# What is actually installed on this machine, for the same reason.
$installedExe = Join-Path $env:LOCALAPPDATA "Chromium\Application\chrome.exe"
$installedVersion = $null
if (Test-Path $installedExe) {
    $installedVersion = (Get-Item $installedExe).VersionInfo.FileVersion
}

Log "Versions: upstream-stable=$latestTag  synced=$localTag  built=$builtVersion  installed=$installedVersion"

$neverBuilt = (-not $builtVersion) -or (-not (Test-Path $lastManifest))
if ($neverBuilt) {
    Log "No usable prior build for profile '$Profile' (built=$builtVersion, manifest=$(Test-Path $lastManifest)) -- treating as a first build."
}

# The question is whether upstream is ahead of what we BUILT.
$buildIsStale = Test-ChromiumVersionIsNewer -Candidate $latestTag -Current $builtVersion
if ($buildIsStale -and $builtVersion) {
    Log "Upstream stable $latestTag is NEWER than the built binary $builtVersion -- a rebuild is required." "WARN"
}

# A built-but-not-installed gap is its own problem: the build succeeded and
# nobody is running it. Report it rather than leaving it to be noticed.
if ($builtVersion -and $installedVersion -and
    (Test-ChromiumVersionIsNewer -Candidate $builtVersion -Current $installedVersion)) {
    Log ("Built $builtVersion but only $installedVersion is installed. Install it with " +
         "'.\update.ps1 -Install' or run: $SrcDir\out\thorium-$Profile\mini_installer.exe --do-not-launch-chrome") "WARN"
}

# A synced tree ahead of the built binary means a previous run got part way.
# Worth saying out loud, because it is the fingerprint of the failure above.
if ($localTag -and $builtVersion -and
    (Test-ChromiumVersionIsNewer -Candidate $localTag -Current $builtVersion)) {
    Log ("The CHECKOUT is at $localTag but the last successful build is $builtVersion -- a previous run " +
         "synced and then failed before producing a binary. Continuing; this run will rebuild.") "WARN"
}

# 3. A Chromium version bump is also the signal that our patch anchors may have
#    moved. We do not try to predict that: apply_zen5_patches.py re-verifies
#    every insertion anchor and exits 3 if one is missing or ambiguous, writing
#    nothing, and the configure stage below treats that as a hard stop. So warn,
#    and let the patcher be the authority.
if ($chromiumChanged -and $localTag) {
    Log "Chromium tag changing $localTag -> $latestTag. The zen5 patches anchor into build/config/compiler/BUILD.gn; apply_zen5_patches.py will verify those anchors and stop the pipeline if upstream moved them." "WARN"
}

# 3b. Track the CLANG revision, not just the Chromium version.
#
#     The two toolchain workarounds this build carries (tail-merge disabled for
#     llvm#199290, SLP capped at 256 bits for an X86 ISel gap) are pinned to a
#     specific clang. One of them -- the SLP cap -- is ALREADY FIXED in a newer
#     clang: verified by running the reproducer against Chromium trunk's roll.
#
#     Chromium rolls clang frequently, so these are meant to retire themselves.
#     Without a reminder they would instead sit in gn/win_zen5_args.gn forever,
#     quietly costing optimisation on a toolchain that no longer needs them.
#     So: record the revision, and say something when it moves.
$clangRevFile = Join-Path $BuildDir "clang-revision.txt"
$updatePy = Join-Path $SrcDir "tools\clang\scripts\update.py"
$currentClang = $null
if (Test-Path $updatePy) {
    $m = Select-String -Path $updatePy -Pattern "^CLANG_REVISION = '([^']+)'" | Select-Object -First 1
    if ($m) { $currentClang = $m.Matches[0].Groups[1].Value }
}
$previousClang = if (Test-Path $clangRevFile) { (Get-Content $clangRevFile -Raw).Trim() } else { $null }
if ($currentClang) {
    if ($previousClang -and ($previousClang -ne $currentClang)) {
        Log "clang rolled: $previousClang -> $currentClang" "WARN"
        Log "RE-TEST THE TOOLCHAIN WORKAROUNDS. Both are pinned to the old compiler and may now be unnecessary:" "WARN"
        Log "  1) zen5_slp_max_reg_size -- the ISel bug it works around is ALREADY FIXED upstream. Try setting it to \"\"." "WARN"
        Log "  2) zen5_extra_target_ldflags (-mllvm:-enable-tail-merge=false) -- llvm#199290; try removing it." "WARN"
        Log "  Fast check (~2 min each, NOT a full build):" "WARN"
        Log "    .\build.ps1 configure -Profile zen5 -Force; .\build.ps1 build -Profile zen5 -Target root_store_tool" "WARN"
        Log "  NOTE: -mllvm flags are not part of LLVM's ThinLTO cache key -- delete" "WARN"
        Log "    src\out\thorium-zen5\thinlto-cache first or the link silently replays the old codegen." "WARN"
    } elseif (-not $previousClang) {
        Log "Recording clang revision $currentClang for future workaround re-testing."
    }
    Set-Content -Path $clangRevFile -Value $currentClang
} else {
    Log "Could not read CLANG_REVISION from $updatePy -- workaround re-test reminders disabled." "WARN"
}
# Rebuild if upstream is ahead of the BUILT binary, if we have never built, or
# if the checkout has moved ahead of the built binary (a part-completed run).
# Deliberately NOT keyed on chromium-tag.txt alone -- see section 2.
$updateAvailable = ($buildIsStale -or $neverBuilt -or
                    ($localTag -and $builtVersion -and
                     (Test-ChromiumVersionIsNewer -Candidate $localTag -Current $builtVersion)))

if (-not $updateAvailable) {
    Log "Up to date: upstream stable $latestTag, built $builtVersion, installed $installedVersion. Nothing to do."
    exit 0
}

if ($CheckOnly) {
    Log "CheckOnly: rebuild needed (upstream=$latestTag built=$builtVersion synced=$localTag never-built=$neverBuilt). Exiting without fetching/building."
    exit 10   # distinct code: "update available" for Task Scheduler / scripts to key off of
}

if (-not $Yes) {
    $resp = Read-Host "Upstream changes detected. Run the full fetch/build/test/package pipeline now? This can take hours. [y/N]"
    if ($resp -notin @("y", "Y", "yes", "Yes")) { Log "User declined. Exiting."; exit 0 }
}

function Invoke-Stage {
    <#
    Run one build.ps1 stage and stop the pipeline if it fails.

    ARGUMENT PASSING -- THE BUG THAT BROKE THIS PIPELINE ENTIRELY.

    -Params is a HASHTABLE, splatted. It used to be a [string[]] splatted as
    `@StageArgs`, e.g. @("configure", "-Profile", $Profile, "-Force"), and that
    is silently wrong: ARRAY splatting passes every element POSITIONALLY. So
    "-Profile" arrived as a positional VALUE, not a parameter name, and
    build.ps1 -- which takes exactly one positional parameter ($Command) --
    failed with:

        A positional parameter cannot be found that accepts argument '-Profile'.

    Only `sync`, the one stage passing no named parameters, ever worked. This
    pipeline had therefore NEVER completed an upgrade. It looked healthy purely
    because every run before 2026-09-18 exited at the up-to-date check without
    reaching a stage; the first run with real work to do synced ~30 GB and then
    died on the very next line.

    Verified empirically rather than reasoned about: array splat throws,
    hashtable splat binds correctly.

    $LASTEXITCODE is deliberately NOT consulted here. It is only set by NATIVE
    commands, so after invoking a .ps1 it holds whatever a previous native
    process left behind -- possibly an exit code Invoke-Logged deliberately
    tolerated via -AllowedExitCodes. build.ps1 runs with
    $ErrorActionPreference = "Stop" and throws, so the exception IS the signal.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Params = @{},
        [string]$FailMessage = $null,
        [int]$FailExit = 1
    )
    Log "Stage: $Name"
    try {
        & "$RepoRoot\build.ps1" $Command @Params
    } catch {
        $msg = if ($FailMessage) { $FailMessage } else { "$Name failed -- stopping pipeline (no release will be produced)." }
        Log "$msg Detail: $_" "ERROR"
        # Say so on the desktop. Exiting non-zero into a log file is not
        # telling anyone: this runs unattended at 03:00 and the only other
        # signal a failure produces is the ABSENCE of an update notification,
        # which looks exactly like a quiet week upstream.
        try {
            Show-ThoriumFailureNotice -Stage $Name -Detail "$msg $_" -LogPath $LogFile -TimeoutMinutes 5 | Out-Null
        } catch {
            Log "Could not raise the failure notification: $_" "WARN"
        }
        exit $FailExit
    }
}

# 4. fetch source (build.ps1 sync handles both Chromium and the Thorium meta-repo)
Invoke-Stage -Name "sync" -Command "sync"

# 5. rebase / reapply zen5 patches -- build.ps1 configure calls
#    apply_zen5_patches.py, which exits 3 (and configure propagates the
#    failure) if a marker is no longer found. We surface that distinctly.
Invoke-Stage -Name "configure (reapplies zen5 patches; stops on patch conflict)" `
    -Command "configure" -Params @{ Profile = $Profile; Force = $true } `
    -FailMessage "PATCH CONFLICT or configure failure. Upstream Thorium's compiler-flag files may have changed shape. See patches/zen5/README.md 'Regenerating after upstream changes'. STOPPING -- no build will be attempted from an unpatched/half-patched tree." `
    -FailExit 2

# 5b. ASSERT THE ZEN 5 TARGETING ACTUALLY SURVIVED THE UPGRADE.
#
#     This is the check this pipeline most needed and did not have. The
#     patches applying cleanly is NOT the same as the flags reaching the
#     compiler, and the gap between those two is invisible in a green build.
#     It has already bitten this project twice:
#
#       * Rust was compiled for generic x86-64 for the project's ENTIRE
#         history, because GN cflags never reach rustc. 278 rlibs, including
#         font shaping and image decode. args.gn looked perfect throughout.
#       * -mtune=skylake-avx512 builds cleanly and emits ZERO 512-bit
#         instructions, silently discarding the whole point of the build.
#
#     A Chromium roll is exactly when this class of failure appears, so it is
#     checked here, before spending hours on a build. verify-source.ps1
#     asserts the GENERATED NINJA -- -march, -mtune, -Ctarget-cpu, and both
#     linker workarounds -- rather than the intent, and exits non-zero if any
#     of them is missing.
#
#     Hard stop: shipping a build labelled "Zen 5" that is silently generic is
#     worse than not shipping.
#
#     $LASTEXITCODE is meaningful here, unlike after the .ps1 calls that
#     Invoke-Stage wraps, because powershell.exe is a NATIVE command. Do not
#     "simplify" this to `& $verifyScript`; that reintroduces the bug
#     documented in Invoke-Stage.
Log "Stage: verify (asserts -march/-mtune/-Ctarget-cpu and the toolchain workarounds reached the generated build files)"
$verifyScript = Join-Path $RepoRoot "verify-source.ps1"
if (-not (Test-Path $verifyScript)) {
    Log "verify-source.ps1 is missing -- cannot confirm the zen5 targeting survived. STOPPING." "ERROR"
    exit 3
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Profile $Profile
if ($LASTEXITCODE -ne 0) {
    $vmsg = ("SOURCE VERIFICATION FAILED (exit $LASTEXITCODE). The zen5 targeting did not reach the " +
             "generated build files, or the tree differs from the pinned tag in an unexpected way. " +
             "Read build\\source-verification.json -- in particular emitted_flags: cxx_march, cxx_mtune, " +
             "rust_cpu, tail_merge_workaround, slp_cap_workaround. STOPPING before the build: a green " +
             "build would hide this.")
    Log $vmsg "ERROR"
    try {
        Show-ThoriumFailureNotice -Stage "verify" -Detail $vmsg -LogPath $LogFile -TimeoutMinutes 5 | Out-Null
    } catch { Log "Could not raise the failure notification: $_" "WARN" }
    exit 3
}
Log "verify OK -- the CPU targeting is present in the generated build files."

# 6. rebuild
Invoke-Stage -Name "build" -Command "build" -Params @{ Profile = $Profile }

# 7. test
Invoke-Stage -Name "test" -Command "test" -Params @{ Profile = $Profile } -FailMessage "tests failed -- stopping pipeline (no release will be produced)."

# 8. ISA analysis
Invoke-Stage -Name "analyze" -Command "analyze" -Params @{ Profile = $Profile } -FailMessage "ISA analysis failed -- stopping."

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

# 9. benchmark -- DELIBERATELY NON-GATING.
#
# This used to stop the pipeline, on the reasoning that we "don't package
# without it". That is the wrong trade for what this project actually is. The
# pipeline exists to deliver Chromium SECURITY updates to one machine, and the
# benchmark is by far its least reliable stage: it drives a real browser
# against a real network. A flaky benchmark must never be the reason a security
# fix goes unpackaged.
#
# It also is not load-bearing for any decision. docs/BENCHMARKS.md records the
# measured position: the Zen 5 build shows no significant Speedometer
# difference (+0.77%, p=0.80), and that test could only have resolved an effect
# above ~8.4% anyway. Results are recorded when they work and skipped loudly
# when they do not.
if ($SkipBenchmark) {
    Log "Stage: benchmark SKIPPED (-SkipBenchmark)."
} else {
    Log "Stage: benchmark (non-gating -- a failure here will not stop the release)"
    try {
        & "$RepoRoot\build.ps1" benchmark -Profile $Profile
    } catch {
        Log ("benchmark failed -- CONTINUING, because this stage is not allowed to block a " +
             "security update. Re-run '.\build.ps1 benchmark -Profile $Profile' if you want the " +
             "numbers. Detail: $_") "WARN"
    }
}

# 10. package only if everything above succeeded
Invoke-Stage -Name "package" -Command "package" -Params @{ Profile = $Profile } -FailMessage "package failed -- stopping."

# 11. installer -- only now, after full validation
Invoke-Stage -Name "installer" -Command "installer" -Params @{ Profile = $Profile } -FailMessage "installer build failed -- stopping."

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

# 12b. Optionally install it here, silently.
#
#      Off by default on purpose: replacing the browser underneath a running
#      session is not something an unattended 03:00 job should do by itself,
#      which is why the normal ending is to OFFER the update (section 13).
#
#      This is the path that was actually verified by hand: mini_installer.exe
#      installs user-level into %LOCALAPPDATA%\Chromium\Application, adopts the
#      existing profile in %LOCALAPPDATA%\Chromium\User Data in place, and
#      registers in Add/Remove Programs. --do-not-launch-chrome keeps it silent.
#
#      NOTE: on Windows `chrome.exe --version` does NOT print and exit -- it
#      ignores the flag and launches the browser. Read the version from the
#      file's version resource, as below.
if ($Install) {
    Log "Stage: install (silent, user-level)"
    # One implementation of "install this build", shared with install.cmd.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepoRoot "scripts\Install-Build.ps1") -Profile $Profile
    if ($LASTEXITCODE -ne 0) {
        Log "silent install did not complete (exit $LASTEXITCODE) -- the packaged build is fine; install it by hand." "WARN"
    }
}

# 13. Offer it. The machine that builds and the machine being updated are the
#     same one, so this checks releases\ directly rather than making a round
#     trip through GitHub. See scripts/Check-ThoriumUpdate.ps1.
$notifier = Join-Path $RepoRoot "scripts\Check-ThoriumUpdate.ps1"
if (Test-Path $notifier) {
    try { & $notifier -Profile $Profile } catch { Log "Update notification failed (non-fatal): $_" "WARN" }
}

exit 0
