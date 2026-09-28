from __future__ import annotations

import argparse
import os
import sys
import time
import ctypes
import ctypes.wintypes
from dataclasses import dataclass
from pathlib import Path
from queue import Queue
from typing import Any, Callable

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel
from pynput import keyboard

from .audit import AuditWriter
from .core import PushToTalkCore, State


SAMPLE_RATE = 16_000
CHANNELS = 1
DTYPE = "float32"

_PID_FILE = Path(os.environ.get("TEMP", "C:/Windows/Temp")) / "wpt.pid"


# ---------------------------------------------------------------------------
# Clipboard helpers (Win32 only — no external deps)
# ---------------------------------------------------------------------------

CF_UNICODETEXT = 13

# Fix return types for 64-bit Windows — ctypes defaults to c_int which truncates pointers
_kernel32 = ctypes.windll.kernel32
_user32 = ctypes.windll.user32
_kernel32.GlobalAlloc.restype = ctypes.c_void_p
_kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
_kernel32.GlobalLock.restype = ctypes.c_void_p
_kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
_kernel32.GlobalUnlock.restype = ctypes.c_bool
_kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
_user32.GetClipboardData.restype = ctypes.c_void_p
_user32.SetClipboardData.restype = ctypes.c_void_p
_user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]


def _clipboard_get() -> str:
    """Return current clipboard text, or empty string on failure."""
    try:
        _user32.OpenClipboard(0)
        h = _user32.GetClipboardData(CF_UNICODETEXT)
        if not h:
            return ""
        p = _kernel32.GlobalLock(h)
        if not p:
            return ""
        text = ctypes.wstring_at(p)
        _kernel32.GlobalUnlock(h)
        return text
    except Exception:
        return ""
    finally:
        try:
            _user32.CloseClipboard()
        except Exception:
            pass


def _clipboard_set(text: str) -> None:
    """Put text onto the clipboard."""
    GMEM_MOVEABLE = 0x0002
    encoded = (text + "\0").encode("utf-16-le")
    h = _kernel32.GlobalAlloc(GMEM_MOVEABLE, len(encoded))
    if not h:
        raise RuntimeError("GlobalAlloc failed")
    p = _kernel32.GlobalLock(h)
    if not p:
        raise RuntimeError("GlobalLock failed")
    ctypes.memmove(p, encoded, len(encoded))
    _kernel32.GlobalUnlock(h)
    _user32.OpenClipboard(0)
    _user32.EmptyClipboard()
    _user32.SetClipboardData(CF_UNICODETEXT, h)
    _user32.CloseClipboard()


def _paste_via_clipboard(text: str, controller: keyboard.Controller) -> None:
    """Write text into the active text box using clipboard + Ctrl+V."""
    previous = _clipboard_get()
    _clipboard_set(text)
    time.sleep(0.05)  # let clipboard settle
    controller.press(keyboard.Key.ctrl)
    controller.press("v")
    controller.release("v")
    controller.release(keyboard.Key.ctrl)
    time.sleep(0.05)
    # restore previous clipboard contents
    if previous:
        _clipboard_set(previous)


# ---------------------------------------------------------------------------
# Device helpers
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class KeyEvent:
    kind: str
    key: Any


def list_input_devices() -> None:
    for index, device in enumerate(sd.query_devices()):
        if device["max_input_channels"] > 0:
            host_api = sd.query_hostapis(device["hostapi"])["name"]
            print(
                f"{index}: {device['name']} | "
                f"inputs={device['max_input_channels']} | {host_api}"
            )


