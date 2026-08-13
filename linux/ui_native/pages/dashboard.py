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
        self._grids: list[tuple[QGridLayout, list[ActionCard], int]] = []

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
        welcome.setWordWrap(True)
        host_layout.addWidget(welcome)
        subtitle = QLabel("Escaneie, escolha um card e execute — sem decorar caminhos de menu.")
        subtitle.setObjectName("welcomeSubtitle")
        subtitle.setWordWrap(True)
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
        cards = [grid.itemAt(index).widget() for index in range(grid.count())]
        self._grids.append((grid, cards, columns))
        self._reflow_grid(grid, self._grids[-1][1], columns, holder.width())
        return holder

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        self._reflow_for_width(event.size().width())

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._reflow_for_width(self.width())

    def _reflow_for_width(self, width: int) -> None:
        for grid, cards, max_columns in self._grids:
            self._reflow_grid(grid, cards, max_columns, width)

    @staticmethod
    def _reflow_grid(
        grid: QGridLayout,
        cards: list[ActionCard],
        max_columns: int,
        width: int,
    ) -> None:
        """Use only as many columns as fit without a horizontal scrollbar."""
        card_width = max(card.minimumWidth() for card in cards) if cards else 1
        columns = max(
            1,
            min(
                max_columns,
                (max(0, width) + grid.horizontalSpacing())
                // (card_width + grid.horizontalSpacing()),
            ),
        )
        while grid.count():
            grid.takeAt(0)
        for index, card in enumerate(cards):
            grid.addWidget(card, index // columns, index % columns)
        for column in range(max_columns):
            grid.setColumnStretch(column, 1 if column < columns else 0)
            grid.setColumnMinimumWidth(column, 0)

    def block_while_running(self, running: bool) -> None:
        for card in self.dashboard_cards:
            card.setEnabled(not running)
