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
.\build.ps1 configure -Profile zen5   # apply the zen5 patch, write args.gn, gn gen. Minutes.
.\verify-source.ps1 -Profile zen5     # the targeting reached the generated ninja. Seconds.
.\build.ps1 build -Profile zen5       # autoninja chrome + mini_installer. HOURS first time.
.\build.ps1 test -Profile zen5        # base_unittests + a headless smoke test
.\build.ps1 analyze -Profile zen5     # ISA report from the built chrome.dll
.\build.ps1 package -Profile zen5     # release folder under releases\
.\build.ps1 publish -Profile zen5     # GitHub Releases (needs gh auth login)
```

After the first build, `update.ps1` runs all of this unattended; see
`docs/UPDATES.md`. Then register the scheduled tasks and the desktop icon
appears on the next deploy:

```powershell
.\scripts\Install-ThoriumTasks.ps1
```

`build.ps1 build -Target <ninja-target>` builds named targets only and
writes no manifest. `root_store_tool` is about 2,500 steps and two minutes
and still links base under ThinLTO, which is what the toolchain-bug matrices
in `docs/TOOLCHAIN-BUGS.md` were bisected with.

## The baseline profile

```powershell
.\build.ps1 configure -Profile baseline
.\build.ps1 build -Profile baseline
.\build.ps1 analyze -Profile baseline
python scripts\compare_builds.py --repo-root C:\thorium --profiles baseline zen5
```

Stock Chromium with the same shared args, in its own `out\thorium-baseline`.
Comparisons are recorded in `docs/BENCHMARKS.md`.

## About PGO

`build.ps1 configure` uses Google's official, generic win64 Chrome PGO
profile, the one `chrome/build/win64.pgo.txt` names for the checked-out
revision, downloading it via Chromium's `tools/update_pgo_profiles.py` when
missing. It is milestone-matched but **not** Zen 5-trained and not trained
on this machine's workload.

Training a local profile means an instrumented `chrome_pgo_phase=1` build, a
representative workload, a `.profraw` to `.profdata` merge and a second full
build, repeated every milestone. Out of scope for the pipeline.

## Code signing

None. This is a personal build; SmartScreen may warn when a release's
installer is run by hand. The deploy path runs it silently and is
unaffected.

## Clang and znver5

The pinned clang must know `-march=znver5`. If it did not, the compile would
fail outright ("unknown target CPU"), and `verify-source.ps1` separately
asserts `-march=znver5` is in the generated ninja before any build starts.
