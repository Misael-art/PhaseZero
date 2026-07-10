from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Signal
from PySide6.QtWidgets import QVBoxLayout, QWidget

from ..command_runner import CommandRunner
from ..models import ActionSpec


class BasePage(QWidget):
    """Base class for every category page.

    Subclasses override ``build()`` to populate their layout with the
    appropriate Qt widgets instead of a homogeneous grid of ActionCards.
    """

    action_requested = Signal(object)
    actions_requested = Signal(object)

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.root = root
        self.runner = runner
        self.actions = actions
        self.by_id = by_id or {}
        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._layout.setSpacing(0)

    def build(self) -> None:
        """Called once during construction. Override to populate layout."""
        pass

    def reload(self) -> None:
        """Called when the page becomes visible. Refresh status / repopulate."""
        pass

    def block_while_running(self, running: bool) -> None:
        """Enable/disable interactive controls when an operation is in flight."""
        pass

    def request_action(self, action: ActionSpec) -> None:
        """Route actions through MainWindow's preview/confirmation workflow."""
        self.action_requested.emit(action)

    def request_actions(self, actions: list[ActionSpec]) -> None:
        """Request a sequential batch while preserving per-action confirmation."""
        if actions:
            self.actions_requested.emit(actions)

    def run_action(self, action_id: str) -> None:
        action = self.by_id.get(action_id)
        if action is not None:
            self.request_action(action)

    def find(self, action_id: str) -> ActionSpec | None:
        return self.by_id.get(action_id)
