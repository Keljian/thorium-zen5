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
    the protocol handler's entry point; see Register-ThoriumUpdateNotifier.ps1.

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

    # The protocol handler appends the activating URI as a positional argument
    # (thorium-zen5-update:install when the toast's button was clicked,
    # thorium-zen5-update:show when the toast body was). Without a parameter to
    # land in, PowerShell rejects the whole call with "A positional parameter
    # cannot be found that accepts argument ...", and a toast button that
    # silently does nothing is worse than no button.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ProtocolArgs
)

$ErrorActionPreference = "Stop"
$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ReleasesDir = Join-Path $RepoRoot "releases"
$RegKey      = "HKCU:\Software\ThoriumZen5"
$AppId       = "ThoriumZen5.UpdateNotifier"

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
# Toast
# ---------------------------------------------------------------------------
function Show-UpdateToast($Available, $Installed) {
    <#
    A toast needs a registered AppUserModelID or Windows drops it silently.
    Register-ThoriumUpdateNotifier.ps1 creates one under HKCU. If it has not
    been run, fall back to the console rather than appearing to have done
    something that did not happen.
    #>
    $aumidKey = "HKCU:\Software\Classes\AppUserModelId\$AppId"
    if (-not (Test-Path $aumidKey)) {
        Say "Update available, but the toast notifier is not registered. Run scripts\Register-ThoriumUpdateNotifier.ps1 once, or install with: .\scripts\Check-ThoriumUpdate.ps1 -Install"
        return
    }

    $from = if ($Installed) { $Installed.Version } else { "not installed" }
    $body = "Chromium $($Available.Version) is built and ready. Installed: $from."

    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $xml = @"
<toast activationType="protocol" launch="thorium-zen5-update:show" scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
      <text>Thorium Zen5 update ready</text>
      <text>$([System.Security.SecurityElement]::Escape($body))</text>
    </binding>
  </visual>
  <actions>
    <action content="Install now" activationType="protocol" arguments="thorium-zen5-update:install"/>
    <action content="Later" activationType="system" arguments="dismiss"/>
  </actions>
</toast>
"@
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
    Say "Toast shown."
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
    # Toast activation arrives as a URI rather than a switch.
    $uri = ($ProtocolArgs | Where-Object { $_ -like "thorium-zen5-update:*" } | Select-Object -First 1)
    if ($uri -and $uri -match ':install$') { $Install = $true }

    $installed = Get-InstalledBuild
    $available = Get-AvailableBuild

    if ($uri -and -not $Install) {
        # Toast body clicked rather than the button: show where the build is
        # instead of installing something nobody asked to install.
        if ($available) { Start-Process explorer.exe $available.Dir }
        exit 0
    }

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
    if (-not $Quiet) { Show-UpdateToast $available $installed }
    exit 10
} catch {
    if (-not $Quiet) { Write-Error $_ }
    exit 1
}
