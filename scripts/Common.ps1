#Requires -Version 5.1
# Shared helpers. Dot-source this; do not run it.
#
# Everything that more than one script needs lives here exactly once: paths,
# Chromium version resolution, what is installed, what has been released, the
# "is this newer" rule, the desktop icon and the toast. Duplicated copies of
# these have drifted apart before (see docs/HISTORY.md).

$ThoriumRoot   = Split-Path -Parent $PSScriptRoot
$ThoriumBuild  = Join-Path $ThoriumRoot "build"
$ThoriumLogs   = Join-Path $ThoriumBuild "logs"
$ReleasesDir   = Join-Path $ThoriumRoot "releases"

# mini_installer's own per-user location. Constant: it is the only place this
# project installs to, and reading it off the uninstall keys means trusting
# every other application's registry values too.
$InstallDir    = Join-Path $env:LOCALAPPDATA "Chromium\Application"

# MIMALLOC_VERBOSE=1 is set at user scope on this machine and git is built on
# mimalloc, so child processes append allocator statistics to their output.
# Silenced for this process and its children only.
$env:MIMALLOC_VERBOSE     = '0'
$env:MIMALLOC_SHOW_STATS  = '0'
$env:MIMALLOC_SHOW_ERRORS = '0'

New-Item -ItemType Directory -Force -Path $ThoriumBuild, $ThoriumLogs | Out-Null

function Add-LogLine {
    # Best effort: a locked log file must never stop the caller.
    param([string]$Path, [string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    try { Add-Content -Path $Path -Value $line -ErrorAction Stop } catch { }
    return $line
}

function Invoke-NativeCapture {
    <#
    Run a native command and return exit code plus combined output without
    throwing. Under $ErrorActionPreference = "Stop", `& git ... 2>&1` turns any
    stderr line into a terminating error; the function-scoped "Continue" here
    shadows that for the duration of the call.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $null
    )
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0
    $pushed = $false
    try {
        if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $pushed = $true }
        $output = & $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    } finally {
        if ($pushed) { Pop-Location }
    }
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join "`n") }
}

function Get-RepoSlug {
    # owner/name for gh, from the origin remote. First URL-shaped line only, so
    # anything else a child process prints cannot become part of the name.
    $r = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $ThoriumRoot, "remote", "get-url", "origin")
    if ($r.ExitCode -ne 0) { throw "Could not read the 'origin' remote from $ThoriumRoot." }
    $url = @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } |
             Where-Object { $_ -match '^(https?://|git@|ssh://)' } | Select-Object -First 1)[0]
    if (-not $url -or $url -notmatch '[:/]([^/:]+)/([^/]+?)(\.git)?\s*$') {
        throw "Unrecognised origin remote: $($r.Output)"
    }
    return "$($Matches[1])/$($Matches[2])"
}

