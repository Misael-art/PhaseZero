from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox, QFrame, QGroupBox, QHBoxLayout, QLabel,
    QPushButton, QScrollArea, QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage


class ServerPage(BasePage):
    """Server controls grouped by subsystem: LLM, Homelab, CasaOS, Hermes, Boot."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        # Status (always useful at top)
        layout.addWidget(SectionHeader("Status geral", "Visão consolidada"))
        for aid in ("server.status", "server.homelab.status", "server.llm"):
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))

        # Homelab stack (the biggest group)
        homelab_box = QGroupBox("Homelab (Docker)")
        homelab_layout = QVBoxLayout(homelab_box)
        for aid in (
            "server.homelab.status", "server.homelab.plan", "server.homelab.repair",
            "server.homelab.up", "server.homelab.up-tailscale", "server.homelab.up-extras",
            "server.homelab.down", "server.homelab.backup", "server.homelab.restore",
            "server.homelab.update", "server.homelab.tailscale",
            "server.homelab.open-portainer", "server.homelab.open-jellyfin",
            "server.homelab.open-vaultwarden", "server.homelab.open-kuma",
            "server.homelab.logs",
        ):
            action = self.find(aid)
            if action:
                homelab_layout.addWidget(self._action_row(action))
        layout.addWidget(homelab_box)

        # CasaOS, Hermes, Slim, Boot
        extra_box = QGroupBox("Extras")
        extra_layout = QVBoxLayout(extra_box)
        for aid in (
            "server.casaos.status", "server.casaos.plan", "server.casaos.install",
            "server.hermes",
            "server.slim", "server.slim.restore",
            "server.boot.install", "server.boot.next",
        ):
            action = self.find(aid)
            if action:
                extra_layout.addWidget(self._action_row(action))
        layout.addWidget(extra_box)
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
