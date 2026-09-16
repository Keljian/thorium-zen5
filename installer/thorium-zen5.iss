; Thorium Zen5 -- Inno Setup installer script.
;
; Invoked by build.ps1's Invoke-Installer with:
;   /DAppFilesDir=<path to extracted browser application files>
;   /DMainExeName=<thorium.exe or chrome.exe>
;   /DThoriumZen5Version=<Chromium version, e.g. 154.0.8037.17>
;   /DBuildId=<chromium_tag+repo_sha+timestamp, uniquely identifies this build>
;   /DProfileName=<zen5|generic-avx512|baseline>
;   /DOutputDir=<releases dir>
;
; ThoriumZen5Version USED TO BE a 10-char commit sha. It is now the Chromium
; version, because it ends up in Add/Remove Programs as DisplayVersion and the
; update checker (scripts/Check-ThoriumUpdate.ps1) has to ORDER it. A sha is
; not orderable, so "is the built one newer than the installed one" was not an
; answerable question. Two builds of the SAME Chromium version are
; distinguished by BuildId instead, which is written to the registry below.
;
; See installer/README.md for why AppFilesDir comes from extracting
; mini_installer.exe's chrome.7z rather than running mini_installer.exe's
; own installer UI: it lets us install under a distinct "Thorium Zen5"
; product identity (install dir, Start Menu entry, Add/Remove Programs
; entry) instead of colliding with any stock Thorium install, and gives us
; full control over upgrade/uninstall/profile-preservation semantics.

#ifndef AppFilesDir
  #error AppFilesDir must be defined (passed by build.ps1)
#endif
#ifndef MainExeName
  #define MainExeName "thorium.exe"
#endif
#ifndef ThoriumZen5Version
  #define ThoriumZen5Version "0.0.0.0"
#endif
#ifndef BuildId
  #define BuildId "unknown"
#endif
#ifndef ProfileName
  #define ProfileName "zen5"
#endif
#ifndef OutputDir
  #define OutputDir "..\releases"
#endif

; Fixed AppId (GUID) so Inno Setup can recognize upgrades vs fresh installs
; across versions. Do not change this once you've done a real install.
#define AppId "{{B7A1E6D4-6E1D-4E7B-9B2C-7A0F1D5E9C31}"

[Setup]
AppId={#AppId}
AppName=Thorium Zen5
AppVersion={#ThoriumZen5Version}
AppPublisher=Personal build (unofficial; not affiliated with Google, the Chromium Authors, or Alex313031/Thorium)
AppPublisherURL=https://github.com/Keljian/thorium-zen5
VersionInfoDescription=Thorium Zen5 -- personal AMD Ryzen 9950X (Zen 5 / AVX-512) optimized Chromium/Thorium build [{#ProfileName}]
; INSTALL LOCATION: under the user profile, NOT under AppData.
; On this machine, a Chromium build installed anywhere beneath
; %LOCALAPPDATA% or %APPDATA% fails to start with
;   "The application has failed to start because its side-by-side
;    configuration is incorrect"
; and Event 33: Activation context generation failed, Dependent Assembly
; <version> could not be found. See installer/README.md "Install location"
; for the isolation: identical bytes run from %USERPROFILE%, from
; %LOCALAPPDATA%\Temp and from C:\thorium, and fail from every other
; AppData path, whatever the internal layout.
DefaultDirName={%USERPROFILE}\ThoriumZen5\Application
DefaultGroupName=Thorium Zen5
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Thorium-Zen5-Setup-{#ProfileName}-{#ThoriumZen5Version}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
; Personal/unofficial build: not code-signed by default (see docs/BUILD.md
; "Code signing"). Add SignTool= here and re-run if you have a certificate.
UninstallDisplayIcon={app}\{#MainExeName}
UninstallDisplayName=Thorium Zen5 ({#ProfileName})
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Registry]
; The update checker's source of truth for "what is installed right now".
;
; Inno already writes DisplayVersion under the Uninstall key, but that is keyed
; on the AppId GUID and is awkward to read; more importantly it cannot tell two
; builds of the same Chromium version apart. These three values can, and they
; are removed on uninstall (uninsdeletekey) so a stale entry never outlives the
; install it describes.
Root: HKCU; Subkey: "Software\ThoriumZen5"; ValueType: string; ValueName: "Version";     ValueData: "{#ThoriumZen5Version}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\ThoriumZen5"; ValueType: string; ValueName: "BuildId";     ValueData: "{#BuildId}";             Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\ThoriumZen5"; ValueType: string; ValueName: "Profile";     ValueData: "{#ProfileName}";         Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\ThoriumZen5"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}";                  Flags: uninsdeletekey

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
; Recursively install every extracted application file. "app" files are
; replaced wholesale on upgrade. This [Files] section never touches the
; user's profile directory (see IMPORTANT note in [Code] below about where
; that actually lives), so upgrades never overwrite bookmarks/history/
; passwords/extensions.
Source: "{#AppFilesDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Thorium Zen5"; Filename: "{app}\{#MainExeName}"; Comment: "Thorium Zen5 -- Zen 5/AVX-512 optimized browser [{#ProfileName}]"
Name: "{group}\Uninstall Thorium Zen5"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Thorium Zen5"; Filename: "{app}\{#MainExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MainExeName}"; Description: "Launch Thorium Zen5"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Only remove application files (handled automatically by Inno via the
; [Files] manifest). User profile data under LOCALAPPDATA\ThoriumZen5\User Data
; is deliberately NOT listed here, so a normal uninstall preserves it --
; matching the spec's "preserve user profile data... except uninstall if
; the user explicitly chooses to remove profile data" (see [Code] below for
; that explicit opt-in prompt).

[Code]
// IMPORTANT / KNOWN LIMITATION (documented in installer/README.md and
// docs/ARCHITECTURE.md "unresolved questions"): Thorium's product-identity
// constants (install_static / chrome_paths.cc) are baked into the compiled
// binary and hardcode the profile directory name as "Thorium" regardless of
// where the .exe is actually installed from. None of the current
// patches/zen5 edits touch this. That means Thorium Zen5, as built by this
// project today, stores its user profile at the SAME path stock Thorium
// would: %LOCALAPPDATA%\Thorium\User Data -- NOT under this installer's own
// %LOCALAPPDATA%\ThoriumZen5\ install directory. On a single-machine
// personal build (this project's stated scope) that's harmless and even
// convenient (an in-place "upgrade" from any previous stock Thorium install
// carries your profile forward automatically); it only matters if you ever
// intend to run stock Thorium and Thorium Zen5 side by side, in which case
// they would currently share one profile. A future patches/zen5 addition
// could rebrand the product-identity constants for full isolation; tracked
// as an unresolved item rather than silently assumed away.
var
  RemoveProfileData: Boolean;

function InitializeUninstall(): Boolean;
begin
  RemoveProfileData := False;
  if MsgBox('Also delete your Thorium Zen5 profile data (bookmarks, history, ' +
            'saved passwords, extensions)? Choose No to keep it for a future reinstall.' + #13#10 + #13#10 +
            'Note: profile data currently lives at %LOCALAPPDATA%\Thorium\User Data ' +
            '(see installer/README.md) -- the same location stock Thorium would use.',
            mbConfirmation, MB_YESNO) = IDYES then
    RemoveProfileData := True;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ProfileDir: String;
begin
  if (CurUninstallStep = usPostUninstall) and RemoveProfileData then
  begin
    ProfileDir := ExpandConstant('{localappdata}\Thorium\User Data');
    if DirExists(ProfileDir) then
      DelTree(ProfileDir, True, True, True);
  end;
end;
