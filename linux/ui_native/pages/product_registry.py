from __future__ import annotations

from dataclasses import replace
from pathlib import Path

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QScrollArea,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from ..command_runner import CommandRunner
from ..icons import desktop_dirs, find_desktop_entry
from ..models import ActionSpec, ProductInstance
from ..product_inventory import inventory_manifest, target_for
from ..widgets import ActionListRow, AdvancedActionsPanel, SectionHeader
from .base import BasePage


_RECOVERY_ACTION_BY_APP = {
    # The canonical setup route is idempotent and previews through AI status;
    # the legacy server restore route changes exposure defaults and is unsafe
    # as an implicit recovery action.
    "app.ollama": "ai.ollama",
    "app.opencode": "ai.opencode-install",
    "app.kimiproxy": "ai.proxies-start-kimi",
    "app.qwen-proxy": "ai.proxies-start-qwen",
    "app.deepseek-proxy": "ai.proxies-start-deeps",
    "app.mimo-proxy": "ai.proxies-start-mimo",
}
_PROXY_RECOVERY_AUTHORITY_BY_APP = {
    "app.kimiproxy": "linux/ai/proxy-suite.sh",
    "app.qwen-proxy": "linux/ai/proxy-suite.sh",
    "app.deepseek-proxy": "linux/ai/proxy-suite.sh",
    "app.mimo-proxy": "linux/ai/proxy-suite.sh",
}
_PROXY_RECOVERY_TARGET_BY_APP = {
    "app.kimiproxy": "kimiproxy",
    "app.qwen-proxy": "qwenproxy",
    "app.deepseek-proxy": "deepsproxy",
    "app.mimo-proxy": "mimo-ai-proxy",
}
_PROXY_CONFIGURE_ACTION_BY_APP = {
    "app.kimiproxy": "ai.proxies-login-kimi",
    "app.qwen-proxy": "ai.proxies-login-qwen",
    "app.deepseek-proxy": "ai.proxies-login-deeps",
    "app.mimo-proxy": "ai.proxies-credentials-mimo",
}
_PROXY_CONFIGURE_TARGET_BY_APP = {
    "app.kimiproxy": ("login", "kimiproxy"),
    "app.qwen-proxy": ("login", "qwenproxy"),
    "app.deepseek-proxy": ("login", "deepsproxy"),
    "app.mimo-proxy": ("set-credentials", "mimo-ai-proxy"),
}
_RECOVERY_IMPACT_BY_APP = {
    "app.ollama": (
        "Ativa ou inicia o serviço Ollama gerenciado; se o pacote estiver ausente, "
        "a rotina também pode instalá-lo. Nenhum modelo é baixado."
    ),
    "app.opencode": (
        "Sincroniza OpenCode e mescla a rota local 9Router com rollback; pode instalar "
        "ou atualizar a CLI. Não inicia login nem importa credenciais."
    ),
    "app.kimiproxy": (
        "Habilita e inicia somente o serviço Kimi deste usuário; proxies Node também "
        "podem religar o runtime Node isolado antes de iniciar."
    ),
    "app.qwen-proxy": (
        "Habilita e inicia somente o serviço Qwen deste usuário; proxies Node também "
        "podem religar o runtime Node isolado antes de iniciar."
    ),
    "app.deepseek-proxy": (
        "Habilita e inicia somente o serviço DeepSeek deste usuário; proxies Node também "
        "podem religar o runtime Node isolado antes de iniciar."
    ),
    "app.mimo-proxy": "Habilita e inicia somente o serviço MiMo deste usuário.",
}


