from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.capabilities import SCHEMA
from linux.capabilities.catalog import BY_ID, CAPABILITIES, PROFILES, compatibility, validate_catalog
from linux.capabilities.engine import (
    CapabilityError,
    apply_plan,
    create_plan,
    read_manifest,
    rollback_operation,
    verify_operation,
)
from linux.capabilities.platform import HostFacts
from linux.capabilities.providers import Provider
from linux.capabilities.catalog import source_for


def host(**changes) -> HostFacts:
    base = HostFacts(
        platform="linux",
        architecture="x86_64",
        distro="arch",
        distro_like=(),
        package_family="arch",
        immutable=False,
        immutable_kind="",
        container=False,
        init="systemd",
        desktop="kde",
        session="wayland",
        gpus=("amd",),
        package_manager="pacman",
        flatpak=True,
        flathub=True,
    )
    return replace(base, **changes)


class FakeProvider(Provider):
    def __init__(self, facts: HostFacts, installed: set[str] | None = None) -> None:
        super().__init__(facts)
        self.installed_names = set(installed or ())
        self.executed: list[list[str]] = []

    def installed(self, source):
        return source.name in self.installed_names

    def available(self, source):
        return True

    def execute(self, plan):
        self.executed.append(plan.command())
        name = plan.args[-1]
        if "uninstall" in plan.args or "-R" in plan.args or "remove" in plan.args:
            self.installed_names.discard(name)
        else:
            self.installed_names.add(name)
        return 0, "ok", ""


@pytest.fixture
def private_state(tmp_path, monkeypatch):
    root = tmp_path / "state"
    monkeypatch.setenv("PZ_CAPABILITIES_STATE_DIR", str(root))
    return root


def test_catalog_is_valid_unique_and_uses_only_trusted_provider_kinds():
    validate_catalog()
    assert len(BY_ID) == len(CAPABILITIES) >= 70
    assert set(PROFILES) >= {
        "gaming-core", "game-streaming", "hardware-tools", "system-health",
        "developer", "security", "backup", "creative", "administration",
        "education", "full-workstation",
    }
    for capability in CAPABILITIES:
        assert capability.sources
        for source in capability.sources:
            assert source.kind in {"package", "flatpak"}
            assert source.version
            assert source.sha256
            if source.kind == "flatpak":
                assert source.remote == "flathub"


def test_compatibility_blocks_non_linux_container_immutable_and_wrong_gpu():
    xpadneo = BY_ID["hardware.xpadneo"]
    rocm = BY_ID["hardware.rocm"]
    assert compatibility(xpadneo, host(platform="windows"))[0] is False
    assert compatibility(xpadneo, host(container=True))[0] is False
    assert compatibility(xpadneo, host(immutable=True, immutable_kind="ostree"))[0] is False
    assert compatibility(rocm, host(gpus=("intel",)))[0] is False
    assert compatibility(rocm, host(gpus=("amd",)))[0] is True


@pytest.mark.parametrize(
    ("family", "distro", "expected"),
    (
        ("arch", "arch", "gamemode"),
        ("debian", "ubuntu", "gamemode"),
        ("fedora", "fedora", "gamemode"),
        ("suse", "opensuse-tumbleweed", "gamemode"),
    ),
)
def test_native_source_selection_is_multi_distro(family, distro, expected):
    facts = host(package_family=family, distro=distro, flatpak=False, flathub=False)
    source = source_for(BY_ID["gaming.gamemode"], facts)
    assert source is not None
    assert source.kind == "package"
    assert source.name == expected


def test_immutable_host_falls_back_to_flatpak_where_available():
    facts = host(
        distro="bazzite", distro_like=("fedora",), package_family="rpm-ostree",
        immutable=True, immutable_kind="rpm-ostree",
    )
    source = source_for(BY_ID["gaming.lutris"], facts)
    assert source is not None
    assert source.kind == "flatpak"


def test_plan_falls_back_when_native_repository_lacks_package(private_state):
    class FlatpakFallbackProvider(FakeProvider):
        def available(self, source):
            return source.kind == "flatpak"

    facts = host()
    provider = FlatpakFallbackProvider(facts)
    plan = create_plan(
        capability_ids=["hardware.qdiskinfo"], facts=facts, provider=provider,
    )
    assert plan["blockers"] == []
    assert plan["actions"][0]["source"]["kind"] == "flatpak"


def test_plan_expands_dependencies_and_records_private_preview(private_state):
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(
        capability_ids=["gaming.goverlay"], facts=facts, provider=provider,
    )
    assert [item["capabilityId"] for item in plan["actions"]] == [
        "gaming.mangohud", "gaming.goverlay",
    ]
    assert plan["confirmToken"]
    record = private_state / "plans" / f"{plan['id']}.json"
    assert stat.S_IMODE(record.stat().st_mode) == 0o600
    assert stat.S_IMODE(private_state.stat().st_mode) == 0o700
    assert all(item["command"]["program"] != "sh" for item in plan["actions"])


