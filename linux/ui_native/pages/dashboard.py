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
from ..operation_ledger import OperationLedger
from ..widgets import ActionCard, SectionHeader, themed_icon
from .base import BasePage

# Jornada de primeiro uso: três passos concretos, cada um uma ação real do
# catálogo (nada de navegação inventada). IDs ausentes simplesmente somem.
ONBOARDING_STEPS: tuple[tuple[str, str, str], ...] = (
    ("1", "Diagnosticar o sistema",
     "Uma checagem rápida diz o que já está bom e o que precisa de atenção."),
    ("2", "Preparar agentes de IA",
     "Instala as regras e conectores para os assistentes funcionarem aqui."),
    ("3", "Criar primeiro backup",
     "Memória, acessos e dados protegidos antes de qualquer mudança grande."),
)

_STEP_HINTS = {number: hint for number, _t, hint in ONBOARDING_STEPS}


def _hint_for(number: str) -> str:
    return _STEP_HINTS.get(number, "")


class DashboardPage(BasePage):
    """Welcome screen with hero cards + tool grid."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.dashboard_cards: list[ActionCard] = []
        self._grids: list[tuple[QGridLayout, list[ActionCard], int]] = []
        try:
            first_use = not OperationLedger(root).records(limit=1)
        except Exception:
            first_use = True
        self.first_use = first_use

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        host = QWidget()
        host_layout = QVBoxLayout(host)
        host_layout.setContentsMargins(2, 2, 8, 8)
        host_layout.setSpacing(14)

        if self.first_use:
            welcome = QLabel("Vamos configurar seu computador 👋")
        else:
            welcome = QLabel("Bem-vindo de volta ao PhaseZero 👋")
        welcome.setObjectName("welcomeTitle")
        welcome.setWordWrap(True)
        host_layout.addWidget(welcome)
        subtitle = QLabel("Escaneie, escolha um card e execute — sem decorar caminhos de menu.")
        subtitle.setObjectName("welcomeSubtitle")
        subtitle.setWordWrap(True)
        host_layout.addWidget(subtitle)

        if self.first_use:
            onboarding = self._build_onboarding()
            if onboarding is not None:
                host_layout.addWidget(onboarding)

        host_layout.addWidget(SectionHeader("Ações rápidas", "As tarefas mais comuns, em destaque."))
        host_layout.addWidget(self._make_grid(DASHBOARD_QUICK, hero=True, columns=2))

        host_layout.addWidget(SectionHeader("Ferramentas & utilidades", "Atalhos para status e reparos."))
        host_layout.addWidget(self._make_grid(DASHBOARD_TOOLS, hero=False, columns=3))
        host_layout.addStretch()

        scroll.setWidget(host)
        self._layout.addWidget(scroll)

    def _build_onboarding(self) -> QWidget | None:
        """Faixa 'Comece por aqui' — 3 passos, só com ações que existem."""
        steps: list[tuple[str, str, ActionSpec]] = []
        for number, title, _hint in ONBOARDING_STEPS:
            action_id = {
                "1": "system.doctor.system",
                "2": "ai.compat",
                "3": "ai.backup.export",
            }.get(number, "")
            action = self.by_id.get(action_id)
            if action is not None:
                steps.append((number, title, action))
        if len(steps) < 2:
            return None
        card = QFrame()
        card.setObjectName("healthHero")
        column = QVBoxLayout(card)
        column.setContentsMargins(20, 16, 20, 16)
        column.setSpacing(8)
        heading = QLabel("Comece por aqui")
        heading.setObjectName("serviceTitle")
        column.addWidget(heading)
        for number, title, action in steps:
            row = QHBoxLayout()
            badge = QLabel(number)
            badge.setObjectName("healthShield")
            badge.setAlignment(Qt.AlignCenter)
            badge.setFixedSize(30, 30)
            text = QVBoxLayout()
            label = QLabel(title)
            label.setObjectName("serviceTitle")
            label.setWordWrap(True)
            hint = QLabel(_hint_for(number))
            hint.setObjectName("cardDescription")
            hint.setWordWrap(True)
            text.addWidget(label)
            text.addWidget(hint)
            run = QPushButton("Executar")
            run.setObjectName("primaryButton")
            run.setAccessibleName(f"{title} — executar agora")
            run.clicked.connect(lambda _=False, a=action: self.request_action(a))
            row.addWidget(badge)
            row.addLayout(text, 1)
            row.addWidget(run)
            column.addLayout(row)
        return card

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
