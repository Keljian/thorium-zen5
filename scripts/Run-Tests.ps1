#Requires -Version 5.1
<#
.SYNOPSIS
    Run base_unittests and decide honestly whether the build is releasable.

.DESCRIPTION
    Replaces "run the exe, trust its exit code", which on 2026-09-18 stopped a
    perfectly good build from ever being packaged. Two separate problems made
    that exit code meaningless, and this script addresses both.

    1. A STARVED LAUNCHER REPORTS EVERY TEST AS FAILED.

       base_unittests shards across child processes and reads each result back
       through a temp "out-of-band success data" file. Starve it -- which is
       easy straight after a build that has just exhausted the commit limit --
       and the launcher cannot collect results, so every test is recorded as a
       failure. Measured on one unchanged binary:

           default (implicit -j32)   9032 failed   620s   thousands of OOB errors
           --test-launcher-jobs=8      10 failed    52s   ZERO OOB errors

       So the exit code said "9032 failures" when the truth was 10. This script
       caps the launcher AND detects the out-of-band symptom explicitly, so that
       failure mode is reported as a HARNESS fault with its own message instead
       of masquerading as thousands of broken tests.

    2. SOME FAILURES ARE PERMANENT AND UNDERSTOOD.

       Eight of those ten are a stack-frame test defeated by the official
       build's inlining, and they will fail on every build this project ever
       makes. Gating on "zero failures" therefore means gating on "never ship
       again". Known failures live in scripts\known-test-failures.txt with a
       reason and a retirement condition; anything NOT listed still fails the
       build.

    Results come from --test-launcher-summary-output JSON, not from scraping
    stdout: the text format ("N tests failed:" then a list) is a human summary
    that has changed shape before, while the JSON carries a per-test status.

.PARAMETER Profile
    Which out\thorium-<profile> to test. Default: zen5.

.PARAMETER Jobs
    Launcher parallelism. 0 (default) derives it from available commit.

.PARAMETER Filter
    Optional --gtest_filter, for narrowing while diagnosing.

.NOTES
    Exit codes: 0 = releasable (possibly with known failures)
                1 = unexpected test failures, or the launcher misbehaved
                2 = could not run at all
#>
[CmdletBinding()]
param(
    [ValidateSet("baseline", "zen5", "generic-avx512")]
    [string]$Profile = "zen5",
    [int]$Jobs = 0,
    [string]$Filter = $null
)

$ErrorActionPreference = "Stop"
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$SrcDir    = Join-Path $RepoRoot "src"
$OutDir    = Join-Path $SrcDir "out\thorium-$Profile"
$LogsDir   = Join-Path $RepoRoot "build\logs"
$Allowlist = Join-Path $PSScriptRoot "known-test-failures.txt"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

