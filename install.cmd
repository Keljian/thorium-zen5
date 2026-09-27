@echo off
REM Install the build sitting in src\out\thorium-zen5, which may not have
REM passed tests. The desktop "Update Chromium" icon installs the newest
REM tested release instead. Refuses while the browser is running.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Build.ps1" -Profile zen5 %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo ==== INSTALLED ====)
if "%RC%"=="3" (echo ==== NOT INSTALLED - close Chromium and run this again ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
