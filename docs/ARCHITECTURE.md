# Architecture

## Layout

```
C:\thorium\                    (this repo's root, = RepoRoot)
  build.ps1                    orchestrator: audit/sync/configure/build/test/analyze/benchmark/package/installer/all
  update.ps1                   automated upstream-update pipeline
  verify-source.ps1            source/config integrity checks -> build/source-verification.json
  scripts\
    ChromiumVersion.ps1        stable-version resolution + downgrade guard, shared by build.ps1 and update.ps1
    audit_build.py             probes the checkout and the pinned clang -> build/audit.json
    apply_zen5_patches.py      the patcher: adds use_znver5 and the targeting block to a stock tree
    analyze_isa.py             disassembles the built binary and counts real AVX-512 instructions
    benchmark.py               startup timing (+ Speedometer if a checkout is supplied)
    compare_builds.py          cross-profile comparison report
    generate_manifest.py       build-manifest-<profile>.json
  gn\                          args.gn profiles: _common_args.gni.txt + win_{baseline,zen5,generic_avx512}_args.gn
  patches\zen5\                the captured diff of the last successful patch application, plus its README
  installer\                   Inno Setup script + docs
  benchmarks\                  benchmark docs/inputs
  docs\                        this directory
  build\                       ALL generated artifacts: audit.json, isa-report-*.json/.txt,
                               benchmark-*.json, build-manifest-*.json, compare-report.json,
                               source-verification.json, chromium-tag.txt, logs\*.log
  releases\                    packaged installers + their reports (git-ignored; large binaries)
  depot_tools\                 cloned from chromium.googlesource.com (git-ignored)
  src\                         the Chromium checkout (git-ignored, ~30GB+ fetched, ~100GB+ after a build)
```

Only the orchestration scripts, Python tools, GN profiles, the captured
patch diff, the installer script and the docs are tracked. Anything
downloaded or generated (`depot_tools/`, `src/`, `build/`, `releases/`) is
`.gitignore`d. `build.ps1 sync` + `build.ps1 configure` regenerate all of
it deterministically from tracked inputs plus whatever Chromium stable is
current at sync time, which is itself recorded in
`build/build-manifest-<profile>.json` for every build.

## One checkout, one patch, three profiles

There is no source overlay. `src/` is a stock Chromium checkout pinned to
a stable tag, and the only file this project modifies is
`build/config/compiler/BUILD.gn` (see `build/audit.json` ->
`modified_files`). `scripts/apply_zen5_patches.py` inserts two blocks into
it: a `declare_args()` defining the `zen5_*` arguments, and a targeting
block inside `config("compiler")` that emits `-march`/`-mtune` for x64
Windows clang builds.

Every argument the patch declares defaults to the value that reproduces
stock behaviour, so a patched tree with `use_znver5` unset compiles
identically to an unpatched one. The three profiles differ only in
`args.gn`:

- `baseline` -- tree left completely unpatched, on purpose. `build.ps1
  configure` skips the patcher entirely for this profile.
- `zen5` -- `use_znver5 = true`.
- `generic-avx512` -- `use_generic_avx512 = true`. Kept as a comparison
  point only. It is measured to emit **zero** 512-bit instructions,
  because clang defaults `skylake-avx512` to `prefer-vector-width=256`, so
  it is not "the AVX-512 build".

`gn/_common_args.gni.txt` holds everything the three profiles share and is
concatenated with the per-profile block at configure time, so the profiles
cannot drift apart in anything other than their CPU-targeting lines. If
they did, the comparison between them would be meaningless.

Switching profiles is `gn gen` into a different `out/` directory. Nothing
is copied and no source is re-overlaid, so profiles can coexist. Going
from `zen5` to `baseline` does require the patcher's edits to be reverted
first, which `build.ps1 sync` does for free via `git checkout -f`.

## How the tree gets patched, and why that survives an update

`build.ps1 sync` runs `git checkout -f tags/<stable>`, which discards the
patched `BUILD.gn` outright, and `build.ps1 configure` then re-synthesises
it. The patch is never rebased, so it can never conflict in the git sense.

`apply_zen5_patches.py` anchors on exact text rather than line numbers,
and each anchor must match **exactly once**:

```
anchor1   config("compiler") {\n  asmflags = []\n
anchor2   "  ldflags = []\n  defines = []\n  configs = []\n"
```

On any other match count it prints the anchor, writes nothing at all, and
exits **3**, which `build.ps1 configure` treats as a hard stop. No build is
ever attempted from a half-patched tree. It is idempotent via a marker
string, and it checks that brace balance is unchanged before writing.

Both anchors were re-checked against Chromium trunk (`origin/main` @
58199c7a, 2026-09-14, 3270 lines against 3260 at the pinned tag) and still
match exactly once, so a milestone bump is not expected to need
re-anchoring. When it eventually does, see `patches/zen5/README.md`
"Regenerating after upstream changes".

## What is NOT build-time specialized (left as runtime dispatch)

Chromium's SIMD-heavy third-party libraries (Highway, dav1d,
libjpeg-turbo, Skia's opts, zlib) are architected around *runtime* CPU
feature dispatch: they compile multiple code paths and select one via a
`cpuid` check at startup, independent of any GN arg. This project
deliberately does not touch that mechanism. Forcing e.g. Highway to pick
its AVX-512 target at compile time would remove its ability to fall back,
for no benefit that `-march` does not already give the rest of the build.

`build/audit.json` -> `third_party_dispatch_survey` records the scan that
established this, per library, with the files the dispatch signature was
found in. It is regenerated by `build.ps1 sync` and again by `build.ps1
configure`, against the real checked-out tree.

## PGO

The build uses Google's official, generic win64 Chrome PGO profile,
downloaded by `build.ps1 configure` via Chromium's own
`tools/update_pgo_profiles.py` and substituted into `args.gn`'s
`pgo_data_path`. It is milestone-matched to the checkout but **not**
Zen5-trained, and not trained on this machine's workload.

Training a local profile means an instrumented `chrome_pgo_phase=1` build,
a representative interactive workload, and a `.profraw` -> `.profdata`
merge, then a second full build. It also has to be redone every milestone,
whereas the official profile arrives free on every sync. It is
intentionally out of scope for the default pipeline. See `docs/BUILD.md`
"About PGO".

Known sharp edge: `Get-OrDownloadPgoProfile` returns the newest existing
`chrome-win64-*.profdata` unless `-Force` is passed. `update.ps1` does pass
`-Force`, so the automated path always refreshes it, but a hand-run
`build.ps1 configure` after a milestone bump will silently reuse the
previous milestone's profile. `chrome/build/win64.pgo.txt` names the
profile the checked-out revision expects and is the right thing to check
against.