$exe = Join-Path $OutDir "base_unittests.exe"
if (-not (Test-Path $exe)) {
    Write-Host "FATAL: $exe not found. Build it: .\build.ps1 build -Profile $Profile -Target base_unittests" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# Launcher parallelism, from available COMMIT rather than core count. A test
# child is a whole process, so it is budgeted more heavily than a compile job.
# ---------------------------------------------------------------------------
if ($Jobs -le 0) {
    $os = Get-CimInstance Win32_OperatingSystem
    $availGB = ($os.FreeVirtualMemory * 1KB) / 1GB
    $Jobs = [int][math]::Max(4, [math]::Min(
        (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors,
        [math]::Floor(($availGB - 6) / 2.0)))
}

$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonOut = Join-Path $LogsDir "base_unittests-$Profile-$stamp.json"
$txtOut  = Join-Path $LogsDir "base_unittests-$Profile-$stamp.txt"

$argv = @("--gtest_shuffle", "--gtest_brief=1",
          "--test-launcher-jobs=$Jobs",
          "--test-launcher-summary-output=$jsonOut")
if ($Filter) { $argv += "--gtest_filter=$Filter" }

Write-Host "base_unittests  profile=$Profile  launcher-jobs=$Jobs"
Write-Host "  binary : $exe"
Write-Host "  summary: $jsonOut"
$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $SrcDir `
            -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput $txtOut -RedirectStandardError "$txtOut.err"
$sw.Stop()
Write-Host ("  exit   : {0} after {1}" -f $proc.ExitCode, $sw.Elapsed.ToString('hh\:mm\:ss'))

# ---------------------------------------------------------------------------
# The launcher-starvation signature. Checked BEFORE the results, because when
# this fires the results are meaningless rather than bad.
# ---------------------------------------------------------------------------
$oob = 0
foreach ($f in @($txtOut, "$txtOut.err")) {
    if (Test-Path $f) {
        $oob += (Select-String -Path $f -Pattern 'out-of-band test success data' -ErrorAction SilentlyContinue |
                 Measure-Object).Count
    }
}
if ($oob -gt 0) {
    Write-Host ""
    Write-Host "HARNESS FAULT: the test launcher failed to collect results from $oob child process(es)." -ForegroundColor Red
    Write-Host "  'Failed to get out-of-band test success data' means the launcher could not read its" -ForegroundColor Red
    Write-Host "  children's result files, so EVERY test it ran is recorded as failed regardless of the" -ForegroundColor Red
    Write-Host "  binary. This is normally resource starvation -- it was first seen straight after a" -ForegroundColor Red
    Write-Host "  build that had exhausted the commit limit. These results say nothing about the build." -ForegroundColor Red
    Write-Host "  Retry with fewer jobs: .\scripts\Run-Tests.ps1 -Profile $Profile -Jobs 4" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Per-test results from the JSON summary.
# ---------------------------------------------------------------------------
if (-not (Test-Path $jsonOut)) {
    Write-Host "FATAL: no summary JSON at $jsonOut -- cannot tell which tests failed." -ForegroundColor Red
    Write-Host "       Raw output: $txtOut" -ForegroundColor Red
    exit 1
}

# Parsed in Python, NOT with ConvertFrom-Json.
#
# PowerShell 5.1's ConvertFrom-Json builds a case-INSENSITIVE dictionary, and
# Chromium's parameterised test names legitimately differ only by case, so it
# throws outright on this summary:
#     Cannot convert the JSON string because a dictionary that was converted
#     from the string contains the duplicated keys
#     '...FeatureListCountryRestrictionTest.Evaluation/DE' and '.../de'.
# The keys really are distinct; the parser really does fold them. That is not
# fixable here, so scripts\parse_test_summary.py does the reading.
#
# This is also why the first version of this script exited 1 with no output at
# all: the terminating parse error killed it before it could report anything,
# which looked exactly like a test failure. A gate that cannot explain itself is
# worse than no gate.
$pythonExe = $null
foreach ($cand in @("C:\Program Files\Python311\python.exe", "python.exe", "python3.exe")) {
    $resolved = if (Test-Path $cand) { $cand } else { (Get-Command $cand -ErrorAction SilentlyContinue).Source }
    if ($resolved) { $pythonExe = $resolved; break }
}
if (-not $pythonExe) {
    Write-Host "FATAL: no python found to parse the test summary." -ForegroundColor Red
    exit 2
}
$parser = Join-Path $PSScriptRoot "parse_test_summary.py"
$parsed = & $pythonExe $parser --summary $jsonOut 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: could not parse $jsonOut" -ForegroundColor Red
    $parsed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

$failed = New-Object System.Collections.Generic.List[string]
$ran = 0
foreach ($line in $parsed) {
    $line = "$line".Trim()
    if ($line -match '^RAN\s+(\d+)$')      { $ran = [int]$Matches[1]; continue }
    if ($line -match '^FAILED\s+(.+)$')     { $failed.Add($Matches[1]); continue }
}
Write-Host ("  tests  : {0} ran, {1} failed" -f $ran, $failed.Count)

# ---------------------------------------------------------------------------
# Allowlist.
# ---------------------------------------------------------------------------
$patterns = @()
if (Test-Path $Allowlist) {
    $patterns = Get-Content $Allowlist |
                ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
                Where-Object { $_ }
} else {
    Write-Host "  note: no allowlist at $Allowlist -- every failure will be treated as unexpected." -ForegroundColor Yellow
}

function Test-Allowed([string]$name) {
    foreach ($p in $patterns) { if ($name -like $p) { return $true } }
    return $false
}

$unexpected = @($failed | Where-Object { -not (Test-Allowed $_) })
$expected   = @($failed | Where-Object { Test-Allowed $_ })

# An allowlist entry matching nothing is stale: either the test was fixed, was
# renamed, or was not run. Say so, so the file gets pruned instead of growing.
$stale = @()
foreach ($p in $patterns) {
    if (-not ($failed | Where-Object { $_ -like $p })) { $stale += $p }
}

Write-Host ""
if ($expected.Count) {
    Write-Host "Known failures ($($expected.Count)) -- documented in scripts\known-test-failures.txt:" -ForegroundColor Yellow
    $expected | Sort-Object | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($stale.Count) {
    Write-Host ""
    Write-Host "STALE allowlist entries ($($stale.Count)) -- matched no failure this run:" -ForegroundColor Cyan
    $stale | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }
    Write-Host "  If the test now passes, delete the line. An unpruned allowlist hides real failures." -ForegroundColor Cyan
}
if ($unexpected.Count) {
    Write-Host ""
    Write-Host "UNEXPECTED failures ($($unexpected.Count)) -- these stop the pipeline:" -ForegroundColor Red
    $unexpected | Sort-Object | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  Diagnose before allowlisting. This build carries three toolchain workarounds and" -ForegroundColor Red
    Write-Host "  full AVX-512 codegen, so a new failure here is exactly the signal that matters." -ForegroundColor Red
    Write-Host "  Useful next step -- run the one test without the launcher in the way:" -ForegroundColor Red
    Write-Host "    $exe --single-process-tests --gtest_filter=$($unexpected[0])" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "PASS: no unexpected failures." -ForegroundColor Green
exit 0
