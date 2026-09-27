#Requires -Version 5.1
<#
.SYNOPSIS
    Prove the CPU targeting reached the generated build files before hours
    are spent building.

.DESCRIPTION
    args.gn saying use_znver5 = true proves only that an argument was set.
    Every real failure on this project was a flag declared but never applied,
    invisible in a green build (Rust compiled for generic x86-64 for months;
    -mtune=skylake-avx512 emitting no 512-bit code). So this checks the
    generated ninja, not the intent:

      1. the zen5 patch marker is in build/config/compiler/BUILD.gn (zen5)
      2. only that file differs from the pinned tag
      3. args.gn carries the expected profile values
      4. the generated ninja came from the BUILD.gn that exists now
         (build\configured-<profile>.json, written by configure)
      5. toolchain.ninja emits -march/-mtune for C++ and -Ctarget-cpu for Rust,
         and the chrome.dll link line carries both toolchain workarounds

    Writes build\source-verification.json. Exit 1 on any error.

.PARAMETER AllowUnpatched
    Tolerate a zen5 tree without the patch, to inspect a fresh sync.
#>
[CmdletBinding()]
param(
    [ValidateSet("baseline", "zen5")]
    [string]$Profile = "zen5",
    [switch]$AllowUnpatched
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "scripts\Common.ps1")

$SrcDir  = Join-Path $ThoriumRoot "src"
$OutDir  = Join-Path $SrcDir "out\thorium-$Profile"
$BuildGn = Join-Path $SrcDir "build\config\compiler\BUILD.gn"

$errors   = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
function Add-Err([string]$m)  { $errors.Add($m);   Write-Host "ERROR: $m" -ForegroundColor Red }
function Add-Warn([string]$m) { $warnings.Add($m); Write-Host "WARN: $m" -ForegroundColor Yellow }

$result = [ordered]@{
    checked_at_utc     = (Get-Date).ToUniversalTime().ToString("o")
    profile            = $Profile
    chromium_tag       = $null
    patch_applied      = $null
    unexpected_changes = @()
    gn_args            = $null
    emitted_flags      = [ordered]@{}
}
$tagFile = Join-Path $ThoriumBuild "chromium-tag.txt"
if (Test-Path $tagFile) { $result.chromium_tag = (Get-Content $tagFile -Raw).Trim() }

if (-not (Test-Path (Join-Path $SrcDir ".git")) -or -not (Test-Path $BuildGn)) {
    Add-Err "No synced Chromium checkout at $SrcDir."
} else {
    # 1. The patch.
    $result.patch_applied = [bool](Select-String -Path $BuildGn -Pattern "thorium-zen5: Zen 5 CPU targeting" -Quiet)
    if ($Profile -eq "zen5" -and -not $result.patch_applied) {
        $m = "The zen5 patch is not applied to $BuildGn (a sync reverts it). Run '.\build.ps1 configure -Profile zen5'."
        if ($AllowUnpatched) { Add-Warn $m } else { Add-Err $m }
    }

    # 2. Nothing else modified. Strict porcelain v1 parsing: two status
    #    characters, a space, the path. Any other line is noise (mimalloc
    #    statistics once became seventy fake "modified files"), and noise means
    #    the answer cannot be trusted either way.
    $st = Invoke-NativeCapture -Exe "git" -Arguments @("-C", $SrcDir, "status", "--porcelain", "--untracked-files=no")
    if ($st.ExitCode -ne 0) {
        Add-Err "git status failed on the checkout: $($st.Output)"
    } else {
        $noise = @()
        foreach ($line in ($st.Output -split "`n")) {
            $line = $line.TrimEnd()
            if (-not $line) { continue }
            if ($line -notmatch '^[ MADRCU?!]{2} (.+)$') { $noise += $line; continue }
            $path = $Matches[1].Trim('"')
            if ($path -match '^(.+?) -> (.+)$') { $path = $Matches[2].Trim('"') }
            if ($path -ne "build/config/compiler/BUILD.gn") { $result.unexpected_changes += $path }
        }
        if ($noise) { Add-Err "git status printed $($noise.Count) non-porcelain line(s), e.g. '$($noise[0])'. Check MIMALLOC_* or git hooks." }
        foreach ($c in $result.unexpected_changes) { Add-Err "Unexpected modification in the checkout: $c" }
    }
}

