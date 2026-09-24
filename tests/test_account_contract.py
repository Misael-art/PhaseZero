from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ai.account_contract import (  # noqa: E402
    Account, Connection, Evidence, Quota, collect_evidence, public_account, redacted_summary,
)
from linux.ai.account_adapters import (  # noqa: E402
    adapt_account_sources, claude_code_account, proxy_auth_account, router_provider_accounts,
)


def test_credential_session_service_and_quota_are_independent():
    found = Evidence("yes", "local-file", "2026-09-24T10:00:00Z")
    unknown = Evidence(error="timeout")
    connection = Connection("c1", "opaque-1", "adapter", "local", True,
                            credential=found, session=unknown, service=found,
                            access=found, quota=Quota("messages", "messages"))
    assert connection.credential.state == "yes"
    assert connection.session.state == "unknown"
    assert connection.quota.display == "não informada"
    assert not connection.usable
    assert Connection(**{**connection.__dict__, "session": Evidence("no", error="unauthorized")}).session.state == "no"
    assert Connection(**{**connection.__dict__, "session": Evidence("no", error="expired")}).session.error == "expired"
    with pytest.raises(ValueError):
        Evidence("no", error="timeout")


def test_private_identity_stays_out_of_redacted_export():
    account = Account("opaque-1", "example", "Trabalho", display_name="Nome Privado",
                      avatar_ref="cache:avatar", secret_ref="keyring:opaque-1")
    assert public_account(account)["displayName"] == "Nome Privado"
    summary = redacted_summary((Connection("c1", account.account_id, "adapter", "local"),))
    assert "Nome Privado" not in str(summary)
    assert "opaque-1" not in str(summary)
    assert "keyring" not in str(summary)


def test_global_deadline_keeps_partial_result_and_cancels_late_probe():
    cancelled = False

    async def fast():
        return Evidence("yes", "explicit-check", "2026-09-24T10:00:00Z",
                        "2026-09-24T10:00:00Z")

    async def slow():
        nonlocal cancelled
        try:
            await asyncio.sleep(1)
        except asyncio.CancelledError:
            cancelled = True
            raise
        return Evidence("yes")

    result = asyncio.run(collect_evidence({"fast": fast, "slow": slow}, deadline_s=0.01))
    assert result["fast"].state == "yes"
    assert result["slow"].state == "unknown"
    assert result["slow"].error == "timeout"
    assert cancelled


def test_claude_adapter_keeps_credential_unknown_and_session_explicit():
    found = claude_code_account({"auth": {"loggedIn": True, "apiProvider": "firstParty"}})
    assert found is not None
    account, connection = found
    assert connection.session.state == "yes"
    assert connection.credential.state == "unknown"
    assert connection.access.state == connection.service.state == "unknown"
    assert account.account_id.startswith("acct:claude:")

    expired = claude_code_account({"auth": {"loggedIn": False, "expired": True}})
    rejected = claude_code_account({"auth": {"loggedIn": False, "httpStatus": 401}})
    timeout = claude_code_account({"auth": {"loggedIn": False, "probeStatus": "timeout"}})
    unavailable = claude_code_account({"auth": {"loggedIn": False, "probeStatus": "backend-unavailable"}})
    assert expired is not None and expired[1].session.error == "expired"
    assert rejected is not None and rejected[1].session.error == "unauthorized"
    assert timeout is not None and timeout[1].session.error == "timeout"
    assert timeout[1].session.state == "unknown"
    assert unavailable is not None and unavailable[1].session.error == "backend-unavailable"


def test_proxy_adapter_distinguishes_artifact_from_live_session():
    present = proxy_auth_account({
        "id": "qwenproxy", "label": "Private Browser Profile",
        "webValidation": {"status": "session-present"}, "service": "active",
    })
    expired = proxy_auth_account({
        "id": "kimiproxy", "credentialStatus": "present", "sessionStatus": "expired",
    })
    unauthorized = proxy_auth_account({
        "id": "deepsproxy", "credentialStatus": "present", "sessionStatus": "401",
    })
    unavailable = proxy_auth_account({
        "id": "mimo-ai-proxy", "credentialStatus": "backend-unavailable",
    })
    assert present is not None
    assert present[1].credential.state == "yes"
    assert present[1].session.state == "unknown"
    assert present[1].service.state == "yes"
    assert expired is not None and expired[1].session.error == "expired"
    assert unauthorized is not None and unauthorized[1].session.error == "unauthorized"
    assert unavailable is not None
    assert unavailable[1].credential.state == "unknown"
    assert unavailable[1].credential.error == "backend-unavailable"


def test_router_provider_adapter_uses_opaque_ids_and_never_infers_credentials():
    rows = router_provider_accounts({"connections": [{
        "id": "db-opaque-73", "provider": "openai", "name": "Private Person",
        "active": True, "status": "success",
    }]})
    assert len(rows) == 1
    account, connection = rows[0]
    assert "db-opaque-73" not in account.account_id
    assert connection.enabled
    assert connection.access.state == "yes"
    assert connection.credential.state == connection.session.state == "unknown"
    summary = redacted_summary((connection,))
    assert "Private Person" not in str(summary)
    assert account.account_id not in str(summary)


def test_account_source_adapter_joins_supported_sources_without_faking_missing_ones():
    results = adapt_account_sources({
        "claude": {"claude": {"auth": {"loggedIn": True, "apiProvider": "firstParty"}}},
        "proxies": [{"id": "qwenproxy", "apiKeyConfigured": True}],
        "routerProviders": {"connections": [{
            "id": "router-id", "provider": "openai", "name": "Private Name",
            "active": True, "status": "success",
        }]},
    })
    assert len(results) == 3
    assert len({account.account_id for account, _ in results}) == 3
    exported = redacted_summary(tuple(connection for _, connection in results))
    assert exported["total"] == 3
    assert "Private Name" not in str(exported)
    assert all(account.account_id not in str(exported) for account, _ in results)
    assert adapt_account_sources({"claude": {"error": "backend-unavailable"}}) == ()
