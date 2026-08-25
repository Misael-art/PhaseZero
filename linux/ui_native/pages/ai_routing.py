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
    "balanced": "Equilibrado",
    "quality": "Mais qualidade",
    "save-quota": "Poupar cota",
    "privacy": "Privacidade",
}

QUOTA_LABELS = {
    "known": "conhecida",
    "unknown": "desconhecida",
    "unavailable": "indisponível",
}

POLICY_REASONS = {
    "balanced": "Equilibra qualidade, cota disponível e confiabilidade.",
    "quality": "Prioriza modelos com maior qualidade para a tarefa.",
    "save-quota": "Poupa contas limitadas e mantém fallbacks disponíveis.",
    "privacy": "Prefere rotas locais e reduz exposição a provedores externos.",
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
        self._recommendations: dict[str, list[dict]] = {}
        self._policy_combo: QComboBox | None = None
        self._apply_all_button: QPushButton | None = None
        self._chain_editor: QListWidget | None = None
        self._chain_task = "code"
        self._technical_widgets: list[QWidget] = []
        self.status_loader.status_ready.connect(self._routing_status_ready)
        self.status_loader.status_failed.connect(self._routing_status_failed)

    # ---------------------------------------------------------------- build
    def build(self) -> None:
        for aid in (
            "ai.routing-inventory", "ai.routing-verify", "ai.routing-plan",
            "ai.routing-apply-all", "ai.routing-status", "ai.routing-rollback",
            "ai.claude-bonsai-run", "ai.claude-bonsai-preflight",
            "ai.routing-recommend-code", "ai.routing-recommend-analysis",
            "ai.routing-recommend-plan", "ai.routing-refresh",
        ):
            action = self.by_id.get(aid) if self.by_id else None
            if action is not None:
                self.mark_represented(action)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader(
            "Roteamento IA", "Escolha a tarefa. O PhaseZero sugere o modelo e aplica a rota."))

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
        actions_row.addWidget(QLabel("Política das 3 rotas:"))
        self._policy_combo = QComboBox()
        for policy_id in POLICIES:
            self._policy_combo.addItem(POLICY_LABELS[policy_id], policy_id)
        self._policy_combo.currentIndexChanged.connect(self._global_policy_changed)
        actions_row.addWidget(self._policy_combo)
        refresh = self._action_button("ai.routing-inventory", "Atualizar cotas")
        if refresh is not None:
            actions_row.addWidget(refresh)
        self._apply_all_button = QPushButton("Aplicar as 3 rotas")
        self._apply_all_button.setObjectName("primaryButton")
        self._apply_all_button.setEnabled(False)
        self._apply_all_button.clicked.connect(self._apply_all)
        actions_row.addWidget(self._apply_all_button)
        preview_all = QPushButton("Prévia do plano")
        preview_all.setObjectName("secondaryButton")
        preview_all.clicked.connect(lambda: self._task_preview("code"))
        actions_row.addWidget(preview_all)
        self._technical_widgets.append(preview_all)
        for aid, label in (("ai.routing-verify", "Verificar"),):
            button = self._action_button(aid, label)
            if button is not None:
                actions_row.addWidget(button)
                self._technical_widgets.append(button)
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
        self._technical_widgets.append(editor_box)
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
        self._technical_widgets.append(bonsai_box)
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
        self._technical_widgets.append(rollback_box)
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
        header.addStretch()
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
        self._technical_widgets.append(quota)

        self._task_cards[task] = {
            "recommended": recommended, "chain": chain,
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
        for task, _label, _aid in TASKS:
            self._fetch_recommendation(task)

    def _fetch_recommendation(self, task: str) -> None:
        card = self._task_cards.get(task)
        if card is None:
            return
        policy = self._policy_combo.currentData() if self._policy_combo is not None else "balanced"
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

    def _global_policy_changed(self) -> None:
        self._recommendations.clear()
        if self._apply_all_button is not None:
            self._apply_all_button.setEnabled(False)
        for task, _label, _aid in TASKS:
            card = self._task_cards.get(task)
            if card is None:
                continue
            card["recommended"].setText("Verificando…")
            card["chain"].setText(_CLEAR)
            card["reason"].clear()
            card["quota"].clear()
        self._fetch_recommendations()

    def _chain_task_changed(self) -> None:
        self._chain_task = self._chain_task_combo.currentData()
        self._populate_chain_editor(self._chain_task)

    def _populate_chain_editor(self, task: str) -> None:
        self._chain_editor.clear()
        for entry in self._recommendations.get(task, []):
            self._chain_editor.addItem(str(entry.get("model_id")))

    def _render_reason(self, task: str) -> None:
        card = self._task_cards.get(task)
        reco = self._recommendations.get(task) or []
        if card is None or not reco:
            return
        top = reco[0]
        if self._advanced_mode:
            text = " · ".join(str(item) for item in (top.get("justifications") or [])[:2])
        else:
            policy = self._policy_combo.currentData() if self._policy_combo is not None else "balanced"
            text = POLICY_REASONS.get(str(policy), POLICY_REASONS["balanced"])
        card["reason"].setText(text)

    def _chain_apply(self) -> None:
        models = [self._chain_editor.item(i).text() for i in range(self._chain_editor.count())]
        if not models:
            self._status_value.setText("Sem modelos na cadeia — adicione ao menos um antes de aplicar")
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
        card = self._task_cards.get(task)
        if card is None:
            return
        policy = str(self._policy_combo.currentData()) if self._policy_combo is not None else "balanced"
        dynamic = ActionSpec(
            id=f"routing.preview.{task}.{policy}",
            category="Roteamento IA",
            title=f"Prévia {task}",
            description="",
            args=("ai", "routing", "apply", "--task", task,
                  "--policy", policy, "--dry-run"),
            icon="document-preview",
        )
        self.request_action(dynamic)

    def _task_apply(self, task: str) -> None:
        card = self._task_cards.get(task)
        if card is None:
            return
        policy = str(self._policy_combo.currentData()) if self._policy_combo is not None else "balanced"
        action = ActionSpec(
            id=f"routing.apply.{task}.{policy}",
            category="Roteamento IA",
            title=f"Aplicar rota {task}",
            description="",
            args=("ai", "routing", "apply", "--task", task,
                  "--policy", policy, "--yes"),
            preview_args=("ai", "routing", "apply", "--task", task,
                          "--policy", policy, "--dry-run"),
            icon="system-run",
            mutable=True,
        )
        self.request_action(action)

    def _apply_all(self) -> None:
        # Backend reconciles all three managed combos in one transaction.
        self._task_apply("code")

    def _rollback_clicked(self) -> None:
        manifest = self._manifest_input.text().strip()
        if not manifest:
            self._status_value.setText(
                "Informe o manifesto em operations/<id> para reverter"
            )
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
                card["reason"].setText("Nenhuma rota pode ser aplicada com esta política.")
                self._recommendations.pop(task, None)
                if self._apply_all_button is not None:
                    self._apply_all_button.setEnabled(False)
                return
            self._recommendations[task] = list(reco)
            top = reco[0]
            card["recommended"].setText(
                f"{top.get('model_id', _CLEAR)}  ·  {top.get('score', 0):.3f}")
            chain_text = " → ".join(str(c.get("model_id")) for c in reco)
            card["chain"].setText(chain_text)
            self._render_reason(task)
            quota = top.get("quota_state", "?")
            pct = top.get("quota", 0)
            conf = top.get("quota_confidence", 0)
            card["quota"].setText(
                f"cota: {QUOTA_LABELS.get(str(quota), quota)} ({pct:.0%}) · confiança: {conf:.0%}")
            if self._apply_all_button is not None:
                self._apply_all_button.setEnabled(
                    all(task_id in self._recommendations for task_id, _label, _aid in TASKS)
                )
            if task == self._chain_task:
                self._populate_chain_editor(task)

    def _routing_status_failed(self, action_id: str, _message: str) -> None:
        if action_id == "ai.routing-status" and self._status_value:
            self._status_value.setText("Indisponível — tente atualizar")
        for task, _label, aid in TASKS:
            if action_id == aid or action_id.startswith(f"routing.dynamic.{task}."):
                card = self._task_cards.get(task)
                if card:
                    card["recommended"].setText("Recomendação indisponível")
                    card["chain"].setText("Atualize cotas e confirme a saúde do 9Router.")
                    card["reason"].setText("A operação não ficará presa: tente novamente após corrigir o gateway.")
                    self._recommendations.pop(task, None)
                    if self._apply_all_button is not None:
                        self._apply_all_button.setEnabled(False)

    def _install_context_status(self) -> None:
        return

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
        for widget in self._technical_widgets:
            widget.setVisible(enabled)
        for task, _label, _aid in TASKS:
            self._render_reason(task)

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
        if not running and self.isVisible():
            self.reload()
