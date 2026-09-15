# Building Thorium Zen5

This builds **stock Chromium** plus one local patch. There is no Thorium
source overlay; see `docs/ARCHITECTURE.md` for why it was dropped.

## Prerequisites (one-time, on the build machine)

- Windows 11 x64
- Visual Studio 2019 or 2022/2026 Build Tools, "Desktop development with
  C++" workload, plus the Windows 10/11 SDK **with its Debugging Tools**
  component (Control Panel -> Programs and Features -> "Windows Software
  Development Kit" -> Change -> check "Debugging Tools for Windows").
- Git for Windows, Python 3, on `PATH`.
- `depot_tools`: `git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git C:\thorium\depot_tools`
- Environment variables (System Properties -> Environment Variables):
  - Put `C:\thorium\depot_tools` at the **front** of `PATH`.
  - `DEPOT_TOOLS_WIN_TOOLCHAIN=0` (use locally installed Visual Studio
    rather than the Google-internal toolchain).
  - `NINJA_SUMMARIZE_BUILD=1`

`build.ps1` constructs a minimal, explicit environment for every child
process it launches (see `Get-DepotToolsEnv`), so a missing global env var
will not silently break a run and the build behaves the same from an
interactive shell, a scheduled task or a remote agent. A completely absent
Visual Studio or Windows SDK will still fail, loudly, before any real work
starts.

Disk/RAM: budget **150GB+ free disk** (source plus one `out/` dir per
profile; each `out/` dir alone is commonly 40-80GB for an official/LTO
build, and the ThinLTO cache policy allows up to 40GB on its own) and
32GB+ RAM. 64GB, as on the reference 9950X machine, is comfortable for a
highly parallel `autoninja -jN` with ThinLTO.

## First build, start to finish

```powershell
cd C:\thorium
.\build.ps1 sync                      # fetch Chromium, pin to current stable, gclient sync. HOURS.
.\build.ps1 configure -Profile zen5   # apply zen5 patches, write args.gn, gn gen. Minutes.
.\build.ps1 build -Profile zen5       # autoninja chrome + mini_installer. HOURS first time.
.\build.ps1 test -Profile zen5        # base_unittests + a headless smoke test
.\build.ps1 analyze -Profile zen5     # real ISA report from the built binary
.\build.ps1 benchmark -Profile zen5   # startup benchmark (+ Speedometer if configured)
.\build.ps1 package -Profile zen5     # stage a release folder under releases\
.\build.ps1 installer -Profile zen5   # build the Windows installer
```

or simply:

```powershell
.\build.ps1 all
```

which runs all of the above in order and stops at the first failure, so no
partial or broken release is ever packaged.

`build.ps1 build -Target <ninja-target>` builds named targets only and
writes no manifest. Use it for fast toolchain canaries;
`net/tools/root_store_tool` is about 2,500 steps and roughly two minutes,
which is what the toolchain-bug matrices in `docs/TOOLCHAIN-BUGS.md` were
bisected with.

## Building the comparison profiles

```powershell
.\build.ps1 configure -Profile baseline
.\build.ps1 build -Profile baseline
.\build.ps1 analyze -Profile baseline

.\build.ps1 configure -Profile generic-avx512
.\build.ps1 build -Profile generic-avx512
.\build.ps1 analyze -Profile generic-avx512

python3 scripts\compare_builds.py --repo-root C:\thorium
```

Each profile builds into its own `out/thorium-<profile>` directory, so
they can coexist; only `baseline` requires the patcher's edits to be out
of the tree, which `build.ps1 sync` handles via `git checkout -f`.

**This has not been done yet.** No `baseline` build exists, so the
performance value of the Zen 5 targeting is currently unmeasured and
`docs/BENCHMARKS.md` is empty.

## About PGO

`build.ps1 configure` downloads Google's official, generic win64 Chrome
PGO profile via Chromium's own `tools/update_pgo_profiles.py` and
substitutes its path into `args.gn`'s `pgo_data_path`. It is
milestone-matched to the checkout but **not** Zen5-trained and not trained
on this machine's workload.

Training a local profile is a real undertaking: an instrumented
`chrome_pgo_phase=1` build, a representative interactive workload, a
`.profraw` -> `.profdata` merge, then a second full build, repeated every
milestone. It is intentionally out of scope for the default pipeline.
`-TrainPgo` is reserved on `build.ps1` for this and is not implemented.

Caveat worth knowing: `Get-OrDownloadPgoProfile` reuses the newest
existing `chrome-win64-*.profdata` unless `-Force` is passed. `update.ps1`
always passes `-Force`, but a hand-run `configure` after a milestone bump
will silently reuse the old milestone's profile.
`chrome/build/win64.pgo.txt` names the profile the current revision
expects.

## Code signing

Not configured by default -- see `installer/README.md`.

## Clang / znver5 support

`scripts/audit_build.py` probes the pinned clang (pulled by `gclient
runhooks`) for `-march=znver5` recognition and records the result in
`build/audit.json`. `build.ps1 configure -Profile zen5` reads that back and
**throws** if the probe failed, rather than letting the build silently
degrade to a coarser target.