# ---------------------------------------------------------------------------
# Chromium versions
# ---------------------------------------------------------------------------
function Resolve-ChromiumStableTag {
    <#
    The HIGHEST current Chromium stable version for Windows, which is also the
    git tag in chromium/src. chromiumdash orders by release time and several
    milestones ship concurrently, so entry [0] can be an older milestone.
    #>
    $uri = "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num=10"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = "thorium-zen5" } -UseBasicParsing -TimeoutSec 60
    } catch {
        throw "Could not resolve the current Chromium stable version from $uri : $_"
    }
    $versions = @(@($resp) | ForEach-Object { $_.version } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    if (-not $versions) { throw "chromiumdash returned no usable stable version for Windows." }
    return [string]($versions | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
}

function Test-ChromiumVersionIsNewer {
    # True only when $Candidate is strictly newer than $Current. Also the
    # downgrade guard: an older resolved version never counts as an update.
    param([Parameter(Mandatory)][string]$Candidate, [string]$Current)
    if (-not $Current)                               { return $true }
    if ($Candidate -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $false }
    if ($Current   -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $true }
    return ([version]$Candidate) -gt ([version]$Current)
}

function Get-FileVersionOrNull([string]$Path) {
    # chrome.exe --version launches the browser on Windows; read the resource.
    if ($Path -and (Test-Path -LiteralPath $Path)) { return (Get-Item -LiteralPath $Path).VersionInfo.FileVersion }
    return $null
}

function Get-Sha256OrNull([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $null
}

# ---------------------------------------------------------------------------
# What is installed, what is released, and which is newer
# ---------------------------------------------------------------------------
function Get-InstalledBuild {
    # $null when nothing is installed. chrome.dll lives in <version>\ beside
    # chrome.exe; its hash is what tells two builds of one version apart.
    $exe = Join-Path $InstallDir "chrome.exe"
    $ver = Get-FileVersionOrNull $exe
    if (-not $ver) { return $null }
    $dll = Join-Path (Join-Path $InstallDir $ver) "chrome.dll"
    return [PSCustomObject]@{ Version = $ver; Exe = $exe; Dll = $dll; DllHash = (Get-Sha256OrNull $dll) }
}

function Get-NewestRelease {
    <#
    The newest complete packaged release for a profile: highest Chromium
    version, then newest build time. A folder without both a manifest and a
    mini_installer is a half-written package and is skipped. Folder names are
    never used for ordering; they start with a commit hash.
    #>
    param([string]$Profile = "zen5")
    $best = $null
    foreach ($d in @(Get-ChildItem $ReleasesDir -Directory -Filter "thorium-zen5-$Profile-*" -ErrorAction SilentlyContinue)) {
        $mf = Join-Path $d.FullName "build-manifest-$Profile.json"
        $mi = Get-ChildItem $d.FullName -Filter "thorium_zen5_mini_installer_*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $mi -or -not (Test-Path $mf)) { continue }
        try { $m = Get-Content $mf -Raw | ConvertFrom-Json } catch { continue }
        $tag = [string]$m.source_revisions.chromium_tag
        if ($tag -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
        $at = try { ([datetime]$m.generated_at_utc).ToUniversalTime() } catch { $d.LastWriteTimeUtc }
        $cand = [PSCustomObject]@{
            Version      = $tag
            Name         = $d.Name
            Dir          = $d.FullName
            Installer    = $mi.FullName
            ManifestPath = $mf
            Manifest     = $m
            At           = $at
            # Manifests from before 2026-09-27 carry no hash; see Test-ReleaseIsNewer.
            DllHash      = [string]$m.chrome_dll_sha256
            Published    = (Test-Path (Join-Path $d.FullName "published.json"))
        }
        if (-not $best -or [version]$cand.Version -gt [version]$best.Version -or
            ([version]$cand.Version -eq [version]$best.Version -and $cand.At -gt $best.At)) { $best = $cand }
    }
    return $best
}

function Test-ReleaseIsNewer {
    <#
    Newer version wins. At the same version the release is newer only when it
    is a DIFFERENT chrome.dll from the installed one: a rebuild after a flag or
    toolchain change keeps the version and changes the binary. A release with
    no recorded hash cannot be compared, so an equal version counts as current
    rather than nagging.
    #>
    param($Release, $Installed)
    if (-not $Release)   { return $false }
    if (-not $Installed) { return $true }
    $r = [version]$Release.Version; $i = [version]$Installed.Version
    if ($r -ne $i) { return ($r -gt $i) }
    if (-not $Release.DllHash -or -not $Installed.DllHash) { return $false }
    return ($Release.DllHash -ne $Installed.DllHash)
}

function Get-BrowserProcesses {
    # Only the installed browser, not a test run out of src\out or another
    # Chromium-based app.
    return @(Get-Process chrome -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) })
}

# ---------------------------------------------------------------------------
# Desktop icon
# ---------------------------------------------------------------------------
function Set-UpdateShortcut {
    <#
    The desktop icon runs Check-ThoriumUpdate.ps1 -Interactive. Its NAME is the
    status: "Update Chromium" normally, "Install Chromium <version>" while a
    newer build is waiting for the browser to close. Recreated if missing;
    duplicates are removed. Must run in the real user context (a scheduled
    task or a normal shell), since the desktop lives under the user profile.
    #>
    param([string]$PendingVersion)
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path $desktop)) { return }
    $want   = if ($PendingVersion) { "Install Chromium $PendingVersion.lnk" } else { "Update Chromium.lnk" }
    $target = Join-Path $desktop $want
    $shell  = New-Object -ComObject WScript.Shell

    $ours = @(Get-ChildItem $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like 'Update Chromium*.lnk' -or $_.Name -like 'Install Chromium *.lnk' } |
              Where-Object { $shell.CreateShortcut($_.FullName).Arguments -match 'Check-ThoriumUpdate\.ps1' })

    $keep = $ours | Where-Object { $_.Name -eq $want } | Select-Object -First 1
    if (-not $keep -and $ours.Count -gt 0) {
        Move-Item -LiteralPath $ours[0].FullName -Destination $target -Force
        $keep = Get-Item -LiteralPath $target
    }
    foreach ($o in $ours) {
        if ($keep -and $o.FullName -ne $keep.FullName -and (Test-Path -LiteralPath $o.FullName)) {
            Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $keep) {
        $sc = $shell.CreateShortcut($target)
        $sc.TargetPath       = Join-Path $PSHOME "powershell.exe"
        $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $ThoriumRoot 'scripts\Check-ThoriumUpdate.ps1')`" -Interactive"
        $sc.WorkingDirectory = $ThoriumRoot
        $sc.IconLocation     = "$env:SystemRoot\System32\imageres.dll,229"
        $sc.Description      = "Install the newest Zen 5 Chromium build"
        $sc.Save()
    }
}

# ---------------------------------------------------------------------------
# Toast
# ---------------------------------------------------------------------------
$script:ThoriumAppId = "ThoriumZen5.UpdateNotifier"

function Show-ThoriumToast {
    <#
    Fire-and-forget. A toast from an unpackaged script can display but cannot
    carry a working button (activation needs MSIX or a COM activator), so it
    only ever says what happened; the desktop icon is the action.

    Windows renders a toast from a process it cannot attribute with no title
    and no body, so the AppUserModelID is registered under HKCU and claimed by
    this process first. Earlier toasts from this id are cleared so the
    notification centre holds only the current state. Never throws.
    #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body)
    try {
        $key = "HKCU:\Software\Classes\AppUserModelId\$script:ThoriumAppId"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name DisplayName    -Value "Chromium Zen 5" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name ShowInSettings -Value 1 -PropertyType DWord -Force | Out-Null
        $exe = Join-Path $InstallDir "chrome.exe"
        if (Test-Path $exe) { New-ItemProperty -Path $key -Name IconUri -Value $exe -PropertyType String -Force | Out-Null }

        if (-not ("ThoriumZen5.Shell" -as [type])) {
            Add-Type -Namespace ThoriumZen5 -Name Shell -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, PreserveSig=false)]
public static extern void SetCurrentProcessExplicitAppUserModelID(string AppID);
"@
        }
        try { [ThoriumZen5.Shell]::SetCurrentProcessExplicitAppUserModelID($script:ThoriumAppId) } catch { }

        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        try { [Windows.UI.Notifications.ToastNotificationManager]::History.Clear($script:ThoriumAppId) } catch { }

        $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$(& $esc $Title)</text><text>$(& $esc $Body)</text></binding></visual></toast>")
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:ThoriumAppId).Show($toast)
        return $true
    } catch {
        return $false
    }
}
