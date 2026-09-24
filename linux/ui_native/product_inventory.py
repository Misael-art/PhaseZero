"""PXA-001: stable product targets for existing Control Center actions.

This inventory describes navigation and ownership. It never probes or mutates a
host. Actions remain executable through their existing IDs while later phases
replace duplicate installers with one product detail and instance contract.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from linux.capabilities.catalog import CAPABILITIES

from .models import ActionSpec, ProductInstance


DESTINATIONS = frozenset({
    "Início", "Aplicativos", "Desenvolvimento", "Inteligência artificial",
    "Contas e conexões", "Plataformas", "Sistema", "Atividade",
})
ROLES = frozenset({"canonical", "shortcut", "legacy"})


@dataclass(frozen=True)
class ProductTarget:
    action_id: str
    target_id: str
    target_kind: str  # app | platform | journey | system | activity
    destination: str
    role: str
    context: str
    instance_scope: str  # local | host | project | account | selected


_CAPABILITY_IDS = frozenset(item.id for item in CAPABILITIES)
_APP_NAMES = {item.id: item.title for item in CAPABILITIES}

# These names deliberately merge actions from several old categories. A
# product has one stable ID even when its setup is offered in multiple places.
_AI_APPS = {
    "opencode": "opencode", "omo": "omo", "memory": "ai-memory",
    "ollama": "ollama", "webui": "open-webui", "usagebar": "usagebar",
    "codexbar": "codexbar", "claude": "claude-code", "9router": "9router",
    "odysseus": "odysseus", "hermes": "hermes", "omniroute": "omniroute",
}
_PROXIES = {"kimi": "kimiproxy", "qwen": "qwen-proxy", "deeps": "deepseek-proxy", "mimo": "mimo-proxy"}
_EXTRA_APPS = {
    "ai-memory": "ai-memory", "claude-code": "Claude Code", "claude-desktop": "Claude Desktop",
    "codex-desktop": "Codex Desktop", "codexbar": "CodexBar", "deepseek-proxy": "DeepSeek Proxy",
    "hermes": "Hermes", "kimiproxy": "Kimi Proxy", "mimo-proxy": "MiMo Proxy",
    "odysseus": "Odysseus", "ollama": "Ollama", "omo": "Oh My OpenCode",
    "omniroute": "OmniRoute", "open-webui": "Open WebUI", "opencode": "OpenCode",
    "qwen-code-desktop": "Qwen Code Desktop", "qwen-proxy": "Qwen Proxy",
    "9router": "9Router", "usagebar": "UsageBar",
}


def _capability_target(capability_id: str) -> str:
    if capability_id not in _CAPABILITY_IDS:
        raise ValueError(f"unknown capability target: {capability_id}")
    return f"app.{capability_id.rsplit('.', 1)[-1]}"


def _ai_app(action_id: str) -> str | None:
    suffix = action_id.removeprefix("ai.")
    if suffix.startswith("desktop."):
        name = suffix.split(".", 2)[1]
        return {"claude": "claude-desktop", "qwen": "qwen-code-desktop", "codex": "codex-desktop"}.get(name)
    if suffix.startswith("proxies-"):
        for token, name in _PROXIES.items():
            if suffix.endswith(f"-{token}") or suffix.endswith(f"-{token}-login"):
                return name
        return None
    for prefix, name in _AI_APPS.items():
        if suffix == prefix or suffix.startswith(prefix + "-") or suffix.startswith(prefix + "."):
            return name
    return None


def target_for(action: ActionSpec) -> ProductTarget:
    """Resolve every static action without guessing installed state."""
    aid = action.id
    category = action.category
    if aid.startswith(("hub.capability.install.", "hub.capability.remove.")):
        capability_id = aid.split(".", 3)[3]
        return ProductTarget(aid, _capability_target(capability_id), "app",
                             "Desenvolvimento" if capability_id.startswith("development.") else "Aplicativos",
                             "shortcut", category, "host")
    if aid.startswith("hub.tuning."):
        return ProductTarget(aid, "system.tune", "system", "Sistema", "shortcut", category, "host")
    if aid.startswith("routing."):
        return ProductTarget(aid, "journey.ai-routing", "journey", "Inteligência artificial",
                             "shortcut", category, "account")
    if aid.startswith("capability.plan."):
        capability_id = aid.removeprefix("capability.plan.")
        destination = "Desenvolvimento" if capability_id.startswith("development.") else "Aplicativos"
        return ProductTarget(aid, _capability_target(capability_id), "app", destination,
                             "canonical", category, "host")
    if aid.startswith("capability.profile.") or aid.startswith("profile."):
        return ProductTarget(aid, f"journey.{aid}", "journey", "Desenvolvimento" if "dev" in aid or "developer" in aid else "Início",
                             "legacy", category, "host")
    if aid.startswith("ai."):
        app = _ai_app(aid)
        if app:
            return ProductTarget(aid, f"app.{app}", "app", "Inteligência artificial",
                                 "shortcut", category, "local")
        if "auth" in aid or "login" in aid or "credentials" in aid or "secrets" in aid:
            destination = "Contas e conexões"
        else:
            destination = "Inteligência artificial"
        return ProductTarget(aid, f"journey.{aid}", "journey", destination,
                             "legacy", category, "account" if destination == "Contas e conexões" else "local")
    if aid.startswith("server.hermes"):
        return ProductTarget(aid, "app.hermes", "app", "Inteligência artificial", "shortcut", category, "host")
    if aid.startswith("server.llm"):
        return ProductTarget(aid, "app.ollama", "app", "Inteligência artificial", "shortcut", category, "host")
    if aid.startswith("server.homelab") or aid.startswith("homelab."):
        return ProductTarget(aid, "platform.homelab", "platform", "Plataformas", "shortcut", category, "selected")
    if aid.startswith("windows."):
        return ProductTarget(aid, "platform.windows-vm", "platform", "Plataformas", "shortcut", category, "selected")
    if aid.startswith(("waydroid.", "steamdeck.", "emulation.")):
        platform = aid.split(".", 1)[0]
        return ProductTarget(aid, f"platform.{platform}", "platform", "Plataformas", "shortcut", category, "host")
    if aid.startswith("desktop."):
        return ProductTarget(aid, f"journey.{aid.split('.', 2)[1]}", "journey", "Aplicativos", "legacy", category, "local")
    if aid.startswith("capability."):
        return ProductTarget(aid, "journey.capabilities", "journey", "Aplicativos", "legacy", category, "host")
    if aid.startswith("flatpak."):
        return ProductTarget(aid, "system.flatpak", "system", "Aplicativos", "shortcut", category, "host")
    if aid.startswith(("boot.", "host.", "system.", "tune.", "themes.")):
        destination = "Atividade" if aid.startswith("system.support-") or aid.startswith("themes.history") else "Sistema"
        return ProductTarget(aid, f"system.{aid.split('.', 1)[0]}", "system", destination, "shortcut", category, "host")
    if aid.startswith("server."):
        return ProductTarget(aid, "platform.server", "platform", "Plataformas", "shortcut", category, "host")
    raise ValueError(f"unclassified action: {aid}")


def inventory(actions: list[ActionSpec]) -> tuple[ProductTarget, ...]:
    rows = tuple(target_for(action) for action in actions)
    if len({row.action_id for row in rows}) != len(actions):
        raise ValueError("duplicate or missing action in product inventory")
    for row in rows:
        if row.destination not in DESTINATIONS or row.role not in ROLES:
            raise ValueError(f"invalid product target: {row.action_id}")
        if row.target_kind == "app" and not row.target_id.startswith("app."):
            raise ValueError(f"invalid app ID: {row.action_id}")
    return rows


def inventory_manifest(root: Path) -> dict[str, object]:
    from .catalog import build_catalog

    actions = build_catalog(root)
    rows = inventory(actions)
    products = [
        {"appId": _capability_target(item.id), "name": item.title,
         "capabilityId": item.id, "sources": [
             {"kind": source.kind, "name": source.name} for source in item.sources
         ]}
        for item in CAPABILITIES
    ]
    capability_apps = {item["appId"] for item in products}
    products.extend(
        {"appId": f"app.{key}", "name": name, "capabilityId": None, "sources": []}
        for key, name in sorted(_EXTRA_APPS.items())
        if f"app.{key}" not in capability_apps
    )
    known_apps = {item["appId"] for item in products}
    missing_apps = {row.target_id for row in rows if row.target_kind == "app"} - known_apps
    if missing_apps:
        raise ValueError(f"app targets without a product record: {sorted(missing_apps)}")
    return {
        "schemaVersion": 1,
        "source": "linux.ui_native.catalog.build_catalog",
        "platform": "linux",
        "actionCount": len(rows),
        "dynamicActionPatterns": [
            "hub.capability.install.<capabilityId>",
            "hub.capability.remove.<capabilityId>",
            "hub.tuning.apply.<tuningId>",
            "hub.tuning.revert.<tuningId>",
            "routing.<operation>.<task>.<policy>",
        ],
        "products": products,
        "actions": [
            {"actionId": row.action_id, "targetId": row.target_id,
             "targetKind": row.target_kind, "destination": row.destination,
             "role": row.role, "context": row.context,
             "instanceScope": row.instance_scope}
            for row in rows
        ],
    }


def instances_from_capability_status(payload: object, *, host_id: str) -> tuple[ProductInstance, ...]:
    """Read-only bridge from capability status; never infers owner or health.

    ``catalog`` payloads have ``hasStatus=false`` and therefore yield unknown
    installation even though their legacy ``installed`` field is false.
    """
    if not isinstance(payload, dict):
        return ()
    rows = payload.get("capabilities")
    if not isinstance(rows, list):
        return ()
    probed = payload.get("hasStatus") is True
    result: list[ProductInstance] = []
    for raw in rows:
        if not isinstance(raw, dict) or raw.get("id") not in _CAPABILITY_IDS:
            continue
        capability_id = raw["id"]
        source = raw.get("source")
        source = source if isinstance(source, dict) else {}
        installation = "unknown" if not probed or not isinstance(raw.get("installed"), bool) else (
            "present" if raw["installed"] else "absent"
        )
        result.append(ProductInstance(
            instance_id=f"{host_id}:capability:{capability_id}",
            app_id=_capability_target(capability_id),
            host_id=host_id,
            scope="host",
            manager=str(source.get("kind") or "unknown"),
            installation=installation,
        ))
    return tuple(result)