def choose_device_interactive() -> int:
    """Prompt user to select an input device from a formatted menu."""
    devices = [
        (idx, dev)
        for idx, dev in enumerate(sd.query_devices())
        if dev["max_input_channels"] > 0
    ]

    if not devices:
        raise SystemExit("ERROR: No input devices found.")

    print("\n" + "─" * 60)
    print("  INPUT DEVICES")
    print("─" * 60)

    for idx, (dev_idx, dev) in enumerate(devices):
        rate = int(dev["default_samplerate"])
        channels = dev["max_input_channels"]
        name = dev["name"][:40]
        print(f"  [{idx}]  {name:<40} │ {channels}ch @ {rate}Hz")

    print("─" * 60 + "\n")

    while True:
        try:
            choice = input("  Select device [0-{}]: ".format(len(devices) - 1))
            idx = int(choice)
            if 0 <= idx < len(devices):
                return devices[idx][0]
        except ValueError:
            pass
        print(f"  Invalid input. Enter 0-{len(devices) - 1}.")


def resolve_input_device(selector: str) -> int:
    if selector.isdigit():
        index = int(selector)
        device = sd.query_devices(index)
        if device["max_input_channels"] < 1:
            raise ValueError(f"Device {index} has no input channels.")
        return index

    needle = selector.casefold()
    matches = [
        index
        for index, device in enumerate(sd.query_devices())
        if device["max_input_channels"] > 0 and needle in device["name"].casefold()
    ]

    if len(matches) != 1:
        raise ValueError(
            f"Expected exactly one input device matching {selector!r}; "
            f"found {matches}. Run with --list-devices."
        )
    return matches[0]


# ---------------------------------------------------------------------------
# Audio capture
# ---------------------------------------------------------------------------

