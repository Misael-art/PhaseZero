from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.catalog import build_catalog
from linux.ui_native.models import ProductInstance
from linux.ui_native.product_inventory import (
    instances_from_capability_status, instances_from_status_payload,
    inventory, inventory_manifest, render_inventory_manifest, target_for,
)


def test_every_action_has_exactly_one_target_and_snapshot_is_current():
    payload = inventory_manifest(ROOT)
    saved = json.loads((ROOT / "linux/ui_native/product_inventory.json").read_text(encoding="utf-8"))
    assert saved == payload
    assert payload["actionCount"] == len(build_catalog(ROOT))
    assert len({item["actionId"] for item in payload["actions"]}) == payload["actionCount"]
    assert json.loads(render_inventory_manifest(payload)) == payload
    assert all(len(item["installationAuthorityIds"]) <= 1 for item in payload["products"])


def test_install_routes_have_one_authority_per_app_scope():
    payload = inventory_manifest(ROOT)
    app_actions = {item.id: item for item in build_catalog(ROOT)}
    grouped = {}
    for action in payload["actions"]:
        authority = action["installationAuthorityId"]
        if not authority:
            continue
        key = (action["targetId"], action["instanceScope"])
        grouped.setdefault(key, set()).add(authority)
    assert grouped
    assert all(len(authorities) == 1 for authorities in grouped.values())
    assert all(
        action["installationAuthorityId"]
        for action in payload["actions"]
        if action["targetKind"] == "app"
        and "watchdog" not in action["actionId"]
        and any(verb in app_actions[action["actionId"]].args for verb in ("install", "setup"))
    )


def test_existing_shortcuts_converge_on_one_product():
    rows = {row.action_id: row for row in inventory(build_catalog(ROOT))}
    assert rows["ai.ollama"].target_id == rows["server.llm"].target_id == "app.ollama"
    assert rows["ai.hermes-status"].target_id == rows["server.hermes"].target_id == "app.hermes"
    assert rows["capability.plan.development.vscode"].target_id == "app.vscode"
    assert rows["capability.plan.development.vscodium"].target_id == "app.vscodium"


def test_ollama_has_one_canonical_host_installer_across_legacy_contexts():
    payload = inventory_manifest(ROOT)
    actions = {item["actionId"]: item for item in payload["actions"]}
    product = next(item for item in payload["products"] if item["appId"] == "app.ollama")
    authority = next(
        item for item in payload["installationAuthorities"]
        if item["appId"] == "app.ollama" and item["instanceScope"] == "host"
    )

    assert product["canonicalActionId"] == "ai.ollama"
    assert product["actionIds"] == sorted(("ai.ollama", "server.llm", "server.llm.expose",
                                           "server.llm.restore", "server.llm.status"))
    assert actions["ai.ollama"]["role"] == "canonical"
    assert actions["server.llm"]["role"] == "shortcut"
    assert actions["ai.ollama"]["instanceScope"] == actions["server.llm"]["instanceScope"] == "host"
    assert actions["ai.ollama"]["installationAuthorityId"] == "linux/ai/setup-ollama.sh"
    assert actions["server.llm"]["installationAuthorityId"] == "linux/ai/setup-ollama.sh"
    assert authority["actionIds"] == ["ai.ollama", "server.llm"]


def test_comparison_groups_only_include_curated_same_function_apps():
    payload = inventory_manifest(ROOT)
    groups = {item["id"]: item["appIds"] for item in payload["comparisonCategories"]}
    assert groups == {
        "code-editor": ["app.vscode", "app.vscodium"],
        "mesh-network": ["app.tailscale", "app.zerotier"],
        "web-browser": ["app.brave", "app.librewolf"],
    }
    categories = {item["appId"]: item["comparisonCategory"] for item in payload["products"]}
    assert categories["app.ollama"] is None
    assert categories["app.9router"] is None


def test_unclassified_action_fails_closed():
    from dataclasses import replace

    action = build_catalog(ROOT)[0]
    try:
        target_for(replace(action, id="unknown.new-action"))
    except ValueError as error:
        assert "unclassified action" in str(error)
    else:
        raise AssertionError("unknown action was silently accepted")


def test_generated_hub_actions_resolve_same_app_as_static_capability():
    from dataclasses import replace

    action = build_catalog(ROOT)[0]
    for operation in ("install", "remove"):
        row = target_for(replace(action, id=f"hub.capability.{operation}.development.vscode"))
        assert row.target_id == "app.vscode"
        assert row.instance_scope == "host"
    assert target_for(replace(action, id="hub.capabilities.status")).target_id == "journey.capabilities"


