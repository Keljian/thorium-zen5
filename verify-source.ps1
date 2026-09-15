#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies the state of the stock-Chromium source tree matches expectations
    before trusting a build: git integrity, the zen5 patches are actually
    applied, no unexpected modifications beyond what's tracked, and the
    configured GN args/compiler target/AVX-512 flags are what we intend.

.DESCRIPTION
    Writes build/source-verification.json with:
        status, source_revision, upstream_revision, patches_applied,
        unexpected_changes, compiler_flags, target_cpu, warnings, errors

    Exits non-zero on any unexpected modification or missing expectation.
    See scripts equivalent intent in Python at scripts/verify_source.py is
    NOT separately implemented -- this script IS the implementation (the
    project asks for "a corresponding Python implementation where useful";
    for git-plumbing-heavy checks like this, native git+PowerShell is more
    direct than shelling out from Python, so this file is authoritative).

.PARAMETER Profile
    Which profile's out dir / args.gn to verify. Default: zen5.
#>
[CmdletBinding()]
param(
    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5"
)

$ErrorActionPreference = "Stop"
$RepoRoot   = $PSScriptRoot
$SrcDir     = Join-Path $RepoRoot "src"
$BuildDir   = Join-Path $RepoRoot "build"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Err([string]$m) { $errors.Add($m); Write-Host "ERROR: $m" -ForegroundColor Red }
function Add-Warn([string]$m) { $warnings.Add($m); Write-Host "WARN: $m" -ForegroundColor Yellow }

function Invoke-NativeCapture {
    <#
    Run a native command, returning exit code + combined output, WITHOUT
    throwing. With $ErrorActionPreference = "Stop", `& git ... 2>&1` promotes
    anything the command writes to stderr into a TERMINATING error -- so
    `git fsck` on the Chromium checkout (which legitimately reports dangling
    objects on stderr, exactly the case the caller below wants to warn about
    rather than die on) would kill this script instead. $ErrorActionPreference
    is function-scoped here, so it reverts on return.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0
    $output = & $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join "`n") }
}

$result = [ordered]@{
    status = "unknown"
    checked_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    profile = $Profile
    source_revision = $null
    upstream_revision = $null
    patches_applied = $null
    unexpected_changes = @()
    compiler_flags = $null
    target_cpu = $null
    warnings = @()
    errors = @()
}

# 1. Git repository integrity (this repo, and the src checkout if present)
if (-not (Test-Path (Join-Path $RepoRoot ".git"))) {
    Add-Err "thorium-zen5 repo root ($RepoRoot) is not a git repository."
} else {
    $fsck = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $RepoRoot, "fsck", "--no-progress")
    if ($fsck.ExitCode -ne 0) { Add-Err "git fsck failed on $RepoRoot : $($fsck.Output)" }
    $rev = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $RepoRoot, "rev-parse", "HEAD")
    $result.source_revision = if ($rev.ExitCode -eq 0) { $rev.Output.Trim() } else { $null }
}

if (Test-Path (Join-Path $SrcDir ".git")) {
    $fsckSrc = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $SrcDir, "fsck", "--no-progress")
    if ($fsckSrc.ExitCode -ne 0) { Add-Warn "git fsck reported issues on the Chromium checkout (large repos sometimes warn on dangling blobs from gclient churn -- review manually): $($fsckSrc.Output)" }
} else {
    Add-Warn "No Chromium checkout at $SrcDir yet -- skipping source-tree checks (run build.ps1 sync first)."
}

# 2. Which Chromium are we pinned to?
$tagFile = Join-Path $BuildDir "chromium-tag.txt"
if (Test-Path $tagFile) {
    $result.upstream_revision = (Get-Content $tagFile -Raw).Trim()
} else {
    Add-Warn "No build\chromium-tag.txt -- the checkout is not pinned to a known Chromium stable tag (run build.ps1 sync)."
}

# 3. Are the zen5 patches applied? The marker apply_zen5_patches.py writes is
#    the authority -- same string the patcher itself checks for idempotency.
$patchedFile = Join-Path $SrcDir "build\config\compiler\BUILD.gn"
$patchesApplied = $false
if (Test-Path $patchedFile) {
    $patchesApplied = (Select-String -Path $patchedFile -Pattern "thorium-zen5: Zen 5 CPU targeting" -Quiet)
    if (-not $patchesApplied) {
        Add-Warn "zen5 marker not found in $patchedFile -- patches not applied yet (expected before the first 'build.ps1 configure -Profile zen5')."
    }
} else {
    Add-Warn "$patchedFile not found -- source not synced yet."
}
$result.patches_applied = $patchesApplied

