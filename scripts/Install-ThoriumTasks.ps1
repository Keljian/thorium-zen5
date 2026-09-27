#Requires -Version 5.1
<#
.SYNOPSIS
    Register (or remove) the two scheduled tasks that keep the browser current.

.DESCRIPTION
    "Thorium Zen5 - Build upstream updates"
        update.ps1 -Yes, daily. Self-gating: one HTTP request on days nothing
        shipped, the full pipeline when something has. Also retries an
        unpublished release and deploys the newest one.
        8-hour time limit: a full build takes 2-3 hours, so anything past 8 is
        hung, and the next run reports a run that never finished. Without a
        limit a hung run blocked every later one silently (IgnoreNew).

    "Thorium Zen5 - Offer update"
        Check-ThoriumUpdate.ps1 at logon and hourly: installs the newest
        release if the browser is closed, otherwise flags it on the desktop.
        Must run in your interactive session to reach the desktop and toasts.

    Both per-user, not elevated.

.PARAMETER RunWhenLoggedOff
    Register the build task as S4U so it runs while logged off. Needs an
    elevated shell to register.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet("baseline", "zen5")]
    [string]$Profile = "zen5",
    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$At = "03:00",
    [switch]$RunWhenLoggedOff,
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$UpdatePs1 = Join-Path $RepoRoot "update.ps1"
$CheckPs1  = Join-Path $PSScriptRoot "Check-ThoriumUpdate.ps1"
$BuildTask = "Thorium Zen5 - Build upstream updates"
$OfferTask = "Thorium Zen5 - Offer update"

if ($Unregister) {
    foreach ($t in $BuildTask, $OfferTask) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Write-Host "Removed: $t"
        }
    }
    return
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# Build task.
$buildAction = New-ScheduledTaskAction -Execute (Join-Path $PSHOME "powershell.exe") -WorkingDirectory $RepoRoot `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Profile {1} -Yes' -f $UpdatePs1, $Profile)
$buildSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 8) -MultipleInstances IgnoreNew
if ($RunWhenLoggedOff) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw "-RunWhenLoggedOff registers an S4U task, which needs an elevated shell." }
    $buildPrincipal = New-ScheduledTaskPrincipal -UserId $me -LogonType S4U -RunLevel Limited
} else {
    $buildPrincipal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
}

# Offer task. wscript + run-hidden.vbs, because Windows Terminal opens a
# window before powershell.exe can honour -WindowStyle Hidden.
$offerAction = New-ScheduledTaskAction -Execute "wscript.exe" -WorkingDirectory $RepoRoot `
    -Argument ('"{0}" "{1}" "-Profile" "{2}"' -f (Join-Path $PSScriptRoot "run-hidden.vbs"), $CheckPs1, $Profile)
# A daily trigger with a 24-hour repetition window; RepetitionDuration
# MaxValue serialises to a value Task Scheduler rejects.
$offerRepeat = New-ScheduledTaskTrigger -Daily -At $At
$offerRepeat.Repetition = (New-ScheduledTaskTrigger -Once -At $At -RepetitionInterval (New-TimeSpan -Hours 1) `
    -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition
$offerTriggers = @((New-ScheduledTaskTrigger -AtLogOn -User $me), $offerRepeat)
$offerSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
$offerPrincipal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited

if ($PSCmdlet.ShouldProcess($BuildTask, "Register (daily at $At)")) {
    Register-ScheduledTask -TaskName $BuildTask -Action $buildAction -Trigger (New-ScheduledTaskTrigger -Daily -At $At) `
        -Settings $buildSettings -Principal $buildPrincipal -Force `
        -Description "Rebuilds Chromium stable with the Zen 5 patch when upstream moves, then deploys it. A no-op on quiet days." | Out-Null
    Write-Host "Registered: $BuildTask (daily $At, 8h limit)"
}
if ($PSCmdlet.ShouldProcess($OfferTask, "Register (logon, then hourly)")) {
    Register-ScheduledTask -TaskName $OfferTask -Action $offerAction -Trigger $offerTriggers `
        -Settings $offerSettings -Principal $offerPrincipal -Force `
        -Description "Installs the newest Zen 5 Chromium release if the browser is closed; otherwise marks it on the desktop icon." | Out-Null
    Write-Host "Registered: $OfferTask (logon, then hourly)"
}
