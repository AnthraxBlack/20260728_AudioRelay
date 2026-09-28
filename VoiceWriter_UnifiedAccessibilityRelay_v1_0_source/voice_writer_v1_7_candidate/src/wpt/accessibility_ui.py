"""A local Tk window for explicit Voice Writer accessibility actions."""

from __future__ import annotations

import argparse
from pathlib import Path
import threading
import tkinter as tk
from tkinter import ttk
from typing import Any, Callable

from .accessibility import (
    Attention,
    LocalOllamaConversation,
    RelayController,
    RelayState,
    RelayStore,
    load_conversation_settings,
)


def _clipboard_text(root: tk.Tk) -> str:
    try:
        return root.clipboard_get().strip()
    except tk.TclError:
        return ""


def _existing_tts(device_selector: str | None):
    """Use the existing Kaiku Reader only; never choose a default output device."""
    try:
        from .kaiku_reader import TextToSpeechReader, resolve_output_device  # type: ignore
    except ImportError:
        return None
    if not device_selector:
        return None
    try:
        return TextToSpeechReader(resolve_output_device(device_selector), Path("voices/en_US-bryce-medium.onnx"))
    except Exception:
        return None


class RelayWindow:
    GLYPHS = {
        Attention.QUIET: "◉  ◉",
        Attention.INPUT: "◉◉  ←",
        Attention.PROCESSING: "◉  ·  ◉",
        Attention.OUTPUT: "→  ◉◉",
        Attention.ERROR: "!  ◉◉",
    }

    def __init__(self, root: tk.Tk, controller: RelayController, store: RelayStore) -> None:
        self.root = root
        self.controller = controller
        self.store = store
        self.on_close: Callable[[], None] | None = None
        root.title("Unified Accessibility Relay")
        root.minsize(720, 560)

        frame = ttk.Frame(root, padding=16)
        frame.grid(sticky="nsew")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        frame.columnconfigure(0, weight=1)

        self.indicator = ttk.Label(frame, text="◉  ◉", font=("Segoe UI", 24))
        self.indicator.grid(row=0, column=0, sticky="w")
        self.status = ttk.Label(frame, text="Ready")
        self.status.grid(row=1, column=0, sticky="w", pady=(0, 12))

        ttk.Label(frame, text="Selected screen text (paste or use Load clipboard):").grid(row=2, column=0, sticky="w")
        self.selected = tk.Text(frame, height=7, wrap="word")
        self.selected.grid(row=3, column=0, sticky="nsew", pady=(4, 8))
        frame.rowconfigure(3, weight=1)

        selection_actions = ttk.Frame(frame)
        selection_actions.grid(row=4, column=0, sticky="w", pady=(0, 14))
        ttk.Button(selection_actions, text="Load clipboard", command=self.load_clipboard).grid(row=0, column=0, padx=(0, 8))
        ttk.Button(selection_actions, text="Read aloud", command=self.read_selected).grid(row=0, column=1, padx=(0, 8))
        ttk.Button(selection_actions, text="Stop reading", command=self.controller.stop_reading).grid(row=0, column=2)

        ttk.Separator(frame).grid(row=5, column=0, sticky="ew", pady=10)
        ttk.Label(frame, text="Conversation request:").grid(row=6, column=0, sticky="w")
        self.request = ttk.Entry(frame)
        self.request.grid(row=7, column=0, sticky="ew", pady=(4, 8))
        self.request.bind("<Return>", lambda _event: self.ask())
        ttk.Button(frame, text="Ask local conversation", command=self.ask).grid(row=8, column=0, sticky="w")

        ttk.Label(frame, text="Response:").grid(row=9, column=0, sticky="w", pady=(14, 0))
        self.response = tk.Text(frame, height=7, wrap="word", state="disabled")
        self.response.grid(row=10, column=0, sticky="nsew", pady=(4, 0))
        frame.rowconfigure(10, weight=1)

        self._unsubscribe = self.store.subscribe(lambda state: root.after(0, self.render, state))
        root.protocol("WM_DELETE_WINDOW", self.close)

    def render(self, state: RelayState) -> None:
        self.indicator.configure(text=self.GLYPHS[state.attention])
        self.status.configure(text=state.status)

    def selected_text(self) -> str:
        return self.selected.get("1.0", "end-1c").strip()

    def load_clipboard(self) -> None:
        text = _clipboard_text(self.root)
        if not text:
            self.store.report_error("Clipboard has no text")
            return
        self.selected.delete("1.0", "end")
        self.selected.insert("1.0", text)
        self.store.publish(RelayState(status="Clipboard text loaded"))

    def read_selected(self) -> None:
        try:
            self.controller.read_aloud(self.selected_text())
        except (RuntimeError, ValueError) as error:
            self.store.report_error(str(error))

    def ask(self) -> None:
        question = self.request.get().strip()
        selected = self.selected_text()

        def run() -> None:
            try:
                answer = self.controller.ask(question, selected_text=selected or None)
            except (RuntimeError, ValueError) as error:
                self.root.after(0, self.show_answer, f"{type(error).__name__}: {error}")
            else:
                self.root.after(0, self.show_answer, answer)

        threading.Thread(target=run, daemon=True).start()

    def show_answer(self, text: str) -> None:
        self.response.configure(state="normal")
        self.response.delete("1.0", "end")
        self.response.insert("1.0", text)
        self.response.configure(state="disabled")

    def close(self) -> None:
        self._unsubscribe()
        self.controller.stop_reading()
        if self.on_close is not None:
            self.on_close()
        self.root.destroy()


