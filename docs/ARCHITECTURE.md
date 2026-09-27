# Architecture

## Layout

```
C:\thorium\                    (repo root)
  build.ps1                    stages: sync/configure/build/test/analyze/package/publish
  update.ps1                   nightly pipeline: runs the stages, publishes, deploys
  verify-source.ps1            proves the targeting reached the generated ninja
  check.cmd update.cmd install.cmd verify.cmd   double-click launchers
  scripts\
    Common.ps1                 shared: paths, version rules, releases, installed build, desktop icon, toast
    Check-ThoriumUpdate.ps1    deploy (scheduled) and the desktop icon (-Interactive)
    Install-Build.ps1          the one install implementation, verified
    Install-ThoriumTasks.ps1   registers the two scheduled tasks
    Run-Tests.ps1              base_unittests gate + known-test-failures.txt + parse_test_summary.py
    apply_zen5_patches.py      adds use_znver5 and the targeting block to a stock tree
    generate_manifest.py       build-manifest-<profile>.json, including the chrome.dll hash
    analyze_isa.py             disassembles chrome.dll and counts real AVX-512 instructions
    Repair-UrlProtocolShadowing.ps1   manual diagnostic (docs/HISTORY.md, 2026-09-19)
    run_bench_suite.py, speedometer_cdp.py, Start-BenchBrowser.ps1,
    compare_builds.py, attribute_isa.py   manual benchmarking and analysis tools
  gn\                          _common_args.gni.txt + win_{baseline,zen5}_args.gn
  patches\zen5\                reference diff of the patch, plus its README
  benchmarks\                  recorded benchmark results
  docs\                        this directory
  build\                       generated state (ignored): manifests, ISA reports, logs\,
                               chromium-tag.txt, configured-<profile>.json, run-state.json
  releases\                    packaged builds (ignored; large binaries)
  depot_tools\, src\           fetched (ignored)
```

Tracked: scripts, GN profiles, the reference diff, docs. Everything
downloaded or generated is ignored and reproducible from `build.ps1 sync`
and `configure` against whatever Chromium stable is current, which each
build's manifest records.

## One checkout, one patch, two profiles

There is no source overlay. `src/` is a stock Chromium checkout pinned to
a stable tag, and the only file this project modifies is
`build/config/compiler/BUILD.gn` (`verify-source.ps1` fails if anything
else differs from the tag). `scripts/apply_zen5_patches.py` inserts two blocks into
it: a `declare_args()` defining the `zen5_*` arguments, and a targeting
block inside `config("compiler")` that emits `-march`/`-mtune` for x64
Windows clang builds.

Every argument the patch declares defaults to the value that reproduces
stock behaviour, so a patched tree with `use_znver5` unset compiles
identically to an unpatched one. The profiles differ only in `args.gn`:

- `baseline` -- stock Chromium. `build.ps1 configure` does not apply the
  patch for it; if a zen5 configure left the patch in place, the output is
  still stock because `use_znver5` defaults to false.
- `zen5` -- `use_znver5 = true`.

The patch also declares `use_generic_avx512`. The profile that set it was
removed on 2026-09-27: it was measured to emit zero 512-bit instructions
(clang defaults `skylake-avx512` to `prefer-vector-width=256`).

`gn/_common_args.gni.txt` holds everything the profiles share and is
concatenated with the per-profile block at configure time, so the profiles
cannot drift apart in anything other than their CPU-targeting lines. If
they did, the comparison between them would be meaningless.

Switching profiles is `gn gen` into a different `out/` directory. Nothing
is copied and no source is re-overlaid, so profiles can coexist.

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

This was established by a survey of the checkout (the audit stage, removed
on 2026-09-27), per library.

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

`build.ps1 configure` uses the profile that `chrome/build/win64.pgo.txt`
names and downloads it when it is missing, so a milestone bump always gets
the matching profile. `-Force` re-downloads regardless.
