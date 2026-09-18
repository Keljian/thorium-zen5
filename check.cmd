@echo off
REM Is a rebuild needed? Compares upstream stable against the version we
REM actually BUILT (not what was last synced -- that distinction is why this
REM pipeline once went quiet for a whole release). Exit 10 = rebuild needed.
setlocal
cd /d "%~dp0"
set MIMALLOC_VERBOSE=0
set MIMALLOC_SHOW_STATS=0
set MIMALLOC_SHOW_ERRORS=0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" -Profile zen5 -CheckOnly %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="10" (echo ==== REBUILD NEEDED - run update.cmd ====)
if "%RC%"=="0"  (echo ==== UP TO DATE ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
