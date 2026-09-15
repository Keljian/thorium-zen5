#Requires -Version 5.1
<#
.SYNOPSIS
    Register (or remove) the two scheduled tasks that make updates automatic.

.DESCRIPTION
    Task 1 -- "Thorium Zen5 - Build upstream updates"
        Runs update.ps1 -Yes daily. update.ps1 self-gates: it asks chromiumdash
        for the highest current stable, compares it to build\chromium-tag.txt,
        and exits immediately if there is nothing newer, so running it daily
        costs one HTTP request on the days nothing has shipped. When something
        has, it runs the whole pipeline: sync, patch, configure, build, test,
        analyze, benchmark, package, installer, publish.

        Runs whether or not you are logged on, but NOT with highest
        privileges: nothing in the pipeline needs admin, and a multi-hour
        unattended build is the last thing that should run elevated.

        DoNotAllowStartIfOnBatteries is off because this is a desktop, and
        ExecutionTimeLimit is set to zero (unlimited) because the default
        three days would be fine but the default *72-hour kill* on a build
        that has hung is not the failure mode you want at hour 71; update.ps1
        already stops itself at the first failing stage.

    Task 2 -- "Thorium Zen5 - Offer update"
        Runs Check-ThoriumUpdate.ps1 at logon and every 4 hours, in your
        interactive session, which is a hard requirement: a toast raised from
        Session 0 is never seen by anyone. It installs nothing on its own. It
        compares what is installed against what is built and, if there is
        something newer, raises the toast whose button installs it.

    Both tasks are per-user. Nothing here writes outside your account.

.PARAMETER Profile
    Which profile the tasks operate on. Default: zen5.

.PARAMETER At
    Time of day for the daily build check, 24h HH:mm. Default 03:00, on the
    theory that a build you did not ask for should not start while you are
    using the machine.

.PARAMETER Unregister
    Remove both tasks and exit.

.PARAMETER WhatIf
    Show what would be registered without touching Task Scheduler.

.EXAMPLE
    .\Install-ThoriumTasks.ps1 -WhatIf
    .\Install-ThoriumTasks.ps1
    .\Install-ThoriumTasks.ps1 -Unregister
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",

    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$At = "03:00",

    [switch]$Unregister
)

$ErrorActionPreference = "Stop"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$UpdatePs1  = Join-Path $RepoRoot "update.ps1"
$CheckPs1   = Join-Path $PSScriptRoot "Check-ThoriumUpdate.ps1"
$PwshExe    = Join-Path $PSHOME "powershell.exe"

$BuildTask  = "Thorium Zen5 - Build upstream updates"
$OfferTask  = "Thorium Zen5 - Offer update"

if ($Unregister) {
    foreach ($t in @($BuildTask, $OfferTask)) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Write-Host "Removed scheduled task: $t"
        } else {
            Write-Host "Not present: $t"
        }
    }
    return
}

foreach ($p in @($UpdatePs1, $CheckPs1)) {
    if (-not (Test-Path $p)) { throw "Missing $p -- run this from the repo's scripts\ directory." }
}

# ---------------------------------------------------------------------------
# Task 1: build
# ---------------------------------------------------------------------------
$buildAction = New-ScheduledTaskAction -Execute $PwshExe -WorkingDirectory $RepoRoot `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Profile {1} -Yes' -f $UpdatePs1, $Profile)

$buildTrigger = New-ScheduledTaskTrigger -Daily -At $At

$buildSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

# S4U: runs whether or not you are logged on, without storing a password and
# without needing network credentials. The build touches only local files and
# HTTPS, so it does not need the network-authenticated token a stored-password
# logon would give it.
$buildPrincipal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType S4U -RunLevel Limited

# ---------------------------------------------------------------------------
# Task 2: offer
# ---------------------------------------------------------------------------
$offerAction = New-ScheduledTaskAction -Execute $PwshExe -WorkingDirectory $RepoRoot `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Profile {1}' -f $CheckPs1, $Profile)

# Logon plus a repeating 4-hour trigger. The repetition is attached to a
# once-trigger starting a minute from now rather than to the logon trigger,
# because a repetition on a logon trigger only repeats within that logon
# session and stops looking like it works after the first sleep/resume.
$offerLogon = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$offerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration ([TimeSpan]::MaxValue)

$offerSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

# Interactive, deliberately: a toast raised from a non-interactive session is
# never displayed to anyone.
$offerPrincipal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive -RunLevel Limited

# ---------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($BuildTask, "Register scheduled task (daily at $At)")) {
    Register-ScheduledTask -TaskName $BuildTask -Action $buildAction -Trigger $buildTrigger `
        -Settings $buildSettings -Principal $buildPrincipal -Force `
        -Description "Checks for a newer Chromium stable and, if there is one, runs the full Thorium Zen5 pipeline. Self-gating: a no-op on days nothing has shipped." | Out-Null
    Write-Host "Registered: $BuildTask (daily $At)"
}

if ($PSCmdlet.ShouldProcess($OfferTask, "Register scheduled task (at logon, then every 4h)")) {
    Register-ScheduledTask -TaskName $OfferTask -Action $offerAction -Trigger @($offerLogon, $offerRepeat) `
        -Settings $offerSettings -Principal $offerPrincipal -Force `
        -Description "Compares the installed Thorium Zen5 against the newest packaged build and raises a toast if there is a newer one. Installs nothing by itself." | Out-Null
    Write-Host "Registered: $OfferTask (logon, then every 4h)"
}

Write-Host ""
Write-Host "Run scripts\Register-ThoriumUpdateNotifier.ps1 once as well, or the toast will not appear."
Write-Host "Inspect with: Get-ScheduledTask -TaskName 'Thorium Zen5*' | Format-List TaskName,State"
