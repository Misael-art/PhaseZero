"""Estado persistente do motor de temas.

Regras:
- Lock cross-process atômico (fcntl) sobre toda mutação.
- IDs persistentes e tokens de confirmação.
- TTL para planos e previews.
- Ownership ledger: só arquivos registrados como `phasezero-managed` são
  tocados por rollback/uninstall.
- Diretório redirecionável por env para testes herméticos.
"""

from __future__ import annotations

import json
import os
import secrets
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

from . import SCHEMA

LOCK_TIMEOUT_SECONDS = 30
PLAN_TTL_SECONDS = 24 * 60 * 60
PREVIEW_TTL_SECONDS = 15

_RETENTION = {"plans": 50, "operations": 100, "rollbacks": 100, "previews": 50, "snapshots": 200}


class ThemesLockTimeout(RuntimeError):
    pass


def root() -> Path:
    override = os.environ.get("PZ_THEMES_STATE_DIR")
    if override:
        path = Path(override).expanduser()
    else:
        xdg = os.environ.get("XDG_STATE_HOME")
        base = Path(xdg) if xdg else Path.home() / ".local" / "state"
        path = base / "phasezero" / "themes"
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass
    return path


@contextmanager
def lock(timeout: float = LOCK_TIMEOUT_SECONDS) -> Iterator[None]:
    """Lock exclusivo cross-process sobre o estado de temas."""
    path = root() / ".lock"
    handle = open(path, "a+", encoding="utf-8")
    try:
        try:
            import fcntl
        except ImportError:  # pragma: no cover - plataformas sem fcntl
            yield
            return
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise ThemesLockTimeout("estado de temas ocupado por outro processo") from None
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def new_id(prefix: str) -> str:
    return f"{prefix}-{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(4)}"


def token() -> str:
    return secrets.token_hex(12)


def save(kind: str, record_id: str, payload: dict) -> Path:
    directory = root() / kind
    directory.mkdir(mode=0o700, exist_ok=True)
    try:
        os.chmod(directory, 0o700)
    except OSError:
        pass
    path = directory / f"{record_id}.json"
    temporary = path.with_suffix(".json.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
        os.chmod(path, 0o600)
        retained = sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
        for obsolete in retained[_RETENTION.get(kind, 100):]:
            obsolete.unlink(missing_ok=True)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return path


def load(kind: str, record_id: str) -> dict:
    if "/" in record_id or "\\" in record_id or ".." in record_id:
        raise ValueError("ID inválido")
    path = root() / kind / f"{record_id}.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"registro ilegível: {record_id}") from exc


def assert_schema(record: dict, kind: str) -> None:
    if record.get("schema") != SCHEMA or record.get("kind") != kind:
        raise ValueError(f"registro incompatível: {kind}")


def ensure_schema(record: dict, kind: str) -> dict:
    record.setdefault("schema", SCHEMA)
    record.setdefault("kind", kind)
    return record


def expired(record: dict, ttl_seconds: int) -> bool:
    created = int(record.get("createdAt", 0))
    return bool(created) and int(time.time()) - created > ttl_seconds


def ownership_ledger_path() -> Path:
    return root() / "ownership.json"


def ownership() -> dict:
    path = ownership_ledger_path()
    if not path.exists():
        return {"schema": SCHEMA, "entries": []}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"schema": SCHEMA, "entries": []}
    if not isinstance(payload, dict) or not isinstance(payload.get("entries"), list):
        return {"schema": SCHEMA, "entries": []}
    return payload


def record_ownership(entry: dict) -> dict:
    """Registra caminhos gerenciados pelo PhaseZero com a operação de origem."""
    payload = ownership()
    payload["entries"].append({
        "path": entry["path"],
        "operationId": entry["operationId"],
        "createdAt": int(time.time()),
    })
    path = ownership_ledger_path()
    temporary = path.with_suffix(".json.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return payload


def is_owned(path: str) -> bool:
    payload = ownership()
    normalized = str(Path(path).expanduser())
    return any(entry.get("path") == normalized for entry in payload.get("entries", ()))
