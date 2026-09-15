#Requires -Version 5.1
<#
.SYNOPSIS
    One-time HKCU registration so update toasts can appear and their button works.

.DESCRIPTION
    Two things have to exist before Check-ThoriumUpdate.ps1 can show a toast
    with a working "Install now" button, and Windows fails both of them
    silently rather than with an error:

    1. An AppUserModelID. A toast raised by a process without a registered
       AUMID is dropped on the floor, no exception, no notification, nothing in
       Action Center. Registering one under HKCU\Software\Classes is enough;
       the usual alternative is to borrow PowerShell's own AUMID, which works
       until the notification is attributed to "Windows PowerShell" in Settings
       and the user turns it off wondering what it is.

    2. A URI protocol handler. Toast buttons cannot run a command directly;
       activationType="protocol" is the only route that survives the toast
       outliving the process that raised it, which is exactly what happens here
       (the checker exits, the toast sits in Action Center, the button is
       clicked an hour later).

    Everything written is under HKCU. No admin rights, no machine-wide state,
    and -Unregister removes all of it.

.PARAMETER Profile
    Baked into the protocol handler's command line. Default: zen5.

.PARAMETER Unregister
    Remove both registrations and exit.

.EXAMPLE
    .\Register-ThoriumUpdateNotifier.ps1
    .\Register-ThoriumUpdateNotifier.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"

$AppId       = "ThoriumZen5.UpdateNotifier"
$Scheme      = "thorium-zen5-update"
$AumidKey    = "HKCU:\Software\Classes\AppUserModelId\$AppId"
$SchemeKey   = "HKCU:\Software\Classes\$Scheme"
$CheckScript = Join-Path $PSScriptRoot "Check-ThoriumUpdate.ps1"

if ($Unregister) {
    foreach ($k in @($AumidKey, $SchemeKey)) {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force; Write-Host "Removed $k" }
        else { Write-Host "Not present: $k" }
    }
    return
}

if (-not (Test-Path $CheckScript)) { throw "Check-ThoriumUpdate.ps1 not found next to this script at $CheckScript" }

# 1. AppUserModelID -- what the toast is attributed to in Action Center and in
#    Settings > Notifications, where the user can turn it off on purpose rather
#    than by accident.
New-Item -Path $AumidKey -Force | Out-Null
New-ItemProperty -Path $AumidKey -Name "DisplayName" -Value "Thorium Zen5" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $AumidKey -Name "ShowInSettings" -Value 1 -PropertyType DWord -Force | Out-Null

$browserExe = $null
$installPath = (Get-ItemProperty "HKCU:\Software\ThoriumZen5" -ErrorAction SilentlyContinue).InstallPath
if ($installPath) {
    $browserExe = Get-ChildItem $installPath -Include "thorium.exe", "chrome.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($browserExe) {
    New-ItemProperty -Path $AumidKey -Name "IconUri" -Value $browserExe.FullName -PropertyType String -Force | Out-Null
}

Write-Host "Registered AppUserModelID: $AppId"

# 2. Protocol handler. -WindowStyle Hidden so a toast click does not flash a
#    console; "%1" carries the activating URI, which the checker reads to tell
#    an Install click from a body click.
$cmd = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Profile {2} "%1"' -f `
    (Join-Path $PSHOME "powershell.exe"), $CheckScript, $Profile

New-Item -Path $SchemeKey -Force | Out-Null
Set-ItemProperty -Path $SchemeKey -Name "(default)" -Value "URL:Thorium Zen5 Update"
New-ItemProperty -Path $SchemeKey -Name "URL Protocol" -Value "" -PropertyType String -Force | Out-Null

$cmdKey = Join-Path $SchemeKey "shell\open\command"
New-Item -Path $cmdKey -Force | Out-Null
Set-ItemProperty -Path $cmdKey -Name "(default)" -Value $cmd

Write-Host "Registered protocol: $Scheme"
Write-Host ""
Write-Host "Test it with:"
Write-Host "  .\Check-ThoriumUpdate.ps1 -Profile $Profile"
Write-Host "and, to confirm the button path works without waiting for a real update:"
Write-Host "  Start-Process '$($Scheme):show'"
