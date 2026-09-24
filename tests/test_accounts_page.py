from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication, QLabel, QPushButton, QRadioButton


ROOT = Path(__file__).resolve().parents[1]

from linux.ai.account_adapters import router_provider_accounts


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _window(qapp):
    from linux.ui_native.main_window import MainWindow

    host_patcher = patch.object(MainWindow, "_host_summary")
    host_patcher.start()
    return MainWindow(ROOT), host_patcher


def test_accounts_page_keeps_same_provider_accounts_separate_and_rejects_stale_probe(
    qapp, tmp_path, monkeypatch,
):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        assert page is not None
        calls = []
        with patch.object(page.status_loader, "fetch", side_effect=lambda key, args: calls.append((key, args))):
            window.show_category("Contas e conexões")
            assert calls == []  # Opening private view never probes providers.
            page.findChild(QPushButton, "refreshAccounts").click()
            old_claude = next(key for key, _args in calls if key.endswith(":claude"))
            page.refresh_accounts()
            current = {key.rsplit(":", 1)[-1]: key for key, _args in calls[-4:]}
            page.status_loader.status_ready.emit(old_claude, "", {"auth": {"loggedIn": True}})
            assert page.summary.text() == "Verificando provedores disponíveis…"

            page.status_loader.status_ready.emit(
                current["claude"], "", {"auth": {"apiProvider": "anthropic", "loggedIn": True}},
            )
            page.status_loader.status_ready.emit(
                current["proxies"], "", {"proxies": []},
            )
            page.status_loader.status_ready.emit(
                current["router-providers"], "", {"connections": [
                    {"id": "record-a", "provider": "openai", "name": "Account One", "active": True, "status": "success"},
                    {"id": "record-b", "provider": "openai", "name": "Account Two", "active": True, "status": "success"},
                ]},
            )
            page.status_loader.status_ready.emit(
                current["router-status"], "", {"healthy": True},
            )

        openai_cards = [
            card for card in page.findChildren(QRadioButton)
            if "openai" in card.accessibleName()
        ]
        assert len(openai_cards) == 2
        assert all(card.focusPolicy() != Qt.NoFocus for card in openai_cards)
        assert len({account.account_id for account, _connection in page._accounts
                    if account.provider == "openai"}) == 2
        openai_cards[0].click()
        openai_cards[1].click()
        assert not openai_cards[0].isChecked()
        assert openai_cards[1].isChecked()
        assert page._selected_by_provider["openai"] == next(
            account.account_id for account, _connection in page._accounts
            if account.provider == "openai" and account.nickname == "Account Two"
        )

        grant_buttons = page.findChildren(QPushButton, "accountConsumerGrant")
        assert len(grant_buttons) == 4
        assert "Sessões ainda não aplicam" in page.findChild(QLabel, "accountGrantScopeNote").text()
        with patch.object(page, "_confirm_grant", return_value=True):
            grant_buttons[0].click()
        granted = page.grant_ledger.for_consumer("app.claude-code")
        assert len(granted) == 1
        assert granted[0].connection_id == page._accounts[1][1].connection_id
        revoke = next(button for button in page.findChildren(QPushButton, "accountConsumerGrant")
                      if button.text().startswith("Revogar uso"))
        revoke.click()
        assert page.grant_ledger.for_consumer("app.claude-code") == ()

        summary = page.redacted_export
        assert summary == {
            "schemaVersion": 2, "total": 3, "enabled": 2,
            "usable": 0, "secretsRedacted": True,
        }
        assert "Account One" not in json.dumps(summary)
        assert "Account Two" not in json.dumps(summary)

        with patch.object(page.status_loader, "fetch", side_effect=lambda key, args: calls.append((key, args))):
            page.refresh_accounts()
            failed = {key.rsplit(":", 1)[-1]: key for key, _args in calls[-4:]}
            for probe_id in failed.values():
                page.status_loader.status_failed.emit(probe_id, "unavailable")
            assert "Consulta parcial" in page.summary.text()
            assert "sem resposta: Claude" in page.summary.text()
            assert "0 contas" not in page.summary.text()
    finally:
        window.close()
        host_patcher.stop()


def test_account_without_photo_uses_accessible_initials(qapp):
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        assert page._initials("Account Two") == "AT"
        assert page._initials("") == "?"
    finally:
        window.close()
        host_patcher.stop()


def test_invalid_grant_ledger_disables_consent_controls(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    ledger_path = tmp_path / "phasezero" / "ai-accounts" / "grants.json"
    ledger_path.parent.mkdir(parents=True)
    ledger_path.write_text("not-json")
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        assert page._grant_load_error
        account, connection = router_provider_accounts({"connections": [{
            "id": "record-a", "provider": "openai", "name": "Private Account", "active": True,
        }]})[0]
        page._accounts = ((account, connection),)
        page._render_cards()
        assert page.findChildren(QPushButton, "accountConsumerGrant") == []
        assert "ledger local inválido" in page.findChild(QLabel, "accountGrantUnavailable").text()
    finally:
        window.close()
        host_patcher.stop()
