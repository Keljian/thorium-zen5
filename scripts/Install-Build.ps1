#Requires -Version 5.1
<#
.SYNOPSIS
    Install the built Chromium on THIS machine, silently, user-level.

.DESCRIPTION
    The one implementation of "install this build". Called by update.ps1
    -Install and by install.cmd, so there is no second copy to drift.

    mini_installer.exe installs into %LOCALAPPDATA%\Chromium\Application,
    adopts the existing profile in %LOCALAPPDATA%\Chromium\User Data in place,
    and registers in Add/Remove Programs. --do-not-launch-chrome keeps it
    silent; there is no UI either way.

    Refuses while the installed browser is running, rather than replacing a
    binary underneath a live session.

    NOTE: on Windows `chrome.exe --version` does NOT print and exit -- it
    ignores the flag and launches the browser. The version is read from the
    file's version resource instead.

.PARAMETER Profile
    Which profile's build to install. Default: zen5.

.PARAMETER Force
    Close the running installed browser first instead of refusing.
#>
[CmdletBinding()]
param(
    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$mini = Join-Path $RepoRoot "src\out\thorium-$Profile\mini_installer.exe"
$builtExe = Join-Path $RepoRoot "src\out\thorium-$Profile\chrome.exe"
$appDir = Join-Path $env:LOCALAPPDATA "Chromium\Application"
$installedExe = Join-Path $appDir "chrome.exe"

function Get-FileVersionOrNull([string]$path) {
    if (Test-Path $path) { return (Get-Item $path).VersionInfo.FileVersion }
    return $null
}

if (-not (Test-Path $mini)) {
    Write-Host "No mini_installer.exe at $mini. Build first: .\build.ps1 build -Profile $Profile" -ForegroundColor Red
    exit 2
}

$builtVersion = Get-FileVersionOrNull $builtExe
$installedBefore = Get-FileVersionOrNull $installedExe
Write-Host "built     : $builtVersion"
Write-Host "installed : $installedBefore"

if ($builtVersion -and $installedBefore -and ($builtVersion -eq $installedBefore)) {
    # Same version string does not prove the same binary -- a flag or toolchain
    # change produces an identical version. Compare content before claiming
    # there is nothing to do.
    $same = $false
    $installedDll = Join-Path (Join-Path $appDir $installedBefore) "chrome.dll"
    $builtDll = Join-Path $RepoRoot "src\out\thorium-$Profile\chrome.dll"
    if ((Test-Path $installedDll) -and (Test-Path $builtDll)) {
        $same = (Get-FileHash $installedDll -Algorithm SHA256).Hash -eq
                (Get-FileHash $builtDll -Algorithm SHA256).Hash
    }
    if ($same) {
        Write-Host "Already installed: chrome.dll is byte-identical to the build output. Nothing to do." -ForegroundColor Green
        exit 0
    }
    Write-Host "Same version ($builtVersion) but a DIFFERENT binary -- installing." -ForegroundColor Yellow
}

$running = @(Get-Process chrome -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -and $_.Path.StartsWith($appDir, [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) {
    if (-not $Force) {
        Write-Host ""
        Write-Host "The installed Chromium is running ($($running.Count) processes)." -ForegroundColor Yellow
        Write-Host "Close it and run this again, or pass -Force to close it automatically." -ForegroundColor Yellow
        exit 3
    }
    Write-Host "Closing the running browser (-Force) ..." -ForegroundColor Yellow
    # Graceful first, so the session is saved rather than looking like a crash.
    foreach ($b in ($running | Where-Object { $_.MainWindowHandle -ne 0 })) { $null = $b.CloseMainWindow() }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 700
        $still = @(Get-Process chrome -ErrorAction SilentlyContinue |
                   Where-Object { $_.Path -and $_.Path.StartsWith($appDir, [StringComparison]::OrdinalIgnoreCase) })
        if ($still.Count -eq 0) { break }
    }
    $still = @(Get-Process chrome -ErrorAction SilentlyContinue |
               Where-Object { $_.Path -and $_.Path.StartsWith($appDir, [StringComparison]::OrdinalIgnoreCase) })
    if ($still.Count -gt 0) { $still | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
}

Write-Host "Installing $mini (silent, user-level) ..."
$proc = Start-Process -FilePath $mini -ArgumentList '--do-not-launch-chrome', '--verbose-logging' `
            -PassThru -Wait -WindowStyle Hidden
Write-Host "mini_installer exit code: $($proc.ExitCode)"

$installedAfter = Get-FileVersionOrNull $installedExe
if (-not $installedAfter) {
    Write-Host "FAILED: $installedExe is absent after the install. See $env:TEMP\chrome_installer.log" -ForegroundColor Red
    exit 1
}

# Prove it is actually our build, not just that something got installed.
$verDir = Join-Path $appDir $installedAfter
$instDll = Join-Path $verDir "chrome.dll"
$builtDll = Join-Path $RepoRoot "src\out\thorium-$Profile\chrome.dll"
$match = $null
if ((Test-Path $instDll) -and (Test-Path $builtDll)) {
    $match = (Get-FileHash $instDll -Algorithm SHA256).Hash -eq (Get-FileHash $builtDll -Algorithm SHA256).Hash
}

Write-Host ""
Write-Host "installed version : $installedAfter"
Write-Host "install dir       : $appDir"
Write-Host "chrome.dll matches build output : $match"
if ($match -eq $false) {
    Write-Host "WARNING: the installed chrome.dll does NOT match the build output." -ForegroundColor Yellow
    exit 1
}
Write-Host "Done." -ForegroundColor Green
exit 0
