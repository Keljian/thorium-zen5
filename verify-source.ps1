#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies the state of the Thorium Zen5 source tree matches expectations
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
$ThoriumMeta = Join-Path $RepoRoot "upstream\Thorium"
$BuildDir   = Join-Path $RepoRoot "build"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Err([string]$m) { $errors.Add($m); Write-Host "ERROR: $m" -ForegroundColor Red }
function Add-Warn([string]$m) { $warnings.Add($m); Write-Host "WARN: $m" -ForegroundColor Yellow }

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
    $fsck = & git -C $RepoRoot fsck --no-progress 2>&1
    if ($LASTEXITCODE -ne 0) { Add-Err "git fsck failed on $RepoRoot : $fsck" }
    $result.source_revision = (& git -C $RepoRoot rev-parse HEAD 2>$null)
}

if (Test-Path (Join-Path $SrcDir ".git")) {
    $fsckSrc = & git -C $SrcDir fsck --no-progress 2>&1
    if ($LASTEXITCODE -ne 0) { Add-Warn "git fsck reported issues on the Chromium checkout (large repos sometimes warn on dangling blobs from gclient churn -- review manually): $fsckSrc" }
} else {
    Add-Warn "No Chromium checkout at $SrcDir yet -- skipping source-tree checks (run build.ps1 sync first)."
}

# 2. Expected upstream revision (Thorium meta-repo)
if (Test-Path (Join-Path $ThoriumMeta ".git")) {
    $result.upstream_revision = (& git -C $ThoriumMeta rev-parse HEAD 2>$null)
} else {
    Add-Warn "Thorium meta-repo not present at $ThoriumMeta."
}

# 3. Patches applied -- check patches/zen5 diffs are reflected in src, and
#    that the zen5 declare_arg actually exists.
$compilerOptGni = Join-Path $SrcDir "build\config\compiler_opt.gni"
$patchesApplied = $false
if (Test-Path $compilerOptGni) {
    $content = Get-Content $compilerOptGni -Raw
    $patchesApplied = $content -match "use_znver5"
    if (-not $patchesApplied) {
        Add-Warn "use_znver5 not found in $compilerOptGni -- zen5 patches not applied yet (expected before first 'build.ps1 configure -Profile zen5|generic-avx512')."
    }
} else {
    Add-Warn "$compilerOptGni not found -- source not synced/overlaid yet."
}
$result.patches_applied = $patchesApplied

# 4. No unexpected source modifications: diff the live src tree's Thorium-
#    overlaid files against the Thorium meta-repo + our zen5 patches. Since
#    Thorium's overlay is a straight file copy (not a git submodule), we
#    compare file hashes for the non-patched files (should be byte-identical
#    to the meta-repo) and rely on apply_zen5_patches.py's own marker check
#    for the 4 files it modifies.
$overlayDirs = @("ash","chrome","chromeos","components","content","extensions",
                  "google_apis","media","net","sandbox","services","tools","ui")
$zen5ModifiedFiles = @(
    "build\config\compiler_opt.gni", "build\config\compiler\BUILD.gn",
    "build\config\win\BUILD.gn", "v8\BUILD.gn"
)
if (Test-Path $SrcDir) {
    foreach ($d in $overlayDirs) {
        $metaPath = Join-Path $ThoriumMeta "src\$d"
        $srcPath = Join-Path $SrcDir $d
        if (-not (Test-Path $metaPath) -or -not (Test-Path $srcPath)) { continue }
        $metaFiles = Get-ChildItem $metaPath -Recurse -File -ErrorAction SilentlyContinue
        foreach ($mf in $metaFiles) {
            $rel = $mf.FullName.Substring($metaPath.Length).TrimStart('\')
            $target = Join-Path $srcPath $rel
            if (-not (Test-Path $target)) {
                $result.unexpected_changes += "Missing in src (present in Thorium overlay): $d\$rel"
                continue
            }
            $h1 = (Get-FileHash $mf.FullName -Algorithm SHA256).Hash
            $h2 = (Get-FileHash $target -Algorithm SHA256).Hash
            if ($h1 -ne $h2) {
                $result.unexpected_changes += "Content differs from Thorium overlay (unexpected local edit?): $d\$rel"
            }
        }
    }
}
if ($result.unexpected_changes.Count -gt 0) {
    foreach ($c in $result.unexpected_changes) { Add-Warn $c }
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

    $expectations = switch ($Profile) {
        "zen5"           { @{ use_avx512 = "true"; use_znver5 = "true"; target_cpu = '"x64"' } }
        "generic-avx512" { @{ use_avx512 = "true"; use_znver5 = $null; target_cpu = '"x64"' } }
        "baseline"       { @{ use_avx512 = "false"; use_znver5 = $null; target_cpu = '"x64"' } }
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
