from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QFrame, QGridLayout, QHBoxLayout, QLabel,
    QLineEdit, QPushButton, QScrollArea, QStyle, QTextEdit, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..proxy_models import (
    PROXY_CARDS, GatewayState, IdeIntegrationState, ProxyState,
    parse_detailed_status, parse_gateway_status,
)
from ..widgets import SectionHeader, themed_icon
from .base import BasePage

_DETAILED_KEY = "proxies.detailed-status"
_POLL_MS = 5_000
_MIMO_PLATFORM = "https://platform.xiaomimimo.com"

ENSURE_ACTIONS: dict[str, str] = {
    "kimiproxy": "ai.proxies-ensure-kimi",
    "qwenproxy": "ai.proxies-ensure-qwen",
    "deepsproxy": "ai.proxies-ensure-deeps",
    "mimo-ai-proxy": "ai.proxies-ensure-mimo",
}
STOP_ACTIONS: dict[str, str] = {
    "kimiproxy": "ai.proxies-stop-kimi",
    "qwenproxy": "ai.proxies-stop-qwen",
    "deepsproxy": "ai.proxies-stop-deeps",
    "mimo-ai-proxy": "ai.proxies-stop-mimo",
}
OPEN_ACTIONS: dict[str, str] = {
    "kimiproxy": "ai.proxies-open-kimi",
    "qwenproxy": "ai.proxies-open-qwen",
    "deepsproxy": "ai.proxies-open-deeps",
    "mimo-ai-proxy": "ai.proxies-open-mimo",
}

_PRIMARY_IDS = {
    "ai.proxies-ensure-kimi",
    "ai.proxies-ensure-qwen",
    "ai.proxies-ensure-deeps",
    "ai.proxies-ensure-mimo",
    "ai.proxies-ensure-all",
    "ai.proxies-open-kimi",
    "ai.proxies-open-qwen",
    "ai.proxies-open-deeps",
    "ai.proxies-open-mimo",
    "ai.proxies-open-studio-mimo",
    "ai.proxies-credentials-mimo",
    "ai.proxies-stop-kimi",
    "ai.proxies-stop-qwen",
    "ai.proxies-stop-deeps",
    "ai.proxies-stop-mimo",
    "ai.proxies-ides",
    "ai.proxies.status",
    "ai.proxies.detailed-status",
    "ai.proxies-provenance",
    "ai.9router-status",
    "ai.9router-install",
    "ai.9router-repair",
    "ai.9router-dashboard",
    "ai.9router-test",
    "ai.odysseus-status",
    "ai.odysseus-install",
    "ai.odysseus-open",
    "ai.odysseus-doctor",
    "ai.hermes-status",
    "ai.hermes-doctor",
    "ai.workspaces-doctor",
    "ai.workspaces-plan",
    "ai.auth-registry",
    "ai.auth-doctor",
}

_LOGIN_PENDING = {"ready-for-login", "session-present", "needs-login", "start-required"}


def _set_state(widget: QWidget, state: str) -> None:
    widget.setProperty("state", state)
    widget.style().unpolish(widget)
    widget.style().polish(widget)


def _friendly_proxy_copy(state: ProxyState) -> tuple[str, str, str]:
    """Return (headline, detail, semantic state) for simple-mode cards."""
    if not state.installed:
        return "Precisa preparar", "Um clique instala, inicia e abre o login se faltar.", "warning"
    if state.auth_status == "login-running":
        return "Login no navegador", "Conclua o login na janela do Chromium.", "warning"
    if state.auth_status == "authenticated":
        if state.running:
            return "Pronto", "Sessão válida. Pode usar nas IDEs.", "success"
        return "Parado", "Sessão válida. Clique em Usar para ligar de novo.", "info"
    if state.auth_status == "configured":
        if state.id == "mimo-ai-proxy" and state.auth_kind == "official-api-key":
            return "Pronto", "API oficial configurada. Nenhum serviço local é necessário.", "success"
        if state.running:
            return "Pronto", "Credenciais configuradas.", "success"
        return "Parado", "Clique em Usar para ligar.", "info"
    if state.auth_status == "missing-credentials":
        if state.id == "mimo-ai-proxy":
            return "Falta chave da API", "Abra API Service na Xiaomi e cole uma chave oficial.", "warning"
        return "Falta credencial", "Abra o provedor e conclua a configuração.", "warning"
    if state.auth_status == "gui-required":
        return "Precisa do desktop", "Abra a Central no Linux gráfico para o login.", "error"
    if state.auth_status in _LOGIN_PENDING or state.auth_status == "session-present":
        if state.running:
            return "Falta login", "Clique em Usar para abrir o navegador.", "warning"
        return "Falta login", "Um clique inicia o proxy e abre o navegador.", "warning"
    if state.running:
        return "Rodando", "Serviço local ativo.", "success"
    return "Parado", "Clique em Usar para ligar.", "info"


