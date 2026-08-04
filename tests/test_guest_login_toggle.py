"""Contracts for the Windows guest login policy toggle in the native UI.

The toggle carries a Windows account password. argv is world-readable through
/proc and the runner echoes the command line back to the user, so the only
acceptable transport is stdin. These tests pin that.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

SECRET = "Sup3rS3cret.Passw0rd!"


@pytest.fixture(scope="module")
def actions():
    from linux.ui_native.catalog import build_catalog

    return {action.id: action for action in build_catalog(ROOT)}


def test_post_install_toggle_exists(actions):
    """Provisioning-time guest_login is not a post-install toggle."""
    for action_id in (
        "windows.guest-login.status",
        "windows.guest-login.auto",
        "windows.guest-login.password",
    ):
        assert action_id in actions, f"missing UI action: {action_id}"


def test_password_never_reaches_argv(actions):
    from linux.ui_native.command_runner import build_program

    action = actions["windows.guest-login.password"]
    _program, args = build_program(
        ROOT, action, preview=False, values={"password": SECRET}
    )
    rendered = " ".join(args)
    assert SECRET not in rendered, "password leaked into argv"
    assert "{password}" not in rendered, "unresolved placeholder survived into argv"
    # The receiving script refuses to read a secret any other way.
    assert "--password-stdin" in args
    assert action.stdin_parameter == "password"


def test_password_field_is_masked(actions):
    action = actions["windows.guest-login.password"]
    secrets = [p for p in action.parameters if p.name == "password"]
    assert secrets, "password parameter missing"
    assert secrets[0].kind == "secret", "password must render masked, not as plain text"


def test_autologin_needs_no_secret(actions):
    """--mode auto generates its own password inside the guest."""
    action = actions["windows.guest-login.auto"]
    assert not action.stdin_parameter
    assert not action.parameters
    assert "--password-stdin" not in action.args


def test_mutating_toggles_are_guarded(actions):
    """Both toggles rewrite the guest login policy, so they need a safe preview."""
    for action_id in ("windows.guest-login.auto", "windows.guest-login.password"):
        action = actions[action_id]
        assert action.mutable
        assert action.preview_args is not None
        assert action.risk == "high"


def test_status_is_read_only(actions):
    action = actions["windows.guest-login.status"]
    assert not action.mutable
    assert not action.elevated


def test_spec_args_carry_no_secret_placeholder(actions):
    """Catch the leak at the source, not only in the regenerated snapshot.

    resolved_args strips a stdin-bound placeholder, so argv stays clean even if
    one is reintroduced. The static catalog generator serialises spec.args
    verbatim though, so a placeholder here still reaches the web UI as a
    literal argument.
    """
    action = actions["windows.guest-login.password"]
    assert "{password}" not in action.args, (
        "stdin-bound secret must have no argv position in spec.args"
    )


def test_static_catalog_carries_no_placeholder():
    """The web UI runs these command strings verbatim."""
    payload = json.loads((ROOT / "linux/ui/actions.json").read_text(encoding="utf-8"))
    for entry in payload["actions"]:
        if "guest-login" not in entry["name"]:
            continue
        assert "{" not in entry["command"], f"placeholder in {entry['name']}: {entry['command']}"
