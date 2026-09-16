# installer/

`thorium-zen5.iss` is an [Inno Setup](https://jrsoftware.org/isinfo.php)
script. `build.ps1 installer` (or `build.ps1 all`) drives it automatically:

1. Extracts the real application files out of the Chromium-produced
   `mini_installer.exe` (which is a self-extracting 7z archive containing
   `setup.exe` + `chrome.7z`) using 7-Zip, following exactly the same
   extraction Thorium's own docs describe for building a "portable"
   release. This gives raw application files instead of Chromium's own
   installer UI/paths.
2. Feeds those files to `thorium-zen5.iss`, which builds a real Windows
   installer under the distinct product name **Thorium Zen5**, with its own
   Start Menu entry, optional desktop shortcut, Add/Remove Programs entry,
   and upgrade/uninstall handling.

Why not just ship `mini_installer.exe` directly? It installs under
Thorium's own "Thorium" product identity and paths, which is fine for
stock Thorium but doesn't satisfy the project's requirement for the Zen5
build to "have a distinct product name" and "identify itself clearly as a
Zen5 build" in Windows' own UI (Start Menu, Programs and Features).

## Known limitation: profile directory

Thorium's *binary* still hardcodes its profile directory as
`%LOCALAPPDATA%\Thorium\User Data`, independent of where this installer
places the application files -- that's controlled by Thorium's own
`install_static`/`chrome_paths.cc` product constants, which none of
`patches/zen5` currently touch (out of scope: those patches only change
compiler targeting, not product branding). See the `[Code]` section of
`thorium-zen5.iss` for the full explanation. Practical effect for this
project's stated single-machine personal-use scope: none -- it's actually
convenient, since an in-place install here will pick up any existing
Thorium profile automatically. It only matters if you plan to run stock
Thorium and Thorium Zen5 side by side.

## Code signing

Not configured. This is a personal/unofficial build; Windows SmartScreen
will show an "unrecognized publisher" warning on first run of the
installer and the browser. If you own an Authenticode code-signing
certificate, add a `SignTool=` line to `thorium-zen5.iss`'s `[Setup]`
section and a `signtool sign` step to `build.ps1`'s `Invoke-Installer`.

## Install location

The installer targets `%USERPROFILE%\ThoriumZen5\Application`, not
`%LOCALAPPDATA%`, which is where a per-user Chromium would normally go. This
is deliberate and was expensive to learn.

Installed anywhere beneath `%LOCALAPPDATA%` or `%APPDATA%` on this machine,
the browser does not start:

```
The application has failed to start because its side-by-side
configuration is incorrect.

Event 33: Activation context generation failed for "...\chrome.exe".
Dependent Assembly 154.0.8037.17,language="*",type="win32",
version="154.0.8037.17" could not be found.
```

chrome.exe's embedded manifest declares a dependency on a private SxS assembly
named after the version, satisfied by `<version>.manifest` plus
`chrome_elf.dll`.

What the error is NOT, each ruled out by direct test on 2026-09-16:

- **Not missing or corrupt files.** The installed `chrome.exe`,
  `chrome_elf.dll` and `<version>.manifest` are byte-identical (SHA-256) to the
  build output.
- **Not the nested-versus-flat layout.** Flattening the `<version>\` subfolder
  into the application directory changes nothing. Both layouts work in a good
  location and both fail in a bad one.
- **Not a poisoned path.** A fresh directory under `%LOCALAPPDATA%` that has
  never held a failed install fails identically.
- **Not permissions.** Granting `BUILTIN\Users:(RX)` across the whole install
  tree changes nothing.

What it tracks exactly is the **path**. The same 251 files, copied with the
same command, run from:

```
%USERPROFILE%\...                OK
%LOCALAPPDATA%\Temp\...          OK
C:\thorium\...                   OK
```

and fail from:

```
%LOCALAPPDATA%\<anything else>   FAILS
%APPDATA%\...                    FAILS
```

That pattern is consistent with a policy on this machine blocking DLL loads
from user-writable AppData paths -- the SxS assembly declares `chrome_elf.dll`,
so a blocked load surfaces as "assembly could not be found" rather than as an
access-denied error. This machine's `%LOCALAPPDATA%` ACL carries an
AppContainer SID and a `CodexSandboxUsers` group from a sandboxing tool, which
is suggestive but was not proven to be the mechanism: the ACL grant above did
not change the outcome, so the exact policy has not been identified.

The root cause is therefore **recorded but unresolved**. `%USERPROFILE%` is a
verified-working location, not an explanation. If you ever want the real
answer, `sxstrace.exe` from an elevated prompt will name what the loader
probed and why it rejected it; that was not run here.
