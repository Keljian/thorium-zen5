# History

Why the scripts look the way they do. Each entry is a real failure on this
machine and what now prevents it. The code keeps a one-line pointer; the
story lives here.

## 2026-09-14

- **Thorium overlay dropped.** Thorium's tree pinned Chromium 138 while
  stable was 154, and its release tags M144..M152 all pointed at one May 8
  commit. The CPU targeting was always this project's own, so it now patches
  stock Chromium directly.
- **`gclient fetch --tags` does not exist** in this depot_tools ("no such
  option"). Tags are fetched with plain `git fetch origin --tags`.
- **`& git ... 2>&1` under `$ErrorActionPreference = "Stop"`** turns any
  stderr line into a terminating error, so the else-branch after a failing
  git call is unreachable. `Invoke-NativeCapture` scopes the preference to
  the call.

## 2026-09-15

- **Stripped environment.** A shell without `ProgramFiles(x86)` made
  Chromium's `vs_toolchain.py` die with `KeyError: 'WINDOWSSDKDIR'`.
  `Get-DepotToolsEnv` now sets it and the other variables Chromium's
  toolchain scripts require.
- **PATH overflow.** vcvarsall runs `set` through cmd.exe (8191-character
  line). A 6,798-character inherited PATH failed it, reported only as
  "error 255". The build gets a short explicit PATH.

## 2026-09-16

- **Near downgrade.** chromiumdash orders releases by release time, and
  entry [0] was 153.0.8010.48 while the checkout was 154. Taking it would
  have synced a milestone backwards. Resolution now takes the highest
  version, and sync refuses to move backwards.
- **Scheduled tasks.** S4U principals need an elevated shell to register;
  `RepetitionDuration` MaxValue serialises to a value Task Scheduler
  rejects; Windows Terminal opens a window before `-WindowStyle Hidden`
  applies, hence `run-hidden.vbs`.

## 2026-09-18

- **The pipeline had never completed an upgrade.** `Invoke-Stage` splatted
  an array, which binds every element positionally, so every stage except
  `sync` failed with "A positional parameter cannot be found that accepts
  argument '-Profile'". Stages now take a hashtable splat.
- **Went quiet after a failed run.** "Up to date" compared the synced tag
  with upstream, and `sync` writes the tag before anything else can fail.
  The check now uses the version of the BUILT binary.
- **70 fake modified files.** `MIMALLOC_VERBOSE=1` at user scope made every
  git call print allocator statistics, and verify parsed them as file
  names. Silenced per process, and git status parsing is strict.
- **Verify passed on stale ninja.** A sync reverted `BUILD.gn` but
  `toolchain.ninja` from the previous configure still carried the flags.
  First fixed with an mtime comparison, replaced on 2026-09-27 by a hash
  stamp (gn rewrites ninja files only when their content changes, so a
  same-tag re-run legitimately leaves an older toolchain.ninja).
- **STATUS_NO_MEMORY at step 3029.** 32 jobs needed more commit than the
  ~42 GB free. Job count is now capped by available commit.
- **9,032 test failures that were 10.** The test launcher inherited
  BelowNormal priority and could not collect results from its children.
  `Run-Tests.ps1` runs at Normal, caps parallelism, detects the out-of-band
  signature, and gates on `known-test-failures.txt`.
- **Concurrent runs** collided on `git fetch` in the shared checkout. A
  named mutex allows one.
- **Two installs drifted.** The Inno Setup install and the mini_installer
  install both reported the same version with different binaries. Inno was
  retired; mini_installer is the only install path.
- **A log reader killed the build.** Add-Content per line hit a sharing
  violation when the log was being tailed. build.ps1 holds one shared
  StreamWriter.

## 2026-09-19

- **Link clicks did nothing.** Hollow per-user `http`/`https` protocol keys
  shadowed the real association. `scripts/Repair-UrlProtocolShadowing.ps1`
  is the manual diagnostic.

## 2026-09-23

- **Compiled but never released.** 154.0.8037.58 compiled, one test failed,
  and the next run saw a current `chrome.exe` and declared itself done. The
  newest packaged release is now part of the rebuild decision.
- **An unrelated app's registry value crashed the notifier.** Unsloth Studio
  writes its InstallLocation in literal quotes; Join-Path read the drive as
  `"C`. The install directory is now a constant.
- **GDI test depends on the PID.** Upstream compares a 16-bit `wProcessId`
  with a 32-bit PID, so it fails whenever the test PID exceeds 65535. It is
  an intermittent (`~`) allowlist entry.
- Rewriting the profile's Preferences file through ConvertTo-Json added a
  BOM. Chromium coped, but the approach was dropped in favour of
  `initial_preferences` and a shortcut flag.

## 2026-09-24

- **Mislabelled release, nearly.** The release picker sorted folders by
  name, which starts with a commit hash, and chose 154.0.8037.58 as the
  newest over 155.0.8059.12. Releases are ordered by the version in their
  manifest, and publish tags from the release's own manifest.

## 2026-09-26

- **Publish 404.** mimalloc statistics appended to `git remote get-url`
  became part of the repository name. The slug takes the first URL line.
- **155 was never installed.** The tray icon's click handler ran through
  `Register-ObjectEvent -Action`, which executes in its own module scope, so
  its `$script:` flag never reached the waiting loop. The click could not
  register. Nothing logged whether the offer was raised either.

## 2026-09-27: consolidation

Audit findings fixed and the scripts shrunk:

- Tray icon and 5-minute wait removed. Deploy installs when the browser is
  closed and otherwise renames the desktop icon to
  "Install Chromium <version>". Toasts are fire-and-forget.
- Installs are verified: installed version must equal the release's, and
  chrome.dll must hash identical when the release records a hash. A refused
  downgrade used to report success.
- Build identity is the chrome.dll SHA-256 in the manifest, replacing the
  BuildId string and the `installed-<profile>.json` record.
- A failed publish is retried on the next run (`published.json` marker).
- The build task has an 8-hour limit, and a run that never finished is
  reported by the next one (`build\run-state.json`). Stalled git transfers
  time out after five minutes.
- The PGO profile is the one `chrome/build/win64.pgo.txt` names, so a
  milestone bump cannot reuse the previous milestone's profile.
- gn's "Build argument has no effect" warning now stops configure.
- Removed: the audit stage, the benchmark stage, the generic-avx512
  profile, the Inno Setup chain, `build.ps1 all`, `-Source GitHub`, and the
  patched-tag marker. Shared code lives in `scripts/Common.ps1`.
