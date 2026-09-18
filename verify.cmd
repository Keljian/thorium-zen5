@echo off
REM Assert the Zen 5 targeting actually reached the generated build files:
REM -march/-mtune on C++, -Ctarget-cpu on Rust, and both linker workarounds.
REM Seconds, not minutes (git fsck is opt-in behind -DeepFsck).
setlocal
cd /d "%~dp0"
set MIMALLOC_VERBOSE=0
set MIMALLOC_SHOW_STATS=0
set MIMALLOC_SHOW_ERRORS=0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-source.ps1" -Profile zen5 %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo ==== VERIFY OK ====) else (echo ==== VERIFY FAILED - see build\source-verification.json ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
