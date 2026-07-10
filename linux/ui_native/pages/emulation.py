from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame, QGroupBox, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QStyle, QTabWidget, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import themed_icon
from .base import BasePage

TABS: list[tuple[str, list[str]]] = [
    ("Geral", [
        "emulation.status", "emulation.setup", "emulation.layout",
        "emulation.doctor", "emulation.fixes", "emulation.optimizers",
    ]),
    ("Frontends", [
        "emulation.emudeck", "emulation.retrodeck", "emulation.srm",
        "emulation.launchbox-install", "emulation.launchbox-sync",
        "emulation.launchbox-verify", "emulation.bigbox-test",
        "emulation.frontends",
    ]),
    ("Mídia e Pastas", [
        "emulation.shared", "emulation.media", "emulation.media-clean",
        "emulation.bios", "emulation.keys", "emulation.firmware",
        "emulation.nsz", "emulation.ps3-game",
    ]),
    ("Performance e Controles", [
        "emulation.controllers", "emulation.performance", "emulation.rom-optimize",
        "emulation.lsfg",
    ]),
    ("Ferramentas", [
        "emulation.lua", "emulation.steam-tools", "emulation.heroic",
        "emulation.pc-games", "emulation.shortcuts",
        "emulation.eden", "emulation.citron", "emulation.hydra",
    ]),
]


class EmulationPage(BasePage):
    """Emulation page with tabs grouping all 44 emulation actions."""

    def build(self) -> None:
        tabs = QTabWidget()
        tabs.setObjectName("emulationTabs")
        tabs.setDocumentMode(True)
        for label, action_ids in TABS:
            page = QWidget()
            layout = QVBoxLayout(page)
            layout.setContentsMargins(4, 4, 4, 4)
            layout.setSpacing(10)
            for aid in action_ids:
                action = self.find(aid)
                if action:
                    layout.addWidget(self._action_row(action))
            layout.addStretch()
            tabs.addTab(page, label)
        self._layout.addWidget(tabs, 1)

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