def writer_state_sink(store: RelayStore) -> Callable[[Any], None]:
    """Map the existing pure Voice Writer state machine to overlay state."""
    from .accessibility import WriterStateBridge

    bridge = WriterStateBridge(store)

    def publish(state: Any) -> None:
        value = getattr(state, "value", str(state))
        labels = {
            "idle": "Voice Writer ready",
            "recording": "Voice Writer is capturing",
            "transcribing": "Voice Writer is transcribing",
            "draft_ready": "Draft ready for typing",
            "typing": "Voice Writer is typing",
            "stopped": "Voice Writer stopped",
        }
        bridge.update_writer_state(
            capturing=value == "recording",
            transcribing=value == "transcribing",
            status=labels.get(value, "Voice Writer state unavailable"),
            error=None,
        )

    return publish


def run_with_app(app: Any, *, config: Path, output_device: str | None) -> None:
    """Run Tk on the main thread and Voice Writer in a worker thread.

    The existing app publishes its states to the overlay. The overlay does not
    gain microphone, hotkey, clipboard-writing, or device-selection control.
    """
    settings = load_conversation_settings(config)
    store = RelayStore()
    app.set_state_sink(writer_state_sink(store))
    speaker = _existing_tts(output_device)
    controller = RelayController(store, speaker, LocalOllamaConversation(settings))
    root = tk.Tk()
    window = RelayWindow(root, controller, store)
    window.on_close = app.request_stop
    worker = threading.Thread(target=app.run, name="voice-writer", daemon=True)
    worker.start()
    root.mainloop()
    worker.join(timeout=2)


def main() -> None:
    parser = argparse.ArgumentParser(description="Unified local accessibility overlay for Voice Writer")
    parser.add_argument("--config", type=Path, default=Path("accessibility_overlay.json"))
    parser.add_argument("--output-device", default=None, help="Exact output name fragment for existing Kaiku Reader")
    args = parser.parse_args()

    settings = load_conversation_settings(args.config)
    store = RelayStore()
    speaker = _existing_tts(args.output_device)
    controller = RelayController(store, speaker, LocalOllamaConversation(settings))
    root = tk.Tk()
    RelayWindow(root, controller, store)
    root.mainloop()


if __name__ == "__main__":
    main()
