from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QButtonGroup, QFrame, QGroupBox, QHBoxLayout, QLabel,
    QPushButton, QRadioButton, QScrollArea, QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage


class BootPage(BasePage):
    """Boot control: radio group for next-session + action buttons."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        # Next-boot selection (RadioButton group, like the old BootSelector)
        boot_box = QGroupBox("Próxima sessão")
        boot_layout = QVBoxLayout(boot_box)
        boot_group = QButtonGroup(self)
        boot_choices = [
            ("boot.normal", "Linux normal", "Limpa one-shot e usa o padrão da distro."),
            ("boot.steamos", "SteamOS", "Próximo boot abre Steam/Gamepad UI."),
            ("boot.windows", "Windows VM", "Próximo boot abre Windows VM fullscreen."),
            ("boot.waydroid", "Waydroid", "Próximo boot abre Android kiosk."),
            ("boot.emergency", "Emergência", "Próximo boot entra em rescue.target."),
        ]
        for idx, (aid, title, desc) in enumerate(boot_choices):
            rb = QRadioButton(f"  {title}")
            rb.setToolTip(desc)
            boot_group.addButton(rb, idx)
            boot_layout.addWidget(rb)
            if idx == 0:
                rb.setChecked(True)
        btn_row = QHBoxLayout()
        apply_btn = QPushButton("Agendar")
        apply_btn.setObjectName("primaryButton")
        apply_btn.clicked.connect(lambda: self._apply_boot_choice(boot_choices, boot_group))
        btn_row.addWidget(apply_btn)
        btn_row.addStretch()
        boot_layout.addLayout(btn_row)
        layout.addWidget(boot_box)

        # Status & tools
        layout.addWidget(SectionHeader("Ferramentas", "GRUB, EFI e recuperação"))
        tool_ids = [
            "boot.status", "boot.selector", "boot.menu",
            "boot.safe-menu", "boot.card", "boot.install-card",
            "boot.efi",
        ]
        for aid in tool_ids:
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))
        layout.addStretch()

        scroll.setWidget(inner)
        self._layout.addWidget(scroll)

    def _apply_boot_choice(
        self, choices: list[tuple[str, str, str]], group: QButtonGroup,
    ) -> None:
        idx = group.checkedId()
        if idx < 0:
            return
        aid = choices[idx][0]
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
        btn.setObjectName("primaryButton" if action.mutable else "secondaryButton")
        btn.clicked.connect(lambda: self.request_action(action))
        row.addWidget(btn)
        return card

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
