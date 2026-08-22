from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QFrame, QGridLayout, QGroupBox, QHBoxLayout, QLabel,
    QPushButton, QScrollArea, QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..proxy_models import (
    PROXY_CARDS, GatewayState, IdeIntegrationState, ProxyState,
    parse_detailed_status, parse_gateway_status,
)
from ..widgets import SectionHeader, themed_icon
from .base import BasePage

# StatusLoader key for the consolidated proxy snapshot (not a catalog action id).
_DETAILED_KEY = "proxies.detailed-status"
_POLL_MS = 15_000

# Browser-session proxies whose OAuth is a headed Chromium flow. Maps the proxy
# id to its catalog login action (the "Autenticar" affordance). mimo-ai-proxy is
# absent on purpose: it authenticates via .env tokens, not a browser.
LOGIN_ACTIONS: dict[str, str] = {
    "kimiproxy": "ai.proxies-login-kimi",
    "qwenproxy": "ai.proxies-login-qwen",
    "deepsproxy": "ai.proxies-login-deeps",
}

# Auth statuses where opening the OAuth browser is the next useful step.
_LOGIN_PENDING = {"ready-for-login", "session-present", "needs-login", "start-required"}


def _set_state(widget: QWidget, state: str) -> None:
    widget.setProperty("state", state)
    widget.style().unpolish(widget)
    widget.style().polish(widget)


