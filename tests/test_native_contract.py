from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def _catalog():
    from linux.ui_native.catalog import build_catalog

    return build_catalog(ROOT)


def _commands() -> set[tuple[str, ...]]:
    return {tuple(action.args) for action in _catalog()}


def test_commands_json_is_canonical_contract():
    result = subprocess.run(
        [str(ROOT / "linux" / "pz"), "commands", "--json"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    assert payload["schemaVersion"] == 2
    assert len(payload["actions"]) == len(_catalog())
    assert len({row["id"] for row in payload["actions"]}) == len(payload["actions"])


def test_catalog_safety_and_parameters():
    for action in _catalog():
        if action.mutable:
            assert action.preview_args, action.id
        assert action.platforms
        placeholders = {
            token[1:-1]
            for token in (*action.args, *(action.preview_args or ()))
            if token.startswith("{") and token.endswith("}")
        }
        assert placeholders <= set(action.parameter_names), action.id


@pytest.mark.parametrize(
    "prefix,variants",
    [
        (("server", "llm"), ("install", "expose-lan", "restore", "status")),
        (("server", "homelab"), ("status", "plan", "up", "down", "open", "logs", "backup", "restore", "update", "repair")),
        (("server", "casaos"), ("status", "plan", "install")),
        (("server", "hermes"), ("setup", "start", "status")),
        (("server", "slim"), ("apply", "restore", "status")),
        (("server", "boot"), ("install", "remove", "status", "next-reboot")),
        (("ai", "omo"), ("setup", "doctor", "status", "enable", "disable", "uninstall")),
        (("ai", "opencode"), ("sync", "status", "local-model", "free-model", "install-hook")),
        (("ai", "mcp"), ("install", "sync", "repair", "status", "list")),
        (("ai", "proxies"), ("status", "install", "configure-ides", "auth", "login", "test")),
        (("ai", "9router"), ("status", "install", "dashboard", "test", "provider", "combo", "usage")),
        (("flatpak", "remote"), ("add", "remove")),
        (("flatpak", "overrides"), ("apply", "remove")),
        (("waydroid", "host-access"), ("link", "unlink", "status")),
        (("emulation", "retrodeck"), ("status", "plan", "integrate", "repair")),
        (("emulation", "shared"), ("status", "plan", "apply", "repair")),
        (("emulation", "media"), ("status", "index", "plan", "apply", "repair", "clean")),
        (("emulation", "launchbox"), ("status", "plan", "install-clean", "import-esde", "verify", "repair")),
        (("emulation", "nsz"), ("status", "install", "plan", "convert", "apply")),
    ],
)
def test_public_action_variants_are_discoverable(prefix, variants):
    commands = _commands()
    for variant in variants:
        assert any(command[: len(prefix) + 1] == (*prefix, variant) for command in commands), (
            prefix,
            variant,
        )


def test_every_profile_has_an_action():
    profile_commands = {action.args for action in _catalog() if action.id.startswith("profile.")}
    for profile in (ROOT / "profiles").glob("*.json"):
        assert ("install", profile.stem) in profile_commands


def test_every_action_is_rendered_in_its_context(qapp):
    from linux.ui_native.command_runner import CommandRunner
    from linux.ui_native.pages.registry import PageRegistry

    registry = PageRegistry(ROOT, CommandRunner(ROOT))
    missing = []
    for action in registry.catalog:
        page = registry.page_for(action.category)
        if page is None or action.id not in page.represented_action_ids:
            missing.append(action.id)
    assert not missing


def test_multi_parameter_resolution_is_argument_safe():
    action = next(item for item in _catalog() if item.id == "flatpak.remote.add")
    assert action.resolved_args(values={"name": "example", "url": "https://example.test/repo"}) == [
        "flatpak",
        "remote",
        "add",
        "example",
        "https://example.test/repo",
    ]


@pytest.fixture
def qapp():
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])
