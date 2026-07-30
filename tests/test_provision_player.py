from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from PySide6.QtCore import QObject, QTimer, QProcess
from PySide6.QtWidgets import QApplication, QMessageBox

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native import provision_player as pp_mod
from linux.ui_native.provision_player import (
    AsyncProc, ProvisionWorker, ProvisionPlayerWindow,
    ST_IDLE, ST_DONE, ST_FAILED, ST_CANCELLED, ST_PROVISIONING,
)


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(autouse=True)
def _isolated_state_path(tmp_path: Path) -> None:
    tmp_state = tmp_path / "windows-vm" / "player.json"
    tmp_state.parent.mkdir(parents=True)
    orig = pp_mod.PLAYER_STATE_PATH
    pp_mod.PLAYER_STATE_PATH = tmp_state
    yield
    pp_mod.PLAYER_STATE_PATH = orig


def _cleanup_player():
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    if ProvisionPlayerWindow._instance is not None:
        win = ProvisionPlayerWindow._instance
        if win._worker and win._worker.isRunning():
            win._worker.abort()
            win._worker.wait(2000)
        if win._async_proc:
            win._async_proc.abort()
        win._closing = True
        ProvisionPlayerWindow._instance = None
    for _ in range(10):
        QApplication.processEvents()
        time.sleep(0.05)
    if PLAYER_STATE_PATH.exists():
        PLAYER_STATE_PATH.unlink()


@pytest.fixture
def fake_pz(tmp_path: Path) -> Path:
    pz = tmp_path / "linux" / "pz"
    pz.parent.mkdir(parents=True)
    pz.write_text("#!/usr/bin/env bash\necho '{\"operationId\":\"op-test-001\",\"state\":\"running\"}'")
    pz.chmod(0o755)
    return tmp_path


@pytest.fixture
def fake_pz_with_status(tmp_path: Path) -> tuple[Path, Path]:
    pz = tmp_path / "linux" / "pz"
    pz.parent.mkdir(parents=True)
    fixture = tmp_path / "status_fixture.json"
    fixture.write_text(json.dumps({
        "state": "completed", "progress": 100,
        "checkpoint": "relaunch", "currentLabel": "test",
        "log": ["step1", "step2", "step3"],
        "vmDir": "/tmp/vm", "snapshotPath": "/tmp/snap.qcow2",
        "snapshotExists": True, "qemuPid": 0, "qemuRunning": False,
        "libvirtRunning": False,
    }))
    pz.write_text(f"""#!/usr/bin/env bash
case "$1" in
  provision)
    case "$2" in
      start) echo '{{"operationId":"op-test-001","state":"running"}}' ;;
      status) cat {fixture} ;;
      resume) exit 0 ;;
      cancel) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
""")
    pz.chmod(0o755)
    return tmp_path, fixture


# ── AsyncProc tests ──

def test_async_proc_timeout_emits_once(qapp, tmp_path: Path) -> None:
    script = tmp_path / "sleep.sh"
    script.write_text("#!/usr/bin/env bash\nsleep 10\n echo ok")
    script.chmod(0o755)

    results: list[tuple[object | None, int]] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))

    proc.run(str(script), [], timeout_ms=200)
    start = time.monotonic()
    while len(results) < 1 and time.monotonic() - start < 5:
        QApplication.processEvents()
        time.sleep(0.05)

    assert len(results) == 1
    assert results[0][1] == -1


def test_async_proc_failed_to_start_terminates(qapp) -> None:
    results: list[tuple[object | None, int]] = []
    errors: list[str] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))
    proc.errorOccurred.connect(lambda msg: errors.append(msg))

    proc.run("/nonexistent/binary", [], timeout_ms=500)
    start = time.monotonic()
    while len(results) < 1 and time.monotonic() - start < 3:
        QApplication.processEvents()
        time.sleep(0.05)

    assert len(results) == 1
    assert results[0][1] == -2


def test_async_proc_stdout_stderr_preserved(qapp, tmp_path: Path) -> None:
    script = tmp_path / "echo.sh"
    script.write_text("#!/usr/bin/env bash\necho '{\"ok\":true}'\necho errmsg >&2")
    script.chmod(0o755)

    results: list[tuple[object | None, int]] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))

    proc.run(str(script), [], timeout_ms=2000)
    start = time.monotonic()
    while len(results) < 1 and time.monotonic() - start < 3:
        QApplication.processEvents()
        time.sleep(0.05)

    assert len(results) == 1
    assert results[0][0] == {"ok": True}


