@echo off
setlocal

set "PROJECT_ROOT=%~dp0"
set "PYTHONPATH=%PROJECT_ROOT%src"
set "PYTHON=%PROJECT_ROOT%.venv\Scripts\python.exe"

if not exist "%PYTHON%" (
    echo [ERROR] Missing .venv\Scripts\python.exe
    echo Run the existing Voice Writer bootstrap first, then run this launcher again.
    exit /b 1
)

if not exist "%PROJECT_ROOT%accessibility_overlay.json" (
    echo [ERROR] Missing accessibility_overlay.json
    echo Copy accessibility_overlay.example.json to accessibility_overlay.json first.
    exit /b 1
)

"%PYTHON%" -m wpt --accessibility-ui --accessibility-config "%PROJECT_ROOT%accessibility_overlay.json" --tts-device "Soundcore" --auto-paste
exit /b %ERRORLEVEL%
