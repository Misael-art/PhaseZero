from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame, QGroupBox, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage


class WaydroidPage(BasePage):
    """Waydroid lifecycle: status, install, repair, launch, host-access, boot."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader("Status", "Estado do container Android"))
        for aid in ("waydroid.status", "waydroid.plan"):
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))

        lifecycle_box = QGroupBox("Ciclo de vida")
        lifecycle_layout = QVBoxLayout(lifecycle_box)
        for aid in ("waydroid.install", "waydroid.repair", "waydroid.launch", "waydroid.host-access"):
            action = self.find(aid)
            if action:
                lifecycle_layout.addWidget(self._action_row(action))
        layout.addWidget(lifecycle_box)

        boot_box = QGroupBox("Boot direto")
        boot_layout = QVBoxLayout(boot_box)
        for aid in ("waydroid.boot.install", "waydroid.boot.next"):
            action = self.find(aid)
            if action:
                boot_layout.addWidget(self._action_row(action))
        layout.addWidget(boot_box)
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
