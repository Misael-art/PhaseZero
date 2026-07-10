from __future__ import annotations

from pathlib import Path

from PySide6.QtWidgets import (
    QFrame, QHBoxLayout, QLabel, QPushButton, QScrollArea,
    QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import StatusPill, SectionHeader, SkeletonPill, themed_icon
from .base import BasePage

STATUS_ACTION_IDS = ("system.doctor",)
PILL_ACTION_IDS = ("system.doctor", "system.repair-plan", "system.support-bundle", "system.version")


class OverviewPage(BasePage):
    """Health checks, audit, and support — status pills with async loading."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        self._inner = QWidget()
        self._layout_main = QVBoxLayout(self._inner)
        self._layout_main.setContentsMargins(2, 2, 8, 8)
        self._layout_main.setSpacing(14)
        self._layout_main.addWidget(SectionHeader("Diagnóstico", "Auditoria completa do sistema"))

        self._pills_container = QVBoxLayout()
        self._pills_container.setSpacing(8)
        self._layout_main.addLayout(self._pills_container)
        self._layout_main.addStretch()

        scroll.setWidget(self._inner)
        self._layout.addWidget(scroll)

        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

    def reload(self) -> None:
        """Show skeleton pills, then fetch real status."""
        self._clear_pills()
        for _ in range(4):
            self._pills_container.addWidget(SkeletonPill())
        for aid in STATUS_ACTION_IDS:
            action = self.find(aid)
            if action is not None:
                self.status_loader.fetch_action(action)

    def _clear_pills(self) -> None:
        while self._pills_container.count():
            item = self._pills_container.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

    def _populate_action_pills(self) -> None:
        """Populate the standard action pills (non-status actions)."""
        self._clear_pills()
        for aid in PILL_ACTION_IDS:
            action = self.by_id.get(aid)
            if action is None:
                continue
            self._pills_container.addWidget(self._make_pill_action(action))

    def _on_status_ready(self, action_id: str, stdout: str, parsed: object) -> None:
        self._populate_action_pills()

    def _on_status_failed(self, action_id: str, error: str) -> None:
        self._populate_action_pills()

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
