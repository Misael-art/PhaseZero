from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox, QFrame, QGridLayout, QGroupBox, QHBoxLayout, QLabel,
    QLineEdit, QListWidget, QPushButton, QScrollArea, QStyle,
    QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage

# Task cards: (task id, label, catalog action id for status fetch)
TASKS = (
    ("code", "Código", "ai.routing-recommend-code"),
    ("analysis", "Análise", "ai.routing-recommend-analysis"),
    ("plan", "Plano", "ai.routing-recommend-plan"),
)
POLICIES = ("balanced", "quality", "save-quota", "privacy")
POLICY_LABELS = {
    "balanced": "Balanced",
    "quality": "Quality",
    "save-quota": "Save quota",
    "privacy": "Privacy",
}

_CLEAR = "—"


def _first(parsed: object, *keys: str, default=None):
    node = parsed
    for key in keys:
        if not isinstance(node, dict):
            return default
        node = node.get(key, {})
    return node if node is not None else default


class AiRoutingPage(BasePage):
    """Dedicated per-task routing page: recommendations, policies, quota,
    fallback chain editor, apply/rollback and an isolated Bonsai card."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._status_value: QLabel | None = None
        self._quota_label: QLabel | None = None
        self._task_cards: dict[str, dict] = {}
        self._chain_editor: QListWidget | None = None
        self._chain_task = "code"
        self.status_loader.status_ready.connect(self._routing_status_ready)
        self.status_loader.status_failed.connect(self._routing_status_failed)

    # ---------------------------------------------------------------- build
    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader(
            "Roteamento IA", "Rota por tarefa, política e quota real do 9Router"))

        summary = QFrame()
        summary.setObjectName("moduleFacts")
        facts = QHBoxLayout(summary)
        facts.setContentsMargins(14, 10, 14, 10)
        self._status_value = self._fact("Estado", "Verificando…", facts)
        self._quota_label = self._fact("Cotas", "—", facts)
        facts.addStretch()
        layout.addWidget(summary)

        actions_row = QHBoxLayout()
        actions_row.setSpacing(8)
        for aid, label in (
            ("ai.routing-inventory", "Atualizar cotas"),
            ("ai.routing-verify", "Verificar"),
            ("ai.routing-plan", "Plano (diff)"),
            ("ai.routing-apply-all", "Aplicar plano"),
        ):
            button = self._action_button(aid, label)
            if button is not None:
                actions_row.addWidget(button)
        actions_row.addStretch()
        layout.addLayout(actions_row)

        grid_host = QWidget()
        grid = QGridLayout(grid_host)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index, (task, label, _aid) in enumerate(TASKS):
            grid.addWidget(self._task_card(task, label), index // 2, index % 2)
        layout.addWidget(grid_host)

        editor_box = QGroupBox("Ordem avançada de fallbacks")
        editor_layout = QVBoxLayout(editor_box)
        editor_row = QHBoxLayout()
        self._chain_task_combo = QComboBox()
        for task, label, _aid in TASKS:
            self._chain_task_combo.addItem(label, task)
        self._chain_task_combo.currentIndexChanged.connect(self._chain_task_changed)
        editor_row.addWidget(QLabel("Tarefa:"))
        editor_row.addWidget(self._chain_task_combo)
        editor_row.addStretch()
        editor_layout.addLayout(editor_row)
        list_row = QHBoxLayout()
        self._chain_editor = QListWidget()
        self._chain_editor.setMaximumHeight(160)
        list_row.addWidget(self._chain_editor, 1)
        order_col = QVBoxLayout()
        for label, slot in (
            ("Subir", self._chain_up),
            ("Descer", self._chain_down),
            ("Aplicar ordem", self._chain_apply),
        ):
            button = QPushButton(label)
            button.setObjectName("secondaryButton")
            button.clicked.connect(slot)
            order_col.addWidget(button)
        order_col.addStretch()
        list_row.addLayout(order_col)
        editor_layout.addLayout(list_row)
        layout.addWidget(editor_box)

        bonsai_box = QGroupBox("Bonsai — rota experimental separada")
        bonsai_layout = QVBoxLayout(bonsai_box)
        warn = QLabel(
            "Rota explícita e isolada do 9Router: sem token Bonsai no roteador, "
            "sem fallback silencioso. Snapshot/upload exigem consentimento "
            "interativo; use preflight antes de iniciar.")
        warn.setWordWrap(True)
        warn.setObjectName("cardDescription")
        bonsai_layout.addWidget(warn)
        bonsai_actions = QHBoxLayout()
        bonsai_action = self.by_id.get("ai.claude-bonsai-run") if self.by_id else None
        if bonsai_action is not None:
            button = QPushButton("Executar Claude via Bonsai (consentimento)")
            button.setObjectName("primaryButton")
            button.clicked.connect(lambda: self.request_action(bonsai_action))
            bonsai_actions.addWidget(button)
        preflight = self.by_id.get("ai.claude-bonsai-preflight") if self.by_id else None
        if preflight is not None:
            button = QPushButton("Preflight")
            button.setObjectName("secondaryButton")
            button.clicked.connect(lambda: self.request_action(preflight))
            bonsai_actions.addWidget(button)
        bonsai_actions.addStretch()
        bonsai_layout.addLayout(bonsai_actions)
        layout.addWidget(bonsai_box)

        rollback_box = QGroupBox("Rollback transacional")
        rollback_layout = QHBoxLayout(rollback_box)
        self._manifest_input = QLineEdit()
        self._manifest_input.setPlaceholderText("Caminho do manifest.json (operations/<id>)")
        rollback_layout.addWidget(self._manifest_input, 1)
        rollback_action = self.by_id.get("ai.routing-rollback") if self.by_id else None
        if rollback_action is not None:
            button = QPushButton("Reverter")
            button.setObjectName("dangerButton")
            button.clicked.connect(self._rollback_clicked)
            rollback_layout.addWidget(button)
        layout.addWidget(rollback_box)

        layout.addStretch()
        scroll.setWidget(inner)
        self._layout.addWidget(scroll)
        self.reload()

    def _fact(self, label: str, value: str, layout: QHBoxLayout) -> QLabel:
        box = QVBoxLayout()
        value_label = QLabel(value)
        value_label.setObjectName("moduleFactValue")
        caption = QLabel(label)
        caption.setObjectName("moduleFactLabel")
        box.addWidget(value_label)
        box.addWidget(caption)
        layout.addLayout(box, 1)
        return value_label

    def _task_card(self, task: str, label: str) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        column = QVBoxLayout(card)
        column.setContentsMargins(14, 12, 14, 12)
        header = QHBoxLayout()
        title = QLabel(label)
        title.setObjectName("cardTitle")
        header.addWidget(title)
        policy = QComboBox()
        for pid in POLICIES:
            policy.addItem(POLICY_LABELS[pid], pid)
        policy.currentIndexChanged.connect(lambda _i, t=task: self._policy_changed(t))
        header.addWidget(policy, 1)
        column.addLayout(header)

        recommended = QLabel("Verificando…")
        recommended.setObjectName("moduleFactValue")
        recommended.setWordWrap(True)
        column.addWidget(recommended)
        chain = QLabel(_CLEAR)
        chain.setObjectName("cardDescription")
        chain.setWordWrap(True)
        column.addWidget(chain)
        reason = QLabel("")
        reason.setObjectName("cardDescription")
        reason.setWordWrap(True)
        column.addWidget(reason)
        quota = QLabel("")
        quota.setObjectName("cardDescription")
        column.addWidget(quota)

        apply_row = QHBoxLayout()
        preview = QPushButton("Prévia")
        preview.setObjectName("secondaryButton")
        preview.clicked.connect(lambda: self._task_preview(task))
        apply = QPushButton("Aplicar")
        apply.setObjectName("primaryButton")
        apply.clicked.connect(lambda: self._task_apply(task))
        apply_row.addWidget(preview)
        apply_row.addWidget(apply)
        apply_row.addStretch()
        column.addLayout(apply_row)

        self._task_cards[task] = {
            "policy": policy, "recommended": recommended, "chain": chain,
            "reason": reason, "quota": quota,
        }
        return card

    # ------------------------------------------------------------- fetching
    def reload(self) -> None:
        super().reload()
        for aid in ("ai.routing-status", "ai.routing-inventory"):
            action = self.by_id.get(aid) if self.by_id else None
            if action and not self.status_loader.running(action.id):
                self.status_loader.fetch_action(action)
        self._fetch_recommendations()

    def _fetch_recommendations(self) -> None:
        for task, _label, aid in TASKS:
            action = self.by_id.get(aid) if self.by_id else None
            if not action:
                continue
            card = self._task_cards.get(task)
            if card is None:
                continue
            policy = card["policy"].currentData()
            dynamic = ActionSpec(
                id=f"routing.dynamic.{task}.{policy}",
                category="Roteamento IA",
                title=f"Recomendação {task} {policy}",
                description="",
                args=("ai", "routing", "recommend", "--task", task,
                      "--policy", policy, "--json"),
                icon="system-search",
            )
            if not self.status_loader.running(dynamic.id):
                self.status_loader.fetch_action(dynamic)

    def _policy_changed(self, task: str) -> None:
        card = self._task_cards.get(task)
        if card:
            card["recommended"].setText("Verificando…")
            card["chain"].setText(_CLEAR)
        self._fetch_recommendations()

    def _chain_task_changed(self) -> None:
        self._chain_task = self._chain_task_combo.currentData()
        self._chain_editor.clear()

    def _chain_apply(self) -> None:
        models = [self._chain_editor.item(i).text() for i in range(self._chain_editor.count())]
        if not models:
            return
        action = ActionSpec(
            id=f"routing.chain-apply.{self._chain_task}",
            category="Roteamento IA",
            title="Aplicar ordem de fallbacks",
            description="",
            args=("ai", "routing", "apply", "--task", self._chain_task,
                  "--yes", "--chain", ",".join(models)),
            icon="system-run",
            mutable=True,
        )
        self.request_action(action)

    def _chain_up(self) -> None:
        self._move_chain(-1)

    def _chain_down(self) -> None:
        self._move_chain(1)

    def _move_chain(self, delta: int) -> None:
        if self._chain_editor is None:
            return
        row = self._chain_editor.currentRow()
        target = row + delta
        if row < 0 or target < 0 or target >= self._chain_editor.count():
            return
        item = self._chain_editor.takeItem(row)
        self._chain_editor.insertItem(target, item)
        self._chain_editor.setCurrentRow(target)

    def _task_preview(self, task: str) -> None:
        action = self.by_id.get("ai.routing-apply-all") if self.by_id else None
        if action:
            return
        dynamic = ActionSpec(
            id=f"routing.preview.{task}",
            category="Roteamento IA",
            title=f"Prévia {task}",
            description="",
            args=("ai", "routing", "apply", "--task", task, "--dry-run"),
            icon="document-preview",
        )
        self.request_action(dynamic)

    def _task_apply(self, task: str) -> None:
        action = ActionSpec(
            id=f"routing.apply.{task}",
            category="Roteamento IA",
            title=f"Aplicar rota {task}",
            description="",
            args=("ai", "routing", "apply", "--task", task, "--yes"),
            icon="system-run",
            mutable=True,
        )
        self.request_action(action)

    def _rollback_clicked(self) -> None:
        manifest = self._manifest_input.text().strip()
        if not manifest:
            return
        action = self.by_id.get("ai.routing-rollback") if self.by_id else None
        if action is None:
            return
        self.request_action(action, value=manifest)

    def _action_button(self, action_id: str, label: str) -> QPushButton | None:
        action = self.by_id.get(action_id) if self.by_id else None
        if action is None:
            return None
        button = QPushButton(label)
        button.setObjectName("primaryButton" if action.mutable else "secondaryButton")
        button.setToolTip(action.description)
        button.clicked.connect(lambda _checked=False, a=action: self.request_action(a))
        return button

    # ------------------------------------------------------------- signals
    def _routing_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if not isinstance(parsed, dict):
            return
        if action_id == "ai.routing-status":
            if self._status_value:
                health = "Online" if parsed.get("health") else "Indisponível"
                self._status_value.setText(health)
        elif action_id == "ai.routing-inventory":
            if self._quota_label:
                states = {}
                for conn in _first(parsed, "connections", default=[]) or []:
                    qs = conn.get("quotaState", "?")
                    states[qs] = states.get(qs, 0) + 1
                text = ", ".join(f"{k}: {v}" for k, v in sorted(states.items())) or _CLEAR
                self._quota_label.setText(text)
            return
        for task, label, aid in TASKS:
            if action_id != aid and not action_id.startswith(f"routing.dynamic.{task}."):
                continue
            card = self._task_cards.get(task)
            if card is None:
                continue
            reco = _first(parsed, "recommendation", default=[]) or []
            if not reco:
                card["recommended"].setText("Nenhum modelo elegível")
                card["chain"].setText("Verifique cotas e saúde do 9Router")
                return
            top = reco[0]
            card["recommended"].setText(
                f"{top.get('model_id', _CLEAR)}  ·  {top.get('score', 0):.3f}")
            chain_text = " → ".join(str(c.get("model_id")) for c in reco)
            card["chain"].setText(chain_text)
            just = " · ".join(str(j) for j in (top.get("justifications") or [])[:2])
            card["reason"].setText(just)
            quota = top.get("quota_state", "?")
            pct = top.get("quota", 0)
            conf = top.get("quota_confidence", 0)
            card["quota"].setText(
                f"quota: {quota} ({pct:.0%}) · confiança: {conf:.0%}")
            if action_id == aid:
                self._chain_editor.clear()
                for entry in reco:
                    self._chain_editor.addItem(str(entry.get("model_id")))

    def _routing_status_failed(self, action_id: str, _message: str) -> None:
        if action_id == "ai.routing-status" and self._status_value:
            self._status_value.setText("Indisponível")
        for task, _label, aid in TASKS:
            if action_id == aid:
                card = self._task_cards.get(task)
                if card:
                    card["recommended"].setText("Erro redigido")

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
