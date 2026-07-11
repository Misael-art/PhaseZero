from __future__ import annotations

import hashlib
import shutil
from pathlib import Path

from . import SCHEMA, state, vita


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _apply_install(action: dict, dry_run: bool) -> dict:
    source = Path(action["path"])
    result = {**action, "status": "pending"}
    if not source.is_file():
        result.update(status="fail", error=f"origem desapareceu: {source}")
        return result

    classification = vita.classify_zip(source)
    if classification.kind != "installable_zip":
        result.update(
            status="fail",
            error=f"origem deixou de ser instalável: {classification.reason}",
        )
        return result
    emulator = vita.detect_vita3k()
    app_dir = vita.installed_app_dir(emulator, classification.title_id)
    if app_dir is None:
        result.update(status="fail", error="pref-path do Vita3K não localizado")
        return result
    if app_dir.exists():
        result.update(status="skip", note=f"já instalado em {app_dir}")
        return result
    if dry_run:
        result.update(
            status="would_install",
            installDir=str(app_dir),
            titleId=classification.title_id,
        )
        return result

    source_hash = _sha256(source)
    try:
        files = vita.install_zip(
            source, classification.root, classification.title_id, app_dir
        )
    except (OSError, ValueError, FileExistsError) as exc:
        result.update(status="fail", error=f"instalação falhou: {exc}")
        return result
    result.update(
        status="installed",
        installDir=str(app_dir),
        titleId=classification.title_id,
        sourceSha256=source_hash,
        files=files,
        installedBytes=sum(record["bytes"] for record in files),
        sourcePreserved=True,
    )
    return result


def run(plan_id: str, confirm: str, dry_run: bool) -> dict:
    try:
        plan_record = state.load_record(plan_id)
    except (OSError, ValueError) as exc:
        return {
            "schema": SCHEMA, "kind": "apply", "status": "fail",
            "error": f"plano não encontrado: {exc}",
        }
    if not dry_run and confirm != plan_record.get("confirmToken"):
        return {
            "schema": SCHEMA, "kind": "apply", "status": "fail",
            "error": "token de confirmação inválido; use o confirmToken do plano",
        }

    results: list[dict] = []
    for action in plan_record.get("actions", []):
        if action.get("action") != "install":
            continue
        if not action.get("executable"):
            results.append({**action, "status": "skip",
                            "note": "; ".join(action.get("blockers", []))})
            continue
        results.append(_apply_install(action, dry_run))

    failed = sum(result["status"] == "fail" for result in results)
    operation_id = state.new_id("op")
    payload = {
        "schema": SCHEMA,
        "kind": "apply",
        "status": "ok" if failed == 0 else "partial" if len(results) > failed else "fail",
        "operationId": operation_id,
        "planId": plan_id,
        "dryRun": dry_run,
        "summary": {
            "attempted": len(results),
            "installed": sum(r["status"] == "installed" for r in results),
            "planned": sum(r["status"] == "would_install" for r in results),
            "skipped": sum(r["status"] == "skip" for r in results),
            "failed": failed,
        },
        "results": results,
    }
    if not dry_run:
        state.save_record(operation_id, payload)
    return payload


def _installed_results(operation: dict) -> list[dict]:
    return [
        result for result in operation.get("results", [])
        if result.get("status") == "installed"
    ]


def verify(operation_id: str) -> dict:
    try:
        operation = state.load_record(operation_id)
    except (OSError, ValueError) as exc:
        return {
            "schema": SCHEMA, "kind": "verify", "status": "fail",
            "error": f"operação não encontrada: {exc}",
        }
    checks: list[dict] = []
    for result in _installed_results(operation):
        install_dir = Path(result["installDir"])
        entry: dict = {
            "titleId": result.get("titleId"),
            "installDir": str(install_dir),
            "launchProbe": "skipped",
        }
        problems: list[str] = []
        if not install_dir.is_dir():
            problems.append("diretório instalado ausente")
        elif not (install_dir / "eboot.bin").is_file():
            problems.append("eboot.bin ausente")
        else:
            for record in result.get("files", []):
                target = install_dir / record["path"]
                if not target.is_file():
                    problems.append(f"arquivo ausente: {record['path']}")
                    break
                if target.stat().st_size != record["bytes"]:
                    problems.append(f"tamanho divergente: {record['path']}")
                    break
                if _sha256(target) != record["sha256"]:
                    problems.append(f"hash divergente: {record['path']}")
                    break
        source = result.get("path")
        if source and not Path(source).is_file():
            problems.append("origem foi removida (deveria estar preservada)")
        entry["status"] = "ok" if not problems else "fail"
        entry["problems"] = problems
        checks.append(entry)
    failed = sum(check["status"] == "fail" for check in checks)
    return {
        "schema": SCHEMA,
        "kind": "verify",
        "status": "ok" if failed == 0 else "fail",
        "operationId": operation_id,
        "checks": checks,
    }


def rollback(operation_id: str) -> dict:
    try:
        operation = state.load_record(operation_id)
    except (OSError, ValueError) as exc:
        return {
            "schema": SCHEMA, "kind": "rollback", "status": "fail",
            "error": f"operação não encontrada: {exc}",
        }
    actions: list[dict] = []
    failed = 0
    for result in _installed_results(operation):
        install_dir = Path(result["installDir"])
        entry = {"titleId": result.get("titleId"), "installDir": str(install_dir)}
        # Only remove paths this operation created, and only under ux0/app.
        if "ux0/app/" not in str(install_dir).replace("\\", "/"):
            entry.update(status="fail", error="caminho fora de ux0/app; recusado")
            failed += 1
        elif not install_dir.exists():
            entry.update(status="skip", note="já removido")
        else:
            try:
                shutil.rmtree(install_dir)
                entry.update(status="removed")
            except OSError as exc:
                entry.update(status="fail", error=str(exc))
                failed += 1
        actions.append(entry)
    return {
        "schema": SCHEMA,
        "kind": "rollback",
        "status": "ok" if failed == 0 else "fail",
        "operationId": operation_id,
        "actions": actions,
        "sourcePreserved": True,
    }
