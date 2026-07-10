from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QButtonGroup, QFrame, QGroupBox, QHBoxLayout, QLabel,
    QPushButton, QRadioButton, QScrollArea, QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import StatusPill, SectionHeader, themed_icon
from .base import BasePage


class SteamDeckPage(BasePage):
    """Dedicated Steam Deck controls: mode radios, status, keyboard, plugins."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        # --- Mode selection (RadioButton group) ---
        mode_box = QGroupBox("Modo de sessão")
        mode_layout = QVBoxLayout(mode_box)
        mode_group = QButtonGroup(self)
        modes = [
            ("steamdeck.handheld", "Portátil", "Aplica perfil portátil."),
            ("steamdeck.docked-tv", "Dock TV", "Aplica perfil TV e controles."),
            ("steamdeck.docked-monitor", "Dock monitor", "Aplica perfil desktop externo."),
        ]
        for idx, (aid, title, desc) in enumerate(modes):
            rb = QRadioButton(f"  {title}")
            rb.setToolTip(desc)
            mode_group.addButton(rb, idx)
            mode_layout.addWidget(rb)
            if idx == 0:
                rb.setChecked(True)
        apply_mode = QPushButton("Aplicar modo")
        apply_mode.setObjectName("primaryButton")
        apply_mode.clicked.connect(lambda: self._apply_radio_mode(modes, mode_group))
        mode_layout.addWidget(apply_mode)
        layout.addWidget(mode_box)

        # --- Status ---
        status_box = QGroupBox("Informações")
        status_layout = QVBoxLayout(status_box)
        for aid in (
            "steamdeck.status", "steamdeck.detect", "steamdeck.runtime",
            "steamdeck.launch-options",
        ):
            action = self.find(aid)
            if action is None:
                continue
            status_layout.addWidget(self._action_row(action))
        layout.addWidget(status_box)

        # --- Services & tools (action buttons) ---
        tools_box = QGroupBox("Ferramentas")
        tools_layout = QVBoxLayout(tools_box)
        tool_ids = [
            "steamdeck.keyboard.toggle", "steamdeck.keyboard.repair",
            "steamdeck.hotkeys", "steamdeck.watcher",
            "steamdeck.console", "steamdeck.desktop",
            "steamdeck.plugins", "steamdeck.plugins.repair",
            "steamdeck.boot", "steamdeck.privileged",
            "steamdeck.removable", "steamdeck.display",
        ]
        for aid in tool_ids:
            action = self.find(aid)
            if action is None:
                continue
            tools_layout.addWidget(self._action_row(action))
        layout.addWidget(tools_box)
        layout.addStretch()

        scroll.setWidget(inner)
        self._layout.addWidget(scroll)

    def _apply_radio_mode(
        self, modes: list[tuple[str, str, str]], group: QButtonGroup,
    ) -> None:
        idx = group.checkedId()
        if idx < 0:
            return
        aid = modes[idx][0]
        action = self.find(aid)
        if action is not None:
            self.request_action(action)

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
        btn.setObjectName("secondaryButton")
        btn.clicked.connect(lambda: self.request_action(action))
        row.addWidget(btn)
        return card

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
