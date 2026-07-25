from __future__ import annotations

import json
import os
import secrets
import time
from pathlib import Path


def state_root() -> Path:
    override = os.environ.get("PZ_LIBRARY_STATE_DIR")
    if override:
        return Path(override).expanduser()
    xdg = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(xdg) / "phasezero" / "emulation-library"


def _record_dir(kind: str) -> Path:
    directory = state_root() / kind
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    return directory


def new_id(prefix: str) -> str:
    return f"{prefix}-{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(4)}"


def new_token() -> str:
    return secrets.token_hex(8)


_ID_KINDS = {"scan": "scans", "plan": "plans", "op": "operations"}


def _path_for(record_id: str) -> Path:
    prefix = record_id.split("-", 1)[0]
    kind = _ID_KINDS.get(prefix)
    if kind is None:
        raise ValueError(f"unknown record id: {record_id}")
    if "/" in record_id or "\\" in record_id or ".." in record_id:
        raise ValueError(f"invalid record id: {record_id}")
    return _record_dir(kind) / f"{record_id}.json"


def save_record(record_id: str, payload: dict) -> Path:
    path = _path_for(record_id)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=1)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    return path


def load_record(record_id: str) -> dict:
    path = _path_for(record_id)
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)
