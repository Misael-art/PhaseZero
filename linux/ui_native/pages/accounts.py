from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox, QFrame, QHBoxLayout, QLabel, QMessageBox, QPushButton, QRadioButton,
    QScrollArea, QVBoxLayout, QWidget,
)

from linux.ai.account_adapters import adapt_account_sources
from linux.ai.account_contract import Account, Connection, Evidence, public_account, redacted_summary
from linux.ai.grants import GrantError, GrantLedger, SUPPORTED_CONSUMER_ADAPTERS

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..preferences import UiPreferences
from ..widgets import SectionHeader
from .base import BasePage


_SOURCES = ("claude", "proxies", "router-providers", "router-status")
_SOURCE_LABELS = {
    "claude": "Claude",
    "proxies": "Proxies IA",
    "router-providers": "Provedores 9Router",
    "router-status": "Saúde 9Router",
}
_CONSUMER_LABELS = {
    "app.claude-code": "Claude Code",
    "app.opencode": "OpenCode",
}


def _grant_ledger_path() -> Path:
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return data_home / "phasezero" / "ai-accounts" / "grants.json"


class AccountsPage(BasePage):
    """Private account view built from read-only status adapters."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._generation = 0
        self._pending: set[str] = set()
        self._results: dict[str, object] = {}
        self._outcomes: dict[str, str] = {}
        self._accounts: tuple[tuple[Account, Connection], ...] = ()
        self._selected_by_provider: dict[str, str] = {}
        self._radios_by_provider: dict[str, list[tuple[str, QRadioButton]]] = {}
        self._cards_layout: QVBoxLayout | None = None
        self.summary: QLabel | None = None
        self._probe_ids: dict[str, tuple[int, str]] = {}
        self._grant_load_error = False
        self.preferences = UiPreferences(self)
        self._privacy_toggle: QCheckBox | None = None
        try:
            self.grant_ledger = GrantLedger(_grant_ledger_path())
        except (OSError, ValueError, TypeError):
            self.grant_ledger = GrantLedger()
            self._grant_load_error = True

    @property
    def redacted_export(self) -> dict[str, object]:
        return redacted_summary(tuple(connection for _account, connection in self._accounts))

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader(
            "Contas e conexões",
            "Identidade aparece só nesta tela privada. Status sem prova continua desconhecido.",
        ))
        row = QHBoxLayout()
        self.summary = QLabel("Ainda não verificado")
        self.summary.setObjectName("accountsSummary")
        row.addWidget(self.summary, 1)
        refresh = QPushButton("Atualizar status")
        refresh.setObjectName("refreshAccounts")
        refresh.clicked.connect(self.refresh_accounts)
        row.addWidget(refresh)
        layout.addLayout(row)
        self._privacy_toggle = QCheckBox("Ocultar identidade das contas")
        self._privacy_toggle.setObjectName("hideAccountIdentity")
        self._privacy_toggle.setAccessibleName("Ocultar identidade das contas nesta tela")
        self._privacy_toggle.setChecked(self.preferences.hide_account_identity)
        self._privacy_toggle.toggled.connect(self._set_identity_hidden)
        layout.addWidget(self._privacy_toggle)
        cards = QWidget()
        self._cards_layout = QVBoxLayout(cards)
        self._cards_layout.setContentsMargins(0, 0, 0, 0)
        self._cards_layout.setSpacing(8)
        layout.addWidget(cards)
        privacy = QLabel("Esta tela privada mostra nomes e estado. Relatórios redigidos incluem só contagens; IDs e referências secretas não são exportados.")
        privacy.setObjectName("accountsPrivacy")
        privacy.setWordWrap(True)
        layout.addWidget(privacy)
        layout.addStretch()
        scroll.setWidget(content)
        self._layout.addWidget(scroll, 1)
        self.status_loader.status_ready.connect(self._source_ready)
        self.status_loader.status_failed.connect(self._source_failed)

    def _set_identity_hidden(self, hidden: bool) -> None:
        self.preferences.set_hide_account_identity(hidden)
        self._render_cards()

    def refresh_accounts(self) -> None:
        self._generation += 1
        generation = self._generation
        self.status_loader.cancel_all()
        self._pending = set(_SOURCES)
        self._results = {}
        self._outcomes = {source: "loading" for source in _SOURCES}
        if self.summary is not None:
            self.summary.setText("Verificando provedores disponíveis…")
        commands = {
            "claude": ["ai", "claude", "status"],
            "proxies": ["ai", "proxies", "detailed-status"],
            "router-providers": ["ai", "9router", "provider", "status"],
            "router-status": ["ai", "9router", "status"],
        }
        self._probe_ids.clear()
        for source, args in commands.items():
            action_id = f"accounts:{generation}:{source}"
            self._probe_ids[action_id] = (generation, source)
            self.status_loader.fetch(action_id, args)

    def _source_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        identity = self._probe_ids.get(action_id)
        if identity is None or identity[0] != self._generation:
            return
        _generation, source = identity
        self._results[source] = parsed
        self._outcomes[source] = "ok" if isinstance(parsed, dict) else "invalid"
        self._pending.discard(source)
        self._render_if_ready()

    def _source_failed(self, action_id: str, _message: str) -> None:
        identity = self._probe_ids.get(action_id)
        if identity is None or identity[0] != self._generation:
            return
        _generation, source = identity
        self._outcomes[source] = "unavailable"
        self._pending.discard(source)
        self._render_if_ready()

    def _render_if_ready(self) -> None:
        if self._pending:
            return
        observed_at = datetime.now(timezone.utc).isoformat()
        proxy_payload = self._results.get("proxies")
        proxies = proxy_payload.get("proxies", []) if isinstance(proxy_payload, dict) else []
        router_payload = self._results.get("router-providers")
        router_status = self._results.get("router-status")
        router_health = Evidence(source="9router-health", observed_at=observed_at)
        if isinstance(router_status, dict) and isinstance(router_status.get("healthy"), bool):
            router_health = Evidence(
                "yes" if router_status["healthy"] else "no",
                "9router-health", observed_at,
            )
        try:
            self._accounts = adapt_account_sources(
                {
                    "claude": self._results.get("claude"),
                    "proxies": proxies if isinstance(proxies, list) else [],
                    "routerProviders": router_payload,
                },
                host_id="local", router_health=router_health, observed_at=observed_at,
            )
        except (TypeError, ValueError):
            self._accounts = ()
            self._outcomes["adapters"] = "invalid"
        self._render_cards()
        if self.summary is not None:
            unavailable = [
                _SOURCE_LABELS[source] for source in _SOURCES
                if self._outcomes.get(source) != "ok"
            ]
            if self._outcomes.get("adapters") == "invalid":
                unavailable.append("adaptação de status")
            if unavailable:
                self.summary.setText(
                    f"Consulta parcial · {len(self._accounts)} registros conhecidos · "
                    f"sem resposta: {', '.join(unavailable)}"
                )
            else:
                self.summary.setText(f"Consulta concluída · {len(self._accounts)} registros conhecidos")

    def _render_cards(self) -> None:
        if self._cards_layout is None:
            return
        while self._cards_layout.count():
            item = self._cards_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()
        self._radios_by_provider.clear()
        for index, (account, connection) in enumerate(self._accounts, start=1):
            public = public_account(account)
            hidden = self.preferences.hide_account_identity
            display_name = f"Conta {index}" if hidden else str(
                public.get("displayName") or public.get("nickname") or "Conta"
            )
            workspace = "workspace oculto" if hidden else str(
                public.get("workspace") or "workspace não informado"
            )
            card = QFrame()
            card.setObjectName("accountCard")
            row = QHBoxLayout(card)
            initials = "?" if hidden else self._initials(display_name)
            avatar = QLabel(initials)
            avatar.setObjectName("accountAvatarInitials")
            avatar.setAlignment(Qt.AlignCenter)
            avatar.setFixedSize(48, 48)
            row.addWidget(avatar)
            details = QVBoxLayout()
            name = QLabel(display_name)
            name.setObjectName("accountDisplayName")
            provider = QLabel(f"{account.provider} · {workspace}")
            provider.setObjectName("accountProvider")
            state = QLabel(self._connection_state(connection))
            state.setObjectName("accountEvidence")
            for label in (name, provider, state):
                label.setWordWrap(True)
                details.addWidget(label)
            row.addLayout(details, 1)
            select = QRadioButton("Selecionar nesta tela")
            select.setAccessibleName(f"Selecionar {name.text()} ({account.provider})")
            select.setChecked(self._selected_by_provider.get(account.provider) == account.account_id)
            select.toggled.connect(
                lambda checked, provider_id=account.provider, account_id=account.account_id:
                self._select_account(provider_id, account_id, checked)
            )
            self._radios_by_provider.setdefault(account.provider, []).append((account.account_id, select))
            row.addWidget(select)
            self._cards_layout.addWidget(card)
            compatible_consumers = [
                consumer for consumer, adapters in SUPPORTED_CONSUMER_ADAPTERS.items()
                if connection.adapter_id in adapters
            ]
            if compatible_consumers:
                if self._grant_load_error:
                    unavailable = QLabel("Autorizações indisponíveis · ledger local inválido")
                    unavailable.setObjectName("accountGrantUnavailable")
                    unavailable.setWordWrap(True)
                    self._cards_layout.addWidget(unavailable)
                    continue
                access_note = QLabel(
                    "Registra consentimento de inferência por app. Sessões ainda não aplicam "
                    "este grant; custos e limites seguem o provedor desta conexão."
                )
                access_note.setObjectName("accountGrantScopeNote")
                access_note.setWordWrap(True)
                self._cards_layout.addWidget(access_note)
                for consumer_id in compatible_consumers:
                    active = next((grant for grant in self.grant_ledger.for_consumer(consumer_id)
                                   if grant.connection_id == connection.connection_id), None)
                    action = QPushButton(
                        f"Revogar uso em {_CONSUMER_LABELS[consumer_id]}" if active else
                        "Conexão desativada" if not connection.enabled else
                        f"Permitir uso em {_CONSUMER_LABELS[consumer_id]}"
                    )
                    action.setObjectName("accountConsumerGrant")
                    action.setAccessibleName(action.text())
                    action.setEnabled(bool(active) or connection.enabled)
                    if not connection.enabled and not active:
                        action.setToolTip("Ative esta conexão no 9Router antes de autorizar o uso.")
                    action.clicked.connect(
                        lambda _checked=False, conn=connection, cid=consumer_id:
                        self._toggle_grant(conn, cid)
                    )
                    self._cards_layout.addWidget(action)

    def _toggle_grant(self, connection: Connection, consumer_id: str) -> None:
        current = next((grant for grant in self.grant_ledger.for_consumer(consumer_id)
                        if grant.connection_id == connection.connection_id), None)
        if current is not None:
            self.grant_ledger.revoke(current.grant_id)
            self._render_cards()
            return
        if not self._confirm_grant(consumer_id):
            return
        try:
            self.grant_ledger.grant(
                connection, consumer_id, ("inference",),
                support=SUPPORTED_CONSUMER_ADAPTERS, consented=True,
            )
        except GrantError as exc:
            QMessageBox.warning(self, "Conexão incompatível", str(exc))
            return
        self._render_cards()

    def _confirm_grant(self, consumer_id: str) -> bool:
        label = _CONSUMER_LABELS[consumer_id]
        answer = QMessageBox.question(
            self, "Permitir uso da conexão?",
            f"{label} poderá enviar solicitações de inferência por esta conexão. "
            "O provedor pode cobrar ou aplicar limites da conta.",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No,
        )
        return answer == QMessageBox.Yes

    def _select_account(self, provider: str, account_id: str, checked: bool) -> None:
        if checked:
            self._selected_by_provider[provider] = account_id
            for other_id, other_radio in self._radios_by_provider.get(provider, []):
                if other_id != account_id and other_radio.isChecked():
                    other_radio.setChecked(False)
        elif self._selected_by_provider.get(provider) == account_id:
            self._selected_by_provider.pop(provider, None)

    @staticmethod
    def _initials(name: str) -> str:
        parts = [part for part in name.split() if part]
        return "".join(part[0].upper() for part in parts[:2]) or "?"

    @staticmethod
    def _connection_state(connection: Connection) -> str:
        return " · ".join((
            f"credencial {connection.credential.state}",
            f"sessão {connection.session.state}",
            f"serviço {connection.service.state}",
            f"acesso {connection.access.state}",
        ))

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)

    def hideEvent(self, event) -> None:
        self._generation += 1
        self.status_loader.cancel_all()
        self._pending.clear()
        super().hideEvent(event)
