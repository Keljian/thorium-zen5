# Keeping Thorium Zen5 up to date

## Manual

```powershell
.\update.ps1                       # checks for updates, prompts, then runs the full pipeline
.\update.ps1 -CheckOnly            # just checks; exit code 10 means a rebuild is needed
.\update.ps1 -Profile zen5 -Yes    # non-interactive (for a scheduled task)
.\update.ps1 -Yes -Install         # ...and silently install the result on this machine
.\update.ps1 -Yes -SkipBenchmark   # skip the (non-gating) benchmark stage
```

Pipeline (`update.ps1`'s stages, each gated on the previous succeeding):

```
upstream update detected
        v
fetch source            (build.ps1 sync -- git checkout -f <tag>, gclient sync -D, runhooks)
        v
reapply zen5 patches    (build.ps1 configure -- apply_zen5_patches.py)
        v
configure               (gn gen)
        v
VERIFY TARGETING        (verify-source.ps1 -- hard stop; see below)
        v
build                   (build.ps1 build)
        v
test                    (build.ps1 test)
        v
ISA analysis            (build.ps1 analyze) + regression flag vs. previous build
        v
benchmark               (build.ps1 benchmark)  -- NON-GATING, see below
        v
package                 (build.ps1 package)
        v
installer               (build.ps1 installer)
        v
release candidate       (releases\thorium-zen5-<profile>-<sha>-<timestamp>\)
```

`update.ps1` **never** silently discards upstream changes, and never
packages from a partially successful run: a failure at any stage exits
non-zero immediately, before the next stage runs. Stage failure is
detected by catching the exception `build.ps1` throws, not by reading
`$LASTEXITCODE`, which after invoking a `.ps1` still holds whatever the
last native process left behind and is therefore meaningless there.

### The verify gate

After `configure` and **before** the hours-long build, the pipeline runs
`verify-source.ps1`, which asserts against the *generated ninja* that the CPU
targeting actually reached the compiler:

| check | asserts |
|---|---|
| `cxx_march` / `cxx_mtune` | `-march=znver5 -mtune=znver5` on the C++ compile |
| `rust_cpu` | `-Ctarget-cpu=znver5` on the Rust compile |
| `tail_merge_workaround` | `-mllvm:-enable-tail-merge=false` on the chrome.dll link |
| `slp_cap_workaround` | `-mllvm:-slp-max-reg-size=256` on the chrome.dll link |

A failure here is a **hard stop** (exit 3). The patches applying cleanly is not
the same thing as the flags reaching the compiler, and the gap between those two
is invisible in a green build -- it has produced two silent wrong builds on this
project already (Rust at the generic baseline for the project's entire history;
`-mtune=skylake-avx512` emitting zero 512-bit instructions). Shipping something
labelled "Zen 5" that is silently generic is worse than not shipping.

### Why the benchmark does not gate

The benchmark stage records results when it works and is **skipped loudly** when
it does not. It is deliberately not allowed to stop the pipeline: this pipeline
exists to deliver Chromium **security** updates to one machine, the benchmark is
its least reliable stage (it drives a real browser against a real network), and a
flaky benchmark must never be why a security fix goes unpackaged. It is also not
load-bearing for any decision -- see `docs/BENCHMARKS.md`, which records that the
Zen 5 build shows no significant Speedometer difference anyway.

### Installing the result

The pipeline's normal ending is to *offer* the update
(`scripts\Check-ThoriumUpdate.ps1`), not to replace a browser you are using. Pass
`-Install` to have it install silently instead, or do it by hand:

```powershell
src\out\thorium-zen5\mini_installer.exe --do-not-launch-chrome --verbose-logging
```

That installs user-level into `%LOCALAPPDATA%\Chromium\Application`, adopts the
existing profile in `%LOCALAPPDATA%\Chromium\User Data` in place, and registers in
Add/Remove Programs. `-Install` refuses while the installed browser is running.

> On Windows, `chrome.exe --version` does **not** print and exit -- it ignores the
> flag and launches the browser. Read the version from the file's version
> resource instead.

## Two bugs that stopped this pipeline working at all

Both were found on 2026-09-18 and are recorded here because each was invisible
in normal operation, and the second is the exact failure this file's design was
meant to prevent.

**1. Named arguments never reached `build.ps1`.** `Invoke-Stage` built a
`[string[]]` and splatted it: `& build.ps1 @StageArgs` with
`@("configure", "-Profile", $Profile, "-Force")`. **Array splatting passes every
element positionally**, so `-Profile` arrived as a positional *value* and
`build.ps1` -- which has exactly one positional parameter -- failed with
`A positional parameter cannot be found that accepts argument '-Profile'`.

Only `sync`, the single stage passing no named parameters, ever worked. This
pipeline had therefore **never completed an upgrade**. It looked healthy because
every run before 2026-09-18 exited at the up-to-date check without reaching a
stage; the first run with real work to do synced ~30 GB and died on the next
line. Fixed by splatting a **hashtable**, which binds names correctly. Verified
empirically, not reasoned about.

**2. "Up to date" was measured against the wrong thing.** The check compared
`build/chromium-tag.txt` -- written by the `sync` stage -- against chromiumdash.
So when the run above synced successfully and *then* failed, the tag file had
already advanced to the new version, and every later run concluded
"already up to date, nothing to do" while the machine kept running the old
build. The pipeline goes permanently quiet, and from outside that is
indistinguishable from a quiet week upstream. That is the silent
security-drift failure the `trap` at the top of `update.ps1` exists to catch,
and the trap could not see it because nothing threw.

Now the check keys on the **version resource of the binary we actually built**
(`out\thorium-<profile>\chrome.exe`), which cannot drift from reality the way a
marker file can. It also reports the installed version, and warns on a
built-but-not-installed gap and on a checkout that has moved ahead of the last
successful build (the fingerprint of a part-completed run).

A related third hole, in `verify-source.ps1`: a missing patch marker was only a
*warning*, and the emitted-flag checks read `toolchain.ninja` without checking
its age. So the script exited 0 on a tree whose `BUILD.gn` a `gclient sync` had
just reverted, because the flags were still present in a `toolchain.ninja` left
over from the previous day's configure. Both are now errors -- an unpatched tree
(unless `-AllowUnpatched`) and generated build files older than `BUILD.gn`.

## What triggers "update available"

Exactly two things:

1. **A newer Chromium stable exists.** `scripts/ChromiumVersion.ps1` asks
   chromiumdash for the last several Windows stable releases and takes the
   **highest version**, then compares it to `build/chromium-tag.txt`, which
   `build.ps1 sync` writes with the tag the checkout is pinned to. This is
   a single cheap HTTP call; the ~30GB source is never fetched just to
   poll.

2. **No `build/build-manifest-<profile>.json` exists**, so a first run for
   a profile does something useful instead of reporting "up to date".

### Why "highest version" and not "most recent release"

chromiumdash orders by release time, and Chrome ships several stable
milestones concurrently. Observed 2026-09-16 with the checkout pinned at
154.0.8037.17, the response led with 153.0.8010.48. Taking entry [0] would
have resolved a stable that is a whole milestone **older** than what was
already built.

`Test-ChromiumVersionIsNewer` is the second half of that fix and is
deliberately a separate function: the update is gated on strict version
ordering, not on inequality, so even if resolution regresses again the
pipeline cannot sync the checkout backwards and discard shipped security
fixes. A resolution that comes back older is logged as a refused downgrade
and treated as up to date.

## Patch conflicts

The only file this project patches is
`src/build/config/compiler/BUILD.gn`. Sync discards the patched copy with
`git checkout -f`, so there is no merge to conflict; the patch is
re-synthesised from scratch at configure time.

If `scripts/apply_zen5_patches.py` can no longer find one of its two
anchors, or finds one more than once, it prints the anchor, writes
nothing, and exits 3. `update.ps1` stops at the configure stage with a
message pointing at `patches/zen5/README.md` "Regenerating after upstream
changes". It does **not** guess a new insertion point and does not
silently skip the targeting.

Both anchors were last verified against Chromium trunk on 2026-09-14 and
still matched exactly once.

## Regressions

After each ISA analysis, `update.ps1` compares the new
`build/isa-report-<profile>.json` against
`build/isa-report-<profile>.previous.json` (saved from the last
*successful* full pipeline run) and flags, without auto-rejecting, a
decrease in AVX-512 instruction count.

Loss of PGO or LTO, or unexpected compiler-flag changes, show up directly
in `build/build-manifest-<profile>.json`. Diff it against the previous
release's copy under `releases\`. `verify-source.ps1` writes
`build/source-verification.json` for the same purpose.

Note that the test stage is currently `base_unittests` plus a headless
`about:blank` smoke test. That is a thin gate for a build carrying
codegen-altering toolchain workarounds; a miscompile from any of them
would more likely surface in Blink or V8 than in base.

## Publishing

`build.ps1 publish` uploads the newest packaged release for a profile to
GitHub Releases, tagged `v<chromium-version>-<profile>`. Release notes are
generated from `build-manifest-<profile>.json` and the ISA report, so what is
published always matches what was measured.

The repo is **private**, and that is not incidental. This build sets
`proprietary_codecs`, `ffmpeg_branding = "Chrome"` and `enable_widevine`, none
of which are ours to redistribute. Publishing here is off-machine storage and
version history for one person. Do not make the repo public without first
stripping those from the published artifacts.

`update.ps1` runs publish last and treats a failure there as a **warning, not
a pipeline failure**. Everything before it produced a good installable build
sitting in `releases\`; an expired `gh` token is a reason to say so, not a
reason to mark a two-hour build as failed. Re-run `build.ps1 publish` on its
own once the cause is fixed.

## Versioning, and why it changed

The installer used to take a 10-char commit sha as its version, which became
`DisplayVersion` in Add/Remove Programs. That made the only question an
updater has to answer -- "is the build I just made newer than the one
installed?" -- unanswerable, because shas do not order.

Now:

- **Version** is the Chromium version, e.g. `154.0.8037.17`. Orderable.
- **BuildId** is `<version>+<repo-sha10>+<utc-timestamp>`, so two builds of the
  *same* Chromium version (a flag change, a toolchain roll) are still
  distinguishable.

Both are written by the installer to `HKCU\Software\ThoriumZen5`, and removed
on uninstall, so a stale entry never outlives the install it describes.

## Full automation

```powershell
.\scripts\Register-ThoriumUpdateNotifier.ps1    # once: AppUserModelID + URI handler, HKCU only
.\scripts\Install-ThoriumTasks.ps1 -WhatIf      # look first
.\scripts\Install-ThoriumTasks.ps1              # then register
```

Two scheduled tasks, both per-user:

**"Thorium Zen5 - Build upstream updates"** runs `update.ps1 -Yes` daily at
03:00. `update.ps1` self-gates, so on a day when nothing has shipped this
costs one HTTP request. Runs whether or not you are logged on, at limited
privilege: nothing in the pipeline needs admin, and an unattended multi-hour
build is the last thing that should run elevated.

**"Thorium Zen5 - Offer update"** runs `scripts\Check-ThoriumUpdate.ps1` at
logon and every four hours, **in the interactive session** -- a toast raised
from Session 0 is never displayed to anyone. It installs nothing on its own.
It compares `HKCU\Software\ThoriumZen5` against the newest complete release
under `releases\` and, if there is something newer, raises a toast whose
"Install now" button runs the installer silently.

The check is local, not a round trip through GitHub, because the machine that
builds this browser and the machine that runs it are the same machine.
`-Source GitHub` exists for the day a second machine wants the same build; it
can only compare versions, not BuildIds, so same-version rebuilds are
invisible over that path.

### Why the toast needs registering

Windows drops a toast raised by a process with no registered
AppUserModelID, silently: no exception, nothing in Action Center. And toast
buttons cannot run a command directly, because the toast usually outlives the
process that raised it -- `activationType="protocol"` is the only route that
survives that. `Register-ThoriumUpdateNotifier.ps1` creates both, under HKCU,
no admin, and `-Unregister` removes them.

Without it the checker still works and still tells you on the console; it just
says so instead of pretending it showed you something.

### Manual polling, if you would rather not have the tasks

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\thorium\update.ps1 -CheckOnly
```

Exit code `10` means an update is available. The `-CheckOnly` path never
installs or publishes anything: nothing ships without completing the
build/test pipeline first.