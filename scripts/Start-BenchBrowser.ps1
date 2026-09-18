<#
.SYNOPSIS
    Launches one build in isolation for benchmarking.

.DESCRIPTION
    Both builds default to %LOCALAPPDATA%\Chromium\User Data. Chromium's
    process singleton is keyed on the user data directory, so launching the
    second build while the first is still running hands the command line to
    the running browser and exits immediately. The window that appears
    belongs to the first build, and the benchmark compares a build with
    itself.

    This script gives each profile its own user data directory, refuses to
    start while another benchmark browser is running, and fixes the window
    geometry. MotionMark scores scale with drawing surface size, so that
    matters as much as which binary is running.

.EXAMPLE
    .\Start-BenchBrowser.ps1 -BuildProfile baseline -Url https://browserbench.org/MotionMark1.3.1/
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('baseline', 'zen5')]
    [string] $BuildProfile,

    [string] $Url = 'about:blank',

    [int] $Width = 1600,
    [int] $Height = 1000,
    [int] $Left = 80,
    [int] $Top = 40,

    # Use the installed zen5 browser rather than its build output directory.
    # Off by default: an installed layout against a build output directory is
    # a difference that has nothing to do with codegen.
    [switch] $UseInstalled,

    # Close a benchmark browser that is already running instead of refusing.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$root         = 'C:\thorium'
$outBase      = Join-Path $root 'src\out\thorium-baseline\chrome.exe'
$outZen5      = Join-Path $root 'src\out\thorium-zen5\chrome.exe'
# The canonical install. This pointed at %USERPROFILE%\ThoriumZen5\Application
# (the Inno package) until 2026-09-18, when that install was removed: it had
# drifted to a pre-Rust build while reporting the SAME version as the current
# one, so -UseInstalled was silently benchmarking an older binary -- and after
# the removal it pointed at a path that no longer exists at all.
$installedExe = Join-Path $env:LOCALAPPDATA 'Chromium\Application\chrome.exe'
$profileDir   = Join-Path $root "build\bench-profiles\$BuildProfile"

$exe = switch ($BuildProfile) {
    'baseline' { $outBase }
    'zen5'     { if ($UseInstalled) { $installedExe } else { $outZen5 } }
}

if (-not (Test-Path $exe)) {
    throw "No binary for profile '$BuildProfile' at $exe. Build it first."
}

$running = @(Get-Process chrome -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $outBase -or $_.Path -eq $outZen5 -or $_.Path -eq $installedExe })

if ($running.Count -gt 0) {
    $paths = ($running | Select-Object -ExpandProperty Path -Unique) -join ', '
    if (-not $Force) {
        throw "A benchmark browser is already running ($paths). Close it or pass -Force. Two builds running at once compete for the GPU."
    }
    Write-Output "Closing running benchmark browser ($paths)"
    $running | Stop-Process -Force
    Start-Sleep -Seconds 3
}

New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

$chromeArgs = @(
    "--user-data-dir=$profileDir"
    '--no-first-run'
    '--no-default-browser-check'
    '--disable-search-engine-choice-screen'
    "--window-size=$Width,$Height"
    "--window-position=$Left,$Top"
    $Url
)

Write-Output "profile     : $BuildProfile"
Write-Output "binary      : $exe"
Write-Output "profile dir : $profileDir"
Write-Output "window      : ${Width}x${Height} at $Left,$Top"

Start-Process -FilePath $exe -ArgumentList $chromeArgs
Start-Sleep -Seconds 5

$started = @(Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if ($started.Count -eq 0) {
    throw "Nothing started from $exe. Another Chromium took the command line -- check for one using the same profile directory."
}

Write-Output "started     : $($started.Count) processes"
Write-Output 'Leave the window in the foreground and unoccluded for the whole run.'