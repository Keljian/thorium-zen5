#Requires -Version 5.1
<#
.SYNOPSIS
    Find and remove per-user URL protocol keys that advertise a handler but
    provide none -- the state in which clicking a link does nothing at all.

.DESCRIPTION
    HKEY_CLASSES_ROOT is an overlay: HKCU\Software\Classes wins over
    HKLM\Software\Classes. A key under HKCU that declares

        URL Protocol = ""

    but has NO shell\open\command subkey is therefore worse than no key at all.
    ShellExecute honours the declaration, looks for a handler, finds none, and
    returns SUCCESS having done nothing. Nothing launches, nothing errors, and
    no log records it.

    Observed on 2026-09-19: clicking any link did nothing. Both
    HKCU\Software\Classes\http and \https existed with URL Protocol set and zero
    subkeys, shadowing perfectly good HKLM handlers. Start-Process on an https
    URL returned without error and started no browser, while launching the
    browser exe directly worked fine -- which is the signature of this fault:
    the binary is healthy and the association is hollow.

    How it got that way: this project uninstalled its Inno-packaged browser,
    which removed %USERPROFILE%\ThoriumZen5\Application\chrome.exe. A cleanup
    pass then removed browser registrations pointing at the vanished exe, but
    deleted only the shell subtree and left the parent protocol keys behind. A
    cleanup that leaves a declaration without an implementation is worse than
    one that leaves both or neither.

    Removing the hollow key restores Windows' intended resolution -- it does NOT
    pick a browser. Whatever UserChoice or HKLM specifies takes over again. Use
    Settings > Default apps to choose the browser; that is the only supported
    way, because UserChoice is signed with a per-user hash.

.PARAMETER Fix
    Actually delete the hollow keys. Without it this only reports, because
    deleting registry keys unprompted is not something a diagnostic should do.

.PARAMETER Schemes
    Which protocols to check. Defaults to the ones a browser owns.

.NOTES
    Exit codes: 0 = nothing hollow found, or fixed
                3 = hollow keys found and -Fix was not passed
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [string[]]$Schemes = @('http', 'https', 'ftp', 'mailto')
)

$ErrorActionPreference = 'Stop'
$backupDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'build\regbackup'

function Test-HollowProtocolKey {
    <#
    Hollow = declares itself a URL protocol handler and supplies no command.
    A key with a working shell\open\command is left strictly alone, as is a key
    that does not claim to be a protocol handler at all.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $item = Get-Item $Path
    $declares = $item.GetValueNames() -contains 'URL Protocol'
    if (-not $declares) { return $false }
    $cmdKey = Join-Path $Path 'shell\open\command'
    if (-not (Test-Path $cmdKey)) { return $true }
    $cmd = (Get-ItemProperty $cmdKey -ErrorAction SilentlyContinue).'(default)'
    return [string]::IsNullOrWhiteSpace($cmd)
}

$hollow = @()
Write-Host "Checking per-user URL protocol keys under HKCU\Software\Classes"
foreach ($s in $Schemes) {
    $path = "HKCU:\Software\Classes\$s"
    if (-not (Test-Path $path)) {
        Write-Host ("  {0,-8} absent (fine -- HKLM handles it)" -f $s)
        continue
    }
    $item = Get-Item $path
    if (Test-HollowProtocolKey -Path $path) {
        Write-Host ("  {0,-8} HOLLOW: declares 'URL Protocol', no usable shell\open\command (subkeys={1})" -f $s, $item.SubKeyCount) -ForegroundColor Red
        $hollow += $s
    } else {
        $cmd = (Get-ItemProperty (Join-Path $path 'shell\open\command') -ErrorAction SilentlyContinue).'(default)'
        Write-Host ("  {0,-8} ok: {1}" -f $s, $cmd) -ForegroundColor Green
    }
}

if (-not $hollow.Count) {
    Write-Host ""
    Write-Host "Nothing hollow. If links still do not open, the fault is elsewhere -- check" -ForegroundColor Green
    Write-Host "whether the browser exe named by the handler actually exists, and try" -ForegroundColor Green
    Write-Host "Start-Process 'https://example.com/' to see whether ShellExecute does anything." -ForegroundColor Green
    exit 0
}

Write-Host ""
if (-not $Fix) {
    Write-Host "Found $($hollow.Count) hollow key(s): $($hollow -join ', ')" -ForegroundColor Yellow
    Write-Host "These make link clicks silently do nothing. Re-run with -Fix to remove them." -ForegroundColor Yellow
    Write-Host "Removing them does not choose a browser; it restores normal resolution." -ForegroundColor Yellow
    exit 3
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($s in $hollow) {
    $bk = Join-Path $backupDir "HKCU-Classes-$s-$stamp.reg"
    & reg.exe export "HKCU\Software\Classes\$s" $bk /y | Out-Null
    if (-not (Test-Path $bk)) { throw "refusing to delete $s -- backup to $bk failed" }
    Write-Host "  backed up $s -> $bk"
    & reg.exe delete "HKCU\Software\Classes\$s" /f | Out-Null
    if (Test-Path "HKCU:\Software\Classes\$s") {
        Write-Host "  FAILED to remove HKCU\Software\Classes\$s" -ForegroundColor Red
    } else {
        Write-Host "  removed HKCU\Software\Classes\$s" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Done. Verify with:  Start-Process 'https://example.com/'" -ForegroundColor Green
Write-Host "A browser should now start. Which one is governed by Settings > Default apps." -ForegroundColor Green
exit 0
