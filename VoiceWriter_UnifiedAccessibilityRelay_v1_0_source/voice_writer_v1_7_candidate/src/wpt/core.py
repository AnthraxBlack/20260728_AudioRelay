from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class State(str, Enum):
    IDLE = "idle"
    RECORDING = "recording"
    TRANSCRIBING = "transcribing"
    DRAFT_READY = "draft_ready"
    TYPING = "typing"
    STOPPED = "stopped"


@dataclass(frozen=True)
class Snapshot:
    state: State
    draft: str


class PushToTalkCore:
    """Pure state machine for one push-to-talk interaction at a time."""

    def __init__(self) -> None:
        self._state = State.IDLE
        self._draft = ""
        self._assert_invariants()

    @property
    def snapshot(self) -> Snapshot:
        return Snapshot(state=self._state, draft=self._draft)

    def record_pressed(self) -> bool:
        if self._state is not State.IDLE:
            return False
        self._state = State.RECORDING
        self._assert_invariants()
        return True

    def record_released(self) -> bool:
        if self._state is not State.RECORDING:
            return False
        self._state = State.TRANSCRIBING
        self._assert_invariants()
        return True

    def transcription_finished(self, text: str) -> bool:
        if self._state is not State.TRANSCRIBING:
            return False

        self._draft = text.strip()
        self._state = State.DRAFT_READY if self._draft else State.IDLE
        self._assert_invariants()
        return True

    def typing_requested(self) -> str | None:
        if self._state is not State.DRAFT_READY:
            return None
        self._state = State.TYPING
        self._assert_invariants()
        return self._draft

    def typing_succeeded(self) -> bool:
        if self._state is not State.TYPING:
            return False
        self._draft = ""
        self._state = State.IDLE
        self._assert_invariants()
        return True

    def typing_failed(self) -> bool:
        if self._state is not State.TYPING:
            return False
        self._state = State.DRAFT_READY
        self._assert_invariants()
        return True

    def discard_draft(self) -> bool:
        if self._state is not State.DRAFT_READY:
            return False
        self._draft = ""
        self._state = State.IDLE
        self._assert_invariants()
        return True

    def stop(self) -> None:
        self._draft = ""
        self._state = State.STOPPED
        self._assert_invariants()

    def _assert_invariants(self) -> None:
        has_draft = bool(self._draft)
        draft_state = self._state in {State.DRAFT_READY, State.TYPING}
        if has_draft != draft_state:
            raise RuntimeError(
                f"Invalid state: state={self._state.value!r}, draft_present={has_draft}"
            )