def test_two_instances_share_one_product_without_merging_host_or_owner():
    local = ProductInstance("local:ollama", "app.ollama", "local", "user",
                            installation="present", origin="external", configuration="unknown")
    homelab = ProductInstance("homelab:ollama", "app.ollama", "homelab", "service",
                              installation="present", origin="phasezero",
                              configuration="ready", health="online")
    assert local.app_id == homelab.app_id
    assert local.instance_id != homelab.instance_id
    assert local.next_action == "verify"
    assert not local.ready
    assert homelab.next_action == "open"


def test_capability_catalog_does_not_fake_absence_or_ownership():
    base = {"capabilities": [{"id": "development.vscode", "installed": False,
                               "source": {"kind": "package"}}]}
    unprobed = instances_from_capability_status({**base, "hasStatus": False}, host_id="host-a")
    assert unprobed[0].installation == "unknown"
    assert unprobed[0].next_action == "verify"
    found = instances_from_capability_status({**base, "hasStatus": True,
        "capabilities": [{**base["capabilities"][0], "installed": True}]}, host_id="host-a")
    assert found[0].installation == "present"
    assert found[0].origin == "unknown"
    assert found[0].health == "unknown"
    assert not found[0].ready


def test_status_adapter_keeps_scope_and_unknown_dimensions_separate():
    local = instances_from_status_payload(
        {"hasStatus": True, "installed": True, "serviceActive": False,
         "origin": "external", "version": "0.4.2"},
        app_id="app.ollama", host_id="host-a", scope="local",
    )[0]
    remote = instances_from_status_payload(
        {"hasStatus": False, "installed": False, "configured": True},
        app_id="app.ollama", host_id="host-b", scope="service",
    )[0]
    assert local.app_id == remote.app_id == "app.ollama"
    assert local.instance_id != remote.instance_id
    assert (local.installation, local.origin, local.health) == ("present", "external", "offline")
    assert (remote.installation, remote.configuration, remote.health) == ("unknown", "ready", "unknown")
    assert not remote.ready
    assert local.to_dict()["instanceId"] == local.instance_id


def test_status_adapter_ignores_malformed_state_fields():
    instance = instances_from_status_payload(
        {"hasStatus": True, "installationState": [], "origin": {},
         "configurationState": [], "health": {}, "error": "provider timeout"},
        app_id="app.hermes", host_id="local", scope="user",
    )[0]
    assert instance.installation == "unknown"
    assert instance.origin == instance.configuration == instance.health == "unknown"


def test_hermes_status_uses_nested_gateway_health_without_claiming_ownership():
    instance = instances_from_status_payload(
        {"id": "hermes", "installed": True, "configured": True,
         "gateway": {"active": False}},
        app_id="app.hermes", host_id="local", scope="local",
    )[0]
    assert (instance.installation, instance.origin, instance.configuration, instance.health) == (
        "present", "unknown", "ready", "offline",
    )


def test_proxy_status_actions_target_exact_product_and_preserve_provenance_contract():
    actions = {action.id: action for action in build_catalog(ROOT)}
    expected = {
        "app.kimiproxy": ("ai.proxies-kimi-status", "kimiproxy"),
        "app.qwen-proxy": ("ai.proxies-qwen-status", "qwenproxy"),
        "app.deepseek-proxy": ("ai.proxies-deeps-status", "deepsproxy"),
        "app.mimo-proxy": ("ai.proxies-mimo-status", "mimo-ai-proxy"),
    }
    rows = {row.action_id: row for row in inventory(list(actions.values()))}
    for app_id, (action_id, proxy_id) in expected.items():
        action = actions[action_id]
        assert not action.mutable
        assert action.status_args == ("ai", "proxies", "product-status", proxy_id)
        assert rows[action_id].target_id == app_id
        assert rows[action_id].instance_scope == "local"
    mimo_credentials = actions["ai.proxies-credentials-mimo"]
    assert mimo_credentials.stdin_parameter == "credentials"
    assert mimo_credentials.parameters[0].name == "credentials"
    assert mimo_credentials.parameters[0].kind == "secret"
    assert "{credentials}" not in mimo_credentials.args
    observed = instances_from_status_payload(
        {"hasStatus": True, "installationState": "present", "origin": "phasezero",
         "configurationState": "ready", "health": "offline",
         "manager": "phasezero-ai-proxy-suite"},
        app_id="app.qwen-proxy", host_id="local", scope="local",
    )[0]
    assert (observed.installation, observed.origin, observed.configuration, observed.health) == (
        "present", "phasezero", "ready", "offline",
    )
    malformed = instances_from_status_payload(
        {"hasStatus": True, "installationState": [], "origin": [],
         "configurationState": [], "health": [], "installed": "yes"},
        app_id="app.qwen-proxy", host_id="local", scope="local",
    )[0]
    assert malformed.installation == malformed.origin == malformed.configuration == malformed.health == "unknown"
