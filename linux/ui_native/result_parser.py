from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def parse_json_output(text: str) -> Any:
    stripped = text.strip()
    if not stripped:
        return None
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass

    decoder = json.JSONDecoder()
    candidates: list[tuple[int, int, Any]] = []
    for index, char in enumerate(text):
        if char not in "[{":
            continue
        try:
            value, consumed = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        candidates.append((index + consumed, -index, value))
    if not candidates:
        return None
    # Prefer final complete JSON value. For nested values ending at same byte,
    # prefer earliest start, which is the outer envelope.
    return max(candidates, key=lambda item: (item[0], item[1]))[2]


def _has_output(value: Any) -> bool:
    if isinstance(value, dict):
        return bool(value)
    if isinstance(value, list):
        return bool(value)
    if isinstance(value, str):
        return bool(value.strip())
    return value is not None


def severity_for(value: Any, exit_code: int, *, mutable: bool = True, has_output: bool | None = None) -> str:
    if exit_code != 0:
        if mutable:
            return "error"
        if has_output is None:
            has_output = _has_output(value)
        return "warning" if has_output else "error"
    if not isinstance(value, dict):
        return "success"
    status = str(value.get("status", "")).casefold()
    if status in {"failed", "error", "blocked", "requiresrestart", "manualaction"}:
        return "error"
    if status in {"warn", "warning", "degraded", "needsinstall", "needsrepair"}:
        return "warning"
    return "success"


def load_result(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("result root must be object")
    return value
