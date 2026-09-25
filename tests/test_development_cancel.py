from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import QEventLoop, QProcess, QTimer
from PySide6.QtWidgets import QApplication, QPushButton


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_development_cancel_waits_for_safe_step_and_keeps_resume_record(qapp, tmp_path, monkeypatch):
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

    pid_file = tmp_path / "child.pid"
    marker = tmp_path / "child-survived-cancel"
    fake = tmp_path / "fake_provider.py"
    fake.write_text(
        "import json, subprocess, sys\n"
        "from pathlib import Path\n"
        "pid_file, marker = map(Path, sys.argv[1:3])\n"
        "extra = sys.argv[3:]\n"
        "cancel_file = Path(extra[extra.index('--cancel-file') + 1])\n"
        "code = 'import time; from pathlib import Path; import sys; time.sleep(2.0); '\n"
        "code += 'Path(sys.argv[1]).write_bytes(bytes([115,116,101,112,45,102,105,110,105,115,104,101,100]))'\n"
        "child = subprocess.Popen([sys.executable, '-c', code, str(marker)])\n"
        "pid_file.write_text(str(child.pid))\n"
        "print('ready', flush=True)\n"
        "child.wait()\n"
        "if cancel_file.is_file():\n"
        " print(json.dumps({'status': 'cancelled'}), flush=True)\n"
        " raise SystemExit(130)\n"
        "print(json.dumps({'status': 'complete'}), flush=True)\n",
        encoding="utf-8",
    )

    def fake_request_action(window, action):
        # Cancellation under test; preview confirmation is covered by the
        # Development page's existing public-action tests.
        window.pending_action = action
        window.runner.start(action, preview=False)

    def fake_build_program(_root, _action, *, preview, value="", values=None):
        assert not preview
        return sys.executable, [str(fake), str(pid_file), str(marker)]

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
    window._ask_cancel = lambda _title, _elevated: True

    def cancel_when_ready(text: str, _is_error: bool) -> None:
        if "ready" in text and not cancelled:
            cancelled.append(True)
            assert window.cancel_button.isEnabled()
            window.cancel_button.click()
            assert window.runner.safe_cancel_pending
            assert window.runner.process.state() != QProcess.NotRunning
            assert window.runner._cancel_file is not None
            assert window.runner._cancel_file.is_file()

    window.runner.output.connect(cancel_when_ready)
    try:
        window.show_category("Desenvolvimento")
        prepare = window.findChild(QPushButton, "prepareDevelopment")
        assert prepare is not None
        prepare.click()
        QTimer.singleShot(6000, loop.quit)
        loop.exec()
        assert completed
        assert cancelled
        assert int(pid_file.read_text(encoding="utf-8")) > 0

        # The in-flight package step finishes; cancellation prevents later steps.
        assert marker.read_bytes() == b"step-finished"
        assert completed[0].exit_code == 130, (
            completed[0].stdout, completed[0].stderr, completed[0].parsed,
        )
        assert completed[0].parsed["status"] == "cancelled"

        record = window.runner.ledger.records(limit=1)[0]
        assert record["status"] == "cancelled"
        assert record["resumable"] is True
        assert record["resumeMode"] == "retry-with-confirmation"
        assert record["nextAction"] == completed[0].action_id
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()
