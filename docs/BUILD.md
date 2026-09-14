# Building Thorium Zen5

## Prerequisites (one-time, on the build machine)

- Windows 11 x64
- Visual Studio 2019 or 2022/2026 Build Tools, "Desktop development with
  C++" workload, plus the Windows 10/11 SDK **with its Debugging Tools**
  component (Control Panel -> Programs and Features -> "Windows Software
  Development Kit" -> Change -> check "Debugging Tools for Windows").
- Git for Windows, Python 3, on `PATH`.
- `depot_tools`: `git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git C:\thorium\depot_tools`
- Environment variables (System Properties -> Environment Variables):
  - Put `C:\thorium\depot_tools` at the **front** of `PATH` (ahead of any
    other Python/Git).
  - `DEPOT_TOOLS_WIN_TOOLCHAIN=0` (use your locally installed Visual
    Studio instead of Google-internal toolchain).
  - `NINJA_SUMMARIZE_BUILD=1`

`build.ps1` also sets these per-invocation for the processes it launches,
so a missing global env var won't silently break a `build.ps1` run, but a
completely absent Visual Studio / Windows SDK will.

Disk/RAM: budget **150GB+ free disk** (source + one out/ dir per profile
you build; each out/ dir alone is commonly 40-80GB for an official/LTO
build) and 32GB+ RAM (64GB, as on the reference 9950X machine, is
comfortable for a highly parallel `autoninja -jN` with ThinLTO).

## First build, start to finish

```powershell
cd C:\thorium
.\build.ps1 sync          # fetch/checkout Chromium + Thorium meta-repo. HOURS. Re-run to update.
.\build.ps1 configure -Profile zen5   # overlay Thorium sources, apply zen5 patches, gn gen. Minutes.
.\build.ps1 build -Profile zen5       # autoninja. HOURS (first build); much faster incrementally.
.\build.ps1 test -Profile zen5        # fast unit test subset + a headless smoke test
.\build.ps1 analyze -Profile zen5     # real ISA report from the built binary
.\build.ps1 benchmark -Profile zen5   # local startup benchmark (+ Speedometer if configured)
.\build.ps1 package -Profile zen5     # stage a release folder under releases\
.\build.ps1 installer -Profile zen5   # build the Thorium Zen5 Windows installer
```

or simply:

```powershell
.\build.ps1 all
```

which runs all of the above in order and stops at the first failure (no
partial/broken releases are ever packaged).

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

See `docs/ARCHITECTURE.md` for why these are sequential builds against a
re-overlaid shared checkout rather than three parallel checkouts.

## About PGO

By default, `build.ps1 configure` downloads Google's official, generic
win64 Chrome PGO profile (the same one stock Thorium uses) via Chromium's
own `tools/update_pgo_profiles.py`, and substitutes its path into
`args.gn`'s `pgo_data_path`. This is **not** Zen5-trained. Training a
Zen5-specific profile is a real, separate undertaking (instrumented build +
representative workload + profile merge) and is intentionally out of scope
for the default pipeline -- see `docs/ARCHITECTURE.md` "PGO" and
`build/audit.json`'s unresolved questions. `-TrainPgo` is reserved on
`build.ps1` for this but not yet implemented.

## Code signing

Not configured by default -- see `installer/README.md`.

## Clang / znver5 support

`scripts/audit_build.py` probes the pinned clang (pulled by `gclient
runhooks`) for `-march=znver5` recognition and records the result in
`build/audit.json`. If it's not recognized, `build.ps1 configure` will
still write `args.gn`, but the resulting build will not actually target
Zen5 -- check `build/audit.json`'s `unresolved_questions` after every
`sync` before trusting a `zen5` build.
