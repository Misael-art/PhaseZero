from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox, QFileDialog, QFormLayout, QFrame, QGroupBox,
    QHBoxLayout, QLabel, QPushButton, QScrollArea, QStyle,
    QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage


class WindowsVMPage(BasePage):
    """Windows VM lifecycle page: status, install, launch, host-access, boot."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        # Status
        layout.addWidget(SectionHeader("Status", "Estado da VM Windows"))
        for aid in ("windows.status", "windows.discover"):
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))

        # Install & Launch
        install_box = QGroupBox("Instalação e inicialização")
        install_layout = QVBoxLayout(install_box)
        for aid in ("windows.plan", "windows.install", "windows.adopt", "windows.launch", "windows.optimize"):
            action = self.find(aid)
            if action:
                install_layout.addWidget(self._action_row(action))
        layout.addWidget(install_box)

        # Graphics acceleration and runtime maintenance.
        graphics_box = QGroupBox("Gráficos e aceleração")
        graphics_layout = QVBoxLayout(graphics_box)
        for aid in (
            "windows.graphics.doctor",
            "windows.graphics.status",
            "windows.graphics.plan-gl",
            "windows.graphics.test-gl",
            "windows.graphics.plan-vfio",
            "windows.graphics.compat",
            "windows.graphics.runtime-status",
            "windows.graphics.runtime-install",
            "windows.graphics.runtime-rollback",
            "windows.graphics.guest-guide",
        ):
            action = self.find(aid)
            if action:
                if aid == "windows.graphics.doctor":
                    self._context_status_action = action
                graphics_layout.addWidget(self._action_row(action))
        layout.addWidget(graphics_box)

        apps_box = QGroupBox("WinBoat e WinPodX — Podman")
        apps_layout = QVBoxLayout(apps_box)
        for aid in ("windows.apps.status", "windows.apps.setup", "windows.apps.configure"):
            action = self.find(aid)
            if action:
                apps_layout.addWidget(self._action_row(action))
        layout.addWidget(apps_box)

        # Host access + Boot
        system_box = QGroupBox("Sistema")
        system_layout = QVBoxLayout(system_box)
        for aid in ("windows.host-access", "windows.boot.install", "windows.boot.next"):
            action = self.find(aid)
            if action:
                system_layout.addWidget(self._action_row(action))
        layout.addWidget(system_box)
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
