from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame, QGroupBox, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QStyle, QTableWidget, QTableWidgetItem,
    QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage


class FlatpakPage(BasePage):
    """Flatpak management: audit results table + action buttons."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader("Status e auditoria", "Estado do Flatpak no sistema"))
        for aid in ("flatpak.status", "flatpak.audit", "flatpak.remotes"):
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))

        layout.addWidget(SectionHeader("Reparos e compatibilidade", ""))
        for aid in ("flatpak.repair", "flatpak.steamdeck", "flatpak.rollback"):
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))
        layout.addStretch()

        scroll.setWidget(inner)
        self._layout.addWidget(scroll)

    def _action_row(self, action: ActionSpec) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        row = QHBoxLayout(card)
        row.setContentsMargins(14, 10, 14, 10)
        icon = QLabel()
        icon.setPixmap(themed_icon(card, action.icon, QStyle.SP_ComputerIcon).pixmap(24, 24))
        icon.setFixedSize(34, 34)
        row.addWidget(icon)
        text = QLabel(action.title)
        text.setObjectName("cardTitle")
        text.setToolTip(action.description)
        row.addWidget(text, 1)
        btn = QPushButton("Executar")
        btn.setObjectName("primaryButton" if action.mutable else "secondaryButton")
        btn.clicked.connect(lambda: self.request_action(action))
        row.addWidget(btn)
        return card

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
