from __future__ import annotations

import json
import os
import time
from dataclasses import asdict
from pathlib import Path
from typing import Iterable

from . import SCHEMA
from .catalog import BY_ID, CAPABILITIES, GROUPS, PROFILES, compatibility, source_for, sources_for
from .models import CapabilitySpec, SourceSpec
from .platform import HostFacts, detect
from .providers import CommandPlan, Provider
from .recipes import recipe_for
from . import state


MAX_MANIFEST_BYTES = 256 * 1024
MAX_OUTPUT_CHARS = 12_000
PLAN_TTL_SECONDS = 24 * 60 * 60


class CapabilityError(RuntimeError):
    """Expected user-facing capability error."""


def _source_dict(source: SourceSpec | None) -> dict | None:
    if source is None:
        return None
    payload = asdict(source)
    payload["distros"] = list(source.distros)
    return payload


def _source_from_dict(payload: dict) -> SourceSpec:
    try:
        source = SourceSpec(
            kind=str(payload["kind"]),
            name=str(payload["name"]),
            distros=tuple(str(value) for value in payload.get("distros", ())),
            version=str(payload.get("version", "")),
            sha256=str(payload.get("sha256", "")),
            remote=str(payload.get("remote", "")),
        )
        source.validate()
        return source
    except (KeyError, TypeError, ValueError) as exc:
        raise CapabilityError("fonte inválida no plano") from exc


def _command_dict(command: CommandPlan) -> dict:
    return {
        "program": command.program,
        "args": list(command.args),
        "elevated": command.elevated,
        "userScope": command.user_scope,
    }


def _clean_output(value: str) -> str:
    value = value.replace("\x00", "")
    home = str(Path.home())
    if home and home != "/":
        value = value.replace(home, "~")
    return value[-MAX_OUTPUT_CHARS:]


def _select_source(
    capability: CapabilitySpec,
    facts: HostFacts,
    provider: Provider,
    *,
    require_available: bool,
) -> tuple[SourceSpec | None, bool]:
    candidates = sources_for(capability, facts)
    for source in candidates:
        if provider.installed(source):
            return source, True
    if require_available:
        for source in candidates:
            if provider.available(source):
                return source, False
        return None, False
    return (candidates[0], False) if candidates else (None, False)


def catalog_payload(
    facts: HostFacts | None = None,
    *,
    group: str = "",
    include_status: bool = False,
) -> dict:
    host = facts or detect()
    provider = Provider(host)
    items: list[dict] = []
    for capability in CAPABILITIES:
        if group and capability.group != group:
            continue
        applicable, reason = compatibility(capability, host)
        if applicable and include_status:
            source, installed = _select_source(
                capability, host, provider, require_available=False,
            )
        elif applicable:
            source, installed = source_for(capability, host), False
        else:
            source, installed = None, False
        if applicable and source is None:
            reason = "nenhuma fonte confiável disponível para este host"
        if not include_status:
            installed = False
        items.append({
            "id": capability.id,
            "title": capability.title,
            "description": capability.description,
            "group": capability.group,
            "groupTitle": GROUPS[capability.group],
            "applicable": applicable and source is not None,
            "reason": reason,
            "installed": installed,
            "source": _source_dict(source),
            "requires": list(capability.requires),
            "conflicts": list(capability.conflicts),
            "risk": capability.risk,
            "reboot": capability.reboot,
            "keywords": list(capability.keywords),
        })
    return {
        "schema": SCHEMA,
        "host": host.to_dict(),
        "groups": GROUPS,
        "capabilities": items,
    }


def profiles_payload() -> dict:
    return {
        "schema": SCHEMA,
        "profiles": [
            {
                "id": profile_id,
                "capabilities": list(capability_ids),
                "count": len(capability_ids),
            }
            for profile_id, capability_ids in PROFILES.items()
        ],
    }