class AiProxiesPage(BasePage):
    """Dedicated lifecycle/OAuth/IDE page for the OpenAI-compatible proxy suite."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        # Per-proxy widget refs: id -> {"dot", "service", "auth", "start", "stop"}
        self._cards: dict[str, dict[str, QWidget]] = {}
        self._auth_rows: dict[str, tuple[QLabel, QLabel]] = {}
        self._gateway_rows: dict[str, tuple[QLabel, QLabel, QLabel]] = {}
        self._ide_values: dict[str, QLabel] = {}
        self._poll = QTimer(self)
        self._poll.setInterval(_POLL_MS)
        self._poll.timeout.connect(self._poll_tick)
        self.status_loader.status_ready.connect(self._proxy_status_ready)
        self.status_loader.status_failed.connect(self._proxy_status_failed)

    # ------------------------------------------------------------------ build
    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader("Agentes e gateways", "Hermes, 9Router e workspace Odysseus"))
        layout.addWidget(self._gateway_row(
            "hermes", "Hermes",
            (("ai.hermes-doctor", "Diagnosticar"), ("ai.hermes-status", "Status")),
        ))
        layout.addWidget(self._gateway_row(
            "9router", "9Router",
            (("ai.9router-dashboard", "Dashboard"), ("ai.9router-test", "Testar"), ("ai.9router-install", "Instalar")),
        ))
        layout.addWidget(self._gateway_row(
            "odysseus", "Odysseus",
            (("ai.odysseus-open", "Abrir"), ("ai.odysseus-doctor", "Doctor"), ("ai.workspaces-plan", "Plano seguro")),
        ))
        diagnostic_row = QHBoxLayout()
        diagnostic_row.addStretch()
        for aid, label in (("ai.workspaces-doctor", "Diagnóstico completo"), ("ai.workspaces-plan", "Ver plano seguro")):
            button = self._action_button(aid, label)
            if button is not None:
                diagnostic_row.addWidget(button)
        layout.addLayout(diagnostic_row)

        layout.addWidget(SectionHeader("Proxies individuais", "Serviços locais OpenAI-compatible"))
        grid_host = QWidget()
        grid = QGridLayout(grid_host)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index, (proxy_id, name, port, suffix) in enumerate(PROXY_CARDS):
            grid.addWidget(self._proxy_card(proxy_id, name, port, suffix), index // 2, index % 2)
        grid.setColumnStretch(0, 1)
        grid.setColumnStretch(1, 1)
        layout.addWidget(grid_host)

        batch = QHBoxLayout()
        batch.setSpacing(8)
        for aid, label in (
            ("ai.proxies", "Instalar tudo"),
            ("ai.proxies-start-all", "Iniciar todos"),
            ("ai.proxies-stop-all", "Parar todos"),
            ("ai.proxies-test", "Testar todos"),
            ("ai.proxies-login-all", "Login em todos"),
        ):
            button = self._action_button(aid, label)
            if button is not None:
                batch.addWidget(button)
        batch.addStretch()
        layout.addLayout(batch)

        auth_box = QGroupBox("Autenticação OAuth / credenciais")
        auth_layout = QVBoxLayout(auth_box)
        for proxy_id, name, _port, _suffix in PROXY_CARDS:
            row = QHBoxLayout()
            dot = QLabel("●")
            dot.setObjectName("pillDot")
            _set_state(dot, "info")
            title = QLabel(name)
            title.setObjectName("cardTitle")
            detail = QLabel("Verificando…")
            detail.setObjectName("cardDescription")
            row.addWidget(dot)
            row.addWidget(title)
            row.addWidget(detail, 1)
            login_button = self._action_button(LOGIN_ACTIONS.get(proxy_id, ""), "Abrir navegador")
            if login_button is not None:
                row.addWidget(login_button)
            auth_layout.addLayout(row)
            self._auth_rows[proxy_id] = (dot, detail)
        layout.addWidget(auth_box)

        ide_box = QGroupBox("Integração com IDEs e agentes")
        ide_layout = QVBoxLayout(ide_box)
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
            ide_layout.addLayout(row)
            self._ide_values[key] = value
        sync_row = QHBoxLayout()
        sync_row.addStretch()
        sync_button = self._action_button("ai.proxies-ides", "Configurar proxies nas IDEs")
        if sync_button is not None:
            sync_row.addWidget(sync_button)
        ide_layout.addLayout(sync_row)
        layout.addWidget(ide_box)

        layout.addStretch()
        scroll.setWidget(inner)
        self._layout.addWidget(scroll)
        self.reload()

    def _gateway_row(self, gateway_id: str, name: str, buttons: tuple[tuple[str, str], ...]) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        row = QHBoxLayout(card)
        row.setContentsMargins(14, 10, 14, 10)
        icon = QLabel()
        icon.setPixmap(themed_icon(card, "network-server", QStyle.SP_DriveNetIcon).pixmap(24, 24))
        icon.setFixedSize(34, 34)
        row.addWidget(icon)
        dot = QLabel("●")
        dot.setObjectName("pillDot")
        _set_state(dot, "info")
        title = QLabel(name)
        title.setObjectName("cardTitle")
        status = QLabel("Verificando…")
        status.setObjectName("cardDescription")
        detail = QLabel("")
        detail.setObjectName("cardDescription")
        row.addWidget(dot)
        row.addWidget(title)
        row.addWidget(status)
        row.addWidget(detail, 1)
        for aid, label in buttons:
            button = self._action_button(aid, label)
            if button is not None:
                row.addWidget(button)
        self._gateway_rows[gateway_id] = (dot, status, detail)
        return card

    def _proxy_card(self, proxy_id: str, name: str, port: int, suffix: str) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        box = QVBoxLayout(card)
        box.setContentsMargins(14, 10, 14, 10)
        box.setSpacing(4)
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
        service = QLabel("Verificando…")
        service.setObjectName("cardDescription")
        box.addWidget(service)
        # Auth line carries its own colour dot so a running-but-unauthenticated
        # proxy (service dot green, auth pending) is visually unambiguous.
        auth_row = QHBoxLayout()
        auth_row.setSpacing(6)
        auth_dot = QLabel("●")
        auth_dot.setObjectName("pillDot")
        _set_state(auth_dot, "info")
        auth = QLabel("")
        auth.setObjectName("cardDescription")
        auth.setWordWrap(True)
        auth_row.addWidget(auth_dot, 0, Qt.AlignTop)
        auth_row.addWidget(auth, 1)
        box.addLayout(auth_row)
        controls = QHBoxLayout()
        controls.setSpacing(8)
        start = self._action_button(f"ai.proxies-start-{suffix}", "Iniciar")
        if start is not None:
            # Make the Start/Authenticate distinction explicit at the point of
            # action: Start only brings the systemd service up, it never logs in.
            start.setToolTip("Sobe o serviço systemd do proxy. Não abre o navegador nem autentica — use “Autenticar” para o login OAuth.")
        stop = self._action_button(f"ai.proxies-stop-{suffix}", "Parar")
        # Browser-session proxies get an inline Authenticate button; mimo (env
        # session) does not — its credentials come from its .env file.
        login = self._action_button(LOGIN_ACTIONS.get(proxy_id, ""), "Autenticar")
        for button in (start, stop, login):
            if button is not None:
                controls.addWidget(button)
        controls.addStretch()
        box.addLayout(controls)
        self._cards[proxy_id] = {
            "dot": dot, "service": service, "auth": auth,
            "auth_dot": auth_dot, "start": start, "stop": stop, "login": login,
        }
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

    @staticmethod
    def _style_login_button(button: QPushButton, state: ProxyState) -> None:
        """Adapt the per-card Authenticate button to the proxy's auth state."""
        status = state.auth_status
        if not state.installed:
            enabled, text, emphasis = False, "Autenticar", "secondaryButton"
            tooltip = "Instale o proxy antes de autenticar."
        elif status == "login-running":
            enabled, text, emphasis = False, "Login em andamento…", "secondaryButton"
            tooltip = "Uma janela de login já está aberta. Conclua o OAuth no navegador."
        elif status == "authenticated":
            enabled, text, emphasis = True, "Reautenticar", "secondaryButton"
            tooltip = "Sessão válida. Reabra o navegador para renovar o login, se necessário."
        elif status == "gui-required":
            enabled, text, emphasis = False, "Autenticar", "secondaryButton"
            tooltip = "Requer sessão gráfica (DISPLAY/WAYLAND) para abrir o navegador."
        elif status in _LOGIN_PENDING:
            enabled, text, emphasis = True, "Autenticar", "primaryButton"
            tooltip = "Abre o navegador para o login OAuth e salva a sessão do proxy."
        else:
            enabled, text, emphasis = True, "Autenticar", "secondaryButton"
            tooltip = "Abre o navegador para o login OAuth e salva a sessão do proxy."
        button.setEnabled(enabled)
        button.setText(text)
        button.setToolTip(tooltip)
        if button.objectName() != emphasis:
            button.setObjectName(emphasis)
            button.style().unpolish(button)
            button.style().polish(button)

    # ----------------------------------------------------------------- status
    def reload(self) -> None:
        super().reload()
        if not self.status_loader.running(_DETAILED_KEY):
            self.status_loader.fetch(_DETAILED_KEY, ["ai", "proxies", "detailed-status"])
        for aid in ("ai.hermes-status", "ai.9router-status", "ai.odysseus-status"):
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

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
        if not running and self.isVisible():
            self.reload()

    def _proxy_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id == _DETAILED_KEY:
            proxies, ide = parse_detailed_status(parsed)
            self._apply_proxies(proxies)
            self._apply_ide(ide)
        elif action_id == "ai.hermes-status":
            self._apply_gateway(parse_gateway_status("hermes", parsed))
        elif action_id == "ai.9router-status":
            self._apply_gateway(parse_gateway_status("9router", parsed))
        elif action_id == "ai.odysseus-status":
            self._apply_gateway(parse_gateway_status("odysseus", parsed))

    def _proxy_status_failed(self, action_id: str, message: str) -> None:
        if action_id == _DETAILED_KEY:
            for refs in self._cards.values():
                service = refs.get("service")
                if isinstance(service, QLabel):
                    service.setText(f"Status indisponível — {message}")
        elif action_id in ("ai.hermes-status", "ai.9router-status", "ai.odysseus-status"):
            gateway_id = {"ai.hermes-status": "hermes", "ai.9router-status": "9router", "ai.odysseus-status": "odysseus"}[action_id]
            refs = self._gateway_rows.get(gateway_id)
            if refs is not None:
                refs[1].setText("Status indisponível")
                _set_state(refs[0], "error")

    def _apply_gateway(self, state: GatewayState) -> None:
        refs = self._gateway_rows.get(state.id)
        if refs is None:
            return
        dot, status, detail = refs
        _set_state(dot, state.state)
        status.setText(state.label)
        detail.setText(state.detail)

    def _apply_proxies(self, proxies: dict[str, ProxyState]) -> None:
        for proxy_id, refs in self._cards.items():
            state = proxies.get(proxy_id)
            dot = refs.get("dot")
            service = refs.get("service")
            auth = refs.get("auth")
            auth_dot = refs.get("auth_dot")
            start = refs.get("start")
            stop = refs.get("stop")
            login = refs.get("login")
            if state is None:
                if isinstance(service, QLabel):
                    service.setText("Sem dados")
                continue
            if isinstance(dot, QLabel):
                _set_state(dot, "success" if state.running else "warning" if state.installed else "error")
            if isinstance(service, QLabel):
                service.setText(f"Serviço: {state.service_label}")
            if isinstance(auth_dot, QLabel):
                _set_state(auth_dot, state.auth_state)
            if isinstance(auth, QLabel):
                extra = f" — falta: {', '.join(state.auth_missing)}" if state.auth_missing else ""
                auth.setText(f"Auth: {state.auth_label}{extra}")
            if isinstance(start, QPushButton):
                start.setEnabled(state.installed and not state.running)
            if isinstance(stop, QPushButton):
                stop.setEnabled(state.installed and state.running)
            if isinstance(login, QPushButton):
                self._style_login_button(login, state)
        for proxy_id, (dot, detail) in self._auth_rows.items():
            state = proxies.get(proxy_id)
            if state is None:
                detail.setText("Sem dados")
                continue
            _set_state(dot, state.auth_state)
            extra = f" — falta: {', '.join(state.auth_missing)}" if state.auth_missing else ""
            detail.setText(state.auth_label + extra)

    def _apply_ide(self, ide: IdeIntegrationState) -> None:
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
