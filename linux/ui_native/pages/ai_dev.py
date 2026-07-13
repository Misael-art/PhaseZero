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
        self.router_service: QLabel | None = None
        self.router_providers: QLabel | None = None
        self.router_combos: QLabel | None = None
        self.status_loader.status_ready.connect(self._router_status_ready)
        self.status_loader.status_failed.connect(self._router_status_failed)

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

        desktop_box = QGroupBox("Aplicativos IA desktop")
        desktop_layout = QVBoxLayout(desktop_box)
        for aid in ("ai.desktop.status", "ai.desktop.claude", "ai.desktop.qwen", "ai.desktop.codex"):
            action = self.find(aid)
            if action:
                desktop_layout.addWidget(self._action_row(action))
        layout.addWidget(desktop_box)

        codexbar_box = QGroupBox("CodexBar — uso e cotas")
        codexbar_layout = QVBoxLayout(codexbar_box)
        for aid in (
            "ai.codexbar-status", "ai.codexbar-health", "ai.codexbar-setup",
            "ai.codexbar-auth", "ai.codexbar-repair",
        ):
            action = self.find(aid)
            if action:
                codexbar_layout.addWidget(self._action_row(action))
        layout.addWidget(codexbar_box)

        router_box = QGroupBox("9Router — roteamento inteligente")
        router_layout = QVBoxLayout(router_box)
        summary = QFrame()
        summary.setObjectName("moduleFacts")
        facts = QHBoxLayout(summary)
        facts.setContentsMargins(14, 10, 14, 10)
        self.router_service = self._router_fact("Serviço", "Verificando…", facts)
        self.router_providers = self._router_fact("Providers ativos", "—", facts)
        self.router_combos = self._router_fact("Combos", "—", facts)
        router_layout.addWidget(summary)
        for aid in (
            "ai.9router-status", "ai.9router-install", "ai.9router-dashboard",
            "ai.9router-test", "ai.9router-secrets", "ai.9router-combos",
            "ai.9router-usage", "ai.9router-client", "ai.9router-check", "ai.9router-update",
            "ai.9router-doctor",
        ):
            action = self.find(aid)
            if action:
                router_layout.addWidget(self._action_row(action))
        layout.addWidget(router_box)

        odysseus_box = QGroupBox("Odysseus — workspace IA agnóstico")
        odysseus_layout = QVBoxLayout(odysseus_box)
        for aid in (
            "ai.odysseus-status", "ai.odysseus-install", "ai.odysseus-open", "ai.odysseus-check",
            "ai.odysseus-update", "ai.odysseus-backup",
        ):
            action = self.find(aid)
            if action:
                odysseus_layout.addWidget(self._action_row(action))
        layout.addWidget(odysseus_box)

        updates_box = QGroupBox("Atualizações PhaseZero")
        updates_layout = QVBoxLayout(updates_box)
        for aid in ("ai.updates-status", "ai.updates-timer"):
            action = self.find(aid)
            if action:
                updates_layout.addWidget(self._action_row(action))
        layout.addWidget(updates_box)

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
        self.reload()

    @staticmethod
    def _router_fact(label: str, value: str, layout: QHBoxLayout) -> QLabel:
        box = QVBoxLayout()
        value_label = QLabel(value)
        value_label.setObjectName("moduleFactValue")
        caption = QLabel(label)
        caption.setObjectName("moduleFactLabel")
        box.addWidget(value_label)
        box.addWidget(caption)
        layout.addLayout(box, 1)
        return value_label

    def reload(self) -> None:
        super().reload()
        action = self.by_id.get("ai.9router-status")
        if action and not self.status_loader.running(action.id):
            self.status_loader.fetch_action(action)

    def _router_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id != "ai.9router-status" or not isinstance(parsed, dict):
            return
        installed = bool(parsed.get("installed"))
        healthy = bool(parsed.get("healthy"))
        if self.router_service:
            self.router_service.setText("Online" if healthy else "Parado" if installed else "Não instalado")
        providers = parsed.get("providers") if isinstance(parsed.get("providers"), dict) else {}
        combos = parsed.get("combos") if isinstance(parsed.get("combos"), dict) else {}
        if self.router_providers:
            self.router_providers.setText(str(providers.get("active", 0)))
        if self.router_combos:
            self.router_combos.setText(str(combos.get("total", 0)))

    def _router_status_failed(self, action_id: str, _message: str) -> None:
        if action_id == "ai.9router-status" and self.router_service:
            self.router_service.setText("Indisponível")

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
