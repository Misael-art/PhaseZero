from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame, QGridLayout, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QStyle, QSizePolicy, QVBoxLayout, QWidget,
)

from ..catalog import DASHBOARD_QUICK, DASHBOARD_TOOLS
from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import ActionCard, SectionHeader, themed_icon
from .base import BasePage


class DashboardPage(BasePage):
    """Welcome screen with hero cards + tool grid."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.dashboard_cards: list[ActionCard] = []

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        host = QWidget()
        host_layout = QVBoxLayout(host)
        host_layout.setContentsMargins(2, 2, 8, 8)
        host_layout.setSpacing(14)

        welcome = QLabel("Bem-vindo de volta ao PhaseZero 👋")
        welcome.setObjectName("welcomeTitle")
        host_layout.addWidget(welcome)
        subtitle = QLabel("Escaneie, escolha um card e execute — sem decorar caminhos de menu.")
        subtitle.setObjectName("welcomeSubtitle")
        host_layout.addWidget(subtitle)

        host_layout.addWidget(SectionHeader("Ações rápidas", "As tarefas mais comuns, em destaque."))
        host_layout.addWidget(self._make_grid(DASHBOARD_QUICK, hero=True, columns=2))

        host_layout.addWidget(SectionHeader("Ferramentas & utilidades", "Atalhos para status e reparos."))
        host_layout.addWidget(self._make_grid(DASHBOARD_TOOLS, hero=False, columns=3))
        host_layout.addStretch()

        scroll.setWidget(host)
        self._layout.addWidget(scroll)

    def _make_grid(self, ids: tuple[str, ...], *, hero: bool, columns: int) -> QWidget:
        holder = QWidget()
        grid = QGridLayout(holder)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index, action_id in enumerate(ids):
            action = self.by_id.get(action_id)
            if action is None:
                continue
            card = ActionCard(action, hero=hero)
            card.requested.connect(self.request_action)
            self.dashboard_cards.append(card)
            grid.addWidget(card, index // columns, index % columns)
        for column in range(columns):
            grid.setColumnStretch(column, 1)
        return holder

    def block_while_running(self, running: bool) -> None:
        for card in self.dashboard_cards:
            card.setEnabled(not running)
