from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Signal
from PySide6.QtWidgets import QGridLayout, QVBoxLayout, QWidget

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..status_loader import StatusLoader
from ..widgets import SkeletonCard


class BasePage(QWidget):
    """Base class for every category page."""

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
        self.status_loader = StatusLoader(root, self)
        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._layout.setSpacing(0)
        self._skeleton_grid: QGridLayout | None = None

    def build(self) -> None:
        pass

    def reload(self) -> None:
        pass

    def block_while_running(self, running: bool) -> None:
        pass

    def show_skeletons(self, count: int = 6, columns: int = 3) -> QGridLayout:
        """Show N skeleton cards in a grid. Returns the grid for layout positioning."""
        self.clear_skeletons()
        container = QWidget()
        grid = QGridLayout(container)
        grid.setContentsMargins(2, 2, 8, 8)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index in range(count):
            card = SkeletonCard()
            grid.addWidget(card, index // columns, index % columns)
        for col in range(columns):
            grid.setColumnStretch(col, 1)
        self._layout.addWidget(container)
        container.setObjectName("_skeleton_container")
        self._skeleton_grid = grid
        return grid

    def clear_skeletons(self) -> None:
        """Remove all skeleton cards from the page."""
        container = self.findChild(QWidget, "_skeleton_container")
        if container is not None:
            self._layout.removeWidget(container)
            container.setParent(None)
            container.deleteLater()
        self._skeleton_grid = None

    def request_action(self, action: ActionSpec) -> None:
        self.action_requested.emit(action)

    def request_actions(self, actions: list[ActionSpec]) -> None:
        if actions:
            self.actions_requested.emit(actions)

    def run_action(self, action_id: str) -> None:
        action = self.by_id.get(action_id)
        if action is not None:
            self.request_action(action)

    def find(self, action_id: str) -> ActionSpec | None:
        return self.by_id.get(action_id)
