from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
import sounddevice as sd
from pynput import keyboard

try:
    from piper import PiperVoice
    PIPER_AVAILABLE = True
except ImportError:
    PIPER_AVAILABLE = False

try:
    from scipy.signal import resample as scipy_resample
    SCIPY_AVAILABLE = True
except ImportError:
    SCIPY_AVAILABLE = False


def list_output_devices() -> None:
    for index, device in enumerate(sd.query_devices()):
        if device["max_output_channels"] > 0:
            host_api = sd.query_hostapis(device["hostapi"])["name"]
            print(
                f"{index}: {device['name']} | "
                f"outputs={device['max_output_channels']} | {host_api}"
            )


def resolve_output_device(selector: str) -> int:
    if selector.isdigit():
        index = int(selector)
        device = sd.query_devices(index)
        if device["max_output_channels"] < 1:
            raise ValueError(f"Device {index} has no output channels.")
        return index

    needle = selector.casefold()
    matches = [
        index
        for index, device in enumerate(sd.query_devices())
        if device["max_output_channels"] > 0 and needle in device["name"].casefold()
    ]

    if len(matches) != 1:
        raise ValueError(
            f"Expected exactly one output device matching {selector!r}; "
            f"found {matches}. Run with --list-devices."
        )
    return matches[0]


def resample_audio(audio: np.ndarray, orig_sr: int, target_sr: int) -> np.ndarray:
    """Resample audio from orig_sr to target_sr.

    Uses scipy.signal.resample if available (high quality),
    falls back to numpy linear interpolation.
    """
    if orig_sr == target_sr:
        return audio

    if len(audio) == 0:
        return audio

    ratio = target_sr / orig_sr
    target_length = max(1, int(len(audio) * ratio))

    if SCIPY_AVAILABLE:
        return scipy_resample(audio, target_length).astype(np.float32)

    # Fallback: simple linear interpolation via numpy
    x_old = np.linspace(0, 1, len(audio))
    x_new = np.linspace(0, 1, target_length)
    return np.interp(x_new, x_old, audio).astype(np.float32)


def find_voice_model(model_path: Path) -> Path:
    """Resolve voice model path, checking multiple locations."""
    if model_path.is_absolute() and model_path.exists():
        return model_path

    if model_path.exists():
        return model_path.resolve()

    # Check relative to script directory
    script_dir = Path(__file__).parent
    relative_path = script_dir / model_path
    if relative_path.exists():
        return relative_path

    # Check relative to current working directory
    cwd_path = Path.cwd() / model_path
    if cwd_path.exists():
        return cwd_path

    raise FileNotFoundError(
        f"Voice model not found: {model_path}\n"
        f"Checked: {model_path}, {relative_path}, {cwd_path}"
    )


class TextToSpeechReader:
    def __init__(
        self,
        device: int,
        voice_model_path: Path,
    ) -> None:
        if not PIPER_AVAILABLE:
            raise RuntimeError(
                "Piper TTS not available. Install with: pip install piper-tts"
            )

        self._device = device
        self._voice_model_path = find_voice_model(Path(voice_model_path))

        print(f"  Loading voice model: {self._voice_model_path}")
        try:
            self._voice = PiperVoice.load(str(self._voice_model_path))
        except Exception as e:
            raise RuntimeError(
                f"Failed to load voice model {self._voice_model_path}: {e}"
            ) from e

        # Query device to get native sample rate
        device_info = sd.query_devices(device)
        self._device_sr = int(device_info["default_samplerate"])
        print(f"  Device sample rate: {self._device_sr} Hz")

    def speak(self, text: str) -> bool:
        """Synthesize text to speech and play through device (non-blocking).

        Returns True on success, False on failure.
        """
        if not text or not text.strip():
            return True

        text = text.strip()

        try:
            # Synthesize audio using Piper
            audio_chunks = []
            piper_sr = None

            for chunk in self._voice.synthesize(text):
                piper_sr = chunk.sample_rate
                # chunk.audio_float_array is already float32, normalized
                audio_chunks.append(chunk.audio_float_array)

            if not audio_chunks:
                return True

            # Concatenate all chunks
            audio = np.concatenate(audio_chunks)

            if len(audio) == 0:
                return True

            # Resample if needed
            if piper_sr and self._device_sr != piper_sr:
                audio = resample_audio(audio, piper_sr, self._device_sr)

            # Play audio (non-blocking so F7 can stop it)
            sd.play(audio, samplerate=self._device_sr, device=self._device, blocking=False)
            return True

        except Exception as error:
            print(f"SPEAK_ERROR {type(error).__name__}: {error}")
            return False

    def stop(self) -> None:
        """Stop playback immediately."""
        try:
            sd.stop()
        except Exception as e:
            print(f"STOP_ERROR {type(e).__name__}: {e}")


