from __future__ import annotations

import shutil
from pathlib import Path

from . import SCHEMA, registry, state, vita


def _free_bytes(path: Path) -> int:
    probe = path
    while not probe.exists():
        parent = probe.parent
        if parent == probe:
            break
        probe = parent
    try:
        return shutil.disk_usage(probe).free
    except OSError:
        return 0


def _plan_install(item: dict) -> dict:
    info = item.get("vita") or {}
    title_id = info.get("titleId") or ""
    emulator = vita.detect_vita3k()
    app_dir = vita.installed_app_dir(emulator, title_id) if title_id else None
    required = int(item.get("sizeBytes") or 0) * 2  # staging + published copy
    blockers: list[str] = []
    if not emulator.installed:
        blockers.append("Vita3K não encontrado; instale o emulador primeiro")
    if app_dir is None:
        blockers.append("pref-path do Vita3K não localizado")
    elif app_dir.exists():
        blockers.append(f"já instalado em {app_dir}")
    elif required and _free_bytes(app_dir.parent) < required:
        blockers.append("espaço em disco insuficiente para staging + instalação")
    action = {
        "action": "install",
        "path": item["path"],
        "system": item.get("system"),
        "destinationEmulator": "vita3k",
        "titleId": title_id or None,
        "installDir": str(app_dir) if app_dir else None,
        "estimatedBytes": required,
        "sourcePreserved": True,
        "reversible": True,
        "executable": not blockers,
        "blockers": blockers,
        "expectedResult": (
            f"aplicação {title_id} disponível em ux0/app/{title_id}; "
            "ZIP original preservado"
        ),
    }
    return action


def _plan_convert(item: dict) -> dict:
    return {
        "action": "convert",
        "path": item["path"],
        "system": item.get("system"),
        "targetFormat": item.get("targetFormat"),
        "sourcePreserved": True,
        "executable": False,
        "delegate": "romopt",
        "delegateCommand": [
            "pz", "emulation", "rom-optimize",
            str(Path(item["path"]).parent),
            "--platform", str(item.get("system")),
            "--dry-run",
        ],
        "blockers": [
            "conversões executam pelo alias rom-optimize nesta versão"
        ],
    }


def run(scan_id: str) -> dict:
    try:
        scan_record = state.load_record(scan_id)
    except (OSError, ValueError) as exc:
        return {
            "schema": SCHEMA, "kind": "plan", "status": "fail",
            "error": f"scan não encontrado: {exc}",
        }

    actions: list[dict] = []
    for item in scan_record.get("items", []):
        transform = item.get("transform")
        if transform == registry.TRANSFORM_INSTALL:
            actions.append(_plan_install(item))
        elif transform == registry.TRANSFORM_CONVERT:
            actions.append(_plan_convert(item))
        elif item.get("state") == registry.STATE_BLOCKED:
            actions.append({
                "action": "blocked",
                "path": item["path"],
                "system": item.get("system"),
                "executable": False,
                "blockers": [item.get("recommendation") or "bloqueado"],
            })
        else:
            actions.append({
                "action": "none",
                "path": item["path"],
                "system": item.get("system"),
                "executable": False,
                "state": item.get("state"),
            })

    executable = [action for action in actions if action.get("executable")]
    plan_id = state.new_id("plan")
    token = state.new_token()
    payload = {
        "schema": SCHEMA,
        "kind": "plan",
        "status": "ok",
        "planId": plan_id,
        "scanId": scan_id,
        "confirmToken": token,
        "summary": {
            "actions": len(actions),
            "executable": len(executable),
            "installs": sum(a["action"] == "install" for a in executable),
            "estimatedBytes": sum(
                int(a.get("estimatedBytes") or 0) for a in executable
            ),
        },
        "actions": actions,
    }
    state.save_record(plan_id, payload)
    return payload