class MicrophoneCapture:
    def __init__(self, device: int) -> None:
        self._device = device
        self._chunks: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None

    def start(self) -> None:
        if self._stream is not None:
            raise RuntimeError("Capture is already running.")

        self._chunks = []

        def callback(
            indata: np.ndarray,
            frames: int,
            time_info: Any,
            status: sd.CallbackFlags,
        ) -> None:
            del frames, time_info, status
            self._chunks.append(indata.copy())

        self._stream = sd.InputStream(
            device=self._device,
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            callback=callback,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        if self._stream is None:
            return np.empty(0, dtype=np.float32)

        stream, self._stream = self._stream, None
        stream.stop()
        stream.close()

        if not self._chunks:
            return np.empty(0, dtype=np.float32)

        return np.concatenate(self._chunks, axis=0).reshape(-1)


# ---------------------------------------------------------------------------
# Transcription
# ---------------------------------------------------------------------------

class OfflineTranscriber:
    def __init__(self, model_name: str, model_dir: Path) -> None:
        os.environ["HF_HUB_OFFLINE"] = "1"
        self._model = WhisperModel(
            model_name,
            device="cpu",
            compute_type="int8",
            cpu_threads=4,
            download_root=str(model_dir),
            local_files_only=True,
        )

    def transcribe(self, audio: np.ndarray) -> str:
        segments, _info = self._model.transcribe(
            audio,
            language="en",
            beam_size=1,
            vad_filter=True,
            condition_on_previous_text=False,
            hotwords="Kaiku",
        )
        return "".join(segment.text for segment in segments).strip()


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

class PushToTalkApp:
    def __init__(
        self,
        device: int,
        model_name: str,
        model_dir: Path,
        audit_log: Path | None = None,
        toggle: bool = False,
        auto_paste: bool = False,
        state_sink: Callable[[State], None] | None = None,
    ) -> None:
        self._toggle = toggle
        self._auto_paste = auto_paste
        self._f8_debounce = False  # prevents auto-repeat in toggle mode
        self._ctrl_down = False
        self._alt_down = False
        self._hotkey_latched: set[str] = set()
        sd.check_input_settings(
            device=device,
            channels=CHANNELS,
            dtype=DTYPE,
            samplerate=SAMPLE_RATE,
        )
        self._core = PushToTalkCore()
        self._capture = MicrophoneCapture(device)
        self._transcriber = OfflineTranscriber(model_name, model_dir)
        self._controller = keyboard.Controller()
        self._events: Queue[KeyEvent] = Queue()
        self._listener: keyboard.Listener | None = None
        self._device = device
        self._model_name = model_name
        self._audit = AuditWriter(audit_log) if audit_log is not None else None
        self._state_sink = state_sink

    def request_stop(self) -> None:
        """Request an orderly stop through the normal event queue."""
        self._events.put(KeyEvent("press", keyboard.Key.esc))

    def set_state_sink(self, state_sink: Callable[[State], None] | None) -> None:
        """Set an observer for state changes; it receives no audio or text."""
        self._state_sink = state_sink

    def _notify_state(self) -> None:
        """Publish a state observation to the optional accessibility renderer."""
        if self._state_sink is not None:
            self._state_sink(self._core.snapshot.state)

    def run(self) -> None:
        # Write PID file so stop_wpt.vbs can kill this process
        _PID_FILE.write_text(str(os.getpid()), encoding="utf-8")

        self._listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
        )
        self._listener.start()

        print()
        print("━" * 50)
        print("  Ctrl+Alt+O -> start recording")
        print("  Ctrl+Alt+P -> stop, transcribe, and paste")
        print("  Ctrl+Alt+X or Escape -> exit")
        print("━" * 50)
        print()
        print("READY  (Ctrl+Alt+O to start recording)")
        self._notify_state()

        try:
            while self._core.snapshot.state is not State.STOPPED:
                self._handle(self._events.get())
        finally:
            if self._core.snapshot.state is State.RECORDING:
                self._capture.stop()
            self._core.stop()
            self._notify_state()

            if self._listener is not None:
                self._listener.stop()
                self._listener.join(timeout=1)

            try:
                _PID_FILE.unlink(missing_ok=True)
            except Exception:
                pass

            print("WPT_STOPPED")

    def _review(self, draft: str) -> str | None:
        """Print the draft and let the user accept, edit, or discard it.

        Returns the confirmed text, or None if discarded.
        Blocks the main event loop while waiting — F8/F9/Esc events queue up
        and are processed after this returns.
        """
        print()
        print(f"  DRAFT: {draft}")
        print("  Enter=accept  |  type edit + Enter=replace  |  x + Enter=discard")
        try:
            raw = input("  > ").strip()
        except (EOFError, KeyboardInterrupt):
            return None

        if raw.lower() == "x":
            return None
        if raw == "":
            return draft
        return raw

    def _write_audit(self, event: str, **fields: Any) -> None:
        if self._audit is not None:
            self._audit.append(event, **fields)

    @staticmethod
    def _key_letter(key: Any) -> str | None:
        vk = getattr(key, "vk", None)

        if isinstance(vk, int) and 65 <= vk <= 90:
            return chr(vk).casefold()

        char = getattr(key, "char", None)

        if isinstance(char, str) and len(char) == 1:
            return char.casefold()

        return None

    def _on_press(self, key: Any, injected: bool = False) -> None:
        if injected:
            return

        if key in {
            keyboard.Key.ctrl,
            keyboard.Key.ctrl_l,
            keyboard.Key.ctrl_r,
        }:
            self._ctrl_down = True
            return

        if key in {
            keyboard.Key.alt,
            keyboard.Key.alt_l,
            keyboard.Key.alt_r,
            keyboard.Key.alt_gr,
        }:
            self._alt_down = True
            return

        letter = self._key_letter(key)

        if (
            self._ctrl_down
            and self._alt_down
            and letter == "o"
            and "start" not in self._hotkey_latched
        ):
            self._hotkey_latched.add("start")
            self._events.put(KeyEvent("press", keyboard.Key.f8))
            return

        if (
            self._ctrl_down
            and self._alt_down
            and letter == "p"
            and "stop" not in self._hotkey_latched
        ):
            self._hotkey_latched.add("stop")
            self._events.put(KeyEvent("release", keyboard.Key.f8))
            return

        if (
            self._ctrl_down
            and self._alt_down
            and letter == "x"
            and "exit" not in self._hotkey_latched
        ):
            self._hotkey_latched.add("exit")
            self._events.put(KeyEvent("press", keyboard.Key.esc))
            return

        # Preserve existing F8/F9/Escape fallback during first validation.
        if key is keyboard.Key.f8:
            if self._toggle:
                if self._f8_debounce:
                    return
                self._f8_debounce = True
                self._events.put(KeyEvent("toggle", key))
            else:
                self._events.put(KeyEvent("press", key))
            return

        if key is keyboard.Key.esc:
            self._events.put(KeyEvent("press", key))

    def _on_release(self, key: Any, injected: bool = False) -> None:
        if injected:
            return

        if key in {
            keyboard.Key.ctrl,
            keyboard.Key.ctrl_l,
            keyboard.Key.ctrl_r,
        }:
            self._ctrl_down = False
            self._hotkey_latched.clear()
            return

        if key in {
            keyboard.Key.alt,
            keyboard.Key.alt_l,
            keyboard.Key.alt_r,
            keyboard.Key.alt_gr,
        }:
            self._alt_down = False
            self._hotkey_latched.clear()
            return

        letter = self._key_letter(key)

        if letter == "o":
            self._hotkey_latched.discard("start")
            return

        if letter == "p":
            self._hotkey_latched.discard("stop")
            return

        if letter == "x":
            self._hotkey_latched.discard("exit")
            return

        # Preserve existing F8/F9/Escape fallback during first validation.
        if key is keyboard.Key.f8:
            if self._toggle:
                self._f8_debounce = False
            else:
                self._events.put(KeyEvent("release", key))
            return

        if key in {keyboard.Key.f9, keyboard.Key.esc}:
            self._events.put(KeyEvent("release", key))

    def _handle(self, event: KeyEvent) -> None:
        """Process one event, then publish the resulting state observation."""
        try:
            self._handle_event(event)
        finally:
            self._notify_state()

    def _handle_event(self, event: KeyEvent) -> None:
        if event.key is keyboard.Key.esc:
            if self._core.snapshot.state is State.RECORDING:
                self._capture.stop()
            self._core.stop()
            return

        # Start recording: F8 press (hold mode) OR F8 toggle when idle
        if event.key is keyboard.Key.f8 and event.kind == "press":
            if self._core.record_pressed():
                self._capture.start()
                self._write_audit("recording.started", device_index=self._device, model_name=self._model_name)
                print("RECORDING")

        elif event.key is keyboard.Key.f8 and event.kind == "toggle":
            if self._core.snapshot.state is State.IDLE:
                if self._core.record_pressed():
                    self._capture.start()
                    self._write_audit("recording.started", device_index=self._device, model_name=self._model_name)
                    print("RECORDING (press F8 again to stop)")
                return
            # falls through to stop-and-transcribe below

        # Stop and transcribe: F8 release (hold mode) OR F8 toggle when recording
        if (event.key is keyboard.Key.f8 and event.kind == "release") or \
           (event.key is keyboard.Key.f8 and event.kind == "toggle" and
            self._core.snapshot.state is State.RECORDING):
            if self._core.record_released():
                audio = self._capture.stop()

                if audio.size == 0:
                    self._core.transcription_finished("")
                    self._write_audit("transcription.finished", seconds=0.0, outcome="no_audio")
                    print("NO_AUDIO")
                    return

                print(f"TRANSCRIBING seconds={audio.size / SAMPLE_RATE:.2f}")
                try:
                    text = self._transcriber.transcribe(audio)
                except Exception as error:
                    self._core.transcription_finished("")
                    self._write_audit("transcription.finished", outcome="transcription_error", reason=type(error).__name__)
                    print(f"TRANSCRIPTION_ERROR {type(error).__name__}: {error}")
                    return

                self._core.transcription_finished(text)
                outcome = "draft_ready" if self._core.snapshot.state is State.DRAFT_READY else "no_speech_detected"
                self._write_audit("transcription.finished", seconds=audio.size / SAMPLE_RATE, outcome=outcome)

                if self._core.snapshot.state is State.DRAFT_READY:
                    if self._auto_paste:
                        # DRAFT_READY -> TYPING -> paste once -> IDLE
                        text = self._core.typing_requested()

                        if text is None:
                            self._write_audit(
                                "typing.finished",
                                outcome="no_draft",
                            )
                            print("AUTO_PASTE_ABORTED: no draft available")
                        else:
                            try:
                                _paste_via_clipboard(text, self._controller)
                            except Exception as error:
                                self._core.typing_failed()
                                self._write_audit(
                                    "typing.finished",
                                    outcome="auto_paste_error",
                                    reason=type(error).__name__,
                                )
                                print(f"PASTE_ERROR {type(error).__name__}: {error}")
                            else:
                                self._core.typing_succeeded()
                                self._write_audit(
                                    "typing.finished",
                                    outcome="auto_pasted",
                                )
                                print(f"PASTED: {text}")
                    else:
                        # Review mode
                        text = self._review(self._core.snapshot.draft)
                        if text is None:
                            self._core.discard_draft()
                            print("DRAFT_DISCARDED")
                        elif text != self._core.snapshot.draft:
                            self._core.discard_draft()
                            self._core.transcription_finished(text)
                            self._write_audit("review.edited")
                            print(f"DRAFT_EDITED: {text}")
                        else:
                            print(f"DRAFT_READY: {text}")
                else:
                    print("NO_SPEECH_DETECTED")

        elif event.key is keyboard.Key.f9 and event.kind == "release":
            text = self._core.typing_requested()
            if text is None:
                self._write_audit("typing.finished", outcome="no_draft")
                print("NO_DRAFT_TO_TYPE")
                return

            try:
                _paste_via_clipboard(text, self._controller)
            except Exception as error:
                self._core.typing_failed()
                self._write_audit("typing.finished", outcome="typing_error", reason=type(error).__name__)
                print(f"TYPING_ERROR {type(error).__name__}: {error}")
                return

            self._core.typing_succeeded()
            self._write_audit("typing.finished", outcome="typed")
            print("DRAFT_TYPED")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Local offline push-to-talk transcription."
    )
    parser.add_argument(
        "--device",
        help="Input device index or unique name fragment. If not provided, you'll be prompted to select.",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List usable input devices and exit.",
    )
    parser.add_argument("--model", default="base.en")
    parser.add_argument("--audit-log", type=Path, help="Optional JSONL operational log.")
    parser.add_argument("--toggle", action="store_true",
        help="Toggle mode: press F8 to start, press F8 again to stop. Default is hold-to-record.")
    parser.add_argument("--auto-paste", action="store_true",
        help="Skip draft review and paste directly. Edit or delete in active window.")
    parser.add_argument(
        "--accessibility-ui",
        action="store_true",
        help="Show the optional local screen-reader and conversation overlay.",
    )
    parser.add_argument(
        "--accessibility-config",
        type=Path,
        default=Path("accessibility_overlay.json"),
        help="Local-only overlay configuration file.",
    )
    parser.add_argument(
        "--tts-device",
        help="Exact output name fragment for existing Kaiku Reader (for example: Soundcore).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.list_devices:
        list_input_devices()
        return

    if args.device is None:
        device = choose_device_interactive()
    else:
        device = resolve_input_device(args.device)

    root = Path(__file__).resolve().parents[2]
    model_dir = root / "models"

    print(f"\n  INPUT_DEVICE {device}: {sd.query_devices(device)['name']}")
    print(f"  MODEL_DIR {model_dir}\n")
    app = PushToTalkApp(
        device,
        args.model,
        model_dir,
        args.audit_log,
        toggle=args.toggle,
        auto_paste=args.auto_paste,
    )
    if args.accessibility_ui:
        from .accessibility_ui import run_with_app
        run_with_app(app, config=args.accessibility_config, output_device=args.tts_device)
    else:
        app.run()


if __name__ == "__main__":
    main()
