@echo off
cd /d D:\Whisper_PushToTalk_Sandbox

set PYTHONPATH=D:\Whisper_PushToTalk_Sandbox\src

echo Starting Kaiku Voice Writer...
echo.
echo Hotkeys:
echo   Ctrl+Alt+O = start recording
echo   Ctrl+Alt+P = stop, transcribe, paste
echo   Ctrl+Alt+X = exit
echo.

py -3.12 -m wpt --auto-paste
