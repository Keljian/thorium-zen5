#Requires -Version 5.1
<#
.SYNOPSIS
    Is there a newer Thorium Zen5 build than the one installed? If so, offer it.

.DESCRIPTION
    The machine that builds this browser and the machine that runs it are the
    same machine, so "is there an update" is a local question: compare what the
    installer wrote to HKCU against the newest packaged release under releases\.
    Going out to the GitHub API to ask about a file this computer produced
    itself would add a network dependency and an auth dependency to a question
    that can be answered from disk. -Source GitHub is there for the day a second
    machine wants the same build.

    Comparison is two-stage, because a version number alone cannot answer it:

      1. Chromium version, ordered. 154.0.8040.3 beats 154.0.8037.17.
      2. If the versions are equal, BuildId. A rebuild of the same Chromium
         version after a flag or toolchain change is a different build and
         should be offerable, and its BuildId differs even though its version
         does not.

    Nothing is installed without a click. -Install is what the toast's button
    (and only the toast's button) invokes.

.PARAMETER Profile
    Which profile's releases to look at. Default: zen5.

.PARAMETER Source
    Local (default) reads releases\. GitHub queries `gh release list`.

.PARAMETER Install
    Skip the check UI and install the newest available build silently. This is
    what the notification's click handler calls, and it is also the way to
    install from a terminal without waiting for a notification.

.PARAMETER Quiet
    No console output and no toast. Sets the exit code only, for a scheduled
    task that wants to decide for itself.

.OUTPUTS
    Exit 0  up to date (or install completed)
    Exit 10 an update is available
    Exit 1  something went wrong

.EXAMPLE
    .\Check-ThoriumUpdate.ps1
    .\Check-ThoriumUpdate.ps1 -Quiet; if ($LASTEXITCODE -eq 10) { ... }
#>
[CmdletBinding()]
param(
    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",

    [ValidateSet("Local", "GitHub")]
    [string]$Source = "Local",

    [switch]$Install,
    [switch]$Quiet,

    # How long to leave the notification up waiting for a click. The scheduled
    # task that runs this has its own 10-minute execution limit, so keep this
    # comfortably under it.
    [int]$TimeoutMinutes = 5
)

$ErrorActionPreference = "Stop"
$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ReleasesDir = Join-Path $RepoRoot "releases"
$RegKey      = "HKCU:\Software\ThoriumZen5"

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

# ---------------------------------------------------------------------------
# What is installed
# ---------------------------------------------------------------------------
function Get-InstalledBuild {
    <#
    Returns $null when nothing is installed, which is a normal state and not an
    error: the first run of this script on a machine that has only ever run the
    browser out of src\out\ has nothing to compare against, and the right
    answer there is "here is a build you could install", not a failure.
    #>
    if (-not (Test-Path $RegKey)) { return $null }
    $p = Get-ItemProperty $RegKey -ErrorAction SilentlyContinue
    if (-not $p -or -not $p.Version) { return $null }
    return @{
        Version     = [string]$p.Version
        BuildId     = [string]$p.BuildId
        Profile     = [string]$p.Profile
        InstallPath = [string]$p.InstallPath
    }
}

# ---------------------------------------------------------------------------
# What is available
# ---------------------------------------------------------------------------
function Get-AvailableBuild {
    if ($Source -eq "GitHub") { return Get-AvailableBuildFromGitHub }
    return Get-AvailableBuildFromDisk
}

function Get-AvailableBuildFromDisk {
    $dirs = Get-ChildItem $ReleasesDir -Directory -Filter "thorium-zen5-$Profile-*" -ErrorAction SilentlyContinue
    $best = $null
    foreach ($d in $dirs) {
        $setup = Get-ChildItem $d.FullName -Filter "Thorium-Zen5-Setup-*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        $mf    = Join-Path $d.FullName "build-manifest-$Profile.json"
        # A release folder without both is a half-finished package (installer
        # stage never ran, or the run died between stages). Skip it rather than
        # offering an update that cannot be installed.
        if (-not $setup -or -not (Test-Path $mf)) { continue }

        $m = Get-Content $mf -Raw | ConvertFrom-Json
        $version = $m.source_revisions.chromium_tag
        if (-not $version -or $version -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }

        $repoSha = $m.source_revisions.thorium_zen5_repo_commit
        $short   = if ($repoSha) { $repoSha.Substring(0, [Math]::Min(10, $repoSha.Length)) } else { "nosha" }
        $stamp   = try { ([datetime]$m.generated_at_utc).ToUniversalTime().ToString("yyyyMMddHHmmss") } catch { "00000000000000" }

        $cand = @{
            Version   = $version
            BuildId   = "$version+$short+$stamp"
            Installer = $setup.FullName
            Stamp     = $stamp
            Dir       = $d.FullName
        }
        # Newest wins: version first, then build timestamp, so a rebuild of the
        # same Chromium version still sorts after the one it replaces.
        if (-not $best -or
            ([version]$cand.Version -gt [version]$best.Version) -or
            ([version]$cand.Version -eq [version]$best.Version -and $cand.Stamp -gt $best.Stamp)) {
            $best = $cand
        }
    }
    return $best
}

function Get-RepoSlug {
    <#
    owner/name for gh, resolved from the git remote rather than hardcoded or
    inferred from the current directory. A scheduled task does not run with its
    cwd inside the repo, and gh with no --repo would then talk to whatever
    repository the cwd happens to belong to, or to none.
    #>
    $url = & git -C $RepoRoot remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $url) { throw "Could not read the 'origin' remote from $RepoRoot." }
    if ($url -notmatch '[:/]([^/:]+)/([^/]+?)(\.git)?\s*$') { throw "Unrecognized remote URL: $url" }
    return "$($Matches[1])/$($Matches[2])"
}