# 3. args.gn.
$argsGn = Join-Path $OutDir "args.gn"
$flags = @{}
if (-not (Test-Path $argsGn)) {
    Add-Err "$argsGn not found. Run '.\build.ps1 configure -Profile $Profile'."
} else {
    foreach ($l in (Get-Content $argsGn)) {
        if ($l -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$') { $flags[$Matches[1]] = $Matches[2] }
    }
    $result.gn_args = $flags
    # zen5_mtune is znver5 on purpose: the tail-merge ldflag works around the
    # znver* ThinLTO miscompile (llvm#199290). If that ldflag is retired,
    # this must change in the same commit. See gn/win_zen5_args.gn.
    $expect = if ($Profile -eq "zen5") {
        @{ use_znver5 = "true"; use_generic_avx512 = "false"; target_cpu = '"x64"'; zen5_march = '"znver5"'; zen5_mtune = '"znver5"' }
    } else {
        @{ target_cpu = '"x64"' }
    }
    foreach ($k in $expect.Keys) {
        if ($flags[$k] -ne $expect[$k]) { Add-Err "args.gn: expected $k = $($expect[$k]), found $(if ($flags[$k]) { $flags[$k] } else { 'unset' })." }
    }
    if ($Profile -eq "baseline" -and $flags["use_znver5"] -eq "true") { Add-Err "args.gn: baseline must not set use_znver5 = true." }
}

# 4. Generated from the current source. Timestamps cannot answer this: gn
#    rewrites a ninja file only when its content changes, so a correct
#    toolchain.ninja can be older than a freshly re-patched BUILD.gn.
$stamp = Join-Path $ThoriumBuild "configured-$Profile.json"
$cfg = try { Get-Content $stamp -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
$nowHash = Get-Sha256OrNull $BuildGn
if (-not $cfg) {
    Add-Err "No ${stamp}: configure has not completed for '$Profile' with this version of build.ps1."
} elseif ($cfg.build_gn_sha256 -ne $nowHash) {
    Add-Err "BUILD.gn has changed since the last configure ($($cfg.configured_utc)); the generated ninja describes another tree. Re-run configure."
}

# 5. What the compiler and linker will actually be given.
$tn = Join-Path $OutDir "toolchain.ninja"
if (-not (Test-Path $tn)) {
    Add-Err "No $tn. Run configure."
} else {
    $text = Get-Content $tn -Raw
    if ($Profile -eq "zen5") {
        $march = ([string]$flags["zen5_march"]).Trim('"'); $mtune = ([string]$flags["zen5_mtune"]).Trim('"')
        foreach ($c in @(@("cxx_march", "-march=$march"), @("cxx_mtune", "-mtune=$mtune"), @("rust_cpu", "-Ctarget-cpu=$march"))) {
            $result.emitted_flags[$c[0]] = $text.Contains($c[1])
            if (-not $text.Contains($c[1])) { Add-Err "'$($c[1])' is not in toolchain.ninja: the GN arg is set but the flag is not emitted." }
        }
        # Both workarounds run in the ThinLTO backend, so they are ldflags and
        # never appear in toolchain.ninja; check the chrome.dll link line.
        $dllNinja = Join-Path $OutDir "obj\chrome\chrome_dll.ninja"
        $ld = if (Test-Path $dllNinja) { (Select-String -Path $dllNinja -Pattern '^\s*ldflags\s*=' | Select-Object -First 1).Line } else { $null }
        if (-not $ld) {
            Add-Warn "No ldflags line in $dllNinja; cannot check the linker workarounds."
        } else {
            foreach ($w in @(@("tail_merge_workaround", "enable-tail-merge=false"), @("slp_cap_workaround", "slp-max-reg-size="))) {
                $result.emitted_flags[$w[0]] = $ld.Contains($w[1])
                if (-not $ld.Contains($w[1])) {
                    Add-Warn "'$($w[1])' is not on the chrome.dll link line. Correct only if the toolchain bug is fixed and the knob retired; otherwise the link will fail."
                }
            }
        }
    } elseif ($text -match '-march=znver') {
        Add-Err "baseline toolchain.ninja contains -march=znver*; it is not a stock build."
    }
}

$result.warnings = @($warnings)
$result.errors   = @($errors)
$result.status   = if ($errors.Count) { "FAIL" } elseif ($warnings.Count) { "OK_WITH_WARNINGS" } else { "OK" }
$out = Join-Path $ThoriumBuild "source-verification.json"
$result | ConvertTo-Json -Depth 5 | Set-Content -Path $out -Encoding ASCII
Write-Host "Wrote $out -- status: $($result.status)"
if ($errors.Count) { exit 1 }
exit 0