# 4. No UNEXPECTED source modifications.
#    On stock Chromium this is far stronger than the old overlay hash compare:
#    src is a real git checkout, so git itself reports precisely which files
#    differ from the pinned tag. Exactly one file should -- the one our patches
#    edit. Anything else is an unexplained local modification and is surfaced.
$expectedModified = @("build/config/compiler/BUILD.gn")
if (Test-Path (Join-Path $SrcDir ".git")) {
    $status = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $SrcDir, "status", "--porcelain", "--untracked-files=no")
    if ($status.ExitCode -ne 0) {
        Add-Err "git status failed on the Chromium checkout: $($status.Output)"
    } else {
        foreach ($line in ($status.Output -split "`n")) {
            $line = $line.Trim()
            if (-not $line) { continue }
            # porcelain format: XY <path>
            $path = ($line -replace '^\S+\s+', '')
            if ($expectedModified -notcontains $path) {
                $result.unexpected_changes += $path
            }
        }
        if ($result.unexpected_changes.Count -gt 0) {
            foreach ($c in $result.unexpected_changes) {
                Add-Err "Unexpected local modification in the Chromium checkout: $c (only $($expectedModified -join ', ') should differ from the pinned tag)"
            }
        } else {
            Write-Host "OK: only the expected file(s) differ from the pinned Chromium tag." -ForegroundColor Green
        }
    }
}

# 5. Expected compiler target / GN args / AVX-512 config for the requested profile
$argsGnPath = Join-Path $SrcDir "out\thorium-$Profile\args.gn"
if (Test-Path $argsGnPath) {
    $argsContent = Get-Content $argsGnPath -Raw
    $flags = @{}
    (Get-Content $argsGnPath) | ForEach-Object {
        if ($_ -match '^\s*([a-zA-Z0-9_]+)\s*=\s*(.+?)\s*$' -and -not $_.TrimStart().StartsWith('#')) {
            $flags[$matches[1]] = $matches[2]
        }
    }
    $result.compiler_flags = $flags
    $result.target_cpu = $flags["target_cpu"]

    # zen5_mtune is asserted, not just recorded: -mtune=znver4/znver5
    # miscompiles under ThinLTO on this toolchain, and -mtune=skylake-avx512
    # builds but silently emits ZERO 512-bit instructions. Either mistake is
    # invisible in a successful build, so it is checked here rather than
    # discovered later in a benchmark. See gn/win_zen5_args.gn.
    $expectations = switch ($Profile) {
        "zen5"           { @{ use_znver5 = "true";  use_generic_avx512 = "false"; target_cpu = '"x64"'; zen5_march = '"znver5"'; zen5_mtune = '"generic"' } }
        "generic-avx512" { @{ use_znver5 = "false"; use_generic_avx512 = "true";  target_cpu = '"x64"' } }
        "baseline"       { @{ use_znver5 = "false"; use_generic_avx512 = "false"; target_cpu = '"x64"' } }
    }
    foreach ($k in $expectations.Keys) {
        $expected = $expectations[$k]
        $actual = $flags[$k]
        if ($null -eq $expected) {
            if ($actual -eq "true") {
                Add-Err "Profile '$Profile' expected $k to be unset/false but args.gn has $k = true"
            }
        } elseif ($actual -ne $expected) {
            Add-Err "Profile '$Profile' expected $k = $expected but args.gn has $k = $actual"
        }
    }
} else {
    Add-Warn "$argsGnPath not found -- profile not configured yet (run build.ps1 configure -Profile $Profile)."
}

# 6. Expected signing/package configuration -- Thorium Zen5 is unsigned by
#    default (personal build; see docs/BUILD.md 'Code signing'). Flag it as
#    an explicit, expected state rather than a silent gap.
$result.warnings_signing = "Thorium Zen5 installer is NOT code-signed by default (personal/unofficial build). " +
    "Windows SmartScreen will warn on first run. This is expected and documented in docs/BUILD.md; " +
    "add your own Authenticode cert + signtool step to build.ps1 Invoke-Installer if you want to sign it."
Add-Warn $result.warnings_signing

$result.warnings = $warnings
$result.errors = $errors
$result.status = if ($errors.Count -gt 0) { "FAIL" } elseif ($warnings.Count -gt 0) { "OK_WITH_WARNINGS" } else { "OK" }

$outPath = Join-Path $BuildDir "source-verification.json"
$result | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath
Write-Host "`nWrote $outPath -- status: $($result.status)"

if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
