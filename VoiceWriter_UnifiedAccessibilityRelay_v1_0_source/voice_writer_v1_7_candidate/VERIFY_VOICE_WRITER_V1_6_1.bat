@echo off
setlocal
title Voice Writer V1.6.1 Verifier
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0VERIFY_VOICE_WRITER_V1_6_1.ps1"
set "VW_EXIT=%ERRORLEVEL%"
echo.
if "%VW_EXIT%"=="0" (
    echo VERIFIER COMPLETE - no failures
) else (
    echo VERIFIER FAILED - inspect results above
)
echo.
pause
exit /b %VW_EXIT%
