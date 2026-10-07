#Requires -Version 5.1
<#
.SYNOPSIS
    Check this machine can build and run the Zen 5 browser before starting a
    first build that takes hours.

.DESCRIPTION
    Read-only. Prints one line per check: OK, WARN (works, with a cost) or
    FAIL (fix before building). Exit 1 if anything failed.

    The Windows SDK version is pinned by Chromium itself, so it can only be
    checked exactly once the checkout exists; before that this lists what is
    installed, and build.ps1 configure names the exact version if it is
    missing.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$script:Failed = 0

function Report([string]$State, [string]$Name, [string]$Detail) {
    $colour = @{ OK = "Green"; WARN = "Yellow"; FAIL = "Red" }[$State]
    Write-Host ("{0,-5} {1,-22} {2}" -f $State, $Name, $Detail) -ForegroundColor $colour
    if ($State -eq "FAIL") { $script:Failed++ }
}

# CPU. The browser is compiled for Zen 5 and faults on anything older, and
# the test stage runs it, so a non-Zen 5 machine cannot complete a build.
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cpu.Manufacturer -eq "AuthenticAMD" -and $cpu.Description -match 'Family 26\b') {
    Report OK "CPU" "$($cpu.Name.Trim()) (Zen 5)"
} else {
    Report FAIL "CPU" "$($cpu.Name.Trim()) is not Zen 5 (AMD family 26). The build would not run on it."
}

# Memory and disk. Figures from docs/BUILD.md.
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramGB -ge 32)     { Report OK   "Memory" "$ramGB GB" }
elseif ($ramGB -ge 16) { Report WARN "Memory" "$ramGB GB. Builds will run with fewer parallel jobs and take longer; 32 GB+ recommended." }
else                   { Report FAIL "Memory" "$ramGB GB. 32 GB+ recommended." }

$drive = (Get-Item $root).PSDrive
$freeGB = [math]::Round($drive.Free / 1GB)
if (Test-Path (Join-Path $root "src")) {
    Report OK "Disk" "$freeGB GB free on $($drive.Name): (checkout already present)"
} elseif ($freeGB -ge 150) {
    Report OK "Disk" "$freeGB GB free on $($drive.Name):"
} else {
    Report FAIL "Disk" "$freeGB GB free on $($drive.Name):. A first build needs 150 GB+."
}

# Tools.
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) { Report OK "Git" $git.Source } else { Report FAIL "Git" "not on PATH. Install Git for Windows." }

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Report FAIL "Python" "python.exe not on PATH. Install Python 3 from python.org and tick 'Add to PATH'."
} elseif ($py.Source -like "*\WindowsApps\*") {
    Report FAIL "Python" "PATH finds the Microsoft Store alias, not a real install. Install Python 3 from python.org, or turn off the alias under App execution aliases."
} else {
    Report OK "Python" $py.Source
}

$dt = Join-Path $root "depot_tools"
if (Test-Path (Join-Path $dt "gclient.py")) {
    Report OK "depot_tools" $dt
} else {
    Report FAIL "depot_tools" "not at $dt. git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git `"$dt`""
}

$pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
if (-not $pf86) { $pf86 = Join-Path $env:SystemDrive "Program Files (x86)" }
$vswhere = Join-Path $pf86 "Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) {
    & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if ($vs) {
    Report OK "Visual Studio C++" $vs
} else {
    Report FAIL "Visual Studio C++" "no Visual Studio with the C++ x64 tools. Install VS 2022 or 2026 (Community or Build Tools) with 'Desktop development with C++'."
}

$kits = $null
try { $kits = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0" -ErrorAction Stop).InstallationFolder } catch { }
if (-not $kits) { $kits = Join-Path $pf86 "Windows Kits\10" }
$installed = @(Get-ChildItem (Join-Path $kits "Include") -Directory -ErrorAction SilentlyContinue |
               Where-Object { Test-Path (Join-Path $_.FullName "um") } | ForEach-Object { $_.Name } | Sort-Object)
$vsTool = Join-Path $root "src\build\vs_toolchain.py"
$m = if (Test-Path $vsTool) { Select-String -Path $vsTool -Pattern "^SDK_VERSION\s*=\s*'([0-9.]+)'" | Select-Object -First 1 }
if ($m) {
    $need = $m.Matches[0].Groups[1].Value
    if ($installed -contains $need) { Report OK "Windows SDK" "$need (the version this Chromium pins)" }
    else { Report FAIL "Windows SDK" "Chromium needs $need; installed: $(if ($installed) { $installed -join ', ' } else { 'none' }). Add it in the Visual Studio Installer under Individual components." }
} elseif ($installed) {
    Report OK "Windows SDK" "installed: $($installed -join ', '). The exact version is checked after the first sync."
} else {
    Report FAIL "Windows SDK" "none found under $kits. Install the Windows 11 SDK with Visual Studio."
}

# Optional: publishing to GitHub Releases.
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Report WARN "GitHub CLI" "not installed. Builds still install locally; publishing to GitHub Releases is skipped."
} else {
    $null = & $gh.Source auth status 2>&1
    if ($LASTEXITCODE -eq 0) { Report OK "GitHub CLI" "logged in" }
    else { Report WARN "GitHub CLI" "installed but not logged in. Run 'gh auth login' to enable publishing." }
}

Write-Host ""
if ($script:Failed) {
    Write-Host "$script:Failed check(s) failed. Fix those before the first build." -ForegroundColor Red
    exit 1
}
$next = if (Test-Path (Join-Path $root "src")) { "" } else { " A first run fetches Chromium and builds everything; expect several hours." }
Write-Host "Ready. Next: .\update.cmd.$next" -ForegroundColor Green
exit 0
