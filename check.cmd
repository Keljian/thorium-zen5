@echo off
REM Is a rebuild needed? Exit 10 = yes, 0 = no. Changes nothing.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" -Profile zen5 -CheckOnly %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="10" (echo ==== REBUILD NEEDED - run update.cmd ====)
if "%RC%"=="0"  (echo ==== UP TO DATE ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
