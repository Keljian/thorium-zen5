# Keeping Thorium Zen5 up to date

## Manual

```powershell
.\update.ps1                       # checks for updates, prompts, then runs the full pipeline
.\update.ps1 -CheckOnly            # just checks; exit code 10 means an update is available
.\update.ps1 -Profile zen5 -Yes    # non-interactive (for a scheduled task)
```

Pipeline (`update.ps1`'s stages, each one gated on the previous succeeding):

```
upstream update detected
        v
fetch source           (build.ps1 sync)
        v
rebase/reapply patches  (build.ps1 configure -- apply_zen5_patches.py)
        v
configure (gn gen)
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
packages/installs from a partially successful run: a failure at any stage
exits non-zero immediately, before the next stage runs.

### Patch conflicts

If `scripts/apply_zen5_patches.py` can no longer find one of its expected
compiler-flag literals (because upstream Thorium reshaped
`compiler_opt.gni` / `compiler/BUILD.gn` / `win/BUILD.gn` / `v8/BUILD.gn`),
`update.ps1` stops at the "configure" stage with a clear error pointing at
`patches/zen5/README.md`'s "Regenerating after upstream changes" section.
It does **not** guess a new insertion point or silently skip the zen5
targeting.

### Regressions

After each ISA analysis, `update.ps1` compares the new
`build/isa-report-<profile>.json` against
`build/isa-report-<profile>.previous.json` (saved from the last *successful*
full pipeline run) and flags -- but does not automatically reject -- a
decrease in AVX-512 instruction count. Loss of PGO/LTO or unexpected
compiler-flag changes show up directly in `build/build-manifest-<profile>.json`
(diff it against the previous release's copy under `releases/`) and in
`verify-source.ps1`'s `build/source-verification.json`.

## Scheduled checking (Windows Task Scheduler)

Create a task that runs:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\thorium\update.ps1 -CheckOnly
```

on whatever cadence you like (daily is reasonable -- Chromium/Thorium
don't release more often than that). Exit code `10` means an update is
available; wire a second action (or a wrapper script) to run
`update.ps1 -Yes` when that happens if you want fully unattended updates.
This project deliberately does **not** install/publish anything from the
`-CheckOnly` path -- per the spec, "do not automatically install or
publish an update without completing the build/test pipeline."

## What triggers "update available"

- The Thorium meta-repo's `main` branch has moved (new Thorium release or
  interim commit).
- Chromium's `origin/main` (or whatever branch your last build was cut
  from) has moved past what's recorded in the last `build-manifest-<profile>.json`.
- Any of the four files `patches/zen5` touches changed between the last
  known Thorium meta-repo commit and its current `main` -- flagged
  specifically as a patch-conflict risk, even before `apply_zen5_patches.py`
  is actually run.
