# Shared Chromium stable-version resolution. Dot-source this from build.ps1 and
# update.ps1.
#
# This logic used to be duplicated in both scripts, with a comment in update.ps1
# asking future editors to "keep in sync with the identical function in
# build.ps1". That is exactly how the bug documented below came to exist in two
# places at once, so the duplication is now gone rather than commented.

function Resolve-ChromiumStableTag {
    <#
    .SYNOPSIS
        Returns the HIGHEST current Chromium stable version for Windows
        (e.g. "154.0.8037.17"), which is also the git tag in chromium/src.

    .DESCRIPTION
        Tracking *stable* rather than trunk is the security-relevant choice:
        trunk is whatever landed an hour ago and can be broken outright, while
        stable is the branch Google ships CVE fixes on.

        WHY "highest version" AND NOT "first entry"
        -------------------------------------------
        chromiumdash orders releases by RELEASE TIME, not by version, and Chrome
        ships several stable milestones CONCURRENTLY. Actual response observed
        2026-09-16:

            [0] 153.0.8010.48   <- most recently RELEASED
            [1] 153.0.8010.47
            [2] 154.0.8037.17   <- highest VERSION (what this project builds)
            [3] 152.0.7977.85
            [4] 153.0.8010.37

        The previous implementation asked for num=1 and took entry [0]. Two
        compounding faults:

          * num=1 means a newer milestone is never even returned;
          * entry [0] is whichever milestone shipped a patch most recently,
            which can be an OLDER milestone.

        Run against the state above, it resolved 153.0.8010.48 while the
        checkout was pinned to 154.0.8037.17 -- so `update.ps1` reported
        "changed=True" and a full pipeline run would have synced the browser
        BACKWARDS a milestone, discarding the security fixes that exist only in
        154, and burning a ~2h rebuild to do it.

        So: request several, and pick the highest version.
    #>
    param([int]$Count = 10)

    $uri = "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num=$Count"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = "thorium-zen5" } -UseBasicParsing
    } catch {
        throw "Failed to resolve the current Chromium stable version from $uri -- check network access: $_"
    }

    $versions = @($resp) |
        ForEach-Object { $_.version } |
        Where-Object { $_ -and ($_ -match '^\d+\.\d+\.\d+\.\d+$') }

    if (-not $versions) {
        throw ("chromiumdash returned no usable 'version' for channel=Stable platform=Windows. " +
               "Response: $($resp | ConvertTo-Json -Compress -Depth 3)")
    }

    return [string](@($versions) | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
}

function Test-ChromiumVersionIsNewer {
    <#
    .SYNOPSIS
        True only when $Candidate is strictly newer than $Current.

    .DESCRIPTION
        A downgrade guard, deliberately separate from the resolution above. Even
        if version resolution regresses again, the pipeline must never sync the
        checkout backwards onto an older milestone: that would silently drop
        shipped security fixes, which is the opposite of why this project tracks
        stable at all.
    #>
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [string]$Current
    )
    if (-not $Current)                                    { return $true }
    if ($Candidate -notmatch '^\d+\.\d+\.\d+\.\d+$')      { return $false }
    if ($Current   -notmatch '^\d+\.\d+\.\d+\.\d+$')      { return $true }
    return ([version]$Candidate) -gt ([version]$Current)
}
