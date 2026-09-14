# Architecture

## Layout

```
C:\thorium\                    (this repo's root, = RepoRoot)
  build.ps1                    orchestrator: audit/sync/configure/build/test/analyze/benchmark/package/installer/all
  update.ps1                   automated upstream-update pipeline
  verify-source.ps1            source/config integrity checks -> build/source-verification.json
  scripts\                     Python tools (audit, patch, ISA analysis, compare, benchmark, manifest)
  gn\                           args.gn profiles: win_baseline_args.gn, win_zen5_args.gn, win_generic_avx512_args.gn
  patches\zen5\                 generated unified diffs + README documenting each edit (see below)
  installer\                    Inno Setup script + docs
  benchmarks\                   benchmark docs/inputs
  docs\                          this directory
  build\                         ALL generated artifacts: audit.json, isa-report-*.json/.txt,
                                  benchmark-*.json, build-manifest-*.json, compare-report.json,
                                  source-verification.json, logs\*.log, current-overlay.txt
  releases\                      packaged installers + their accompanying reports (git-ignored; large binaries)
  depot_tools\                   cloned from chromium.googlesource.com (git-ignored)
  upstream\Thorium\              cloned from github.com/Alex313031/Thorium (git-ignored, meta-repo only)
  src\                           the actual Chromium checkout (git-ignored, ~30GB+ fetched, ~100GB+ after build)
```

Only the top-level orchestration scripts, Python tools, GN profiles,
patches, installer script, and docs are tracked in this git repo. Anything
downloaded or generated (`depot_tools/`, `upstream/`, `src/`, `build/`,
`releases/`) is `.gitignore`d -- see that file for the exact rules and
rationale. This keeps the git history small and diffable while still being
fully reproducible: `build.ps1 sync` + `build.ps1 configure` regenerate
everything ignored, deterministically, from tracked inputs plus whatever
upstream Chromium/Thorium revision is current at sync time (which is itself
recorded in `build/build-manifest-<profile>.json` for every build).

## One shared Chromium checkout, two source "overlays"

Thorium is not a separate git fork of Chromium; it is Chromium plus a set
of files Thorium's own `win_scripts/setup.py` (or `setup.sh` on
Linux/Mac) copies on top of a stock checkout, plus a further overlay for
each SIMD "flavor" (stock/AVX/AVX2/AVX-512/SSE variants each replace a
different `third_party/opus` build, among other things). That means the
*source tree itself*, not just the GN args, differs between a "baseline"
build and an "AVX-512-family" build.

This project uses exactly **two** source overlays:

- `stock` -- Thorium's default file set, no AVX2/AVX-512 third_party
  overlay. Used by the `baseline` profile.
- `avx512` -- Thorium's default file set **plus**
  `other/AVX2/third_party` (reused by upstream Thorium for both its AVX2
  and AVX-512 flavors) **plus** this project's `patches/zen5`. Used by both
  the `zen5` and `generic-avx512` profiles.

Because `zen5` and `generic-avx512` share the *same* overlay and differ
only in `args.gn` (`use_znver5 = true` vs. unset) and because the zen5
patches are inert unless `use_znver5 = true`, switching between those two
profiles never requires re-copying source -- only `gn gen` with a different
`args.gn`. Switching to/from `baseline`, however, does re-run the file
overlay (`build.ps1 configure` tracks the currently-applied overlay in
`build/current-overlay.txt` and only re-copies when it changes).

**Consequence, stated plainly**: baseline vs. zen5 vs. generic-avx512
comparisons in this project are *sequential* builds from one checkout that
gets re-overlaid between flavors, not three simultaneously-checked-out
trees. Each build is still fully reproducible and its exact GN args /
source commit are recorded in its own `build-manifest-<profile>.json`, so
the comparison in `compare-report.json` is comparing two real, freshly
built artifacts -- just not built at the same instant from physically
separate checkouts. If you want true parallel checkouts, clone this repo's
`src/` logic into `C:\thorium-baseline`, `C:\thorium-zen5`, etc.; nothing
about `build.ps1` prevents multiple independent RepoRoots.

## How the zen5 patches were derived

Documented step by step, so future-you (or an update) can redo this
inspection against a new Thorium revision if `scripts/apply_zen5_patches.py`
ever stops finding its markers:

1. Clone `https://github.com/Alex313031/Thorium.git` (shallow) somewhere
   scratch -- this is the *meta-repo*, not a full Chromium checkout, so
   it's small and fast.
2. `win_scripts/setup.py` is the authoritative Windows source-overlay
   script (`docs/WIN_INSTRUCTIONS.txt` is an older, partially superseded
   manual-steps document -- cross-check both, prefer `setup.py`).
3. `other/AVX512/win_AVX512_args.gn` is the real AVX-512 `args.gn` flavor;
   `src/build/config/compiler_opt.gni` declares `use_avx512` and friends,
   with a comment stating the AVX-512 feature set is deliberately the
   "least common denominator" subset, common to all AVX-512 CPUs.
4. `grep -r use_avx512 src/build/config src/v8/BUILD.gn` finds every call
   site: `compiler/BUILD.gn` (Windows AND Linux/Mac x64 branches),
   `win/BUILD.gn` (a cflags block AND a separate release-only ldflags
   block), and `v8/BUILD.gn` (Windows AND non-Windows). All of them
   hardcode `-mllvm:-march=skylake-avx512` (or the `-Wl,-mllvm,` spelling)
   as the ThinLTO backend's codegen/scheduling target -- this is the
   generic-AVX-512-treated-as-final-target problem the project exists to
   fix.
5. `scripts/apply_zen5_patches.py` inserts `if (use_znver5) { ... } else`
   ahead of each such call site (see that file's own docstring for exactly
   how edit sites are located robustly, and `patches/zen5/README.md` for
   what each edit does).

## What is NOT build-time specialized (left as runtime dispatch)

Chromium's third-party SIMD-heavy libraries (Highway, dav1d,
libjpeg-turbo, Skia's opts, zlib) are architected around *runtime* CPU
feature dispatch: they compile multiple code paths and pick one via a
`cpuid`-based check at process startup, independent of any GN arg. Thorium
does not touch this mechanism for any of its SIMD flavors, including
AVX-512, and this project deliberately doesn't either -- forcing e.g.
Highway to select its AVX-512 target at compile time would remove its
ability to run correctly on a non-AVX-512 machine, and (per this project's
own audit) there's no evidence Thorium's `use_avx512` flag was ever meant
to touch that layer. See `build/audit.json`'s `affected_targets_classification`
for the full A/B/C/D/E classification, and re-run
`python3 scripts/audit_build.py` after `build.ps1 sync` to re-verify this
against the real, current third-party source (the version checked in here
was produced before the first real sync, from the Thorium meta-repo alone,
which does not contain the full Chromium tree).

## PGO

Thorium's PGO profile is Google's official, generic win64 Chrome profile,
trained on generic hardware -- not Zen5-specific. This project does not
attempt to train a Zen5-specific profile by default (that requires a full
instrumented `chrome_pgo_phase=1` build, a representative interactive
workload, and a `.profraw` -> `.profdata` merge -- a substantial project of
its own). This is recorded as an explicit unresolved item in
`build/audit.json`, not silently skipped.
