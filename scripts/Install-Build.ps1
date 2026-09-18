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
    [switch]$Force,

    # Also run the Inno Setup package silently, updating
    # %USERPROFILE%\ThoriumZen5\Application. Off by default because it is a
    # second, separately-installed copy; see the note below on why both exist.
    [switch]$IncludeInno
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

# THERE ARE TWO PLACES THIS PROJECT CAN BE INSTALLED, AND THEY DRIFT.
#
#   A. %LOCALAPPDATA%\Chromium\Application    -- mini_installer.exe, stock
#      Chromium's own layout. Start Menu entry "Chromium".
#   B. %USERPROFILE%\ThoriumZen5\Application  -- the Inno Setup package this
#      repo builds (build.ps1 installer). Start Menu entry "Thorium Zen5".
#
# Found on 2026-09-18: both existed, both reported 154.0.8037.17, and they were
# DIFFERENT BINARIES -- B's chrome.dll was 309,050,880 bytes from 07:46 while
# the build output (and A) was 308,667,904 bytes from 12:46. B predated the
# Rust-targeting rebuild. B is the one actually being run.
#
# This script used to know only about A, so it would report a successful install
# while the browser in daily use stayed on an older build. That is the same
# silent-success failure the rest of this project keeps having to design out, so
# every install location is now enumerated and compared, and a stale one is a
# loud warning rather than an omission.
$InstallLocations = @(
    [PSCustomObject]@{
        Name     = 'Chromium (mini_installer)'
        AppDir   = (Join-Path $env:LOCALAPPDATA 'Chromium\Application')
        Kind     = 'mini'
    }
    [PSCustomObject]@{
        Name     = 'Thorium Zen5 (Inno Setup)'
        AppDir   = (Join-Path $env:USERPROFILE 'ThoriumZen5\Application')
        Kind     = 'inno'
    }
)

function Get-InstalledInfo {
    <#
    Version + chrome.dll hash for one install location. chrome.exe sits at the
    top level in both layouts; chrome.dll lives in the versioned subdirectory.
    #>
    param([Parameter(Mandatory)][string]$AppDir)
    $exe = Join-Path $AppDir 'chrome.exe'
    if (-not (Test-Path $exe)) { return $null }
    $ver = (Get-Item $exe).VersionInfo.FileVersion
    $dll = $null; $hash = $null
    if ($ver) {
        $cand = Join-Path (Join-Path $AppDir $ver) 'chrome.dll'
        if (Test-Path $cand) { $dll = $cand }
    }
    if (-not $dll) {
        $cand = Get-ChildItem $AppDir -Recurse -Filter 'chrome.dll' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($cand) { $dll = $cand.FullName }
    }
    if ($dll) { $hash = (Get-FileHash $dll -Algorithm SHA256).Hash }
    return [PSCustomObject]@{ AppDir = $AppDir; Exe = $exe; Version = $ver; Dll = $dll; Hash = $hash }
}
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
$builtDllPath = Join-Path $RepoRoot "src\out\thorium-$Profile\chrome.dll"
$builtHash = if (Test-Path $builtDllPath) { (Get-FileHash $builtDllPath -Algorithm SHA256).Hash } else { $null }
$installedBefore = Get-FileVersionOrNull $installedExe

Write-Host "built : $builtVersion  ($builtDllPath)"
Write-Host ""
Write-Host "Install locations found:"
$found = @()
foreach ($loc in $InstallLocations) {
    $info = Get-InstalledInfo -AppDir $loc.AppDir
    if (-not $info) { Write-Host ("  {0,-28} not installed" -f $loc.Name); continue }
    $state = if ($builtHash -and $info.Hash -eq $builtHash) { "CURRENT" } else { "STALE" }
    $colour = if ($state -eq 'CURRENT') { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-28} {1,-16} {2}" -f $loc.Name, $info.Version, $state) -ForegroundColor $colour
    Write-Host ("  {0,-28} {1}" -f '', $info.AppDir)
    $found += [PSCustomObject]@{ Loc = $loc; Info = $info; State = $state }
}
Write-Host ""

# A stale install this script does not manage is exactly how "update succeeded"
# can coexist with "the browser I use is old". Say so plainly.
$staleInno = $found | Where-Object { $_.Loc.Kind -eq 'inno' -and $_.State -eq 'STALE' }
if ($staleInno) {
    $setup = Get-ChildItem (Join-Path $RepoRoot 'releases') -Recurse -Filter 'Thorium-Zen5-Setup-*.exe' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host "WARNING: the Inno Setup install ($($staleInno.Info.AppDir)) is NOT this build." -ForegroundColor Yellow
    Write-Host "         That is the one with the 'Thorium Zen5' Start Menu entry -- likely the one you run." -ForegroundColor Yellow
    if ($setup) {
        Write-Host "         Update it with:" -ForegroundColor Yellow
        Write-Host "           `"$($setup.FullName)`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -ForegroundColor Yellow
        Write-Host "         (or run install.cmd -IncludeInno once a fresh installer has been built)" -ForegroundColor Yellow
    } else {
        Write-Host "         No Thorium-Zen5-Setup-*.exe under releases\ yet -- run '.\build.ps1 installer'." -ForegroundColor Yellow
    }
    Write-Host ""
}

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
if ($IncludeInno) {
    $setup = Get-ChildItem (Join-Path $RepoRoot 'releases') -Recurse -Filter 'Thorium-Zen5-Setup-*.exe' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $setup) {
        Write-Host "-IncludeInno: no Thorium-Zen5-Setup-*.exe under releases\. Run '.\build.ps1 installer' first." -ForegroundColor Yellow
    } else {
        $innoDir = Join-Path $env:USERPROFILE 'ThoriumZen5\Application'
        $innoRunning = @(Get-Process chrome -ErrorAction SilentlyContinue |
                         Where-Object { $_.Path -and $_.Path.StartsWith($innoDir, [StringComparison]::OrdinalIgnoreCase) })
        if ($innoRunning.Count -gt 0 -and -not $Force) {
            Write-Host "-IncludeInno: Thorium Zen5 is running ($($innoRunning.Count) processes). Close it, or pass -Force." -ForegroundColor Yellow
        } else {
            if ($innoRunning.Count -gt 0) {
                foreach ($b in ($innoRunning | Where-Object { $_.MainWindowHandle -ne 0 })) { $null = $b.CloseMainWindow() }
                Start-Sleep -Seconds 6
                Get-Process chrome -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -and $_.Path.StartsWith($innoDir, [StringComparison]::OrdinalIgnoreCase) } |
                    Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            Write-Host "Running $($setup.Name) silently ..."
            $ip = Start-Process -FilePath $setup.FullName `
                     -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -PassThru -Wait
            $after = Get-InstalledInfo -AppDir $innoDir
            $ok = ($after -and $builtHash -and $after.Hash -eq $builtHash)
            Write-Host ("Inno install exit $($ip.ExitCode); version now $($after.Version); matches build: $ok")
            if (-not $ok) { Write-Host "WARNING: the Inno install still does not match the build output." -ForegroundColor Yellow }
        }
    }
}

Write-Host "Done." -ForegroundColor Green
exit 0
