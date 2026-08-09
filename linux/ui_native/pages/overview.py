from __future__ import annotations

from pathlib import Path

from PySide6.QtWidgets import (
    QFrame, QHBoxLayout, QLabel, QPushButton, QScrollArea,
    QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import ActionListRow, StatusPill, SectionHeader, SkeletonPill, SkeletonTile, stop_shimmer, themed_icon
from .base import BasePage

STATUS_ACTION_IDS = ("system.doctor",)
PILL_ACTION_IDS = ("system.doctor", "system.repair-plan", "system.support-bundle", "system.version")
INSTALL_ACTION_IDS = (
    "system.installation.status", "system.self-update.check", "system.self-update.apply",
    "system.installation.converge", "system.installation.prune",
)


class OverviewPage(BasePage):
    """Health checks, audit, and support — status pills with async loading."""

    def build(self) -> None:
        for action_id in PILL_ACTION_IDS:
            action = self.by_id.get(action_id)
            if action is not None:
                self.mark_represented(action)
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
        self._layout_main.addWidget(SectionHeader(
            "Instalação PhaseZero",
            "Versão ativa, atualização verificada, convergência de canais e retenção.",
        ))
        install_surface = QFrame()
        install_surface.setObjectName("actionListSurface")
        install_layout = QVBoxLayout(install_surface)
        install_layout.setContentsMargins(0, 0, 0, 0)
        install_layout.setSpacing(0)
        for action_id in INSTALL_ACTION_IDS:
            action = self.by_id.get(action_id)
            if action is None:
                continue
            self.mark_represented(action)
            row = ActionListRow(action)
            row.selected.connect(self.action_selected.emit)
            install_layout.addWidget(row)
        self._layout_main.addWidget(install_surface)
        self._layout_main.addStretch()

        scroll.setWidget(self._inner)
        self._layout.addWidget(scroll)

        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

    def reload(self) -> None:
        """Fetch health asynchronously; placeholders appear only after 200 ms."""
        self._clear_pills()
        self.begin_loading(self._show_status_skeletons)
        action = self.find("system.doctor")
        if action is not None:
            self.status_loader.fetch_action(action)
        else:
            self._on_status_failed("system.doctor", "ação indisponível")

    def _show_status_skeletons(self) -> None:
        for _ in range(4):
            self._pills_container.addWidget(SkeletonPill())

    def _clear_pills(self) -> None:
        while self._pills_container.count():
            item = self._pills_container.takeAt(0)
            if item.widget():
                for tile in item.widget().findChildren(SkeletonTile):
                    stop_shimmer(tile)
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
        self._loading_timer.stop()
        self._loading_callback = None
        self._clear_pills()
        rows = parsed if isinstance(parsed, list) else []
        counts = {"PASS": 0, "WARN": 0, "FAIL": 0, "ERROR": 0, "INFO": 0}
        for row in rows:
            text = str(row)
            for key in counts:
                if text.startswith(f"[{key}]"):
                    counts[key] += 1
                    break
        total = sum(counts.values())
        if total:
            self._pills_container.addWidget(StatusPill("Verificações aprovadas", "success", str(counts["PASS"])))
            self._pills_container.addWidget(StatusPill("Avisos", "warning", str(counts["WARN"] + counts["INFO"])))
            self._pills_container.addWidget(StatusPill("Falhas", "error", str(counts["FAIL"] + counts["ERROR"])))
        else:
            self._pills_container.addWidget(StatusPill("Diagnóstico concluído", "success", "saída disponível"))
        for aid in PILL_ACTION_IDS:
            action = self.by_id.get(aid)
            if action is not None:
                self._pills_container.addWidget(self._make_pill_action(action))

    def _on_status_failed(self, action_id: str, error: str) -> None:
        self._loading_timer.stop()
        self._loading_callback = None
        self._clear_pills()
        self._pills_container.addWidget(StatusPill("Diagnóstico indisponível", "error", error))
        for aid in PILL_ACTION_IDS:
            action = self.by_id.get(aid)
            if action is not None:
                self._pills_container.addWidget(self._make_pill_action(action))

    def _make_pill_action(self, action: ActionSpec) -> QFrame:
        self.mark_represented(action)
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
        btn = QPushButton("Pré-visualizar" if action.mutable else "Executar")
        btn.setObjectName("primaryButton" if action.mutable else "secondaryButton")
        btn.setAccessibleDescription(("Auditar e confirmar antes de aplicar: " if action.mutable else "Executar: ") + action.title)
        btn.clicked.connect(lambda: self.request_action(action))
        row.addWidget(btn)
        return card

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
