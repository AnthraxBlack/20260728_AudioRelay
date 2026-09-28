from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


_ALLOWED_FIELDS = frozenset(
    {
        "device_index",
        "device_name",
        "model_name",
        "seconds",
        "outcome",
        "reason",
    }
)

_FORBIDDEN_FIELDS = frozenset(
    {
        "audio",
        "draft",
        "keystrokes",
        "text",
        "transcript",
    }
)


class AuditWriter:
    """Append non-content operational events as JSON Lines."""

    def __init__(self, path: Path) -> None:
        self._path = path

    def append(self, event: str, **fields: Any) -> dict[str, Any]:
        unknown = set(fields) - _ALLOWED_FIELDS
        forbidden = set(fields) & _FORBIDDEN_FIELDS

        if forbidden:
            raise ValueError(
                f"Sensitive fields are prohibited in audit records: {sorted(forbidden)}"
            )
        if unknown:
            raise ValueError(f"Unsupported audit fields: {sorted(unknown)}")
        if not event:
            raise ValueError("Event name must not be empty.")

        record = {
            "schema": "wpt.audit.v1",
            "utc": datetime.now(timezone.utc).isoformat(),
            "event": event,
            "fields": fields,
        }
        line = json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"

        self._path.parent.mkdir(parents=True, exist_ok=True)
        with self._path.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())

        return record