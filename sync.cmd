@echo off
REM Fetch/refresh the Chromium checkout only -- no configure, no build.
REM
REM NOTE: a sync REVERTS build\config\compiler\BUILD.gn, so the Zen 5 patches
REM are gone afterwards until you configure again. verify.cmd will correctly
REM report the tree as unpatched until then.
setlocal
cd /d "%~dp0"
set MIMALLOC_VERBOSE=0
set MIMALLOC_SHOW_STATS=0
set MIMALLOC_SHOW_ERRORS=0
echo ============================================================
echo  Thorium Zen5 - SYNC (checkout only; ~30 GB tree, several minutes)
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" sync %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo ==== SYNC DONE - patches are now REVERTED; run update.cmd to rebuild ====) else (echo ==== FAILED rc=%RC% ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
