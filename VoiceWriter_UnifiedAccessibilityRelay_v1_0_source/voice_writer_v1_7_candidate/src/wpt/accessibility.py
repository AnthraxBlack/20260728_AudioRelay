"""State and local-only services for the Unified Accessibility Relay.

This module intentionally has no microphone, keyboard, clipboard-writing, screen
capture, window-control, or audio-device-selection authority.  Existing Voice
Writer code may publish observations through :class:`WriterStateBridge`.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from enum import Enum
import json
from pathlib import Path
from typing import Callable, Protocol
from urllib.error import URLError
from urllib.request import Request, urlopen


class Attention(str, Enum):
    QUIET = "quiet"
    INPUT = "input"
    PROCESSING = "processing"
    OUTPUT = "output"
    ERROR = "error"


@dataclass(frozen=True)
class RelayState:
    """A current-state representation, not an activity history."""

    attention: Attention = Attention.QUIET
    status: str = "Ready"
    capturing: bool = False
    transcribing: bool = False
    speaking: bool = False
    error: str | None = None


StateListener = Callable[[RelayState], None]


class RelayStore:
    def __init__(self) -> None:
        self._state = RelayState()
        self._listeners: list[StateListener] = []

    @property
    def state(self) -> RelayState:
        return self._state

    def subscribe(self, listener: StateListener) -> Callable[[], None]:
        self._listeners.append(listener)
        listener(self._state)

        def unsubscribe() -> None:
            if listener in self._listeners:
                self._listeners.remove(listener)

        return unsubscribe

    def publish(self, state: RelayState) -> None:
        if state.capturing:
            state = replace(state, attention=Attention.INPUT, status="Voice Writer is capturing")
        elif state.transcribing:
            state = replace(state, attention=Attention.PROCESSING, status="Voice Writer is transcribing")
        elif state.speaking:
            state = replace(state, attention=Attention.OUTPUT, status="Reading aloud")
        elif state.error:
            state = replace(state, attention=Attention.ERROR, status=state.error)
        else:
            state = replace(state, attention=Attention.QUIET)
        self._state = state
        for listener in tuple(self._listeners):
            listener(state)

    def report_error(self, message: str) -> None:
        self.publish(replace(self._state, error=message, capturing=False, transcribing=False, speaking=False))


class WriterStateBridge:
    """Observation-only bridge exposed to the existing Voice Writer process."""

    def __init__(self, store: RelayStore) -> None:
        self._store = store

    def update_writer_state(
        self,
        *,
        capturing: bool,
        transcribing: bool,
        status: str | None = None,
        error: str | None = None,
    ) -> None:
        self._store.publish(
            replace(
                self._store.state,
                capturing=capturing,
                transcribing=transcribing,
                error=error,
                status=status or self._store.state.status,
                speaking=False if (capturing or transcribing) else self._store.state.speaking,
            )
        )


class SpeechOutput(Protocol):
    def speak(self, text: str) -> bool: ...
    def stop(self) -> None: ...


class ConversationBackend(Protocol):
    def reply(self, user_text: str, *, context: str | None = None) -> str: ...


@dataclass(frozen=True)
class ConversationSettings:
    enabled: bool = False
    endpoint: str = "http://127.0.0.1:11434/api/chat"
    model: str = "qwen3:4b"
    system_prompt: str = "Give a concise, plain-language explanation. State uncertainty when relevant."


class LocalOllamaConversation:
    """Small explicit client for a locally configured Ollama server only."""

    def __init__(self, settings: ConversationSettings) -> None:
        self._settings = settings

    def reply(self, user_text: str, *, context: str | None = None) -> str:
        if not self._settings.enabled:
            raise RuntimeError("Conversation is disabled in accessibility_overlay.json")
        if not self._settings.endpoint.startswith("http://127.0.0.1:"):
            raise RuntimeError("Only a localhost Ollama endpoint is allowed")
        prompt = user_text.strip()
        if context and context.strip():
            prompt = f"Selected text:\n{context.strip()}\n\nRequest:\n{prompt}"
        payload = {
            "model": self._settings.model,
            "stream": False,
            "messages": [
                {"role": "system", "content": self._settings.system_prompt},
                {"role": "user", "content": prompt},
            ],
        }
        request = Request(
            self._settings.endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urlopen(request, timeout=90) as response:  # nosec: localhost guard above
                result = json.loads(response.read().decode("utf-8"))
        except URLError as error:
            raise RuntimeError(f"Local conversation service unavailable: {error.reason}") from error
        try:
            return str(result["message"]["content"]).strip()
        except (KeyError, TypeError) as error:
            raise RuntimeError("Local conversation service returned an unexpected response") from error


def load_conversation_settings(path: Path) -> ConversationSettings:
    if not path.exists():
        return ConversationSettings()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        values = data.get("conversation", {})
        return ConversationSettings(
            enabled=bool(values.get("enabled", False)),
            endpoint=str(values.get("endpoint", ConversationSettings.endpoint)),
            model=str(values.get("model", ConversationSettings.model)),
            system_prompt=str(values.get("system_prompt", ConversationSettings.system_prompt)),
        )
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Cannot read overlay configuration: {error}") from error


class RelayController:
    """User-initiated read and conversation actions over a shared state store."""

    def __init__(self, store: RelayStore, speaker: SpeechOutput | None, conversation: ConversationBackend) -> None:
        self._store = store
        self._speaker = speaker
        self._conversation = conversation

    def read_aloud(self, text: str) -> None:
        if not text.strip():
            raise ValueError("There is no text to read")
        if self._speaker is None:
            raise RuntimeError("TTS unavailable: existing Kaiku Reader was not found")
        self._store.publish(replace(self._store.state, speaking=True, error=None))
        if not self._speaker.speak(text.strip()):
            self._store.report_error("TTS could not start")

    def stop_reading(self) -> None:
        if self._speaker is not None:
            self._speaker.stop()
        self._store.publish(replace(self._store.state, speaking=False, error=None, status="Ready"))

    def ask(self, user_text: str, *, selected_text: str | None = None) -> str:
        if not user_text.strip():
            raise ValueError("Type or transcribe a request first")
        self._store.publish(replace(self._store.state, attention=Attention.PROCESSING, status="Local conversation is responding", error=None))
        try:
            answer = self._conversation.reply(user_text, context=selected_text)
        except Exception as error:
            self._store.report_error(str(error))
            raise
        self._store.publish(replace(self._store.state, attention=Attention.QUIET, status="Response ready", error=None))
        return answer