def read_manifest(path: str | os.PathLike[str]) -> dict:
    source = Path(path).expanduser()
    if source.is_symlink():
        raise CapabilityError("manifesto não pode ser link simbólico")
    try:
        size = source.stat().st_size
    except OSError as exc:
        raise CapabilityError(f"manifesto inacessível: {exc}") from exc
    if size > MAX_MANIFEST_BYTES:
        raise CapabilityError("manifesto excede 256 KiB")
    try:
        payload = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CapabilityError(f"manifesto JSON inválido: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("schema") != SCHEMA:
        raise CapabilityError(f"manifesto requer schema {SCHEMA}")
    for key in ("profiles", "capabilities"):
        if key in payload and not isinstance(payload[key], list):
            raise CapabilityError(f"campo {key} deve ser lista")
    allowed = {"schema", "profiles", "capabilities", "policy", "description"}
    unknown = set(payload) - allowed
    if unknown:
        raise CapabilityError(f"campos desconhecidos no manifesto: {', '.join(sorted(unknown))}")
    policy = payload.get("policy", {})
    if not isinstance(policy, dict):
        raise CapabilityError("campo policy deve ser objeto")
    unknown_policy = set(policy) - {"maxRisk", "allowReboot"}
    if unknown_policy:
        raise CapabilityError(
            f"políticas desconhecidas: {', '.join(sorted(unknown_policy))}"
        )
    if policy.get("maxRisk", "high") not in {"normal", "elevated", "high"}:
        raise CapabilityError("policy.maxRisk inválido")
    if "allowReboot" in policy and not isinstance(policy["allowReboot"], bool):
        raise CapabilityError("policy.allowReboot deve ser booleano")
    return payload


def _expand_selection(
    capability_ids: Iterable[str], profile_ids: Iterable[str]
) -> list[CapabilitySpec]:
    requested: list[str] = []
    for profile_id in profile_ids:
        if profile_id not in PROFILES:
            raise CapabilityError(f"perfil desconhecido: {profile_id}")
        requested.extend(PROFILES[profile_id])
    requested.extend(capability_ids)
    if not requested:
        raise CapabilityError("selecione ao menos uma capability ou perfil")

    ordered: list[str] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(capability_id: str) -> None:
        if capability_id not in BY_ID:
            raise CapabilityError(f"capability desconhecida: {capability_id}")
        if capability_id in visiting:
            raise CapabilityError(f"ciclo de dependência em {capability_id}")
        if capability_id in visited:
            return
        visiting.add(capability_id)
        for dependency in BY_ID[capability_id].requires:
            visit(dependency)
        visiting.remove(capability_id)
        visited.add(capability_id)
        ordered.append(capability_id)

    for capability_id in requested:
        visit(str(capability_id))

    selected = set(ordered)
    conflicts = sorted({
        f"{capability_id} ↔ {conflict}"
        for capability_id in ordered
        for conflict in BY_ID[capability_id].conflicts
        if conflict in selected
    })
    if conflicts:
        raise CapabilityError("conflitos na seleção: " + ", ".join(conflicts))
    return [BY_ID[capability_id] for capability_id in ordered]


def create_plan(
    *,
    capability_ids: Iterable[str] = (),
    profile_ids: Iterable[str] = (),
    manifest: str = "",
    facts: HostFacts | None = None,
    provider: Provider | None = None,
) -> dict:
    capabilities = list(capability_ids)
    profiles = list(profile_ids)
    manifest_policy: dict = {}
    if manifest:
        payload = read_manifest(manifest)
        capabilities.extend(str(value) for value in payload.get("capabilities", ()))
        profiles.extend(str(value) for value in payload.get("profiles", ()))
        if isinstance(payload.get("policy"), dict):
            manifest_policy = payload["policy"]
    host = facts or detect()
    package_provider = provider or Provider(host)
    selected = _expand_selection(capabilities, profiles)
    actions: list[dict] = []
    blockers: list[str] = []
    reboot = "no"
    risk = "normal"
    risk_order = {"normal": 0, "elevated": 1, "high": 2}
    reboot_order = {"no": 0, "recommended": 1, "required": 2}
    for capability in selected:
        applicable, reason = compatibility(capability, host)
        recipe = recipe_for(capability.id)
        recipe_active = recipe.active() if recipe else True
        if applicable and recipe:
            recipe_compatible, recipe_reason = recipe.compatible(host)
            if not recipe_compatible:
                applicable, reason = False, recipe_reason
        source, installed = _select_source(
            capability, host, package_provider, require_available=True,
        ) if applicable else (None, False)
        available = source is not None
        status = "installed" if installed and recipe_active else "configure" if installed else "install"
        command = None
        if not applicable:
            status = "blocked"
        elif source is None:
            status = "blocked"
            reason = "nenhuma fonte confiável disponível para este host"
        elif not available:
            status = "blocked"
            reason = f"fonte não encontrada no repositório: {source.name}"
        else:
            command = package_provider.install_plan(source) if not installed else None
        if status == "blocked":
            blockers.append(f"{capability.title}: {reason}")
        if risk_order[capability.risk] > risk_order[risk]:
            risk = capability.risk
        if reboot_order[capability.reboot] > reboot_order[reboot]:
            reboot = capability.reboot
        actions.append({
            "capabilityId": capability.id,
            "title": capability.title,
            "status": status,
            "reason": reason,
            "source": _source_dict(source),
            "command": _command_dict(command) if command else None,
            "recipe": {
                "kind": "systemd-service",
                "unit": recipe.unit,
                "description": recipe.description,
                "active": recipe_active,
                "command": _command_dict(recipe.apply_plan()) if not recipe_active else None,
            } if recipe else None,
            "risk": capability.risk,
            "reboot": capability.reboot,
        })
    max_risk = str(manifest_policy.get("maxRisk", "high"))
    if risk_order[risk] > risk_order[max_risk]:
        blockers.append(f"risco {risk} excede policy.maxRisk={max_risk}")
    if manifest_policy.get("allowReboot") is False and reboot != "no":
        blockers.append(f"plano requer reboot {reboot}, bloqueado pela policy.allowReboot")
    plan_id = state.new_id("plan")
    confirmation = state.token()
    record = {
        "schema": SCHEMA,
        "kind": "plan",
        "id": plan_id,
        "createdAt": int(time.time()),
        "host": host.to_dict(),
        "profiles": profiles,
        "requestedCapabilities": capabilities,
        "actions": actions,
        "blockers": blockers,
        "ok": not blockers,
        "status": "blocked" if blockers else "ready",
        "risk": risk,
        "reboot": reboot,
        "policy": manifest_policy,
        "confirmToken": confirmation,
    }
    state.save("plans", plan_id, record)
    return record


def _revalidate_action(action: dict, host: HostFacts, provider: Provider) -> tuple[CapabilitySpec, SourceSpec]:
    capability_id = str(action.get("capabilityId", ""))
    capability = BY_ID.get(capability_id)
    if capability is None:
        raise CapabilityError(f"capability removida do catálogo: {capability_id}")
    applicable, reason = compatibility(capability, host)
    if not applicable:
        raise CapabilityError(f"{capability.title}: {reason}")
    expected = _source_from_dict(action.get("source") or {})
    if expected not in sources_for(capability, host) or not provider.supports(expected):
        raise CapabilityError(f"fonte mudou desde o preview: {capability.title}")
    if not provider.installed(expected) and not provider.available(expected):
        raise CapabilityError(f"fonte deixou de estar disponível: {capability.title}")
    return capability, expected


def apply_plan(
    plan_id: str,
    *,
    confirmation: str = "",
    dry_run: bool = False,
    facts: HostFacts | None = None,
    provider: Provider | None = None,
) -> dict:
    plan = state.load("plans", plan_id)
    if plan.get("schema") != SCHEMA or plan.get("kind") != "plan":
        raise CapabilityError("registro de plano incompatível")
    if int(time.time()) - int(plan.get("createdAt", 0)) > PLAN_TTL_SECONDS:
        raise CapabilityError("plano expirado; gere um novo preview")
    if plan.get("blockers"):
        raise CapabilityError("plano contém bloqueios; revise a seleção")
    if not dry_run and confirmation != plan.get("confirmToken"):
        raise CapabilityError("token de confirmação inválido")
    host = facts or detect()
    package_provider = provider or Provider(host)
    results: list[dict] = []
    installed_by_operation: list[dict] = []
    recipes_by_operation: list[dict] = []
    failed = False
    for action in plan.get("actions", ()): 
        if action.get("status") == "installed":
            results.append({"capabilityId": action["capabilityId"], "status": "preexisting"})
            continue
        capability, source = _revalidate_action(action, host, package_provider)
        command = package_provider.install_plan(source)
        recipe = recipe_for(capability.id)
        recipe_command = recipe.apply_plan() if recipe and not recipe.active() else None
        needs_install = action.get("status") == "install" and not package_provider.installed(source)
        if not needs_install and recipe_command is None:
            results.append({"capabilityId": capability.id, "status": "preexisting"})
            continue
        if dry_run:
            results.append({
                "capabilityId": capability.id,
                "status": "dry-run",
                "command": _command_dict(command) if needs_install else None,
                "recipeCommand": _command_dict(recipe_command) if recipe_command else None,
            })
            continue
        code, stdout, stderr = (0, "", "")
        if needs_install:
            code, stdout, stderr = package_provider.execute(command)
        item = {
            "capabilityId": capability.id,
            "status": "installed" if code == 0 else "failed",
            "exitCode": code,
            "stdout": _clean_output(stdout),
            "stderr": _clean_output(stderr),
        }
        results.append(item)
        if code == 0:
            if needs_install:
                installed_by_operation.append({
                    "capabilityId": capability.id,
                    "source": _source_dict(source),
                })
            if recipe_command:
                recipe_code, recipe_stdout, recipe_stderr = package_provider.execute(recipe_command)
                item["recipeExitCode"] = recipe_code
                item["recipeStdout"] = _clean_output(recipe_stdout)
                item["recipeStderr"] = _clean_output(recipe_stderr)
                if recipe_code == 0:
                    recipes_by_operation.append({
                        "capabilityId": capability.id,
                        "unit": recipe.unit,
                    })
                else:
                    item["status"] = "failed"
                    failed = True
                    break
        else:
            failed = True
            break
    operation_id = state.new_id("operation")
    rollback_token = state.token()
    record = {
        "schema": SCHEMA,
        "kind": "operation",
        "id": operation_id,
        "planId": plan_id,
        "createdAt": int(time.time()),
        "dryRun": dry_run,
        "status": "failed" if failed else ("preview" if dry_run else "complete"),
        "results": results,
        "installedByOperation": installed_by_operation,
        "recipesByOperation": recipes_by_operation,
        "rollbackToken": rollback_token,
        "reboot": plan.get("reboot", "no"),
    }
    state.save("operations", operation_id, record)
    return record


def verify_operation(
    operation_id: str,
    *,
    facts: HostFacts | None = None,
    provider: Provider | None = None,
) -> dict:
    operation = state.load("operations", operation_id)
    host = facts or detect()
    package_provider = provider or Provider(host)
    checks = []
    for item in operation.get("installedByOperation", ()):
        source = _source_from_dict(item.get("source") or {})
        installed = package_provider.installed(source)
        checks.append({"capabilityId": item.get("capabilityId"), "installed": installed})
    for item in operation.get("recipesByOperation", ()):
        recipe = recipe_for(str(item.get("capabilityId", "")))
        active = bool(recipe and recipe.unit == item.get("unit") and recipe.active())
        checks.append({
            "capabilityId": item.get("capabilityId"),
            "recipe": item.get("unit"),
            "active": active,
            "installed": active,
        })
    return {
        "schema": SCHEMA,
        "operationId": operation_id,
        "ok": all(check["installed"] for check in checks),
        "checks": checks,
    }


def rollback_operation(
    operation_id: str,
    *,
    confirmation: str = "",
    dry_run: bool = False,
    facts: HostFacts | None = None,
    provider: Provider | None = None,
) -> dict:
    operation = state.load("operations", operation_id)
    if operation.get("schema") != SCHEMA or operation.get("kind") != "operation":
        raise CapabilityError("registro de operação incompatível")
    if operation.get("dryRun"):
        raise CapabilityError("preview não possui alterações para reverter")
    if not dry_run and confirmation != operation.get("rollbackToken"):
        raise CapabilityError("token de rollback inválido")
    host = facts or detect()
    package_provider = provider or Provider(host)
    results = []
    failed = False
    for item in reversed(operation.get("recipesByOperation", ())):
        recipe = recipe_for(str(item.get("capabilityId", "")))
        if recipe is None or recipe.unit != item.get("unit"):
            raise CapabilityError("receita de rollback não corresponde ao catálogo atual")
        command = recipe.rollback_plan()
        if dry_run:
            results.append({
                "capabilityId": item.get("capabilityId"),
                "status": "dry-run",
                "recipeCommand": _command_dict(command),
            })
            continue
        code, stdout, stderr = package_provider.execute(command)
        results.append({
            "capabilityId": item.get("capabilityId"),
            "status": "service-disabled" if code == 0 else "failed",
            "exitCode": code,
            "stdout": _clean_output(stdout),
            "stderr": _clean_output(stderr),
        })
        if code != 0:
            failed = True
            break
    if failed:
        rollback_id = state.new_id("rollback")
        record = {
            "schema": SCHEMA, "kind": "rollback", "id": rollback_id,
            "operationId": operation_id, "createdAt": int(time.time()),
            "dryRun": dry_run, "status": "failed", "results": results,
        }
        state.save("rollbacks", rollback_id, record)
        return record
    for item in reversed(operation.get("installedByOperation", ())):
        source = _source_from_dict(item.get("source") or {})
        command = package_provider.remove_plan(source)
        if dry_run:
            results.append({
                "capabilityId": item.get("capabilityId"),
                "status": "dry-run",
                "command": _command_dict(command),
            })
            continue
        code, stdout, stderr = package_provider.execute(command)
        results.append({
            "capabilityId": item.get("capabilityId"),
            "status": "removed" if code == 0 else "failed",
            "exitCode": code,
            "stdout": _clean_output(stdout),
            "stderr": _clean_output(stderr),
        })
        if code != 0:
            failed = True
            break
    rollback_id = state.new_id("rollback")
    record = {
        "schema": SCHEMA,
        "kind": "rollback",
        "id": rollback_id,
        "operationId": operation_id,
        "createdAt": int(time.time()),
        "dryRun": dry_run,
        "status": "failed" if failed else ("preview" if dry_run else "complete"),
        "results": results,
    }
    state.save("rollbacks", rollback_id, record)
    return record