def test_async_proc_abort_prevents_emit(qapp, tmp_path: Path) -> None:
    script = tmp_path / "sleep.sh"
    script.write_text("#!/usr/bin/env bash\nsleep 10\necho ok")
    script.chmod(0o755)

    results: list[tuple[object | None, int]] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))

    proc.run(str(script), [], timeout_ms=5000)
    proc.abort()
    QApplication.processEvents()
    time.sleep(0.1)
    QApplication.processEvents()

    assert len(results) == 0


# ── ProvisionWorker tests ──

def test_worker_attach_does_not_execute_start(fake_pz: Path) -> None:
    worker = ProvisionWorker(fake_pz, "plan-1", "tok-1")
    worker.configure_attach("op-existing-001")
    assert worker._mode == "attach"
    assert worker._operation_id == "op-existing-001"
    assert worker._plan_id == "plan-1"
    assert worker._confirm_token == "tok-1"


# ── Progress sequence tests ──

def test_progress_sequence_from_shell() -> None:
    script = ROOT / "linux" / "windows-vm" / "provision.sh"
    text = script.read_text(encoding="utf-8")
    m = re.search(r"CP_WEIGHTS=\(([^)]+)\)", text)
    assert m
    weights = [int(x) for x in m.group(1).split()]
    assert sum(weights) == 100

    checkpoints = ["validate", "assets", "answer-media", "disk", "setup",
                   "drivers", "tweaks", "verify", "snapshot", "relaunch"]
    start_seq = []
    end_seq = []
    for cp in checkpoints:
        s = 0
        e = 0
        for i, w in enumerate(weights):
            if checkpoints[i] == cp:
                e += w
                break
            s += w
            e += w
        start_seq.append(s)
        end_seq.append(e)

    assert start_seq == [0, 5, 15, 20, 50, 65, 75, 80, 85, 95]
    assert end_seq == [5, 15, 20, 50, 65, 75, 80, 85, 95, 100]


def test_progress_completed_is_100_from_shell() -> None:
    script = ROOT / "linux" / "windows-vm" / "provision.sh"
    text = script.read_text(encoding="utf-8")
    assert '.progress = 100' in text


# ── Window lifecycle tests ──

def test_close_aborts_worker(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None, iso="/fake.iso")
    win._operation_id = "op-test"
    win._attach_worker("op-test")
    assert win._worker is not None
    assert win._worker.isRunning()
    win.close()
    QApplication.processEvents()
    time.sleep(0.3)
    assert not win._worker.isRunning()
    _cleanup_player()


def test_player_action_intercepted_in_request_action(qapp) -> None:
    from linux.ui_native.main_window import MainWindow, ParameterDialog
    from linux.ui_native.catalog import build_catalog

    catalog = build_catalog(ROOT)
    player_action = [a for a in catalog if a.id == "windows.provision.player"]
    assert len(player_action) == 1
    assert player_action[0].args == ("--internal-player",)
    assert not player_action[0].elevated

    with (
        patch("linux.ui_native.main_window.ProvisionPlayerWindow.open") as mock_open,
        patch("linux.ui_native.main_window.CommandRunner.start") as mock_start,
        patch.object(ParameterDialog, "exec", return_value=ParameterDialog.Accepted),
        patch.object(ParameterDialog, "values", return_value={"input": "/fake.iso", "graphics": "compat", "image_index": "1"}),
    ):
        win = MainWindow(ROOT)
        win.request_action(player_action[0])
        mock_open.assert_called_once()
        mock_start.assert_not_called()


# ── Cancel/retry/discard non-zero exit handling ──

def test_cancel_transitions_to_cancelled(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_PROVISIONING
    win._operation_id = "op-test"
    win._on_cancel()
    for _ in range(100):
        QApplication.processEvents()
        if win._state in (ST_CANCELLED,):
            break
        time.sleep(0.05)
    assert win._state in (ST_CANCELLED,)
    _cleanup_player()


def test_retry_without_operation_fails(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None)
    win._operation_id = ""
    win._on_retry()
    QApplication.processEvents()
    assert win._state == ST_FAILED
    _cleanup_player()


def test_discard_removes_state_file(qapp) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    for _ in range(5):
        QApplication.processEvents()
        time.sleep(0.05)
    try:
        win = ProvisionPlayerWindow(ROOT, MagicMock(), None)
        win._operation_id = ""
        win._set_state(ST_FAILED)
        win._save_state()
        assert PLAYER_STATE_PATH.exists()
        with patch("linux.ui_native.provision_player.QMessageBox.question",
                   return_value=QMessageBox.Yes):
            win._on_discard()
        for _ in range(20):
            QApplication.processEvents()
            time.sleep(0.02)
        assert not PLAYER_STATE_PATH.exists()
    finally:
        for _ in range(5):
            QApplication.processEvents()
            time.sleep(0.05)
        _cleanup_player()
