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

    # Run the build even when nobody is logged on. This needs an S4U principal,
    # which Task Scheduler will only register from an ELEVATED shell: without
    # elevation it fails with "Access is denied" (HRESULT 0x80070005), observed
    # on rohansdesktopry 2026-09-16. Without this switch the build task runs as
    # an ordinary interactive task, which is fine on a desktop that stays
    # logged in and needs no elevation at all.
    [switch]$RunWhenLoggedOff,

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

# RunLevel Limited either way: nothing in the pipeline needs admin, and an
# unattended multi-hour build is the last thing that should run elevated.
#
# S4U runs whether or not you are logged on, without storing a password, but
# registering an S4U principal itself requires an elevated shell. Interactive
# is the default so the common case needs no elevation; -RunWhenLoggedOff opts
# into S4U and says plainly what it costs.
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($RunWhenLoggedOff) {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevated) {
        throw ("-RunWhenLoggedOff registers an S4U task, which Task Scheduler only allows from an " +
               "elevated shell (it fails with 'Access is denied' otherwise). Re-run this script as " +
               "Administrator, or drop the switch to register an ordinary interactive task.")
    }
    $buildPrincipal = New-ScheduledTaskPrincipal -UserId $me -LogonType S4U -RunLevel Limited
} else {
    $buildPrincipal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
}

# ---------------------------------------------------------------------------
# Task 2: offer
# ---------------------------------------------------------------------------
$offerAction = New-ScheduledTaskAction -Execute $PwshExe -WorkingDirectory $RepoRoot `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Profile {1}' -f $CheckPs1, $Profile)

# Logon, plus a daily trigger that repeats every 4 hours for 24 hours.
#
# NOT -RepetitionDuration ([TimeSpan]::MaxValue): that serialises to
# P99999999DT23H59M59S, which Task Scheduler rejects outright with "The task
# XML contains a value which is incorrectly formatted or out of range"
# (HRESULT 0x80041318), observed on rohansdesktopry 2026-09-16. A daily
# trigger carrying a 24-hour repetition window is the bounded equivalent and
# repeats forever because the trigger itself recurs daily.
$offerLogon = New-ScheduledTaskTrigger -AtLogOn -User $me
$offerRepeat = New-ScheduledTaskTrigger -Daily -At $At
$offerRepeat.Repetition = (New-ScheduledTaskTrigger -Once -At $At `
    -RepetitionInterval (New-TimeSpan -Hours 4) `
    -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition

$offerSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

# Interactive, deliberately: a toast raised from a non-interactive session is
# never displayed to anyone.
$offerPrincipal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited

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
Write-Host "Nothing else to register: the checker raises the notification itself."
Write-Host "Inspect with: Get-ScheduledTask -TaskName 'Thorium Zen5*' | Format-List TaskName,State"
