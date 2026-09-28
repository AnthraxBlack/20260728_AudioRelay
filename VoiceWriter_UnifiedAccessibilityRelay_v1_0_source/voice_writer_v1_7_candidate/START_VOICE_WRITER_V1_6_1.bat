@echo off
setlocal
title AnthBlackSystems Voice Writer V1.6.1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0START_VOICE_WRITER_V1_6_1.ps1"
set "VW_EXIT=%ERRORLEVEL%"

if not "%VW_EXIT%"=="0" (
    echo.
    echo ============================================================
    echo VOICE WRITER V1.6.1 FAILED - exit code %VW_EXIT%
    echo The window is being kept open so the failure can be inspected.
    echo ============================================================
    echo.
    pause
)

exit /b %VW_EXIT%
