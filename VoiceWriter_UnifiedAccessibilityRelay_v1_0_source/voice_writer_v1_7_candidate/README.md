# Unified Accessibility Relay — integration capsule

This is an extension of the existing `Whisper_PushToTalk_Sandbox` / `wpt`
project. It adds an optional UI switch and a state-observer hook to `app.py`;
it does not alter `core.py`, audio device settings, hotkeys, paste behaviour,
or the existing provenance launcher.

The `voices/` directory in the working candidate contains the supplied Bryce
Piper model. The compact source archive intentionally omits that unchanged
64 MB model; retain the existing `voices/en_US-bryce-medium.onnx` and its
adjacent `.onnx.json` file when installing the source bundle.

It provides one quiet desktop window for four explicit actions:

1. **Read selected text** — the user chooses text (clipboard) and explicitly asks
   for speech.
2. **Explain selected text** — the user chooses text, which is sent only to a
   configured local Ollama endpoint.  It is off unless enabled in the overlay
   config.
3. **Conversation** — typed or transcribed text may be sent to that same local
   endpoint.  No cloud endpoint, screen capture, clicking, or microphone capture
   is added by this capsule.
4. **Voice Writer state** — the window displays state supplied by an existing
   `PushToTalkCore` bridge.  It cannot start or stop recording itself.

The two-dot indicator is a *representation*: `←` means the existing writer is
capturing, `·` means it is transcribing, `→` means TTS playback is active, and
`!` means the integration reports an error.  It has no authority over audio.

## Install into the existing project

Copy the three Python files from `src/wpt/` into the existing project's
`src/wpt/` directory.  Copy `accessibility_overlay.example.json` to
`accessibility_overlay.json`, edit only the local Ollama model name if desired,
then run from the project root:

```powershell
$env:PYTHONPATH = (Join-Path $PWD 'src')
.\.venv\Scripts\python.exe -m wpt --accessibility-ui --tts-device Soundcore --auto-paste
```

The TTS bridge looks for the existing `wpt.kaiku_reader.TextToSpeechReader` and
only uses the explicit `--tts-device` selector.  The normal Voice Writer input
device selection is untouched.
If it is unavailable, the UI still runs, but it reports `TTS unavailable` rather
than silently switching devices or services.

## Wire the existing Voice Writer state

The smallest integration is one call from the code that already observes
`PushToTalkCore` state:

```python
overlay_bridge.update_writer_state(
    capturing=state is State.RECORDING,
    transcribing=state is State.TRANSCRIBING,
    error=None,
)
```

The bridge only accepts observations.  It has no recording-start, device-
selection, clipboard-writing, or typing method. Closing the overlay asks the
existing Voice Writer instance to exit cleanly through its normal event queue.

## Tests

```powershell
$env:PYTHONPATH = (Join-Path $PWD 'src')
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```
