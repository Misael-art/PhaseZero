#!/usr/bin/env python3
"""Store central de backups do PhaseZero (contraparte Python de linux/lib/common.sh).

Mantém o mesmo layout do lado bash, para que `pz_backup_latest`,
`migrate_legacy_baks` e o `host wipe` enxerguem os dois lados:

    $PZ_STATE/backups/<sha256 do path original>/<basename>.bak.<epoch-ns>
    $PZ_STATE/backups/<sha256 do path original>/origin

Backup NUNCA fica ao lado do arquivo original.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path

__all__ = ["state_dir", "backup_root", "backup_file", "latest_backup", "ledger_record"]


def state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return Path(base) / "phasezero"


def backup_root() -> Path:
    override = os.environ.get("PZ_BACKUP_ROOT")
    if override:
        return Path(override)
    return state_dir() / "backups"


def _key(path: Path) -> str:
    # os.path.abspath (não resolve()): igual ao `realpath -m` do lado bash,
    # que não segue symlinks nem exige que o path exista.
    real = os.path.abspath(str(path))
    return hashlib.sha256(real.encode("utf-8")).hexdigest()


def backup_dir_for(path: Path) -> Path:
    return backup_root() / _key(path)


def backup_file(path: Path, module: str = "emulation", dry_run: bool = False) -> Path | None:
    """Copia <path> para o store central. Devolve o path do backup, ou None."""
    path = Path(path)
    if not path.exists():
        return None
    target_dir = backup_dir_for(path)
    dest = target_dir / f"{path.name}.bak.{time.time_ns()}"
    if dry_run:
        return dest
    target_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(target_dir, 0o700)
    except OSError:
        pass
    (target_dir / "origin").write_text(os.path.abspath(str(path)) + "\n", encoding="utf-8")
    shutil.copy2(path, dest)
    ledger_record(
        module=module,
        action="backup",
        modified=[os.path.abspath(str(path))],
        backups=[str(dest)],
        reversible=True,
        rollback_cmd=f"cp -p -- {dest} {os.path.abspath(str(path))}",
    )
    return dest


def latest_backup(path: Path) -> Path | None:
    """Backup mais recente com dual-read: store central, depois legado."""
    path = Path(path)
    target_dir = backup_dir_for(path)
    candidates: list[Path] = []
    if target_dir.is_dir():
        candidates = [p for p in target_dir.glob("*.bak.*") if p.is_file()]
    if not candidates and path.parent.is_dir():
        candidates = [
            p
            for p in path.parent.glob(f"{path.name}.bak.*")
            if p.is_file()
        ] + [
            p
            for p in path.parent.glob(f"{path.name}.phasezero.bak.*")
            if p.is_file()
        ]
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def ledger_record(
    *,
    module: str,
    action: str,
    created: list[str] | None = None,
    modified: list[str] | None = None,
    backups: list[str] | None = None,
    services: list[str] | None = None,
    packages: list[str] | None = None,
    scope: str = "user",
    reversible: bool = False,
    rollback_cmd: str = "",
    dry_run: bool = False,
) -> None:
    """Append no mesmo ledger JSONL que linux/lib/ledger.sh grava.

    Nunca levanta: um ledger indisponível não pode derrubar a operação que
    já mutou o host.
    """
    if dry_run or os.environ.get("PZ_DRY_RUN") == "1":
        return
    entry = {
        "operation_id": os.environ.get("PZ_OPERATION_ID", "unknown"),
        "module": module,
        "action": action,
        "timestamp": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "created": created or [],
        "modified": modified or [],
        "backups": backups or [],
        "services": services or [],
        "packages": packages or [],
        "scope": scope if scope in ("user", "system") else "user",
        "reversible": bool(reversible),
        "rollback_cmd": rollback_cmd,
    }
    ledger_dir = Path(os.environ.get("PZ_LEDGER_DIR") or (state_dir() / "ledger"))
    ledger_file = Path(os.environ.get("PZ_LEDGER_FILE") or (ledger_dir / "ledger.jsonl"))
    try:
        ledger_dir.mkdir(parents=True, exist_ok=True)
        with ledger_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        return
