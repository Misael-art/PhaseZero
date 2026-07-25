from __future__ import annotations

from pathlib import Path

from PySide6.QtWidgets import QFrame, QGridLayout, QScrollArea, QVBoxLayout, QWidget

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import ActionCard, SectionHeader
from .base import BasePage


class ApplicationsPage(BasePage):
    """Desktop web-app and game launcher workflows."""

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.cards: list[ActionCard] = []

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        host = QWidget()
        layout = QVBoxLayout(host)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)
        layout.addWidget(SectionHeader("Aplicativos e jogos", "Launchers organizados no menu do desktop."))
        grid = QGridLayout()
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        visible = [action for action in self.actions if action.visibility != "advanced"]
        for index, action in enumerate(visible):
            self.mark_represented(action)
            card = ActionCard(action)
            card.requested.connect(self.request_action)
            self.cards.append(card)
            grid.addWidget(card, index // 2, index % 2)
        layout.addLayout(grid)
        layout.addStretch()
        scroll.setWidget(host)
        self._layout.addWidget(scroll)

    def block_while_running(self, running: bool) -> None:
        for card in self.cards:
            card.setEnabled(not running)
