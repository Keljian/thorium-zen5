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