class ProductRegistryPage(BasePage):
    """One searchable app list and one reusable detail for every app context."""

    product_opened = Signal(str, str)
    comparison_opened = Signal(str)
    back_requested = Signal()
    desktop_entry_requested = Signal(str)

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.manifest = inventory_manifest(root)
        self.products = [row for row in self.manifest["products"] if isinstance(row, dict)]
        self._product_by_id = {str(row["appId"]): row for row in self.products}
        self._targets = {
            row.action_id: row for row in (target_for(action) for action in self.by_id.values())
        }
        self._cards: dict[str, QFrame] = {}
        self._compare_checks: dict[str, QCheckBox] = {}
        self._compare_selected: set[str] = set()
        self._instances: dict[str, ProductInstance] = {}
        self._selected_app_id = ""
        self._context_action_id = ""
        self._status_action_id = ""
        self._list_page: QWidget | None = None
        self._detail_page: QWidget | None = None
        self._comparison_page: QWidget | None = None
        self._stack: QStackedWidget | None = None
        self._search: QLineEdit | None = None
        self._detail_layout: QVBoxLayout | None = None
        self._detail_actions_start = 0
        self._status_label: QLabel | None = None
        self._instance_selector: QComboBox | None = None
        self._primary_button: QPushButton | None = None
        self._primary_action: ActionSpec | None = None
        self._primary_desktop_entry = ""
        self._product_summary: QLabel | None = None
        self._product_facts: QLabel | None = None
        self._context_label: QLabel | None = None
        self.status_loader.product_instances_ready.connect(self._instances_ready)
        self.status_loader.status_failed.connect(self._status_failed)

    @property
    def selected_app_id(self) -> str:
        return self._selected_app_id

    @property
    def context_action_id(self) -> str:
        return self._context_action_id

    def product_name(self, app_id: str) -> str:
        product = self._product_by_id.get(app_id, {})
        return str(product.get("name") or app_id)

    @property
    def instances(self) -> tuple[ProductInstance, ...]:
        return tuple(self._instances.values())

    def build(self) -> None:
        self._stack = QStackedWidget()
        self._list_page = self._build_list()
        self._detail_page = self._build_detail()
        self._comparison_page = self._build_comparison()
        self._stack.addWidget(self._list_page)
        self._stack.addWidget(self._detail_page)
        self._stack.addWidget(self._comparison_page)
        self._stack.setCurrentWidget(self._list_page)
        self._layout.addWidget(self._stack, 1)
        for action in self.actions:
            target = self._targets.get(action.id)
            if target is not None and target.target_kind == "app":
                self.mark_represented(action)

    def _build_list(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader("Aplicativos", "Busque um produto. Atalhos antigos levam ao mesmo detalhe."))
        self._search = QLineEdit()
        self._search.setObjectName("productSearch")
        self._search.setPlaceholderText("Buscar app pelo nome ou recurso…")
        self._search.setClearButtonEnabled(True)
        self._search.setAccessibleName("Buscar aplicativos")
        self._search.textChanged.connect(self._filter_products)
        layout.addWidget(self._search)
        self._compare_button = QPushButton("Comparar selecionados (0/2)")
        self._compare_button.setObjectName("compareProducts")
        self._compare_button.setEnabled(False)
        self._compare_button.clicked.connect(self._compare_products)
        layout.addWidget(self._compare_button)
        scroll = QScrollArea()
        scroll.setObjectName("productCatalogScroll")
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        self._cards_layout = QVBoxLayout(content)
        self._cards_layout.setContentsMargins(2, 2, 8, 12)
        self._cards_layout.setSpacing(8)
        for product in sorted(self.products, key=lambda row: str(row.get("name", "")).casefold()):
            app_id = str(product["appId"])
            card = QFrame()
            card.setObjectName("productCard")
            card_layout = QVBoxLayout(card)
            card_layout.setContentsMargins(12, 10, 12, 10)
            title_row = QHBoxLayout()
            open_button = QPushButton(str(product.get("name") or app_id))
            open_button.setObjectName("productOpenButton")
            open_button.setAccessibleDescription(f"Abrir detalhe de {product.get('name') or app_id}")
            open_button.clicked.connect(lambda _checked=False, key=app_id: self.open_product(key))
            title_row.addWidget(open_button, 1)
            compare_category = product.get("comparisonCategory")
            if isinstance(compare_category, str) and compare_category:
                compare = QCheckBox("Comparar")
                compare.setObjectName("compareProductToggle")
                compare.setAccessibleName(f"Selecionar {product.get('name') or app_id} para comparação")
                compare.toggled.connect(lambda checked, key=app_id: self._toggle_comparison(key, checked))
                self._compare_checks[app_id] = compare
                title_row.addWidget(compare)
            card_layout.addLayout(title_row)
            info = QLabel(f"{app_id} · Estado não verificado")
            info.setObjectName("productCardSummary")
            info.setWordWrap(True)
            card_layout.addWidget(info)
            self._cards[app_id] = card
            self._cards_layout.addWidget(card)
        non_product_actions = [
            action for action in self.actions
            if self._targets.get(action.id) is None or self._targets[action.id].target_kind != "app"
        ]
        if non_product_actions:
            self._cards_layout.addWidget(SectionHeader(
                "Outras operações do desktop",
                "Atalhos de sistema e jornadas antigas continuam disponíveis.",
            ))
            for action in non_product_actions:
                self.mark_represented(action)
                row = ActionListRow(action)
                row.selected.connect(self.action_selected.emit)
                self._cards_layout.addWidget(row)
        self._cards_layout.addStretch()
        scroll.setWidget(content)
        layout.addWidget(scroll, 1)
        return page

    def _build_detail(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)
        back = QPushButton("‹  Todos os aplicativos")
        back.setObjectName("productDetailBack")
        back.clicked.connect(self.close_detail)
        layout.addWidget(back)
        self._detail_layout = layout
        self._context_label = QLabel("")
        self._context_label.setObjectName("productContext")
        self._context_label.setWordWrap(True)
        layout.addWidget(self._context_label)
        self._product_summary = QLabel("")
        self._product_summary.setObjectName("productDescription")
        self._product_summary.setWordWrap(True)
        layout.addWidget(self._product_summary)
        self._product_facts = QLabel("")
        self._product_facts.setObjectName("productFacts")
        self._product_facts.setWordWrap(True)
        layout.addWidget(self._product_facts)
        self._instance_selector = QComboBox()
        self._instance_selector.setObjectName("productInstanceSelector")
        self._instance_selector.setAccessibleName("Instância do aplicativo")
        self._instance_selector.currentIndexChanged.connect(self._selected_instance_changed)
        self._instance_selector.hide()
        layout.addWidget(self._instance_selector)
        self._status_label = QLabel("Instalação, configuração e saúde: desconhecidas")
        self._status_label.setObjectName("productStatus")
        self._status_label.setWordWrap(True)
        layout.addWidget(self._status_label)
        self._primary_button = QPushButton("Verificar")
        self._primary_button.setObjectName("productPrimaryAction")
        self._primary_button.setToolTip("Confere status antes de escolher uma ação.")
        self._primary_button.clicked.connect(self._primary_clicked)
        layout.addWidget(self._primary_button)
        layout.addWidget(SectionHeader("Ações disponíveis", "Ações atuais convergem neste produto e mantêm a confirmação existente."))
        self._detail_actions_start = layout.count()
        return page

    def _build_comparison(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        back = QPushButton("‹  Voltar aos aplicativos")
        back.setObjectName("comparisonBack")
        back.clicked.connect(self._close_comparison)
        layout.addWidget(back)
        self._comparison_layout = layout
        self._comparison_content_start = layout.count()
        return page

    def _filter_products(self, text: str) -> None:
        query = text.strip().casefold()
        for app_id, product in self._product_by_id.items():
            aliases = product.get("searchTerms", [])
            fields = [str(product.get("name", "")), app_id]
            if isinstance(aliases, list):
                fields.extend(str(alias) for alias in aliases)
            fields.extend(
                self.by_id[action_id].searchable_text
                for action_id in product.get("actionIds", [])
                if action_id in self.by_id
            )
            self._cards[app_id].setVisible(not query or any(query in value.casefold() for value in fields))

    def _toggle_comparison(self, app_id: str, checked: bool) -> None:
        if checked:
            if len(self._compare_selected) >= 2:
                checkbox = self._compare_checks[app_id]
                checkbox.blockSignals(True)
                checkbox.setChecked(False)
                checkbox.blockSignals(False)
                return
            self._compare_selected.add(app_id)
        else:
            self._compare_selected.discard(app_id)
        for key, checkbox in self._compare_checks.items():
            checkbox.setEnabled(key in self._compare_selected or len(self._compare_selected) < 2)
        count = len(self._compare_selected)
        self._compare_button.setText(f"Comparar selecionados ({count}/2)")
        self._compare_button.setEnabled(count == 2)

    def _compare_products(self) -> None:
        if len(self._compare_selected) != 2 or self._stack is None:
            return
        first_id, second_id = sorted(self._compare_selected)
        first = self._product_by_id[first_id]
        second = self._product_by_id[second_id]
        category = first.get("comparisonCategory")
        if not category or category != second.get("comparisonCategory"):
            return
        self._clear_comparison_rows()
        names = f"{first.get('name', first_id)} e {second.get('name', second_id)}"
        self._comparison_layout.addWidget(SectionHeader(
            f"Comparar {names}", f"Mesma função catalogada: {category}. Sem recomendação de substituição automática.",
        ))
        fields = (
            ("Descrição", "description"),
            ("Grupo", "group"),
            ("Fontes de instalação", "sources"),
            ("Requisitos", "requires"),
            ("Conflitos", "conflicts"),
            ("Compatibilidade", "compatibility"),
            ("Risco declarado", "risk"),
            ("Licença", "license"),
        )
        for label, key in fields:
            self._comparison_layout.addWidget(self._comparison_row(
                label, self._display_value(first.get(key)), self._display_value(second.get(key)),
            ))
        self._comparison_layout.addStretch()
        self._stack.setCurrentWidget(self._comparison_page)
        self.comparison_opened.emit(str(category))

    def _comparison_row(self, label: str, first: str, second: str) -> QFrame:
        frame = QFrame()
        frame.setObjectName("comparisonRow")
        row = QHBoxLayout(frame)
        row.setContentsMargins(12, 8, 12, 8)
        key = QLabel(label)
        key.setObjectName("comparisonKey")
        key.setWordWrap(True)
        left = QLabel(first)
        right = QLabel(second)
        left.setWordWrap(True)
        right.setWordWrap(True)
        row.addWidget(key, 1)
        row.addWidget(left, 2)
        row.addWidget(right, 2)
        return frame

    @staticmethod
    def _display_value(value: object) -> str:
        if isinstance(value, list):
            return ", ".join(str(item.get("name") or item.get("kind")) if isinstance(item, dict) else str(item)
                             for item in value) or "Não informado"
        if isinstance(value, dict):
            values = [f"{key}: {ProductRegistryPage._display_value(item)}" for key, item in value.items()]
            return " · ".join(values) or "Não informado"
        if value is None or value == "":
            return "Não informado"
        return str(value)

    def _clear_comparison_rows(self) -> None:
        while self._comparison_layout.count() > self._comparison_content_start:
            item = self._comparison_layout.takeAt(self._comparison_content_start)
            widget = item.widget()
            if widget is not None:
                widget.setParent(None)
                widget.deleteLater()

    def _close_comparison(self) -> None:
        if self._stack is not None and self._list_page is not None:
            self._stack.setCurrentWidget(self._list_page)
            self._compare_selected.clear()
            for checkbox in self._compare_checks.values():
                checkbox.blockSignals(True)
                checkbox.setChecked(False)
                checkbox.setEnabled(True)
                checkbox.blockSignals(False)
            self._toggle_comparison_count()
            self.back_requested.emit()

    def _toggle_comparison_count(self) -> None:
        self._compare_button.setText(f"Comparar selecionados ({len(self._compare_selected)}/2)")
        self._compare_button.setEnabled(len(self._compare_selected) == 2)

    def open_product(self, app_id: str, context_action_id: str = "") -> None:
        product = self._product_by_id.get(app_id)
        if product is None or self._stack is None or self._detail_layout is None:
            return
        self.status_loader.cancel_all()
        self._selected_app_id = app_id
        self._context_action_id = context_action_id
        self._instances.clear()
        self._populate_instance_selector()
        self._status_label.setText("Instalação, configuração e saúde: desconhecidas")
        self._product_summary.setText(self._display_value(product.get("description")))
        facts = (
            ("Grupo", product.get("group")),
            ("Fontes", product.get("sources")),
            ("Requisitos", product.get("requires")),
            ("Conflitos", product.get("conflicts")),
            ("Compatibilidade", product.get("compatibility")),
            ("Risco", product.get("risk")),
            ("Licença", product.get("license")),
        )
        self._product_facts.setText("\n".join(
            f"{label}: {self._display_value(value)}" for label, value in facts
        ))
        if context_action_id and context_action_id in self.by_id:
            action = self.by_id[context_action_id]
            target = self._targets.get(context_action_id)
            scope = target.instance_scope if target is not None else "selected"
            self._context_label.setText(f"Atalho de origem: {action.category} · {action.title} · escopo {scope}")
        else:
            self._context_label.setText("Catálogo de aplicativos")
        self._clear_detail_actions()
        self._render_detail_actions()
        self._detail_layout.addStretch()
        self._stack.setCurrentWidget(self._detail_page)
        self.product_opened.emit(app_id, context_action_id)
        status_action = self._status_action(product)
        self._status_action_id = status_action.id if status_action is not None else ""
        target = self._targets.get(status_action.id) if status_action is not None else None
        self._status_scope = target.instance_scope if target is not None else "host"
        self._render_primary_action()
        if status_action is not None:
            self.status_loader.fetch_product_status(
                status_action, app_id=app_id, host_id="local", scope=self._status_scope,
            )

    def _render_detail_actions(self) -> None:
        self._clear_detail_actions()
        product = self._product_by_id.get(self._selected_app_id, {})
        all_actions = [self.by_id[item] for item in product.get("actionIds", []) if item in self.by_id]
        actions = all_actions
        context_message = ""
        if self._instances:
            instance = self._selected_instance()
            if instance is None:
                actions = []
                context_message = "Selecione uma instância para ver ações aplicáveis."
            elif instance.host_id != "local":
                actions = []
                context_message = "Ações remotas ainda não estão disponíveis neste detalhe."
            elif self._same_scope_instance_count(instance) > 1:
                actions = []
                context_message = "Há várias instâncias neste escopo; ações não conseguem distingui-las ainda."
            else:
                actions = [
                    action for action in all_actions
                    if (target := self._targets.get(action.id)) is not None
                    and target.instance_scope == instance.scope
                ]
                if not actions:
                    context_message = "Nenhuma ação disponível para este escopo."
        if context_message:
            notice = QLabel(context_message)
            notice.setObjectName("productInstanceActionNotice")
            notice.setWordWrap(True)
            self._detail_layout.addWidget(notice)
            return
        action_ids = [item for item in product.get("actionIds", []) if item in self.by_id]
        action_ids.sort(key=lambda action_id: (
            action_id != product.get("canonicalActionId"),
            not bool(self._manifest_action(action_id).get("installationAuthorityId")),
            self.by_id[action_id].title.casefold(),
        ))
        standard: list[ActionSpec] = []
        advanced: list[ActionSpec] = []
        for action_id in action_ids:
            action = self.by_id[action_id]
            if action not in actions:
                continue
            (advanced if action.visibility == "advanced" or action.risk in {"elevated", "high"} else standard).append(action)
        for action in standard:
            row = ActionListRow(action)
            row.selected.connect(self.action_requested.emit)
            self._detail_layout.addWidget(row)
        if advanced:
            panel = AdvancedActionsPanel(advanced)
            panel.requested.connect(self.action_requested.emit)
            panel.setVisible(self._advanced_mode)
            self._advanced_panels.append(panel)
            self._detail_layout.addWidget(panel)

    def _selected_instance(self) -> ProductInstance | None:
        if not self._instances:
            return None
        if len(self._instances) == 1:
            return next(iter(self._instances.values()))
        if self._instance_selector is None:
            return None
        instance_id = self._instance_selector.currentData()
        return self._instances.get(str(instance_id)) if instance_id else None

    def _same_scope_instance_count(self, instance: ProductInstance) -> int:
        return sum(
            other.host_id == instance.host_id and other.scope == instance.scope
            for other in self._instances.values()
        )

    def _populate_instance_selector(self) -> None:
        selector = self._instance_selector
        if selector is None:
            return
        selector.blockSignals(True)
        selector.clear()
        if len(self._instances) > 1:
            selector.addItem("Selecione uma instância…", "")
            for instance in sorted(
                self._instances.values(), key=lambda item: (item.host_id, item.scope, item.instance_id),
            ):
                label = f"{instance.host_id} · {instance.scope}"
                if self._same_scope_instance_count(instance) > 1:
                    label += f" · {instance.instance_id}"
                selector.addItem(label, instance.instance_id)
            selector.setCurrentIndex(0)
            selector.show()
        else:
            selector.hide()
        selector.blockSignals(False)

    def _selected_instance_changed(self, _index: int) -> None:
        self._render_status()
        self._render_detail_actions()

    def _selected_context_is_actionable(self) -> bool:
        if not self._instances:
            return True
        instance = self._selected_instance()
        return bool(
            instance is not None
            and instance.host_id == "local"
            and self._same_scope_instance_count(instance) == 1
        )

    def _action_matches_selected_instance(self, action: ActionSpec) -> bool:
        if not self._instances:
            return True
        instance = self._selected_instance()
        target = self._targets.get(action.id)
        return bool(
            self._selected_context_is_actionable()
            and instance is not None and target is not None
            and target.instance_scope == instance.scope
        )

    def _manifest_action(self, action_id: str) -> dict[str, object]:
        return next((row for row in self.manifest["actions"] if row.get("actionId") == action_id), {})

    def _status_action(self, product: dict[str, object]) -> ActionSpec | None:
        candidates = []
        for action_id in product.get("actionIds", []):
            action = self.by_id.get(action_id)
            target = self._targets.get(action_id)
            if (
                action is not None and target is not None and not action.mutable
                and (action.id.endswith("status") or ".status." in action.id)
                and action.status_args
            ):
                candidates.append((target.instance_scope != "host", action.id, action))
        if candidates:
            return min(candidates)[2]
        if product.get("capabilityId"):
            return ActionSpec(
                "product.capabilities.status", "Aplicativos", "Verificar aplicativo", "",
                ("capabilities", "status", "--json"), "",
                status_args=("capabilities", "status", "--json"),
            )
        return None

    def _action_for_state(self, state: str) -> ActionSpec | None:
        if not self._selected_app_id:
            return None
        product = self._product_by_id[self._selected_app_id]
        actions = [self.by_id[item] for item in product.get("actionIds", []) if item in self.by_id]
        if state == "prepare":
            authority_ids = set(product.get("installationAuthorityIds", []))
            return next((action for action in actions if self._action_matches_selected_instance(action)
                         and self._manifest_action(action.id).get(
                             "installationAuthorityId") in authority_ids and action.mutable), None)
        if state == "configure":
            configure_id = _PROXY_CONFIGURE_ACTION_BY_APP.get(self._selected_app_id, "")
            configure = self.by_id.get(configure_id)
            instance = self._selected_instance()
            route = _PROXY_CONFIGURE_TARGET_BY_APP.get(self._selected_app_id)
            if (
                configure is not None and route is not None and instance is not None
                and configure_id in product.get("actionIds", [])
                and self._action_matches_selected_instance(configure)
                and instance.origin == "phasezero"
                and instance.manager == "phasezero-ai-proxy-suite"
                and configure.mutable and len(configure.args) == 4
                and configure.args[2:] == route
            ):
                return configure
        terms = {
            "configure": {"configure", "setup"},
            # Resolver may run a read-only diagnostic automatically. Mutable
            # repair/start actions require an app-specific, ownership-checked
            # recovery route above; matching command arguments here can start
            # an unrelated managed service for an externally observed app.
            "resolve": {"doctor"},
            "open": {"open", "launch", "dashboard"},
        }.get(state, set())
        if state == "resolve":
            recovery_id = _RECOVERY_ACTION_BY_APP.get(self._selected_app_id, "")
            recovery = self.by_id.get(recovery_id)
            instance = self._selected_instance()
            proxy_authority = _PROXY_RECOVERY_AUTHORITY_BY_APP.get(self._selected_app_id)
            proxy_recovery_owned = bool(
                recovery is not None and instance is not None
                and proxy_authority == "linux/ai/proxy-suite.sh"
                and instance.manager == "phasezero-ai-proxy-suite"
                and recovery.id == recovery_id
                and recovery.args[:3] == ("ai", "proxies", "start")
                and len(recovery.args) > 3
                and recovery.args[3] == _PROXY_RECOVERY_TARGET_BY_APP.get(self._selected_app_id)
            )
            if (
                recovery is not None and recovery_id in product.get("actionIds", [])
                and self._action_matches_selected_instance(recovery)
                and instance is not None and instance.origin == "phasezero"
            ):
                authority_id = self._manifest_action(recovery_id).get("installationAuthorityId")
                declared_authority = authority_id in product.get("installationAuthorityIds", [])
                if recovery.mutable and (declared_authority or proxy_recovery_owned):
                    return replace(
                        recovery,
                        impact=_RECOVERY_IMPACT_BY_APP.get(self._selected_app_id, recovery.impact),
                    )
        return next((action for action in actions if self._action_matches_selected_instance(action)
                     and (state != "resolve" or not action.mutable) and any(
            term in action.id.casefold().replace("-", ".").split(".")
            or term in action.args for term in terms
        ) and action.id != self._status_action_id), None)

    def _desktop_entry_for_product(self, product: dict[str, object]) -> str:
        sources = product.get("sources", [])
        if not isinstance(sources, list):
            return ""
        roots = desktop_dirs()
        for source in sources:
            if not isinstance(source, dict):
                continue
            entry = find_desktop_entry(
                str(source.get("kind") or ""), str(source.get("name") or ""), roots,
            )
            if entry is not None:
                return str(entry)
        return ""

    def _render_primary_action(self) -> None:
        if self._primary_button is None:
            return
        instance = self._selected_instance()
        if len(self._instances) > 1 and instance is None:
            self._primary_button.setText("Selecionar instância")
            self._primary_action = None
            self._primary_desktop_entry = ""
            self._primary_button.setEnabled(False)
            self._primary_button.setToolTip("Escolha qual instância do aplicativo este detalhe representa.")
            return
        state = instance.next_action if instance is not None else "verify"
        product = self._product_by_id[self._selected_app_id]
        labels = {"prepare": "Preparar", "configure": "Configurar",
                  "verify": "Verificar", "resolve": "Resolver", "open": "Abrir"}
        self._primary_button.setText(labels.get(state, "Verificar"))
        self._primary_action = self._action_for_state(state) if state != "verify" else None
        self._primary_desktop_entry = (
            self._desktop_entry_for_product(product)
            if state == "open" and self._primary_action is None
            and self._selected_context_is_actionable() else ""
        )
        enabled = (
            bool(self._status_action_id) if state == "verify" else
            self._primary_action is not None or bool(self._primary_desktop_entry)
        )
        enabled = enabled and self._selected_context_is_actionable()
        self._primary_button.setEnabled(enabled)
        if state == "verify":
            self._primary_button.setToolTip("Confere status sem alterar instalação, conta ou serviço.")
        else:
            self._primary_button.setToolTip(
                self._primary_action.description if self._primary_action is not None
                else "Abre pelo atalho de aplicativo instalado." if self._primary_desktop_entry
                else "Ação principal indisponível para este estado observado."
            )

    def _primary_clicked(self) -> None:
        if not self._selected_app_id:
            return
        if not self._selected_context_is_actionable():
            return
        if self._primary_action is not None:
            self.action_requested.emit(self._primary_action)
            return
        if self._primary_desktop_entry:
            self.desktop_entry_requested.emit(self._primary_desktop_entry)
            return
        product = self._product_by_id[self._selected_app_id]
        status_action = self._status_action(product)
        if status_action is not None:
            instance = self._selected_instance()
            selected_scope = instance.scope if instance is not None else self._status_scope
            selected_host = instance.host_id if instance is not None else "local"
            target = self._targets.get(status_action.id)
            self._status_scope = selected_scope or (target.instance_scope if target is not None else "host")
            self.status_loader.fetch_product_status(
                status_action, app_id=self._selected_app_id, host_id=selected_host, scope=self._status_scope,
                instance_key=instance.instance_id if instance is not None else "default",
            )

    def _instances_ready(self, action_id: str, instances: object) -> None:
        if action_id != self._status_action_id:
            # StatusLoader discards replaced contexts; keep this guard for same-app refreshes.
            return
        rows = tuple(item for item in instances if isinstance(item, ProductInstance)) if isinstance(instances, tuple) else ()
        self._instances = {item.instance_id: item for item in rows}
        self._populate_instance_selector()
        self._render_status()
        self._render_detail_actions()

    def _status_failed(self, action_id: str, _message: str) -> None:
        if action_id == self._status_action_id:
            self._instances.clear()
            self._populate_instance_selector()
            self._status_label.setText("Status indisponível · instalação, configuração e saúde desconhecidas")
            self._render_primary_action()
            self._render_detail_actions()

    def _render_status(self) -> None:
        if not self._instances:
            self._status_label.setText("Instalação, configuração e saúde: desconhecidas")
            self._render_primary_action()
            return
        instance = self._selected_instance()
        if instance is None:
            self._status_label.setText(
                f"{len(self._instances)} instâncias observadas · selecione uma para ver estado e ações."
            )
            self._render_primary_action()
            return
        self._status_label.setText(
            f"Instância: {instance.host_id} · escopo {instance.scope} · "
            f"Instalação: {instance.installation} · Origem: {instance.origin} · "
            f"Configuração: {instance.configuration} · Saúde: {instance.health} · "
            f"Ação: {instance.next_action}"
        )
        self._render_primary_action()

    def _clear_detail_actions(self) -> None:
        if self._detail_layout is None:
            return
        while self._detail_layout.count() > self._detail_actions_start:
            item = self._detail_layout.takeAt(self._detail_actions_start)
            widget = item.widget()
            if widget is not None:
                if widget in self._advanced_panels:
                    self._advanced_panels.remove(widget)
                widget.setParent(None)
                widget.deleteLater()

    def close_detail(self) -> None:
        if self._stack is not None and self._list_page is not None:
            self.status_loader.cancel_all()
            self._selected_app_id = ""
            self._context_action_id = ""
            self._status_action_id = ""
            self._stack.setCurrentWidget(self._list_page)
            self.back_requested.emit()

    def show_catalog(self) -> None:
        if self._stack is not None and self._list_page is not None:
            self.status_loader.cancel_all()
            self._selected_app_id = ""
            self._context_action_id = ""
            self._status_action_id = ""
            self._stack.setCurrentWidget(self._list_page)

    def reload(self) -> None:
        if self._selected_app_id:
            self.open_product(self._selected_app_id, self._context_action_id)

    def block_while_running(self, running: bool) -> None:
        for card in self._cards.values():
            card.setEnabled(not running)
        if self._detail_page is not None:
            self._detail_page.setEnabled(not running)

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
