#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy the newest packaged build: install it if the browser is closed,
    otherwise flag it on the desktop.

.DESCRIPTION
    Compares the installed browser with the newest complete release under
    releases\ (see Get-NewestRelease and Test-ReleaseIsNewer in Common.ps1).
    Releases are only written after build, tests and ISA analysis pass, so the
    raw build output in src\out is never deployed from here.

    Default (the scheduled task, and the end of update.ps1):
      * up to date         -> the desktop icon reads "Update Chromium"
      * newer, browser shut -> install silently, toast the result
      * newer, browser open -> the desktop icon becomes
                              "Install Chromium <version>", and one toast per
                              build says so. The next check with the browser
                              closed installs it.
    Nothing waits and nothing closes the browser.

    A failed automatic install is not retried for the same build; the desktop
    icon still offers it, and build\logs\offer.log has the installer output.

.PARAMETER Interactive
    The desktop icon. Shows both versions, asks you to close the browser if it
    is open, installs, reopens the browser, and waits for Enter.

.PARAMETER Install
    Install the newest release now if it is newer (with -Force, even if not).

.PARAMETER Quiet
    Change nothing. Exit 10 if an update is available, 0 if not.

.NOTES
    Exit codes: 0 up to date or installed | 10 update waiting | 1 failed
#>
[CmdletBinding()]
param(
    [ValidateSet("baseline", "zen5")]
    [string]$Profile = "zen5",
    [switch]$Interactive,
    [switch]$Install,
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common.ps1")

$OfferLog   = Join-Path $ThoriumLogs "offer.log"
$StateFile  = Join-Path $ThoriumBuild "deploy-state-$Profile.json"
$InstallPs1 = Join-Path $PSScriptRoot "Install-Build.ps1"

function Log([string]$m) { $null = Add-LogLine -Path $OfferLog -Message $m }

function Get-State {
    $s = try { Get-Content $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
    if (-not $s) { $s = [PSCustomObject]@{ Notified = ""; Failed = "" } }
    return $s
}
function Save-State($s) { try { $s | ConvertTo-Json | Set-Content -Path $StateFile -Encoding ASCII } catch { } }

function Invoke-Install($Release) {
    # Returns the Install-Build exit code; its output goes to the console
    # when interactive and to offer.log otherwise.
    if ($Interactive) {
        & $InstallPs1 -Profile $Profile -Installer $Release.Installer
        return $LASTEXITCODE
    }
    $out = & $InstallPs1 -Profile $Profile -Installer $Release.Installer *>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($l in ($out -split "`r?`n" | Where-Object { $_.Trim() })) { Log "  $l" }
    return $code
}

function Get-VersionText($b) { if ($b) { $b.Version } else { "nothing" } }

try {
    $release   = Get-NewestRelease -Profile $Profile
    $installed = Get-InstalledBuild
    $newer     = Test-ReleaseIsNewer $release $installed

    # ---------------------------------------------------------------- quiet
    if ($Quiet) { if ($newer) { exit 10 } else { exit 0 } }

    # ------------------------------------------------------------- -Install
    if ($Install) {
        if (-not $release) { Write-Host "No complete release under releases\."; exit 1 }
        if (-not $newer -and -not $Force) { Write-Host "Installed $(Get-VersionText $installed) is current."; exit 0 }
        $code = Invoke-Install $release
        Log "install requested: $($release.Version) ($($release.Name)) -> exit $code"
        if ($code -eq 0) { Set-UpdateShortcut }
        exit $code
    }

    # --------------------------------------------------------- desktop icon
    if ($Interactive) {
        try { $Host.UI.RawUI.WindowTitle = "Update Chromium (Zen 5)" } catch { }
        Write-Host "Installed : $(Get-VersionText $installed)"
        Write-Host ("Available : " + $(if ($release) { "$($release.Version)   ($($release.Name))" } else { "none" }))
        Write-Host ""
        $code = 0
        if (-not $release) {
            Write-Host "No complete packaged release under releases\." -ForegroundColor Yellow
        } elseif (-not $newer) {
            Write-Host "Up to date." -ForegroundColor Green
            Set-UpdateShortcut
        } else {
            $wasOpen = (Get-BrowserProcesses).Count -gt 0
            $go = $true
            while ((Get-BrowserProcesses).Count -gt 0) {
                $a = Read-Host "Chromium is open. Close all its windows, then press Enter to install $($release.Version) (N to cancel)"
                if ($a -match '^[Nn]') { $go = $false; break }
            }
            if (-not $go) {
                Write-Host "Not installed."
                $code = 10
            } else {
                $code = Invoke-Install $release
                Log "desktop install: $($release.Version) (was $(Get-VersionText $installed)) -> exit $code"
                Write-Host ""
                if ($code -eq 0) {
                    Write-Host "Updated to $($release.Version)." -ForegroundColor Green
                    Set-UpdateShortcut
                    if ($wasOpen) { Start-Process -FilePath (Join-Path $InstallDir "chrome.exe") }
                } else {
                    Write-Host "Update did not complete (exit $code)." -ForegroundColor Red
                }
            }
        }
        Write-Host ""
        Read-Host "Press Enter to close" | Out-Null
        exit $code
    }

    # --------------------------------------------------------------- deploy
    if (-not $newer) { Set-UpdateShortcut; exit 0 }

    $state = Get-State
    if ((Get-BrowserProcesses).Count -gt 0) {
        Set-UpdateShortcut -PendingVersion $release.Version
        if ($state.Notified -ne $release.Name) {
            Log "waiting: $($release.Version) ($($release.Name)) is ready, installed $(Get-VersionText $installed), browser open"
            $null = Show-ThoriumToast -Title "Chromium $($release.Version) is ready" `
                -Body "It installs by itself at the next hourly check with Chromium closed, or now from the 'Install Chromium $($release.Version)' icon on the desktop."
            $state.Notified = $release.Name
            Save-State $state
        }
        exit 10
    }

    if ($state.Failed -eq $release.Name) {
        # Already failed once for this build; do not retry or re-toast every hour.
        Set-UpdateShortcut -PendingVersion $release.Version
        exit 1
    }

    Log "auto-install: $($release.Version) ($($release.Name)), was $(Get-VersionText $installed)"
    $code = Invoke-Install $release
    Log "auto-install: exit $code"
    switch ($code) {
        0 {
            Set-UpdateShortcut
            $null = Show-ThoriumToast -Title "Chromium $($release.Version) installed" `
                -Body "Installed while the browser was closed. Previous version: $(Get-VersionText $installed)."
            $state.Notified = ""; $state.Failed = ""; Save-State $state
            exit 0
        }
        { $_ -in 3, 4 } {
            # The browser opened, or another install started, in the meantime.
            Set-UpdateShortcut -PendingVersion $release.Version
            exit 10
        }
        default {
            Set-UpdateShortcut -PendingVersion $release.Version
            $null = Show-ThoriumToast -Title "Chromium $($release.Version) did not install" `
                -Body "Install-Build exited $code. Details in build\logs\offer.log. The desktop icon can retry."
            $state.Failed = $release.Name; Save-State $state
            exit 1
        }
    }
} catch {
    Log "FAILED: $($_.Exception.Message)"
    if ($Interactive) {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Press Enter to close" | Out-Null
    } elseif (-not $Quiet) { Write-Host "FAILED: $($_.Exception.Message)" }
    exit 1
}
