from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox, QFrame, QGroupBox, QHBoxLayout, QLabel,
    QPushButton, QScrollArea, QStyle, QTableWidget,
    QTableWidgetItem, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage


class AiDevPage(BasePage):
    """AI & Dev tools: proxy table, setup checklist, MCP status, etc."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.tool_checkboxes: dict[str, QCheckBox] = {}

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        # Status & repair (compact action rows)
        layout.addWidget(SectionHeader("Status e reparo", "Agentes, MCP e integrações"))
        for aid in ("ai.status", "ai.doctor", "ai.repair", "ai.compat", "ai.admin", "ai.desktop"):
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))

        # Proxies table
        proxy_box = QGroupBox("Proxies IA (OpenAI-compatible)")
        proxy_layout = QVBoxLayout(proxy_box)
        proxy_ids = [
            "ai.proxies", "ai.proxies-ides", "ai.proxies-auth",
            "ai.proxies-login-kimi", "ai.proxies-login-qwen", "ai.proxies-login-deeps",
            "ai.proxies-test",
        ]
        for aid in proxy_ids:
            action = self.find(aid)
            if action:
                proxy_layout.addWidget(self._action_row(action))
        layout.addWidget(proxy_box)

        # Tool setup checklist
        setup_box = QGroupBox("Ferramentas (setup)")
        setup_layout = QVBoxLayout(setup_box)
        tool_ids = [
            "ai.opencode", "ai.opencode-free", "ai.ollama", "ai.webui",
            "ai.memory", "ai.omo", "ai.ides", "ai.usagebar", "ai.mcp-sync",
        ]
        for aid in tool_ids:
            action = self.find(aid)
            if action:
                cb = QCheckBox(f"  {action.title}")
                cb.setToolTip(action.description)
                cb.setObjectName("toolCheck")
                self.tool_checkboxes[action.id] = cb
                btn = QPushButton("Instalar")
                btn.setObjectName("secondaryButton")
                btn.clicked.connect(lambda _checked=False, a=action: self.request_action(a))
                row = QHBoxLayout()
                row.addWidget(cb)
                row.addWidget(btn)
                row.addStretch()
                setup_layout.addLayout(row)
        selected = QPushButton("Pré-visualizar selecionados")
        selected.setObjectName("primaryButton")
        selected.clicked.connect(self._request_selected_tools)
        setup_layout.addWidget(selected)
        layout.addWidget(setup_box)
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

    def _request_selected_tools(self) -> None:
        selected = [
            action for action in self.actions
            if self.tool_checkboxes.get(action.id) is not None
            and self.tool_checkboxes[action.id].isChecked()
        ]
        self.request_actions(selected)
