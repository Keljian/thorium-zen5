#Requires -Version 5.1
<#
.SYNOPSIS
    Install a build on this machine, silently, and prove it landed.

.DESCRIPTION
    The one implementation of "install this build", used by
    Check-ThoriumUpdate.ps1 (releases) and install.cmd (the raw build output).

    mini_installer.exe installs user-level into %LOCALAPPDATA%\Chromium\
    Application and keeps the existing profile. Its exit code is an installer
    status code, not a success flag, so success is decided afterwards: the
    installed version must equal the build's version, and chrome.dll must hash
    identical to the build's when that hash is known. A refused downgrade or a
    half-finished install therefore reports failure instead of success.

    Never closes the browser. If it is running, nothing is changed (exit 3).

    After a successful install it stops the default-browser nag:
    initial_preferences beside chrome.exe for new profiles, and
    --no-default-browser-check on the Chromium shortcuts for existing ones.
    mini_installer ships neither.

.PARAMETER Installer
    A packaged release's mini_installer. Its version and chrome.dll hash come
    from the build-manifest beside it. Without this, the build output in
    src\out\thorium-<profile> is installed, which may not have passed tests.

.NOTES
    Exit codes: 0 installed (or already this exact build)
                1 the install did not verify
                2 nothing to install
                3 the browser is running; nothing changed
                4 another install is in progress
#>
[CmdletBinding()]
param(
    [ValidateSet("baseline", "zen5")]
    [string]$Profile = "zen5",
    [string]$Installer
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common.ps1")

if ($Installer) {
    $mf = Join-Path (Split-Path $Installer -Parent) "build-manifest-$Profile.json"
    $m = if (Test-Path $mf) { Get-Content $mf -Raw | ConvertFrom-Json } else { $null }
    $expectVersion = if ($m) { [string]$m.source_revisions.chromium_tag } else { $null }
    $expectHash    = if ($m) { [string]$m.chrome_dll_sha256 } else { $null }
} else {
    $out = Join-Path $ThoriumRoot "src\out\thorium-$Profile"
    $Installer     = Join-Path $out "mini_installer.exe"
    $expectVersion = Get-FileVersionOrNull (Join-Path $out "chrome.exe")
    $expectHash    = Get-Sha256OrNull (Join-Path $out "chrome.dll")
}

if (-not (Test-Path -LiteralPath $Installer)) { Write-Host "No installer at $Installer." -ForegroundColor Red; exit 2 }
if ($expectVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Write-Host "Cannot tell which Chromium version $Installer is (no manifest or chrome.exe beside it)." -ForegroundColor Red
    exit 2
}

# One install at a time: the offer task and the desktop icon can overlap.
$mutex = New-Object System.Threading.Mutex($false, 'Global\ThoriumZen5-install')
$owned = try { $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $true }
if (-not $owned) { Write-Host "Another install is already running." -ForegroundColor Yellow; exit 4 }

$before = Get-InstalledBuild
Write-Host ("installing : $expectVersion  ($Installer)")
Write-Host ("installed  : " + $(if ($before) { $before.Version } else { "nothing" }))

if ($before -and $expectHash -and $before.Version -eq $expectVersion -and $before.DllHash -eq $expectHash) {
    Write-Host "Already installed: chrome.dll is byte-identical. Nothing to do." -ForegroundColor Green
    exit 0
}
if ($before -and ([version]$before.Version -gt [version]$expectVersion)) {
    Write-Host "Refusing to downgrade $($before.Version) to $expectVersion." -ForegroundColor Red
    exit 1
}
$running = Get-BrowserProcesses
if ($running.Count -gt 0) {
    Write-Host "Chromium is running ($($running.Count) processes). Close it and try again; nothing was changed." -ForegroundColor Yellow
    exit 3
}

$proc = Start-Process -FilePath $Installer -ArgumentList '--do-not-launch-chrome', '--verbose-logging' `
            -PassThru -Wait -WindowStyle Hidden
$after = Get-InstalledBuild

$problem = $null
if (-not $after) {
    $problem = "chrome.exe is missing from $InstallDir after the install."
} elseif ($after.Version -ne $expectVersion) {
    $problem = "installed version is $($after.Version), expected $expectVersion."
} elseif ($expectHash -and $after.DllHash -ne $expectHash) {
    $problem = "installed chrome.dll does not match the build (hash differs)."
}
if ($problem) {
    Write-Host "FAILED: $problem mini_installer exit $($proc.ExitCode); log: $env:TEMP\chrome_installer.log" -ForegroundColor Red
    exit 1
}
$how = if ($expectHash) { "version and chrome.dll hash verified" } else { "version verified; this release records no hash" }
Write-Host "Installed $($after.Version) ($how)." -ForegroundColor Green

# Default-browser nag. Non-fatal: a browser that nags still installed fine.
try {
    $prefs = Join-Path $InstallDir "initial_preferences"
    if (-not (Test-Path $prefs)) {
        $json = '{"browser":{"check_default_browser":false},"distribution":{"make_chrome_default":false,' +
                '"make_chrome_default_for_user":false,"skip_first_run_ui":true},"first_run_tabs":[]}'
        [IO.File]::WriteAllText($prefs, $json)   # no BOM
    }
    $shell = New-Object -ComObject WScript.Shell
    $dirs = @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')) |
            Where-Object { $_ -and (Test-Path $_) }
    foreach ($lnk in (Get-ChildItem $dirs -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
        $sc = $shell.CreateShortcut($lnk.FullName)
        if ($sc.TargetPath -ne $after.Exe -or $sc.Arguments -match '--no-default-browser-check') { continue }
        $sc.Arguments = ("$($sc.Arguments) --no-default-browser-check").Trim()
        $sc.Save()
    }
} catch {
    Write-Host "Default-browser settings not applied (not fatal): $($_.Exception.Message)" -ForegroundColor Yellow
}
exit 0