class KaikuReaderApp:
    def __init__(self, device: int, voice_model_path: Path) -> None:
        self._device = device
        self._voice_model_path = Path(voice_model_path)
        self._reader = TextToSpeechReader(device, voice_model_path)
        self._controller = keyboard.Controller()
        self._listener: keyboard.Listener | None = None
        self._currently_playing = False  # Toggle state flag
        self._running = True

    def run(self) -> None:
        self._listener = keyboard.Listener(on_release=self._on_release)
        self._listener.start()

        print("\nKaiku Reader Active")
        print("F7: toggle speaking (press again to stop)")
        print("Escape: exit\n")

        try:
            while self._running:
                time.sleep(0.1)
        except KeyboardInterrupt:
            pass
        finally:
            self._stop()

    def _on_release(self, key: Any, injected: bool = False) -> None:
        if injected:
            return

        if key is keyboard.Key.f7:
            self._speak_clipboard()
        elif key is keyboard.Key.esc:
            self._stop()

    def _speak_clipboard(self) -> None:
        """Toggle: start speaking if idle, stop if currently playing."""
        if self._currently_playing:
            # Stop current playback
            self._reader.stop()
            self._currently_playing = False
            print("Stopped.")
            return

        # Get clipboard text
        try:
            import pyperclip
            text = pyperclip.paste()
        except ImportError:
            try:
                # Windows fallback using ctypes
                import ctypes
                CF_UNICODETEXT = 13

                _user32 = ctypes.windll.user32
                _kernel32 = ctypes.windll.kernel32

                _user32.OpenClipboard(0)
                h = _user32.GetClipboardData(CF_UNICODETEXT)
                if h:
                    p = _kernel32.GlobalLock(h)
                    if p:
                        text = ctypes.wstring_at(p)
                        _kernel32.GlobalUnlock(h)
                    else:
                        text = ""
                else:
                    text = ""
                _user32.CloseClipboard()
            except Exception as e:
                print(f"ERROR reading clipboard: {e}")
                return

        if not text or not text.strip():
            print("Clipboard is empty")
            return

        preview = text[:60].replace("\n", " ")
        print(f"Speaking: {preview}...")

        # Start playback (non-blocking)
        success = self._reader.speak(text)
        if success:
            self._currently_playing = True
            print("(press F7 again to stop)")
        else:
            print("Failed to speak")

    def _stop(self) -> None:
        self._running = False
        if self._listener is not None:
            self._listener.stop()
            self._listener.join(timeout=1)
        print("\nKaiku Reader stopped")


def choose_device_interactive() -> int:
    """Prompt user to select an output device from a formatted menu."""
    devices = [
        (idx, dev)
        for idx, dev in enumerate(sd.query_devices())
        if dev["max_output_channels"] > 0
    ]

    if not devices:
        raise SystemExit("ERROR: No output devices found.")

    print("\n" + "─" * 60)
    print("  OUTPUT DEVICES")
    print("─" * 60)

    for idx, (dev_idx, dev) in enumerate(devices):
        rate = int(dev["default_samplerate"])
        channels = dev["max_output_channels"]
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read clipboard text aloud using Piper TTS."
    )
    parser.add_argument(
        "--device",
        help="Output device index or unique name fragment.",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List usable output devices and exit.",
    )
    parser.add_argument(
        "--voice-model",
        type=Path,
        default=Path("voices/en_US-bryce-medium.onnx"),
        help="Path to Piper voice model.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.list_devices:
        list_output_devices()
        return

    if args.device is None:
        device = choose_device_interactive()
    else:
        device = resolve_output_device(args.device)

    print(f"\n  OUTPUT_DEVICE {device}: {sd.query_devices(device)['name']}")

    try:
        KaikuReaderApp(device, args.voice_model).run()
    except Exception as e:
        print(f"FATAL ERROR: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()