def test_all_profiles_resolve_without_catalog_gaps(private_state, monkeypatch):
    from linux.capabilities.recipes import ServiceRecipe

    monkeypatch.setattr(ServiceRecipe, "active", lambda self: False)
    facts = host()
    for profile_id in PROFILES:
        plan = create_plan(
            profile_ids=[profile_id], facts=facts, provider=FakeProvider(facts),
        )
        assert plan["actions"], profile_id
        assert plan["blockers"] == [], (profile_id, plan["blockers"])


def test_manifest_policy_blocks_excess_risk_and_reboot(private_state, tmp_path):
    manifest = tmp_path / "restricted.json"
    manifest.write_text(json.dumps({
        "schema": SCHEMA,
        "capabilities": ["hardware.xpadneo"],
        "policy": {"maxRisk": "normal", "allowReboot": False},
    }), encoding="utf-8")
    facts = host(package_family="debian", distro="debian")
    plan = create_plan(
        manifest=str(manifest), facts=facts, provider=FakeProvider(facts),
    )
    assert plan["status"] == "blocked"
    assert any("maxRisk" in blocker for blocker in plan["blockers"])
    assert any("allowReboot" in blocker for blocker in plan["blockers"])


def test_apply_verify_and_rollback_are_transaction_scoped(private_state):
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(
        capability_ids=["gaming.gamemode"], facts=facts, provider=provider,
    )
    with pytest.raises(CapabilityError, match="token"):
        apply_plan(plan["id"], confirmation="wrong", facts=facts, provider=provider)
    operation = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
    )
    assert operation["status"] == "complete"
    assert len(operation["installedByOperation"]) == 1
    assert verify_operation(operation["id"], facts=facts, provider=provider)["ok"] is True
    preview = rollback_operation(
        operation["id"], dry_run=True, facts=facts, provider=provider,
    )
    assert preview["status"] == "preview"
    rollback = rollback_operation(
        operation["id"], confirmation=operation["rollbackToken"],
        facts=facts, provider=provider,
    )
    assert rollback["status"] == "complete"
    assert provider.installed_names == set()


def test_preexisting_item_is_never_rollback_candidate(private_state):
    facts = host()
    provider = FakeProvider(facts, {"gamemode"})
    plan = create_plan(
        capability_ids=["gaming.gamemode"], facts=facts, provider=provider,
    )
    operation = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
    )
    assert operation["results"][0]["status"] == "preexisting"
    assert operation["installedByOperation"] == []
    rollback_operation(
        operation["id"], confirmation=operation["rollbackToken"],
        facts=facts, provider=provider,
    )
    assert provider.installed_names == {"gamemode"}


def test_reversible_service_recipe_is_previewed_applied_and_rolled_back(
    private_state, monkeypatch,
):
    from linux.capabilities.recipes import ServiceRecipe

    monkeypatch.setattr(ServiceRecipe, "active", lambda self: False)
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(
        capability_ids=["development.docker"], facts=facts, provider=provider,
    )
    assert plan["actions"][0]["recipe"]["unit"] == "docker.service"
    operation = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
    )
    assert operation["recipesByOperation"] == [{
        "capabilityId": "development.docker", "unit": "docker.service",
    }]
    rollback_operation(
        operation["id"], confirmation=operation["rollbackToken"],
        facts=facts, provider=provider,
    )
    commands = [" ".join(command) for command in provider.executed]
    assert any("enable --now docker.service" in command for command in commands)
    assert any("disable --now docker.service" in command for command in commands)


def test_manifest_is_bounded_versioned_and_rejects_symlink(tmp_path):
    manifest = tmp_path / "profile.json"
    manifest.write_text(json.dumps({
        "schema": SCHEMA,
        "profiles": ["gaming-core"],
        "capabilities": ["backup.rclone"],
    }), encoding="utf-8")
    assert read_manifest(manifest)["schema"] == SCHEMA
    link = tmp_path / "linked.json"
    link.symlink_to(manifest)
    with pytest.raises(CapabilityError, match="simbólico"):
        read_manifest(link)


def test_cli_detect_and_profiles_emit_versioned_json():
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT)
    for command in ("detect", "profiles"):
        result = subprocess.run(
            [sys.executable, "-m", "linux.capabilities", command],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=20, check=False,
        )
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout)["schema"] == SCHEMA


def test_pz_exposes_capabilities_cli():
    result = subprocess.run(
        [str(ROOT / "linux" / "pz"), "capabilities", "profiles"],
        cwd=ROOT, capture_output=True, text=True, timeout=20, check=False,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["schema"] == SCHEMA


def test_ui_preview_bindings_feed_plan_tokens_without_prompting():
    from linux.ui_native.catalog import build_catalog

    action = next(
        item for item in build_catalog(ROOT)
        if item.id == "capability.plan.gaming.gamemode"
    )
    assert action.mutable is True
    assert action.parameters == ()
    assert action.preview_bindings == (("plan_id", "id"), ("confirm", "confirmToken"))
    assert action.resolved_args(preview=True) == [
        "capabilities", "plan", "--capability", "gaming.gamemode",
    ]
    assert action.resolved_args(values={"plan_id": "plan-1", "confirm": "token-1"}) == [
        "capabilities", "apply", "--plan-id", "plan-1", "--confirm", "token-1",
    ]
