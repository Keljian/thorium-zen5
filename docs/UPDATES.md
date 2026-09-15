# Keeping Thorium Zen5 up to date

## Manual

```powershell
.\update.ps1                       # checks for updates, prompts, then runs the full pipeline
.\update.ps1 -CheckOnly            # just checks; exit code 10 means an update is available
.\update.ps1 -Profile zen5 -Yes    # non-interactive (for a scheduled task)
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
build                   (build.ps1 build)
        v
test                    (build.ps1 test)
        v
ISA analysis            (build.ps1 analyze) + regression flag vs. previous build
        v
benchmark               (build.ps1 benchmark)
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

## Scheduled checking (Windows Task Scheduler)

Create a task that runs:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\thorium\update.ps1 -CheckOnly
```

on whatever cadence you like; daily is reasonable. Exit code `10` means an
update is available. Wire a second action, or a wrapper script, to run
`update.ps1 -Yes` when that happens if you want unattended updates.

The `-CheckOnly` path deliberately never installs or publishes anything:
nothing ships without completing the build/test pipeline first.