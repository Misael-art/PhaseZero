from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from PySide6.QtCore import QEventLoop, QProcess, QTimer
from PySide6.QtWidgets import QApplication, QPushButton


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_development_cancel_runs_engine_to_safe_boundary_and_keeps_resume_record(
    qapp, tmp_path, monkeypatch,
):
    from linux.ui_native.main_window import MainWindow

    home = tmp_path / "home"
    config = home / ".config"
    data = home / ".local" / "share"
    state = home / ".local" / "state"
    for path in (home, config, data, state):
        path.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(config))
    monkeypatch.setenv("XDG_DATA_HOME", str(data))
    monkeypatch.setenv("XDG_STATE_HOME", str(state))

    capability_state = state / "phasezero-capabilities"
    package_state = tmp_path / "installed-packages.json"
    package_events = tmp_path / "fake-package-events.jsonl"
    pid_file = tmp_path / "child.pid"
    marker = tmp_path / "child-survived-cancel"
    monkeypatch.setenv("PZ_CAPABILITIES_STATE_DIR", str(capability_state))
    monkeypatch.setenv("PZ_TEST_PACKAGE_STATE", str(package_state))
    monkeypatch.setenv("PZ_TEST_PACKAGE_EVENTS", str(package_events))
    monkeypatch.setenv("PZ_TEST_CHILD_PID", str(pid_file))
    monkeypatch.setenv("PZ_TEST_CHILD_MARKER", str(marker))

    from linux.capabilities import engine
    from linux.capabilities.platform import HostFacts
    from linux.capabilities.providers import Provider

    facts = HostFacts(
        platform="linux", architecture="x86_64", distro="arch", distro_like=(),
        package_family="arch", immutable=False, immutable_kind="", container=False,
        init="systemd", desktop="kde", session="wayland", gpus=("amd",),
        package_manager="pacman", flatpak=True, flathub=True,
    )

    class PlanningProvider(Provider):
        def installed(self, _source):
            return False

        def available(self, _source):
            return True

        def estimate_space(self, _source):
            return {"downloadBytes": 1024, "installedBytes": 4096}

        def estimate_transaction_space(self, _sources):
            return None

    monkeypatch.setattr(
        engine.shutil, "disk_usage",
        lambda _path: SimpleNamespace(free=10**12, total=10**12, used=0),
    )
    plan = engine.create_plan(
        profile_ids=["development-web-js"], facts=facts,
        provider=PlanningProvider(facts),
    )
    assert not plan["blockers"]
    assert [item["capabilityId"] for item in plan["actions"]] == [
        "development.nodejs", "development.pnpm",
    ]

    fake = tmp_path / "fake_provider.py"
    fake.write_text(
        "import json, os, subprocess, sys\n"
        "from pathlib import Path\n"
        "from types import SimpleNamespace\n"
        "sys.path.insert(0, r'__ROOT__')\n"
        "from linux.capabilities import __main__ as cli\n"
        "from linux.capabilities import engine\n"
        "from linux.capabilities.platform import HostFacts\n"
        "from linux.capabilities.providers import Provider\n"
        "facts = HostFacts(\n"
        " platform='linux', architecture='x86_64', distro='arch', distro_like=(),\n"
        " package_family='arch', immutable=False, immutable_kind='', container=False,\n"
        " init='systemd', desktop='kde', session='wayland', gpus=('amd',),\n"
        " package_manager='pacman', flatpak=True, flathub=True,\n"
        ")\n"
        "package_state = Path(os.environ['PZ_TEST_PACKAGE_STATE'])\n"
        "package_events = Path(os.environ['PZ_TEST_PACKAGE_EVENTS'])\n"
        "pid_file = Path(os.environ['PZ_TEST_CHILD_PID'])\n"
        "marker = Path(os.environ['PZ_TEST_CHILD_MARKER'])\n"
        "def installed_packages():\n"
        " return set(json.loads(package_state.read_text(encoding='utf-8'))) if package_state.exists() else set()\n"
        "class FakeProvider(Provider):\n"
        " def __init__(self):\n"
        "  super().__init__(facts)\n"
        " def installed(self, source):\n"
        "  return source.name in installed_packages()\n"
        " def available(self, _source):\n"
        "  return True\n"
        " def estimate_space(self, _source):\n"
        "  return {'downloadBytes': 1024, 'installedBytes': 4096}\n"
        " def estimate_transaction_space(self, _sources):\n"
        "  return None\n"
        " def execute(self, plan):\n"
        "  package = plan.args[-1]\n"
        "  with package_events.open('a', encoding='utf-8') as stream:\n"
        "   stream.write(json.dumps({'package': package}) + '\\n')\n"
        "  if package == 'nodejs':\n"
        "   code = 'import time; from pathlib import Path; import sys; time.sleep(2.0); '\n"
        "   code += 'Path(sys.argv[1]).write_bytes(bytes([115,116,101,112,45,102,105,110,105,115,104,101,100]))'\n"
        "   child = subprocess.Popen([sys.executable, '-c', code, str(marker)])\n"
        "   pid_file.write_text(str(child.pid), encoding='utf-8')\n"
        "   child_code = child.wait()\n"
        "   if child_code != 0:\n"
        "    return child_code, '', 'fixture child failed'\n"
        "  packages = installed_packages()\n"
        "  packages.add(package)\n"
        "  package_state.write_text(json.dumps(sorted(packages)), encoding='utf-8')\n"
        "  return 0, 'fixture package installed', ''\n"
        "provider = FakeProvider()\n"
        "engine.shutil.disk_usage = lambda _path: SimpleNamespace(free=10**12, total=10**12, used=0)\n"
        "real_apply_plan = engine.apply_plan\n"
        "cli.detect = lambda: facts\n"
        "cli.apply_plan = lambda plan_id, **kwargs: real_apply_plan(\n"
        " plan_id, facts=facts, provider=provider, **kwargs,\n"
        ")\n"
        "arguments = sys.argv[1:]\n"
        "if arguments and arguments[0] == 'capabilities':\n"
        " arguments = arguments[1:]\n"
        "raise SystemExit(cli.main(arguments))\n".replace("__ROOT__", str(ROOT)),
        encoding="utf-8",
    )

    def fake_request_action(window, action):
        # Cancellation under test; preview confirmation is covered by the
        # Development page's existing public-action tests.
        window.pending_action = action
        window.runner.start(action, preview=False)

    def fake_build_program(_root, _action, *, preview, value="", values=None):
        assert not preview
        return sys.executable, [
            str(fake), "capabilities", "apply", "--plan-id", plan["id"],
            "--confirm", plan["confirmToken"],
        ]

    completed = []
    loop = QEventLoop()

    def quiet_operation_completed(window, result):
        completed.append(result)
        window.cancel_button.setEnabled(False)
        loop.quit()

    monkeypatch.setattr(MainWindow, "request_action", fake_request_action)
    monkeypatch.setattr(MainWindow, "operation_completed", quiet_operation_completed)
    monkeypatch.setattr("linux.ui_native.command_runner.build_program", fake_build_program)
    host_patcher = patch.object(MainWindow, "_host_summary")
    status_patcher = patch("linux.ui_native.status_loader.StatusLoader.fetch_product_status")
    host_patcher.start()
    status_patcher.start()
    window = MainWindow(ROOT)
    cancelled = []
    cancel_file_paths = []
    window._ask_cancel = lambda _title, _elevated: True

    cancel_timer = QTimer(window)

    def cancel_when_package_running() -> None:
        if pid_file.is_file() and not cancelled:
            cancelled.append(True)
            assert window.cancel_button.isEnabled()
            window.cancel_button.click()
            assert window.runner.safe_cancel_pending
            assert window.runner.process.state() != QProcess.NotRunning
            assert window.runner._cancel_file is not None
            assert window.runner._cancel_file.is_file()
            cancel_file_paths.append(window.runner._cancel_file)

    cancel_timer.timeout.connect(cancel_when_package_running)
    try:
        window.show_category("Desenvolvimento")
        prepare = window.findChild(QPushButton, "prepareDevelopment")
        assert prepare is not None
        prepare.click()
        cancel_timer.start(20)
        QTimer.singleShot(6000, loop.quit)
        loop.exec()
        cancel_timer.stop()
        assert completed
        assert cancelled
        assert int(pid_file.read_text(encoding="utf-8")) > 0

        # The in-flight package step finishes; cancellation prevents later steps.
        assert marker.read_bytes() == b"step-finished"
        assert completed[0].exit_code == 130, (
            completed[0].stdout, completed[0].stderr, completed[0].parsed,
        )
        assert completed[0].parsed["status"] == "cancelled"
        assert completed[0].parsed["results"] == [{
            "capabilityId": "development.nodejs", "status": "installed",
            "exitCode": 0, "stdout": "fixture package installed", "stderr": "",
        }]
        assert json.loads(package_state.read_text(encoding="utf-8")) == ["nodejs"]
        package_attempts = [
            json.loads(line)["package"]
            for line in package_events.read_text(encoding="utf-8").splitlines()
        ]
        assert package_attempts == ["nodejs"]

        record = window.runner.ledger.records(limit=1)[0]
        assert record["status"] == "cancelled"
        assert record["resumable"] is True
        assert record["resumeMode"] == "retry-with-confirmation"
        assert record["nextAction"] == completed[0].action_id
        assert len(cancel_file_paths) == 1
        assert not cancel_file_paths[0].exists()
    finally:
        cancel_timer.stop()
        window.close()
        host_patcher.stop()
        status_patcher.stop()
