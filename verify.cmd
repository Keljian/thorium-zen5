@echo off
REM Check the Zen 5 targeting reached the generated build files. Seconds.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-source.ps1" -Profile zen5 %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo ==== VERIFY OK ====) else (echo ==== VERIFY FAILED - see build\source-verification.json ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
