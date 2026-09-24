"""PXA-006 account evidence contract. No credential material belongs here.

Adapters may populate this contract only from explicit evidence. A local file,
an HTTP timeout and a backend that could not start all mean different things.
The existing redacted auth registry remains a separate v1 summary.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import datetime
from typing import Awaitable, Callable


STATES = frozenset({"yes", "no", "unknown"})
ERRORS = frozenset({"none", "expired", "unauthorized", "timeout", "backend-unavailable", "network", "unknown"})


@dataclass(frozen=True)
class Evidence:
    state: str = "unknown"
    source: str = "unknown"
    observed_at: str = ""
    verified_at: str = ""
    expires_at: str = ""
    error: str = "none"

    def __post_init__(self) -> None:
        if self.state not in STATES or self.error not in ERRORS:
            raise ValueError("invalid account evidence")
        if self.verified_at and not self.observed_at:
            raise ValueError("verified evidence needs observation time")
        for value in (self.observed_at, self.verified_at, self.expires_at):
            if value:
                datetime.fromisoformat(value.replace("Z", "+00:00"))
        if self.error in {"timeout", "backend-unavailable", "network", "unknown"} and self.state != "unknown":
            raise ValueError("probe failure cannot prove a negative state")


@dataclass(frozen=True)
class Quota:
    dimension: str
    unit: str
    remaining: float | None = None
    total: float | None = None
    reset_at: str = ""
    source: str = "unknown"  # official | local_estimate | unknown
    observed_at: str = ""

    def __post_init__(self) -> None:
        if self.source not in {"official", "local_estimate", "unknown"}:
            raise ValueError("invalid quota source")
        if self.remaining is not None and self.remaining < 0:
            raise ValueError("negative quota")
        if self.total is not None and self.total < 0:
            raise ValueError("negative quota total")
        if self.source == "unknown" and (self.remaining is not None or self.total is not None):
            raise ValueError("unknown quota cannot invent numbers")

    @property
    def display(self) -> str:
        return "não informada" if self.remaining is None else f"{self.remaining:g} {self.unit} restantes"


@dataclass(frozen=True)
class Account:
    account_id: str
    provider: str
    nickname: str
    workspace: str = ""
    display_name: str = ""
    avatar_ref: str = ""
    secret_ref: str = ""

    def __post_init__(self) -> None:
        if not self.account_id or not self.provider or not self.nickname:
            raise ValueError("account requires opaque ID, provider and nickname")
        if any(marker in self.secret_ref.lower() for marker in ("token=", "password=", "sk-")):
            raise ValueError("secret_ref must be a store reference, not a secret")


@dataclass(frozen=True)
class Connection:
    connection_id: str
    account_id: str
    adapter_id: str
    instance_id: str
    enabled: bool = False
    credential: Evidence = field(default_factory=Evidence)
    session: Evidence = field(default_factory=Evidence)
    service: Evidence = field(default_factory=Evidence)
    access: Evidence = field(default_factory=Evidence)
    quota: Quota | None = None

    @property
    def usable(self) -> bool:
        return (self.enabled and self.credential.state == "yes"
                and self.session.state == "yes" and self.service.state == "yes"
                and self.access.state == "yes"
                and (self.quota is None or self.quota.remaining is None or self.quota.remaining > 0))


@dataclass(frozen=True)
class Grant:
    grant_id: str
    connection_id: str
    consumer_id: str
    scopes: tuple[str, ...]
    enabled: bool = False


def public_account(account: Account) -> dict[str, object]:
    """Private UI projection. Diagnostic exports must use redacted_summary."""
    return {"accountId": account.account_id, "provider": account.provider,
            "nickname": account.nickname, "workspace": account.workspace,
            "displayName": account.display_name, "avatarRef": account.avatar_ref}


def redacted_summary(connections: tuple[Connection, ...]) -> dict[str, object]:
    """No identity, avatar, secret reference or per-account ID in logs/exports."""
    return {"schemaVersion": 2, "total": len(connections),
            "enabled": sum(connection.enabled for connection in connections),
            "usable": sum(connection.usable for connection in connections),
            "secretsRedacted": True}


Probe = Callable[[], Awaitable[Evidence]]


async def collect_evidence(probes: dict[str, Probe], *, deadline_s: float = 10.0) -> dict[str, Evidence]:
    """Bound aggregate latency; late probes never overwrite a newer selection.

    Callers keep their own selection generation and only apply the returned
    snapshot if it still matches. Probe implementations must cooperate with
    cancellation; subprocess adapters must terminate child processes.
    """
    if deadline_s <= 0:
        raise ValueError("deadline must be positive")
    async def run(probe: Probe) -> Evidence:
        try:
            value = await probe()
            return value if isinstance(value, Evidence) else Evidence(error="unknown")
        except asyncio.CancelledError:
            raise
        except TimeoutError:
            return Evidence(error="timeout")
        except OSError:
            return Evidence(error="backend-unavailable")
        except Exception:
            return Evidence(error="unknown")

    tasks = {key: asyncio.create_task(run(probe)) for key, probe in probes.items()}
    try:
        done, pending = await asyncio.wait(tasks.values(), timeout=deadline_s)
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        return {key: (task.result() if task in done and not task.cancelled() else Evidence(error="timeout"))
                for key, task in tasks.items()}
    finally:
        for task in tasks.values():
            if not task.done():
                task.cancel()
