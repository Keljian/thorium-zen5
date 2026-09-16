#Requires -Version 5.1
<#
.SYNOPSIS
    The project's desktop notification, shared by update.ps1 and
    Check-ThoriumUpdate.ps1.

.DESCRIPTION
    Dot-source this; do not run it. It defines Show-ThoriumNotification and the
    AppUserModelID registration it depends on.

    WHY THIS IS TWO SURFACES

    Neither mechanism Windows offers an unpackaged script does both halves of
    the job, so each does the half it actually does.

    DISPLAY is a native toast (Windows.UI.Notifications), which renders
    correctly here: title, body, the lot.

    THE CLICK is a tray icon, delivered in-process. Toast buttons cannot be
    made to work: activationType="protocol" is refused by the toast broker,
    which grants activation only to packaged (MSIX) apps or ones registering a
    COM activator. That was proven rather than assumed -- ShellExecute
    activation of the very same URI ran its handler fine, so the scheme
    resolved and only the broker refused it. A NotifyIcon balloon on its own is
    no good either: its click works, but Windows 11 renders it with no title
    and no body.

    So the toast says what happened and points at the tray icon, and the tray
    icon is the button. The toast carries no buttons, because a button that
    does nothing is worse than no button.

    WHY IT IS SHARED

    update.ps1 and Check-ThoriumUpdate.ps1 both need this. The one time this
    project duplicated a function across those two scripts -- the Chromium
    stable-version resolver -- the same bug ended up in both copies and drove a
    milestone DOWNGRADE. See scripts/ChromiumVersion.ps1. Not repeating that.
#>

$script:ThoriumAppId = "ThoriumZen5.UpdateNotifier"

function Get-ThoriumBrowserExe {
    <# The installed browser's exe, for the notification icon. $null if not installed. #>
    $installPath = (Get-ItemProperty "HKCU:\Software\ThoriumZen5" -ErrorAction SilentlyContinue).InstallPath
    if (-not $installPath) { return $null }
    $exe = Get-ChildItem $installPath -Include "thorium.exe", "chrome.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

function Register-ThoriumAppId {
    <#
    An AppUserModelID registered under HKCU and claimed by this process.

    Both steps are needed. Windows renders a notification from a process it
    cannot attribute with the presentation stripped out -- icon, no title, no
    body -- and registering the id without claiming it leaves the notification
    attributed to "Windows PowerShell" and inheriting that same emptiness.

    Idempotent, HKCU only. No separate setup step to forget.
    #>
    $key = "HKCU:\Software\Classes\AppUserModelId\$script:ThoriumAppId"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name "DisplayName"    -Value "Thorium Zen5" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name "ShowInSettings" -Value 1             -PropertyType DWord  -Force | Out-Null

    $exe = Get-ThoriumBrowserExe
    if ($exe) { New-ItemProperty -Path $key -Name "IconUri" -Value $exe -PropertyType String -Force | Out-Null }

    if (-not ("W.Shell" -as [type])) {
        Add-Type -Namespace W -Name Shell -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, PreserveSig=false)]
public static extern void SetCurrentProcessExplicitAppUserModelID(string AppID);
"@
    }
    try { [W.Shell]::SetCurrentProcessExplicitAppUserModelID($script:ThoriumAppId) } catch { }
}

function Show-ThoriumNotification {
    <#
    Raise a notification and wait for the tray icon to be clicked.

    Returns $true if it was clicked, $false on timeout.

    Cost, stated: the calling process stays alive while the tray icon is up.
    Bound it with -TimeoutMinutes, and keep that under any scheduled task's own
    execution limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string]$TrayTooltip = "Thorium Zen5",
        [int]$TimeoutMinutes = 5,
        [switch]$Quiet
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    Register-ThoriumAppId

    # --- display: native toast
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

        # Clear our own earlier notifications first, or the notification centre
        # accumulates one entry per check and keeps showing stale ones -- during
        # this project's history, stale toasts from an older revision kept
        # offering an "Install now" button long after that button had been
        # removed from the code, which is indistinguishable from a live
        # notification that is broken.
        try { [Windows.UI.Notifications.ToastNotificationManager]::History.Clear($script:ThoriumAppId) } catch { }

        # NOT scenario="reminder". That is for toasts carrying actions the user
        # must answer; ours has none, and Windows files that shape straight into
        # the notification centre without ever drawing a banner.
        $xml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$([System.Security.SecurityElement]::Escape($Title))</text>
      <text>$([System.Security.SecurityElement]::Escape($Body))</text>
    </binding>
  </visual>
</toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:ThoriumAppId).Show($toast)
        if (-not $Quiet) { Write-Host "Notification shown (also filed in the notification centre, Win+N)." }
    } catch {
        # Never let a cosmetic failure cost the caller its notification: the
        # tray icon below is the part that carries the action.
        if (-not $Quiet) { Write-Host "Could not raise the toast ($($_.Exception.Message)). The tray icon is still there." }
    }

    # --- action: tray icon
    $exe = Get-ThoriumBrowserExe
    $icon = if ($exe) { [System.Drawing.Icon]::ExtractAssociatedIcon($exe) } else { [System.Drawing.SystemIcons]::Information }

    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = $icon
    $ni.Text = $TrayTooltip
    $ni.Visible = $true

    $script:ThoriumNotifyClicked = $false
    $onIcon = Register-ObjectEvent -InputObject $ni -EventName Click -Action { $script:ThoriumNotifyClicked = $true }

    try {
        if (-not $Quiet) { Write-Host "Tray icon active for up to $TimeoutMinutes min." }
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while (-not $script:ThoriumNotifyClicked -and (Get-Date) -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
    } finally {
        if ($onIcon) { Unregister-Event -SourceIdentifier $onIcon.Name -ErrorAction SilentlyContinue }
        $ni.Visible = $false
        $ni.Dispose()
    }

    return $script:ThoriumNotifyClicked
}

function Show-ThoriumFailureNotice {
    <#
    The pipeline failed. Say so, and open the log if the tray icon is clicked.

    This exists because a failed build used to tell nobody anything. The
    success path notified; the failure path exited non-zero into a log file
    that only gets read by someone who already suspects something is wrong. A
    milestone bump that breaks the patch anchors would have looked exactly like
    Chromium simply not having shipped a release.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Detail,
        [string]$LogPath,
        [int]$TimeoutMinutes = 5
    )

    $short = if ($Detail.Length -gt 300) { $Detail.Substring(0, 300) + "..." } else { $Detail }
    $body  = "The '$Stage' stage failed, so no new build was produced. $short"
    if ($LogPath) { $body += " Click the tray icon to open the log." }

    $clicked = Show-ThoriumNotification -Title "Thorium Zen5 build FAILED" -Body $body `
        -TrayTooltip "Thorium Zen5 build failed - click to open the log" -TimeoutMinutes $TimeoutMinutes

    if ($clicked -and $LogPath -and (Test-Path $LogPath)) {
        Start-Process notepad.exe -ArgumentList $LogPath -ErrorAction SilentlyContinue
    }
    return $clicked
}
