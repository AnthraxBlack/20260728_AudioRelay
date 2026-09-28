from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from wpt.accessibility import Attention, LocalOllamaConversation, RelayController, RelayStore, WriterStateBridge, load_conversation_settings
from wpt.accessibility_ui import writer_state_sink
from wpt.core import State


class FakeSpeaker:
    def __init__(self) -> None:
        self.spoken: list[str] = []
        self.stopped = False

    def speak(self, text: str) -> bool:
        self.spoken.append(text)
        return True

    def stop(self) -> None:
        self.stopped = True


class FakeConversation:
    def reply(self, user_text: str, *, context: str | None = None) -> str:
        return f"{user_text}|{context}"


class AccessibilityTests(unittest.TestCase):
    def test_writer_bridge_is_observation_only_and_maps_capture(self) -> None:
        store = RelayStore()
        bridge = WriterStateBridge(store)
        bridge.update_writer_state(capturing=True, transcribing=False)
        self.assertTrue(store.state.capturing)
        self.assertEqual(store.state.attention, Attention.INPUT)
        self.assertEqual(store.state.status, "Voice Writer is capturing")

    def test_draft_ready_returns_attention_to_quiet(self) -> None:
        store = RelayStore()
        sink = writer_state_sink(store)
        sink(State.TRANSCRIBING)
        sink(State.DRAFT_READY)
        self.assertEqual(store.state.attention, Attention.QUIET)
        self.assertEqual(store.state.status, "Draft ready for typing")

    def test_controller_reads_only_on_explicit_call(self) -> None:
        store = RelayStore()
        speaker = FakeSpeaker()
        controller = RelayController(store, speaker, FakeConversation())
        controller.read_aloud("Read me")
        self.assertEqual(speaker.spoken, ["Read me"])
        self.assertEqual(store.state.attention, Attention.OUTPUT)
        controller.stop_reading()
        self.assertTrue(speaker.stopped)
        self.assertFalse(store.state.speaking)

    def test_conversation_preserves_selected_text_as_explicit_context(self) -> None:
        controller = RelayController(RelayStore(), FakeSpeaker(), FakeConversation())
        self.assertEqual(controller.ask("Explain", selected_text="A form field"), "Explain|A form field")

    def test_local_endpoint_guard_rejects_remote_endpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"conversation": {"enabled": True, "endpoint": "https://example.test/chat"}}), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "localhost"):
                LocalOllamaConversation(load_conversation_settings(path)).reply("hello")


if __name__ == "__main__":
    unittest.main()
