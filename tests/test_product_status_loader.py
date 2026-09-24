from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.models import ActionSpec
from linux.ui_native.status_loader import StatusLoader


def test_status_loader_emits_scoped_product_instance(tmp_path):
    action = ActionSpec(
        "app.ollama.status", "AI", "Status Ollama", "", ("ai", "status"), "",
        status_args=("ai", "status"),
    )
    loader = StatusLoader(tmp_path)
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.ollama", host_id="local", scope="service",
        )
        loader.fetch_product_status(
            action, app_id="app.ollama", host_id="homelab-a", scope="service",
        )
    assert fetch.call_count == 2
    assert fetch.call_args_list[-1].args == (action.id, ["ai", "status"])

    instances = loader.product_instances_from_result(action.id, {
        "installed": True,
        "serviceActive": True,
        "configured": True,
        "version": "1.2.3",
    })
    assert len(instances) == 1
    instance = instances[0]
    assert (instance.app_id, instance.host_id, instance.scope) == (
        "app.ollama", "homelab-a", "service",
    )
    assert (instance.installation, instance.health, instance.version) == (
        "present", "online", "1.2.3",
    )
    assert instance.ready
    assert loader.product_instances_from_result(action.id, {"installed": True}) == ()


def test_status_loader_rejects_mutating_action(tmp_path):
    action = ActionSpec(
        "app.ollama.install", "AI", "Instalar Ollama", "", ("ai", "setup", "ollama"), "",
        mutable=True,
    )
    loader = StatusLoader(tmp_path)
    failures = []
    loader.status_failed.connect(lambda action_id, reason: failures.append((action_id, reason)))
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.ollama", host_id="local", scope="service",
        )
    fetch.assert_not_called()
    assert failures == [(action.id, "product status requires a read-only action")]


def test_status_loader_normalizes_capability_catalog_by_app_and_scope(tmp_path):
    action = ActionSpec(
        "product.capabilities.status", "Aplicativos", "Status de recursos", "",
        ("capabilities", "status", "--json"), "",
        status_args=("capabilities", "status", "--json"),
    )
    loader = StatusLoader(tmp_path)
    with patch.object(loader, "fetch"):
        loader.fetch_product_status(
            action, app_id="app.vscode", host_id="local", scope="host",
        )
    instances = loader.product_instances_from_result(action.id, {
        "hasStatus": True,
        "capabilities": [
            {"id": "development.vscode", "installed": True,
             "origin": "external", "configuration": "ready", "health": "online"},
            {"id": "development.neovim", "installed": False},
        ],
    })
    assert len(instances) == 1
    assert (instances[0].app_id, instances[0].scope, instances[0].origin) == (
        "app.vscode", "host", "external",
    )
    assert instances[0].ready
