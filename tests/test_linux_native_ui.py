from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.catalog import CATEGORIES, build_catalog, catalog_manifest
from linux.ui_native.boot_selector import BOOT_CHOICES, build_boot_selector_program
from linux.ui_native.command_runner import build_program
from linux.ui_native.models import ActionSpec
from linux.ui_native.result_parser import parse_json_output, severity_for


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


def test_catalog_covers_every_control_center_category(catalog):
    categories = {item.category for item in catalog}
    expected = {row[0] for row in CATEGORIES if row[0] != "Resultados"}
    assert categories == expected
    assert len(catalog) >= 100


def test_every_mutation_has_safe_preview(catalog):
    mutable = [item for item in catalog if item.mutable]
    assert mutable
    assert all(item.preview_args for item in mutable)
    assert all(item.preview_args != item.args for item in mutable)


def test_catalog_ids_and_commands_are_allowlisted(catalog):
    ids = [item.id for item in catalog]
    assert len(ids) == len(set(ids))
    valid_commands = {
        "install",
        "steamdeck",
        "windows-vm",
        "waydroid",
        "emulation",
        "boot",
        "flatpak",
        "ai",
        "doctor",
        "support-bundle",
        "repair-plan",
        "tune",
        "version",
    }
    for item in catalog:
        assert item.args[0] in valid_commands
        if item.preview_args:
            assert item.preview_args[0] in valid_commands


def test_input_token_substitution_is_literal():
    action = ActionSpec(
        "test.input",
        "test",
        "Input",
        "Input",
        ("emulation", "bios", "import", "{input}"),
        "folder",
        mutable=True,
        preview_args=("emulation", "bios", "status"),
        input_kind="path",
    )
    dangerous_looking = "/tmp/$(touch should-not-run); value"
    assert action.resolved_args(dangerous_looking)[-1] == dangerous_looking
    with pytest.raises(ValueError):
        build_program(ROOT, action, preview=False)


def test_build_program_never_uses_shell(catalog):
    action = next(item for item in catalog if item.id == "profile.safe-base")
    program, args = build_program(ROOT, action, preview=True)
    assert program == str(ROOT / "linux" / "pz")
    assert args == ["install", "safe-base", "--dry-run"]


def test_elevated_program_prefers_phasezero_admin(catalog):
    action = next(item for item in catalog if item.id == "boot.safe-menu")
    with patch("linux.ui_native.command_runner.shutil.which") as which:
        which.side_effect = lambda name: "/usr/bin/phasezero-admin" if name == "phasezero-admin" else None
        program, args = build_program(ROOT, action, preview=False)
    assert program == "/usr/bin/phasezero-admin"
    assert args[0] == str(ROOT / "linux" / "pz")
    assert args[1:] == ["boot", "install-safe-menu"]


def test_boot_selector_uses_admin_bridge_without_shell():
    with patch("linux.ui_native.boot_selector.shutil.which") as which:
        which.side_effect = lambda name: "/usr/bin/bigsudo" if name == "bigsudo" else None
        program, args = build_boot_selector_program(ROOT, "windows", reboot=True)
    assert program == "/usr/bin/bigsudo"
    assert args == [str(ROOT / "linux" / "pz"), "boot", "choose", "windows", "--reboot"]
    assert [choice.key for choice in BOOT_CHOICES] == [
        "normal",
        "steamos",
        "windows",
        "waydroid",
        "emergency",
    ]


def test_json_parser_accepts_logs_before_envelope():
    text = 'INFO: checking\n{"status":"warn","checks":[{"name":"x"}]}\n'
    assert parse_json_output(text)["status"] == "warn"
    assert severity_for(parse_json_output(text), 0) == "warning"
    assert severity_for(None, 1) == "error"


def test_manifest_serializes_catalog(catalog):
    manifest = catalog_manifest(ROOT)
    assert manifest["schemaVersion"] == 1
    assert len(manifest["actions"]) == len(catalog)
    json.dumps(manifest)


def test_appimage_bundle_is_standalone():
    apprun = (ROOT / "packaging" / "linux" / "appimage" / "AppRun").read_text()
    assert '"$PHASEZERO_ROOT:' in apprun, "linux.ui_native must resolve from any cwd"
    build = (ROOT / "packaging" / "linux" / "appimage" / "build-appimage.sh").read_text()
    assert "shiboken6==" in build, "PySide6 needs shiboken6 bundled explicitly"
    assert "--smoke-test" in build, "bundle must be smoke-tested before packaging"


def test_native_gui_offscreen_smoke(tmp_path):
    screenshot = tmp_path / "ui.png"
    state = tmp_path / "state"
    env = os.environ.copy()
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["XDG_STATE_HOME"] = str(state)
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "linux.ui_native",
            "--smoke-test",
            "--screenshot",
            str(screenshot),
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert screenshot.exists()
    assert screenshot.stat().st_size > 20_000


def test_boot_selector_offscreen_smoke(tmp_path):
    screenshot = tmp_path / "boot-selector.png"
    state = tmp_path / "state"
    env = os.environ.copy()
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["XDG_STATE_HOME"] = str(state)
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "linux.ui_native",
            "--boot-selector",
            "--smoke-test",
            "--screenshot",
            str(screenshot),
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert screenshot.exists()
    assert screenshot.stat().st_size > 10_000


def test_profile_preview_runs_without_mutation(tmp_path):
    env = os.environ.copy()
    env["HOME"] = str(tmp_path / "home")
    env["XDG_STATE_HOME"] = str(tmp_path / "state")
    Path(env["HOME"]).mkdir()
    result = subprocess.run(
        [str(ROOT / "linux" / "pz"), "install", "safe-base", "--dry-run"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "would install" in result.stdout.casefold()
    assert not (Path(env["HOME"]) / ".config").exists()


def test_qprocess_runner_writes_result_envelope(tmp_path):
    script = r"""
import json
from pathlib import Path
from PySide6.QtCore import QCoreApplication, QTimer
from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner

root = Path.cwd()
app = QCoreApplication([])
runner = CommandRunner(root)
action = next(a for a in build_catalog(root) if a.id == "system.version")
state = {"result": None}
def done(result):
    state["result"] = result
    app.quit()
runner.completed.connect(done)
QTimer.singleShot(10000, app.quit)
runner.start(action)
app.exec()
result = state["result"]
assert result is not None
assert result.ok
assert result.result_path.exists()
saved = json.loads(result.result_path.read_text())
assert saved["action"] == "system.version"
assert saved["exitCode"] == 0
"""
    env = os.environ.copy()
    env["XDG_STATE_HOME"] = str(tmp_path / "state")
    result = subprocess.run(
        [sys.executable, "-c", script],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 0, result.stderr
