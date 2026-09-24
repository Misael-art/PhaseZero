from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.catalog import build_catalog
from linux.ui_native.models import ProductInstance
from linux.ui_native.product_inventory import (
    instances_from_capability_status, inventory, inventory_manifest, target_for,
)


def test_every_action_has_exactly_one_target_and_snapshot_is_current():
    payload = inventory_manifest(ROOT)
    saved = json.loads((ROOT / "linux/ui_native/product_inventory.json").read_text(encoding="utf-8"))
    assert saved == payload
    assert payload["actionCount"] == len(build_catalog(ROOT))
    assert len({item["actionId"] for item in payload["actions"]}) == payload["actionCount"]


def test_existing_shortcuts_converge_on_one_product():
    rows = {row.action_id: row for row in inventory(build_catalog(ROOT))}
    assert rows["ai.ollama"].target_id == rows["server.llm"].target_id == "app.ollama"
    assert rows["ai.hermes-status"].target_id == rows["server.hermes"].target_id == "app.hermes"
    assert rows["capability.plan.development.vscode"].target_id == "app.vscode"
    assert rows["capability.plan.development.vscodium"].target_id == "app.vscodium"


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
