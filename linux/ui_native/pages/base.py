from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QTimer, Signal
from PySide6.QtWidgets import QGridLayout, QVBoxLayout, QWidget

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..status_loader import StatusLoader
from ..widgets import SkeletonCard, SkeletonTile, stop_shimmer


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
        self._loading_timer = QTimer(self)
        self._loading_timer.setSingleShot(True)
        self._loading_callback = None
        self._loading_timer.timeout.connect(self._show_delayed_loading)

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

    def begin_loading(self, callback, delay_ms: int = 200) -> None:
        """Schedule loading placeholders, avoiding flashes for fast status calls."""
        self.finish_loading()
        self._loading_callback = callback
        self._loading_timer.start(max(0, delay_ms))

    def _show_delayed_loading(self) -> None:
        callback = self._loading_callback
        self._loading_callback = None
        if callback is not None:
            callback()

    def finish_loading(self) -> None:
        self._loading_timer.stop()
        self._loading_callback = None
        self.clear_skeletons()

    def clear_skeletons(self) -> None:
        """Remove all skeleton cards from the page."""
        container = self.findChild(QWidget, "_skeleton_container")
        if container is not None:
            for tile in container.findChildren(SkeletonTile):
                stop_shimmer(tile)
            self._layout.removeWidget(container)
            container.setParent(None)
            container.deleteLater()
        self._skeleton_grid = None

    def cancel_status(self) -> None:
        self._loading_timer.stop()
        self.status_loader.cancel_all()
        self.clear_skeletons()

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
