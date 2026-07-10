from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame, QHBoxLayout, QLabel, QPushButton, QScrollArea,
    QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import StatusPill, SectionHeader, themed_icon
from .base import BasePage


class OverviewPage(BasePage):
    """Health checks, audit, and support — status pills + action buttons."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader("Diagnóstico", "Auditoria completa do sistema"))
        pills_layout = QVBoxLayout()
        pills_layout.setSpacing(8)
        for aid in ("system.doctor", "system.repair-plan", "system.support-bundle", "system.version"):
            action = self.by_id.get(aid)
            if action is None:
                continue
            pills_layout.addWidget(self._make_pill_action(action))
        layout.addLayout(pills_layout)
        layout.addStretch()

        scroll.setWidget(inner)
        self._layout.addWidget(scroll)

    def _make_pill_action(self, action: ActionSpec) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        row = QHBoxLayout(card)
        row.setContentsMargins(14, 12, 14, 12)
        icon = QLabel()
        px = themed_icon(card, action.icon, QStyle.SP_ComputerIcon).pixmap(28, 28)
        icon.setPixmap(px)
        icon.setFixedSize(38, 38)
        row.addWidget(icon)
        text_box = QVBoxLayout()
        title = QLabel(action.title)
        title.setObjectName("cardTitle")
        desc = QLabel(action.description)
        desc.setObjectName("cardDescription")
        desc.setWordWrap(True)
        text_box.addWidget(title)
        text_box.addWidget(desc)
        row.addLayout(text_box, 1)
        btn = QPushButton("Executar")
        btn.setObjectName("primaryButton" if action.mutable else "secondaryButton")
        btn.clicked.connect(lambda: self.request_action(action))
        row.addWidget(btn)
        return card

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
