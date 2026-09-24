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
