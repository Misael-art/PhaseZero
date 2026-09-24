"""Explicit, per-consumer connection grants. Secrets stay in their owner store."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping

from .account_contract import Connection, Grant


# Consumers may request only declared scopes from declared adapters.
SUPPORTED_CONSUMER_ADAPTERS: dict[str, dict[str, tuple[str, ...]]] = {
    "app.claude-code": {"9router-provider-status": ("inference",)},
    "app.opencode": {"9router-provider-status": ("inference",)},
}


class GrantError(ValueError):
    """Consent request is invalid or consumer cannot use this adapter/scope."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _grant_id(connection_id: str, consumer_id: str) -> str:
    digest = hashlib.sha256(f"{connection_id}\0{consumer_id}".encode()).hexdigest()[:24]
    return f"grant:{digest}"


class GrantLedger:
    """Private local consent ledger; ``support`` maps consumer -> adapter -> scopes."""

    SCHEMA_VERSION = 1

    def __init__(self, path: Path | None = None):
        self.path = path
        self._grants: dict[str, Grant] = {}
        if path is not None and path.exists():
            self._load()

    def grant(
        self,
        connection: Connection,
        consumer_id: str,
        scopes: tuple[str, ...],
        *,
        support: Mapping[str, Mapping[str, tuple[str, ...]]],
        consented: bool,
    ) -> Grant:
        if not consented:
            raise GrantError("explicit user consent required")
        if not consumer_id or not connection.connection_id:
            raise GrantError("consumer and connection IDs required")
        if not connection.enabled:
            raise GrantError("connection is disabled")
        requested = tuple(sorted(set(scopes)))
        if not requested or any(not scope or not scope.strip() for scope in requested):
            raise GrantError("at least one valid scope required")
        supported_scopes = support.get(consumer_id, {}).get(connection.adapter_id)
        if supported_scopes is None:
            raise GrantError("consumer does not support this connection adapter")
        unsupported = sorted(set(requested) - set(supported_scopes))
        if unsupported:
            raise GrantError("consumer does not support requested scopes: " + ", ".join(unsupported))

        grant_id = _grant_id(connection.connection_id, consumer_id)
        previous = self._grants.get(grant_id)
        if previous and previous.enabled and previous.scopes == requested:
            return previous
        grant = Grant(grant_id, connection.connection_id, consumer_id, requested,
                      enabled=True, consented_at=_now())
        self._grants[grant_id] = grant
        self._save()
        return grant

    def revoke(self, grant_id: str) -> Grant | None:
        grant = self._grants.get(grant_id)
        if grant is None or not grant.enabled:
            return grant
        revoked = Grant(grant.grant_id, grant.connection_id, grant.consumer_id,
                        grant.scopes, enabled=False,
                        consented_at=grant.consented_at, revoked_at=_now())
        self._grants[grant_id] = revoked
        self._save()
        return revoked

    def for_consumer(self, consumer_id: str) -> tuple[Grant, ...]:
        return tuple(sorted((g for g in self._grants.values()
                             if g.consumer_id == consumer_id and g.enabled),
                            key=lambda g: g.grant_id))

    def _load(self) -> None:
        assert self.path is not None
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        if raw.get("schemaVersion") != self.SCHEMA_VERSION or not isinstance(raw.get("grants"), list):
            raise GrantError("unsupported grant ledger schema")
        for item in raw["grants"]:
            grant = Grant(
                grant_id=str(item["grantId"]),
                connection_id=str(item["connectionId"]),
                consumer_id=str(item["consumerId"]),
                scopes=tuple(str(scope) for scope in item["scopes"]),
                enabled=bool(item["enabled"]),
                consented_at=str(item.get("consentedAt", "")),
                revoked_at=str(item.get("revokedAt", "")),
            )
            if grant.grant_id != _grant_id(grant.connection_id, grant.consumer_id):
                raise GrantError("invalid grant identity")
            self._grants[grant.grant_id] = grant

    def _save(self) -> None:
        if self.path is None:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.path.parent, 0o700)
        payload = {
            "schemaVersion": self.SCHEMA_VERSION,
            "grants": [
                {"grantId": g.grant_id, "connectionId": g.connection_id,
                 "consumerId": g.consumer_id, "scopes": list(g.scopes),
                 "enabled": g.enabled, "consentedAt": g.consented_at,
                 "revokedAt": g.revoked_at}
                for g in sorted(self._grants.values(), key=lambda x: x.grant_id)
            ],
        }
        fd, temp_name = tempfile.mkstemp(prefix=".grants-", dir=self.path.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(payload, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_name, self.path)
            os.chmod(self.path, 0o600)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)
