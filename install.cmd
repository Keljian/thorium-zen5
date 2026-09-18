@echo off
REM Silently install the build already sitting in src\out\thorium-zen5 into
REM %%LOCALAPPDATA%%\Chromium\Application. Keeps your existing profile.
REM Verifies the installed chrome.dll hashes identical to the build output.
REM Refuses if the installed browser is running; pass -Force to close it.
setlocal
cd /d "%~dp0"
echo ============================================================
echo  Thorium Zen5 - INSTALL (silent, user-level)
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Build.ps1" -Profile zen5 %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo ==== INSTALLED ====)
if "%RC%"=="3" (echo ==== SKIPPED - browser running. Close it, or: install.cmd -Force ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
