@echo off
REM Thorium Zen5 -- full upstream update: sync, reapply Zen 5 patches, verify
REM the targeting reached the compiler, build, test, ISA report, package, and
REM silently install the result. Double-click it; no flags needed.
REM
REM Exit codes: 0 ok | 2 patch conflict | 3 verify failed (targeting did not
REM reach the build) | anything else see build\logs\update.log
setlocal
cd /d "%~dp0"

REM mimalloc verbose output leaks into git stdout and breaks output parsing.
REM Scoped to this window only; your user environment is untouched.
set MIMALLOC_VERBOSE=0
set MIMALLOC_SHOW_STATS=0
set MIMALLOC_SHOW_ERRORS=0

echo ============================================================
echo  Thorium Zen5 - UPDATE
echo  sync -^> patch -^> verify -^> build -^> test -^> package -^> install
echo  This takes a few hours. The machine stays usable (BelowNormal).
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" -Profile zen5 -Yes -Install -SkipBenchmark %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo ==== DONE ====) else (echo ==== FAILED rc=%RC% - see build\logs\update.log ====)
if /i not "%THORIUM_NOPAUSE%"=="1" pause
exit /b %RC%