class MimoTokenDialog(QDialog):
    """Configure Xiaomi's supported API without browser-session extraction."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Conectar Mimo")
        self.setMinimumWidth(560)
        layout = QVBoxLayout(self)
        guide = QTextEdit()
        guide.setReadOnly(True)
        guide.setMaximumHeight(150)
        guide.setPlainText(
            "1. Clique em Abrir API Service e entre na conta Xiaomi.\n"
            "2. Crie uma chave de API no portal oficial.\n"
            "3. Cole a chave abaixo e salve.\n\n"
            "A chave fica em arquivo protegido. Não copie cookies, cabeçalhos do "
            "DevTools, user id ou tokens de sessão."
        )
        layout.addWidget(guide)
        open_btn = QPushButton("Abrir API Service")
        open_btn.setObjectName("primaryButton")
        open_btn.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(_MIMO_PLATFORM)))
        layout.addWidget(open_btn)
        self.api_key = QLineEdit()
        self.api_key.setEchoMode(QLineEdit.Password)
        self.api_key.setPlaceholderText("sk-… ou tp-…")
        self.base_url = QLineEdit("https://api.xiaomimimo.com/v1")
        self.model = QLineEdit("mimo-v2.5-pro")
        for field, label in (
            (self.api_key, "Chave da API"),
            (self.base_url, "Endpoint oficial"),
            (self.model, "Modelo"),
        ):
            layout.addWidget(QLabel(label))
            field.setAccessibleName(label)
            layout.addWidget(field)
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def payload(self) -> dict[str, str]:
        return {
            "apiKey": self.api_key.text().strip(),
            "baseUrl": self.base_url.text().strip(),
            "model": self.model.text().strip(),
        }


class AiProxiesPage(BasePage):
    """WinVM-style proxy surface: one Usar button runs install+start+login."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._cards: dict[str, dict[str, QWidget]] = {}
        self._gateway_rows: dict[str, dict[str, QWidget]] = {}
        self._gateway_state: dict[str, GatewayState] = {}
        self._proxy_state: dict[str, ProxyState] = {}
        self._next_action_values: dict[str, str] = {}
        self._ide_values: dict[str, QLabel] = {}
        self._technical_widgets: list[QWidget] = []
        self._auth_group_labels: dict[str, QLabel] = {}
        self._provenance: dict[str, dict[str, object]] = {}
        self._poll = QTimer(self)
        self._poll.setInterval(_POLL_MS)
        self._poll.timeout.connect(self._poll_tick)
        self.status_loader.status_ready.connect(self._proxy_status_ready)
        self.status_loader.status_failed.connect(self._proxy_status_failed)

    def build(self) -> None:
        for action_id in _PRIMARY_IDS:
            action = self.by_id.get(action_id)
            if action is not None:
                self.mark_represented(action)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(14)

        layout.addWidget(self._build_hero())
        layout.addWidget(self._build_gateways())
        layout.addWidget(self._build_auth_registry())
        layout.addWidget(self._build_provenance())
        layout.addWidget(SectionHeader(
            "Proxies individuais",
            "Um clique instala, liga e abre o navegador se o login ainda faltar",
        ))
        grid_host = QWidget()
        grid = QGridLayout(grid_host)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index, (proxy_id, name, port, _suffix) in enumerate(PROXY_CARDS):
            grid.addWidget(self._proxy_card(proxy_id, name, port), index // 2, index % 2)
        grid.setColumnStretch(0, 1)
        grid.setColumnStretch(1, 1)
        layout.addWidget(grid_host)
        layout.addWidget(self._build_ides())
        layout.addStretch()
        scroll.setWidget(inner)
        self._layout.addWidget(scroll, 1)
        self.reload()

    def _install_context_status(self) -> None:
        return

    def _build_hero(self) -> QFrame:
        hero = QFrame()
        hero.setObjectName("serviceHero")
        row = QHBoxLayout(hero)
        row.setContentsMargins(20, 18, 20, 18)
        row.setSpacing(16)
        icon = QLabel()
        icon.setObjectName("serviceIcon")
        icon.setPixmap(themed_icon(hero, "network-server", QStyle.SP_DriveNetIcon).pixmap(38, 38))
        icon.setAlignment(Qt.AlignCenter)
        icon.setFixedSize(58, 58)
        row.addWidget(icon)
        copy = QVBoxLayout()
        copy.setSpacing(3)
        title = QLabel("Proxies IA")
        title.setObjectName("serviceTitle")
        self.state_label = QLabel("● Verificando…")
        self.state_label.setObjectName("serviceState")
        self.state_label.setProperty("state", "info")
        self.state_detail = QLabel("Lendo instalação, serviços e sessões")
        self.state_detail.setObjectName("cardDescription")
        self.state_detail.setWordWrap(True)
        copy.addWidget(title)
        copy.addWidget(self.state_label)
        copy.addWidget(self.state_detail)
        row.addLayout(copy, 1)
        self.refresh_button = QPushButton("Atualizar")
        self.refresh_button.setObjectName("secondaryButton")
        self.refresh_button.clicked.connect(self.reload)
        row.addWidget(self.refresh_button)
        self.prepare_button = QPushButton("Preparar todos")
        self.prepare_button.setObjectName("primaryButton")
        self.prepare_button.setMinimumSize(160, 50)
        self.prepare_button.clicked.connect(lambda: self.run_action("ai.proxies-ensure-all"))
        row.addWidget(self.prepare_button)
        return hero

    def _build_gateways(self) -> QWidget:
        host = QWidget()
        layout = QVBoxLayout(host)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(14)
        layout.addWidget(SectionHeader(
            "Agentes e gateways",
            "Autenticação, roteamento e workspace com prontidão verificável",
        ))
        layout.addWidget(self._gateway_card(
            "hermes", "Hermes",
            "Agente e canais remotos. Autenticação, MCPs e acesso seguro.",
            "ai.hermes-doctor", "ai.hermes-doctor", "ai.hermes-status",
            install_label="Diagnosticar", repair_label="Diagnosticar", open_label="Ver status",
        ))
        layout.addWidget(self._gateway_card(
            "9router", "9Router",
            "Painel local de modelos, cotas e fallbacks",
            "ai.9router-install", "ai.9router-repair", "ai.9router-dashboard",
        ))
        layout.addWidget(self._gateway_card(
            "odysseus", "Odysseus",
            "Workspace experimental. Deploy exige Podman rootless, proveniência e release gate.",
            "ai.workspaces-plan", "ai.odysseus-doctor", "ai.odysseus-open",
            install_label="Ver plano", repair_label="Diagnosticar", open_label="Abrir",
        ))
        diagnostic_row = QHBoxLayout()
        diagnostic_row.addStretch()
        for action_id, label in (
            ("ai.workspaces-doctor", "Diagnóstico completo"),
            ("ai.workspaces-plan", "Ver plano seguro"),
        ):
            button = self._action_button(action_id, label)
            if button is not None:
                diagnostic_row.addWidget(button)
        layout.addLayout(diagnostic_row)
        return host

    def _build_auth_registry(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "Autenticação central",
            "Inventário redigido: nenhuma chave, e-mail ou nome de conta aparece aqui",
        ))
        self.auth_summary = QLabel("Verificando contas e sessões…")
        self.auth_summary.setObjectName("settingValue")
        self.auth_summary.setWordWrap(True)
        layout.addWidget(self.auth_summary)
        grid_host = QWidget()
        grid = QGridLayout(grid_host)
        grid.setContentsMargins(0, 4, 0, 4)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(8)
        for index, (group_id, title) in enumerate((
            ("core", "Clientes principais"),
            ("providers", "Providers do 9Router"),
            ("proxies", "Sessões dos proxies"),
            ("workspaces", "Agentes e workspaces"),
        )):
            host = QFrame()
            host.setObjectName("actionCard")
            box = QVBoxLayout(host)
            box.setContentsMargins(12, 10, 12, 10)
            caption = QLabel(title)
            caption.setObjectName("cardTitle")
            value = QLabel("Verificando…")
            value.setObjectName("cardDescription")
            value.setWordWrap(True)
            box.addWidget(caption)
            box.addWidget(value)
            self._auth_group_labels[group_id] = value
            grid.addWidget(host, index // 2, index % 2)
        grid.setColumnStretch(0, 1)
        grid.setColumnStretch(1, 1)
        layout.addWidget(grid_host)
        buttons = QHBoxLayout()
        buttons.addStretch()
        doctor = self._action_button("ai.auth-doctor", "Diagnosticar")
        dashboard = self._action_button("ai.9router-dashboard", "Gerenciar providers")
        if doctor is not None:
            buttons.addWidget(doctor)
        if dashboard is not None:
            buttons.addWidget(dashboard)
        layout.addLayout(buttons)
        return card

    def _build_provenance(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QHBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        copy = QVBoxLayout()
        title = QLabel("Procedência dos proxies")
        title.setObjectName("cardTitle")
        self.provenance_summary = QLabel("Verificando snapshots…")
        self.provenance_summary.setObjectName("settingValue")
        self.provenance_detail = QLabel(
            "Origem, commit, árvore, licença e lockfiles fixados. Isto não é auditoria semântica do código."
        )
        self.provenance_detail.setObjectName("cardDescription")
        self.provenance_detail.setWordWrap(True)
        copy.addWidget(title)
        copy.addWidget(self.provenance_summary)
        copy.addWidget(self.provenance_detail)
        layout.addLayout(copy, 1)
        button = self._action_button("ai.proxies-provenance", "Ver detalhes")
        if button is not None:
            layout.addWidget(button)
        return card

    def _gateway_card(
        self, gateway_id: str, name: str, description: str,
        install_id: str, repair_id: str, open_id: str,
        *, install_label: str = "Instalar", repair_label: str = "Reparar",
        open_label: str = "Abrir",
    ) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        row = QHBoxLayout(card)
        row.setContentsMargins(14, 12, 14, 12)
        icon = QLabel()
        icon.setPixmap(themed_icon(card, "network-server", QStyle.SP_DriveNetIcon).pixmap(24, 24))
        icon.setFixedSize(34, 34)
        row.addWidget(icon)
        copy = QVBoxLayout()
        copy.setSpacing(2)
        title = QLabel(name)
        title.setObjectName("cardTitle")
        status = QLabel("Verificando…")
        status.setObjectName("cardDescription")
        detail = QLabel(description)
        detail.setObjectName("cardDescription")
        detail.setWordWrap(True)
        copy.addWidget(title)
        copy.addWidget(status)
        copy.addWidget(detail)
        row.addLayout(copy, 1)
        use = QPushButton("Usar")
        use.setObjectName("primaryButton")
        use.setMinimumHeight(44)
        use.setEnabled(False)
        use.clicked.connect(lambda: self._gateway_use(gateway_id))
        row.addWidget(use)
        self._gateway_rows[gateway_id] = {
            "status": status, "detail": detail, "use": use,
            "install": install_id, "repair": repair_id, "open": open_id,
            "install_label": install_label, "repair_label": repair_label,
            "open_label": open_label, "description": description,
        }
        return card

    def _proxy_card(self, proxy_id: str, name: str, port: int) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        box = QVBoxLayout(card)
        box.setContentsMargins(14, 12, 14, 12)
        box.setSpacing(6)
        head = QHBoxLayout()
        title = QLabel(name)
        title.setObjectName("cardTitle")
        port_label = QLabel(f":{port}")
        port_label.setObjectName("cardDescription")
        head.addWidget(title)
        head.addWidget(port_label)
        head.addStretch()
        dot = QLabel("●")
        dot.setObjectName("pillDot")
        _set_state(dot, "info")
        head.addWidget(dot)
        box.addLayout(head)
        headline = QLabel("Verificando…")
        headline.setObjectName("settingValue")
        box.addWidget(headline)
        detail = QLabel("")
        detail.setObjectName("cardDescription")
        detail.setWordWrap(True)
        box.addWidget(detail)
        controls = QHBoxLayout()
        controls.setSpacing(8)
        use = QPushButton("Usar")
        use.setObjectName("primaryButton")
        use.setMinimumHeight(44)
        use.setToolTip("Prepara o proxy e, quando estiver pronto, abre o OpenCode já no modelo.")
        use.clicked.connect(lambda _checked=False, pid=proxy_id: self._on_use_clicked(pid))
        stop = self._action_button(STOP_ACTIONS.get(proxy_id, ""), "Parar")
        if stop is not None:
            stop.setObjectName("dangerOutlineButton")
        controls.addWidget(use)
        if stop is not None:
            controls.addWidget(stop)
        controls.addStretch()
        box.addLayout(controls)
        self._cards[proxy_id] = {
            "dot": dot, "headline": headline, "detail": detail,
            "port": port_label, "use": use, "stop": stop,
        }
        self._technical_widgets.append(port_label)
        return card

    def _build_ides(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "IDEs e agentes",
            "Depois do proxy pronto, conecte OpenCode, Continue e ZCode",
        ))
        self.ide_summary = QLabel("Verificando integração…")
        self.ide_summary.setObjectName("cardDescription")
        self.ide_summary.setWordWrap(True)
        layout.addWidget(self.ide_summary)
        for key, label in (
            ("opencode", "OpenCode / OpenCode Desktop"),
            ("continue", "Continue (VS Code / Code-OSS)"),
            ("zcode", "ZCode"),
            ("env", "Env global (ide-defaults.env)"),
        ):
            row = QHBoxLayout()
            caption = QLabel(label)
            caption.setObjectName("cardTitle")
            value = QLabel("—")
            value.setObjectName("cardDescription")
            row.addWidget(caption)
            row.addWidget(value, 1, Qt.AlignRight)
            host = QWidget()
            host.setLayout(row)
            layout.addWidget(host)
            self._ide_values[key] = value
            self._technical_widgets.append(host)
        sync_row = QHBoxLayout()
        sync_row.addStretch()
        sync_button = self._action_button("ai.proxies-ides", "Configurar IDEs (proxies)")
        if sync_button is not None:
            sync_row.addWidget(sync_button)
        layout.addLayout(sync_row)
        return card

    def _action_button(self, action_id: str, label: str) -> QPushButton | None:
        action = self.find(action_id) if action_id else None
        if action is None:
            return None
        button = QPushButton(label)
        button.setObjectName("primaryButton" if action.mutable else "secondaryButton")
        button.setToolTip(action.description)
        button.clicked.connect(lambda _checked=False, a=action: self.request_action(a))
        return button

    def consume_action_values(self, action: ActionSpec) -> dict[str, str]:
        if action.id != "ai.proxies-credentials-mimo":
            return {}
        values = dict(self._next_action_values)
        self._next_action_values = {}
        return values

    def _on_use_clicked(self, proxy_id: str) -> None:
        state = self._proxy_state.get(proxy_id)
        if proxy_id == "mimo-ai-proxy" and (
            state is None or state.auth_status == "missing-credentials"
        ):
            self._connect_mimo()
            return
        if state is not None and state.auth_status in {"authenticated", "configured"} and state.running:
            self.run_action(OPEN_ACTIONS.get(proxy_id, ""))
            return
        self.run_action(ENSURE_ACTIONS.get(proxy_id, ""))

    def _connect_mimo(self) -> None:
        dialog = MimoTokenDialog(self)
        if dialog.exec() != QDialog.Accepted:
            return
        payload = dialog.payload()
        if not all(payload.values()):
            return
        import json
        self._next_action_values = {"credentials": json.dumps(payload)}
        credentials = self.by_id.get("ai.proxies-credentials-mimo")
        open_action = self.by_id.get("ai.proxies-open-mimo")
        if credentials is not None and open_action is not None:
            self.request_actions([credentials, open_action])
        elif credentials is not None:
            self.request_action(credentials)

    def _gateway_use(self, gateway_id: str) -> None:
        refs = self._gateway_rows.get(gateway_id) or {}
        state = self._gateway_state.get(gateway_id)
        if state is None or not state.installed:
            self.run_action(str(refs.get("install") or ""))
            return
        if not state.healthy:
            self.run_action(str(refs.get("repair") or refs.get("install") or ""))
            return
        self.run_action(str(refs.get("open") or ""))

    def reload(self) -> None:
        if not self.status_loader.running(_DETAILED_KEY):
            self.status_loader.fetch(_DETAILED_KEY, ["ai", "proxies", "detailed-status"])
        for aid in (
            "ai.auth-registry", "ai.hermes-status", "ai.9router-status", "ai.odysseus-status",
        ):
            action = self.by_id.get(aid)
            if action is not None and not self.status_loader.running(aid):
                self.status_loader.fetch_action(action)

    def _poll_tick(self) -> None:
        if self.isVisible() and self.isEnabled():
            self.reload()

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._poll.start()

    def hideEvent(self, event) -> None:
        self._poll.stop()
        super().hideEvent(event)

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
        for widget in self._technical_widgets:
            widget.setVisible(enabled)

    def block_while_running(self, running: bool) -> None:
        self.prepare_button.setEnabled(not running)
        self.refresh_button.setEnabled(not running)
        for refs in self._cards.values():
            use = refs.get("use")
            stop = refs.get("stop")
            if isinstance(use, QPushButton):
                use.setEnabled(not running)
            if isinstance(stop, QPushButton):
                stop.setEnabled(not running)
        for refs in self._gateway_rows.values():
            use = refs.get("use")
            if isinstance(use, QPushButton):
                use.setEnabled(not running)
        if not running and self.isVisible():
            self.reload()

    def _proxy_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id == _DETAILED_KEY:
            proxies, ide = parse_detailed_status(parsed)
            self._apply_proxies(proxies)
            self._apply_ide(ide)
            provenance = parsed.get("provenance") if isinstance(parsed, dict) else None
            self._apply_provenance(provenance)
        elif action_id == "ai.9router-status":
            self._apply_gateway(parse_gateway_status("9router", parsed))
        elif action_id == "ai.odysseus-status":
            self._apply_gateway(parse_gateway_status("odysseus", parsed))
        elif action_id == "ai.hermes-status":
            self._apply_gateway(parse_gateway_status("hermes", parsed))
        elif action_id == "ai.auth-registry":
            self._apply_auth_registry(parsed)

    def _proxy_status_failed(self, action_id: str, message: str) -> None:
        if action_id == _DETAILED_KEY:
            self.state_label.setText("● Estado indisponível")
            self.state_detail.setText("Não foi possível ler os proxies. Tente atualizar.")
            _set_state(self.state_label, "error")
            self.provenance_summary.setText("Procedência indisponível")
            _set_state(self.provenance_summary, "error")
            for refs in self._cards.values():
                headline = refs.get("headline")
                if isinstance(headline, QLabel):
                    headline.setText(f"Status indisponível — {message}")
        elif action_id in ("ai.hermes-status", "ai.9router-status", "ai.odysseus-status"):
            gateway_id = {
                "ai.hermes-status": "hermes",
                "ai.9router-status": "9router",
                "ai.odysseus-status": "odysseus",
            }[action_id]
            refs = self._gateway_rows.get(gateway_id)
            if refs is not None:
                status = refs.get("status")
                if isinstance(status, QLabel):
                    status.setText("Status indisponível")
        elif action_id == "ai.auth-registry":
            self.auth_summary.setText("Autenticação indisponível. Tente atualizar.")
            _set_state(self.auth_summary, "error")
            for label in self._auth_group_labels.values():
                label.setText("Status indisponível")

    def _apply_auth_registry(self, parsed: object) -> None:
        if not isinstance(parsed, dict):
            self._proxy_status_failed("ai.auth-registry", "invalid payload")
            return
        entries = [entry for entry in parsed.get("entries", []) if isinstance(entry, dict)]
        summary = parsed.get("summary") if isinstance(parsed.get("summary"), dict) else {}
        ready = int(summary.get("ready") or 0)
        total = int(summary.get("total") or len(entries))
        attention = int(summary.get("attention") or 0)
        accounts = int(summary.get("accounts") or 0)
        missing_essential = int(summary.get("missingEssential") or 0)
        if missing_essential:
            self.auth_summary.setText(
                f"{missing_essential} integração essencial pendente · {ready}/{total} prontas"
            )
            _set_state(self.auth_summary, "error")
        elif attention:
            self.auth_summary.setText(
                f"{ready}/{total} prontas · {attention} pedem atenção · {accounts} contas catalogadas"
            )
            _set_state(self.auth_summary, "warning")
        else:
            self.auth_summary.setText(f"{ready}/{total} prontas · {accounts} contas catalogadas")
            _set_state(self.auth_summary, "success")

        groups = {
            "core": [entry for entry in entries if entry.get("id") in {"gateway:9router", "client:opencode", "client:claude", "client:bonsai"}],
            "providers": [entry for entry in entries if str(entry.get("id", "")).startswith("provider:")],
            "proxies": [entry for entry in entries if str(entry.get("id", "")).startswith("proxy:")],
            "workspaces": [entry for entry in entries if str(entry.get("id", "")).startswith("workspace:")],
        }
        for group_id, rows in groups.items():
            label = self._auth_group_labels.get(group_id)
            if label is None:
                continue
            group_ready = sum(1 for row in rows if row.get("ready") is True)
            pending = [str(row.get("label") or row.get("id")) for row in rows if row.get("ready") is not True]
            suffix = ""
            if pending:
                visible = ", ".join(pending[:4])
                remaining = len(pending) - 4
                suffix = f" · revisar: {visible}" + (f" +{remaining}" if remaining > 0 else "")
            label.setText(f"{group_ready}/{len(rows)} prontas{suffix}")

    def _apply_gateway(self, state: GatewayState) -> None:
        self._gateway_state[state.id] = state
        refs = self._gateway_rows.get(state.id)
        if refs is None:
            return
        status = refs.get("status")
        detail = refs.get("detail")
        use = refs.get("use")
        if isinstance(status, QLabel):
            status.setText(state.label.capitalize() if state.label else "—")
            _set_state(status, state.state)
        if isinstance(detail, QLabel):
            detail.setText(state.detail or str(refs.get("description") or ""))
        if isinstance(use, QPushButton):
            if not state.installed:
                use.setText(str(refs.get("install_label") or "Instalar"))
            elif not state.healthy:
                use.setText(str(refs.get("repair_label") or "Reparar"))
            else:
                use.setText(str(refs.get("open_label") or "Abrir"))
            use.setEnabled(True)

    def _apply_provenance(self, parsed: object) -> None:
        if not isinstance(parsed, dict):
            self.provenance_summary.setText("Procedência indisponível")
            _set_state(self.provenance_summary, "error")
            return
        sources = [row for row in parsed.get("sources", []) if isinstance(row, dict)]
        self._provenance = {str(row.get("id")): row for row in sources}
        summary = parsed.get("summary") if isinstance(parsed.get("summary"), dict) else {}
        total = int(summary.get("total") or len(sources))
        approved = int(summary.get("approved") or 0)
        installed = int(summary.get("installed") or 0)
        ready = int(summary.get("ready") or 0)
        invalid = int(summary.get("invalidInstalled") or 0)
        if invalid:
            self.provenance_summary.setText(f"{invalid} instalação bloqueada · {ready}/{installed} verificadas")
            _set_state(self.provenance_summary, "error")
        elif approved != total:
            self.provenance_summary.setText(f"{approved}/{total} fontes aprovadas · instalação bloqueada para as demais")
            _set_state(self.provenance_summary, "warning")
        else:
            self.provenance_summary.setText(f"{approved}/{total} fontes aprovadas · {ready}/{installed} instalações íntegras")
            _set_state(self.provenance_summary, "success")
        for proxy_id, refs in self._cards.items():
            row = self._provenance.get(proxy_id)
            if row is None or row.get("installed") is not True or row.get("ready") is True:
                continue
            headline = refs.get("headline")
            detail = refs.get("detail")
            dot = refs.get("dot")
            use = refs.get("use")
            if isinstance(headline, QLabel):
                headline.setText("Bloqueado por procedência")
            if isinstance(detail, QLabel):
                detail.setText(str(row.get("reason") or "Snapshot local inválido."))
            if isinstance(dot, QLabel):
                _set_state(dot, "error")
            if isinstance(use, QPushButton):
                use.setText("Revisar procedência")
                use.setEnabled(False)

    def _apply_proxies(self, proxies: dict[str, ProxyState]) -> None:
        self._proxy_state = dict(proxies)
        ready = 0
        login = 0
        missing = 0
        for proxy_id, refs in self._cards.items():
            state = proxies.get(proxy_id)
            headline = refs.get("headline")
            detail = refs.get("detail")
            dot = refs.get("dot")
            use = refs.get("use")
            stop = refs.get("stop")
            if state is None:
                if isinstance(headline, QLabel):
                    headline.setText("Sem dados")
                continue
            label, copy, semantic = _friendly_proxy_copy(state)
            if isinstance(dot, QLabel):
                _set_state(dot, semantic)
            if isinstance(headline, QLabel):
                headline.setText(label)
            if isinstance(detail, QLabel):
                extra = ""
                if self._advanced_mode and state.auth_missing:
                    extra = f" Falta: {', '.join(state.auth_missing)}."
                detail.setText(copy + extra)
            if isinstance(use, QPushButton):
                if state.auth_status == "login-running":
                    use.setText("Login aberto…")
                    use.setEnabled(True)
                    use.setToolTip("Se a janela sumiu, clique de novo para reabrir o login.")
                elif state.auth_status == "missing-credentials":
                    use.setText("Conectar conta")
                    use.setEnabled(True)
                elif not state.installed:
                    use.setText("Usar")
                    use.setEnabled(True)
                elif state.running and state.auth_status in {"authenticated", "configured"}:
                    use.setText("Abrir no OpenCode")
                    use.setEnabled(True)
                elif state.auth_status == "session-present":
                    use.setText("Usar")
                    use.setEnabled(True)
                    use.setToolTip("Sessão salva, mas o chat ainda precisa de um login válido. Clique para abrir o navegador.")
                else:
                    use.setText("Usar")
                    use.setEnabled(True)
            if isinstance(stop, QPushButton):
                stop.setEnabled(state.installed and state.running)
            if state.auth_status in {"authenticated", "configured"} and state.running:
                ready += 1
            elif state.auth_status in _LOGIN_PENDING or state.auth_status in {
                "login-running", "session-present", "missing-credentials",
            }:
                login += 1
            elif not state.installed:
                missing += 1
        self.refresh_button.setEnabled(True)
        if missing and not ready:
            self.state_label.setText("● Precisa preparar")
            self.state_detail.setText("Clique em Usar em um proxy — instalação, serviço e login andam juntos.")
            _set_state(self.state_label, "warning")
        elif login:
            self.state_label.setText("● Falta login")
            self.state_detail.setText("Conclua o login no navegador. O proxy inicia sozinho depois.")
            _set_state(self.state_label, "warning")
        elif ready:
            self.state_label.setText("● Pronto")
            self.state_detail.setText(f"{ready} proxies prontos para as IDEs")
            _set_state(self.state_label, "success")
        else:
            self.state_label.setText("● Parado")
            self.state_detail.setText("Proxies instalados. Clique em Usar para ligar.")
            _set_state(self.state_label, "info")

    def _apply_ide(self, ide: IdeIntegrationState) -> None:
        wired = ide.opencode_providers + ide.continue_models + ide.zcode_providers
        if wired:
            self.ide_summary.setText("OpenCode, Continue e ZCode já veem os proxies locais.")
        else:
            self.ide_summary.setText("Ainda não conectado. Um clique injeta os proxies nas IDEs.")
        default_hint = f" (padrão: {ide.default_proxy})" if ide.default_proxy else ""
        values = {
            "opencode": f"{ide.opencode_providers} providers",
            "continue": f"{ide.continue_models} modelos",
            "zcode": f"{ide.zcode_providers} providers",
            "env": ("configurado" if ide.env_defaults else "não configurado") + default_hint,
        }
        for key, text in values.items():
            label = self._ide_values.get(key)
            if label is not None:
                label.setText(text)
        self.set_advanced_mode(self._advanced_mode)
