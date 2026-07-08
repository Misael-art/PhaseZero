from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class ActionSpec:
    id: str
    category: str
    title: str
    description: str
    args: tuple[str, ...]
    icon: str
    mutable: bool = False
    preview_args: tuple[str, ...] | None = None
    elevated: bool = False
    badge: str = ""
    input_label: str = ""
    input_kind: str = ""
    keywords: tuple[str, ...] = field(default_factory=tuple)

    def resolved_args(self, value: str = "", *, preview: bool = False) -> list[str]:
        source = self.preview_args if preview and self.preview_args is not None else self.args
        return [value if token == "{input}" else token for token in source]

    @property
    def searchable_text(self) -> str:
        return " ".join(
            (self.title, self.description, self.category, self.badge, *self.args, *self.keywords)
        ).casefold()

    @property
    def variant(self) -> str:
        """Visual weight of the primary button: danger / primary / secondary."""
        if self.badge in {"Alto risco", "Resgate"}:
            return "danger"
        if self.mutable:
            return "primary"
        return "secondary"

    @property
    def state(self) -> str:
        """Semantic colour of the badge chip (EmuDeck-style status colours)."""
        mapping = {
            "Alto risco": "error",
            "Resgate": "error",
            "Reparo": "warning",
            "Requer ISO": "warning",
            "Reversível": "success",
            "Protegido": "success",
            "Seguro": "success",
        }
        if self.badge in mapping:
            return mapping[self.badge]
        if self.elevated:
            return "warning"
        return "info"


@dataclass
class OperationResult:
    action_id: str
    command: list[str]
    preview: bool
    exit_code: int
    started_at: str
    finished_at: str
    stdout: str
    stderr: str
    parsed: Any = None
    result_path: Path | None = None

    @property
    def ok(self) -> bool:
        return self.exit_code == 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "action": self.action_id,
            "command": self.command,
            "preview": self.preview,
            "ok": self.ok,
            "exitCode": self.exit_code,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "result": self.parsed,
        }
