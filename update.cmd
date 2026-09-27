@echo off
REM Full update: sync, patch, verify, build, test, analyze, package, publish,
REM then deploy (installs if Chromium is closed, otherwise the desktop icon
REM offers it). Takes hours; the machine stays usable (BelowNormal).
REM Exit codes: 0 ok | 2 patch no longer applies | 3 verify failed |
REM anything else see build\logs\update.log
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" -Profile zen5 -Yes %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo ==== DONE ====) else (echo ==== FAILED rc=%RC% - see build\logs\update.log ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