function Get-AvailableBuildFromGitHub {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "-Source GitHub needs the GitHub CLI (gh) on PATH and an authenticated account."
    }
    $slug = Get-RepoSlug
    $json = & gh release list --repo $slug --limit 30 --json tagName,createdAt 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw "gh release list failed for $slug. Check 'gh auth status'." }

    $best = $null
    foreach ($r in ($json | ConvertFrom-Json)) {
        # Tags are v<version>-<profile>, written by build.ps1 publish.
        if ($r.tagName -notmatch "^v(\d+\.\d+\.\d+\.\d+)-$([regex]::Escape($Profile))$") { continue }
        $version = $Matches[1]
        $cand = @{
            Version   = $version
            BuildId   = $null          # not carried in the tag; see the note below
            Installer = $null          # downloaded on demand by Install-Build
            Stamp     = ([datetime]$r.createdAt).ToUniversalTime().ToString("yyyyMMddHHmmss")
            Tag       = $r.tagName
        }
        if (-not $best -or [version]$cand.Version -gt [version]$best.Version) { $best = $cand }
    }
    # Honest limitation: a GitHub-sourced check can only compare versions, not
    # BuildIds, because the tag does not carry one (two builds of the same
    # Chromium version would collide on the same tag and the second is uploaded
    # with --clobber). Same-version rebuilds are therefore invisible over this
    # path. The local path does not have this problem, which is the other reason
    # it is the default.
    return $best
}

# ---------------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------------
function Test-IsNewer($Available, $Installed) {
    if (-not $Available) { return $false }
    if (-not $Installed) { return $true }
    $a = [version]$Available.Version
    $i = [version]$Installed.Version
    if ($a -gt $i) { return $true }
    if ($a -lt $i) { return $false }
    # Same Chromium version. Different build is still an update; unknown
    # BuildId (the GitHub path) is deliberately treated as NOT newer, so an
    # ambiguous answer never nags.
    if (-not $Available.BuildId) { return $false }
    return ($Available.BuildId -ne $Installed.BuildId)
}

# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------
function Show-UpdateNotification {
    <#
    Returns $true if the user asked to install.

    WHY THIS IS A NotifyIcon AND NOT A NATIVE TOAST WITH BUTTONS
    ------------------------------------------------------------
    The first version of this used Windows.UI.Notifications directly, with an
    "Install now" button using activationType="protocol" against a custom
    thorium-zen5-update: scheme registered under HKCU\Software\Classes.

    The toast displayed correctly. The button did not work. Clicking it
    produced "Get an app to open this 'thorium-zen5-update' link".

    That is NOT a registration problem, and it was worth proving rather than
    guessing. With the handler temporarily repointed at a script that recorded
    what it received, ShellExecute activation of the same URI ran the handler
    fine -- so the scheme resolves, and the shell can open it. What cannot open
    it is the toast activation broker, which requires the notifying app to have
    an identity Windows only grants to packaged (MSIX) apps or to apps
    registering a COM activator CLSID. A .ps1 run from Task Scheduler is
    neither, and the usual workaround -- a Start Menu shortcut carrying a
    System.AppUserModel.ID, set through IPropertyStore P/Invoke -- is a hundred
    lines of COM interop to obtain an app identity we are only pretending to
    have, which would then be one Windows update away from breaking again.

    A NotifyIcon balloon avoids the broker entirely. Windows still surfaces it
    as a notification and still files it in Action Center, but the click event
    is delivered straight to the process that raised it, so the handler is a
    PowerShell event subscription rather than a URI the OS has to route back to
    an app it does not believe exists.

    Cost of the approach, stated: this process has to stay alive while the
    notification is on screen, and a tray icon is visible for that window.
    TimeoutMinutes bounds it, and the scheduled task's own 10-minute execution
    limit bounds it again.
    #>
    param($Available, $Installed, [int]$TimeoutMinutes = 5)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $from = if ($Installed) { $Installed.Version } else { "not installed" }

    # Icon: the installed browser's own, when there is one. Falls back to the
    # shell's information icon rather than failing over something cosmetic.
    $icon = $null
    if ($Installed -and $Installed.InstallPath) {
        $exe = Get-ChildItem $Installed.InstallPath -Include "thorium.exe", "chrome.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe.FullName) }
    }
    if (-not $icon) { $icon = [System.Drawing.SystemIcons]::Information }

    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = $icon
    $ni.Text = "Thorium Zen5"
    $ni.BalloonTipTitle = "Thorium Zen5 update ready"
    $ni.BalloonTipText = "Chromium $($Available.Version) is built and ready (installed: $from). Click to install."
    $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $ni.Visible = $true

    $script:NotifyClicked = $false
    $script:NotifyDone = $false
    # BalloonTipClicked fires on the notification; Click fires on the tray icon
    # itself, which is the fallback if the balloon has already auto-dismissed
    # into Action Center by the time the user looks at it.
    $onClick  = Register-ObjectEvent -InputObject $ni -EventName BalloonTipClicked -Action { $script:NotifyClicked = $true; $script:NotifyDone = $true }
    $onIcon   = Register-ObjectEvent -InputObject $ni -EventName Click            -Action { $script:NotifyClicked = $true; $script:NotifyDone = $true }
    $onClosed = Register-ObjectEvent -InputObject $ni -EventName BalloonTipClosed -Action { $script:NotifyDone = $true }

    try {
        $ni.ShowBalloonTip(30000)
        Say "Notification shown. Waiting up to $TimeoutMinutes min for a click."
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while (-not $script:NotifyDone -and (Get-Date) -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        # A dismissed balloon is not a decline: it may have auto-hidden into
        # Action Center while the user was elsewhere. Keep the tray icon
        # clickable for the rest of the window in that case.
        if ($script:NotifyDone -and -not $script:NotifyClicked) {
            while (-not $script:NotifyClicked -and (Get-Date) -lt $deadline) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 200
            }
        }
    } finally {
        foreach ($s in @($onClick, $onIcon, $onClosed)) { if ($s) { Unregister-Event -SourceIdentifier $s.Name -ErrorAction SilentlyContinue } }
        $ni.Visible = $false
        $ni.Dispose()
    }

    return $script:NotifyClicked
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
function Install-Build($Available, $Installed) {
    if (-not $Available) { throw "Nothing available to install." }

    $installer = $Available.Installer
    if (-not $installer -and $Available.Tag) {
        $tmp = Join-Path $env:TEMP "thorium-zen5-$($Available.Tag)"
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Say "Downloading $($Available.Tag) from GitHub..."
        & gh release download $Available.Tag --repo (Get-RepoSlug) --pattern "Thorium-Zen5-Setup-*.exe" --dir $tmp --clobber
        if ($LASTEXITCODE -ne 0) { throw "gh release download failed for $($Available.Tag)." }
        $installer = (Get-ChildItem $tmp -Filter "Thorium-Zen5-Setup-*.exe" | Select-Object -First 1).FullName
    }
    if (-not $installer -or -not (Test-Path $installer)) { throw "Installer not found: $installer" }

    # Refuse to install over a running browser. Inno would prompt to close it,
    # but this path runs unattended from a toast click, where a modal prompt
    # nobody sees looks like a hang.
    $running = Get-Process -Name "thorium", "chrome" -ErrorAction SilentlyContinue |
               Where-Object { $_.Path -and $Installed -and $Installed.InstallPath -and $_.Path.StartsWith($Installed.InstallPath, [StringComparison]::OrdinalIgnoreCase) }
    if ($running) {
        Say "Thorium Zen5 is running. Close it and run this again, or install manually: $installer"
        return 1
    }

    Say "Installing $($Available.Version)..."
    # VERYSILENT with no restart; Inno returns 0 on success.
    $p = Start-Process -FilePath $installer -ArgumentList @("/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES") -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Installer exited $($p.ExitCode)." }
    Say "Installed $($Available.Version)."
    return 0
}

# ---------------------------------------------------------------------------
try {
    $installed = Get-InstalledBuild
    $available = Get-AvailableBuild

    if ($Install) {
        exit (Install-Build $available $installed)
    }

    if (-not $available) {
        Say "No complete packaged release for profile '$Profile' found via $Source."
        exit 0
    }

    if (-not (Test-IsNewer $available $installed)) {
        $what = if ($installed) { "Installed $($installed.Version) is current." } else { "Nothing installed, and nothing newer available." }
        Say $what
        exit 0
    }

    Say "Update available: $($available.Version) (installed: $(if ($installed) { $installed.Version } else { 'none' }))"
    if ($Quiet) { exit 10 }

    if (Show-UpdateNotification -Available $available -Installed $installed -TimeoutMinutes $TimeoutMinutes) {
        exit (Install-Build $available $installed)
    }
    Say "Not installed. The build stays in $($available.Dir); run with -Install whenever you want it."
    exit 10
} catch {
    if (-not $Quiet) { Write-Error $_ }
    exit 1
}
