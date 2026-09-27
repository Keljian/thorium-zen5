# Keeping the browser up to date

Two scheduled tasks do all of it. Nothing needs to be run by hand unless
something fails, and failures raise a toast.

| task | when | does |
|---|---|---|
| Thorium Zen5 - Build upstream updates | daily 03:00, 8 h limit | `update.ps1 -Yes`: rebuild if Chromium stable moved, publish, deploy |
| Thorium Zen5 - Offer update | at logon, then hourly | `Check-ThoriumUpdate.ps1`: deploy |

Register or refresh them with `scripts\Install-ThoriumTasks.ps1` (run it from
a normal PowerShell window, not elevated).

## Deploy

"Deploy" compares the installed browser with the newest complete release
under `releases\`:

| state | result |
|---|---|
| installed is current | desktop icon reads **Update Chromium** |
| newer release, Chromium closed | installed silently, toast says so |
| newer release, Chromium open | desktop icon becomes **Install Chromium &lt;version&gt;**, one toast per build |

Nothing waits for a click and nothing closes the browser. Close Chromium and
the next hourly check installs it, or double-click the desktop icon to do it
now: the icon shows both versions, asks you to close Chromium if it is open,
installs, reopens it, and waits for Enter.

If an automatic install fails it is not retried for that build (no hourly
toast storm); the desktop icon still offers it. Every install and every
waiting build is logged in `build\logs\offer.log`.

Only releases are deployed. A release is written after build, tests and ISA
analysis have all passed, so the raw build output in `src\out` (which can hold
a build whose tests failed) is never installed from here. `install.cmd`
installs `src\out` deliberately, for testing.

### Newer means

- a higher Chromium version, or
- the same version with a **different chrome.dll**. The manifest records
  `chrome_dll_sha256`; the installed `chrome.dll` is hashed and compared. A
  rebuild after a flag or toolchain change keeps the version number and
  changes the binary, so it is offered. A byte-identical rebuild is not.

Releases made before 2026-09-27 carry no hash, so for those an equal version
counts as current.

### What an install proves

`scripts\Install-Build.ps1` runs `mini_installer.exe --do-not-launch-chrome`
(user-level, into `%LOCALAPPDATA%\Chromium\Application`, keeping the existing
profile) and then checks the result itself, because mini_installer's exit code
is an installer status code rather than a success flag:

- the installed version must equal the release's version (a refused
  downgrade or a failed install is reported as a failure), and
- the installed `chrome.dll` must hash identical to the release's, when the
  release records a hash.

It refuses to run while Chromium is open (exit 3) and holds a lock so the
hourly task and the desktop icon cannot install at the same time. After a
successful install it writes `initial_preferences` and adds
`--no-default-browser-check` to the Chromium shortcuts, which stops the
"make Chromium your default browser" prompt that mini_installer brings back.
Windows does not let a script take the default browser association itself.

## The nightly pipeline

```
sync       git checkout -f <stable tag>, gclient sync -D, runhooks
configure  apply the zen5 patch, args.gn, gn gen
verify     verify-source.ps1: the targeting reached the generated ninja (hard stop)
build      chrome + mini_installer, build manifest
test       base_unittests via Run-Tests.ps1, headless smoke test
analyze    ISA report; warns if the AVX-512 count fell
package    releases\thorium-zen5-<profile>-<chromium sha>-<time>\
publish    GitHub Releases (non-fatal; retried next run)
deploy     as above
```

A rebuild happens when any of these is true, and never otherwise:

- upstream stable is newer than the **built** binary (`chrome.exe` version),
- the checkout is ahead of the built binary (a run died after sync),
- the built binary is newer than the newest **release** (a run compiled and
  then failed a later stage),
- there is no usable previous build.

The synced tag alone is not the test: a run that fails after sync has
already advanced it. The resolved stable version is the highest one
chromiumdash reports for Windows, and sync refuses to move the checkout
backwards.

Every run, including a quiet one, also publishes the newest release if it
was never published (`published.json` in the release folder marks success)
and deploys.

### Resuming

```powershell
.\update.ps1 -Yes -FromStage package   # e.g. after a test failure is understood
.\update.ps1 -Yes -Force               # rebuild the current tag from sync
.\update.ps1 -CheckOnly                # exit 10 if a rebuild is needed
```

Stages are idempotent. Skipping `verify` skips the check that stops a
silently generic build, so skip it only on purpose.

### Hangs and crashes

`build\run-state.json` says `running` while a run is in progress. If the next
run finds it still saying `running`, the previous run was killed (the 8-hour
limit), crashed, or the machine restarted, and it says so in a toast. A
stalled git transfer times out after five minutes rather than hanging the run.
One pipeline runs at a time (a named mutex); a second exits 11, and a build
already running in the same out directory outside the pipeline also exits 11,
with a toast.

### Exit codes

| code | meaning |
|---|---|
| 0 | nothing to do, or the pipeline completed |
| 1 | a stage failed (`build\logs\update.log`) |
| 2 | the zen5 patch no longer applies, or configure failed |
| 3 | verify failed: the targeting did not reach the build files |
| 10 | `-CheckOnly`: a rebuild is needed |
| 11 | another run, or another build in the same out dir, is in progress |

## Patch conflicts

The only file patched is `src/build/config/compiler/BUILD.gn`. Sync discards
it with `git checkout -f` and configure re-applies the patch from scratch, so
there is no merge to conflict. If `apply_zen5_patches.py` cannot find one of
its two anchors exactly once, it writes nothing and exits 3, and the pipeline
stops at configure (exit 2). See `patches/zen5/README.md` "Regenerating after
upstream changes". The diff of each fresh application is saved under
`build\patch-capture\` for comparison with the tracked reference diff.

## Clang rolls

The two toolchain workarounds in `gn/win_zen5_args.gn` are pinned to a clang
revision. When `tools/clang/scripts/update.py` rolls, the log says so and asks
for a re-test with the `root_store_tool` canary. See `docs/TOOLCHAIN-BUGS.md`.

## Publishing

`build.ps1 publish` uploads the newest release, tagged
`v<chromium-version>-<profile>` from that release's own manifest, with notes
generated from the manifest and ISA report. The repository is private on
purpose: `proprietary_codecs`, `ffmpeg_branding = "Chrome"` and
`enable_widevine` are not ours to redistribute. Do not make it public without
stripping those.

`gh` must be logged in as you (`gh auth login`), in a normal shell.

## Toasts

A toast from an unpackaged script can display text but cannot carry a working
button (Windows grants activation only to MSIX apps or COM activators), so
toasts only report; the desktop icon is the action. The toast is attributed to
a registered AppUserModelID (`ThoriumZen5.UpdateNotifier`), without which
Windows shows it with no title or body.

## Allocator noise

`MIMALLOC_VERBOSE=1` is set at user scope on this machine, and git runs on
mimalloc, so every git call prints allocator statistics. `scripts\Common.ps1`
forces `MIMALLOC_VERBOSE`, `MIMALLOC_SHOW_STATS` and `MIMALLOC_SHOW_ERRORS` to 0
for its own process and children; your environment is left alone. Removing
`MIMALLOC_VERBOSE` from your user environment would silence it everywhere.
