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
    ST_IDLE, ST_DONE, ST_FAILED, ST_CANCELLED, ST_PROVISIONING, ST_VALIDATING,
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
  windows-vm)
    case "$2" in
      provision)
        case "$3" in
          start) echo '{{"operationId":"op-test-001","state":"running"}}' ;;
          status) cat {fixture} ;;
          resume) exit 0 ;;
          cancel)
            if [ -n "$PZ_FAKE_CANCEL_FAIL" ]; then exit 1; fi
            if [ -n "$PZ_FAKE_CANCEL_NO_REMOVE" ]; then
              echo '{{"success":true,"cancelled":true,"removalRequested":true,"removalSucceeded":false,"preservedPath":"/tmp/vm","error":"staging removal failed","operationId":"op-test-001"}}'
              exit 1
            fi
            case " $* " in
              *" --remove-staging "*)
                echo '{{"success":true,"cancelled":true,"removalRequested":true,"removalSucceeded":true,"preservedPath":"","error":"","operationId":"op-test-001"}}' ;;
              *)
                echo '{{"success":true,"cancelled":true,"removalRequested":false,"removalSucceeded":false,"preservedPath":"","error":"","operationId":"op-test-001"}}' ;;
            esac ;;
          shutdown)
            if [ -n "$PZ_FAKE_SHUTDOWN_FAIL" ]; then
              echo '{{"success":false,"operationId":"op-test-001","waitedSeconds":0}}'
              exit 1
            fi
            echo '{{"success":true,"operationId":"op-test-001","waitedSeconds":2}}' ;;
          *) exit 1 ;;
        esac
        ;;
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


def test_completed_snapshot_is_finalized_before_boot_validation(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None, iso="/fake.iso")
    with patch.object(win, "_run_finalize_async") as finalize:
        win._on_validation_result({
            "snapshotExists": True,
            "qemuRunning": False,
            "libvirtRunning": False,
            "adoptedDiskExists": False,
        }, 0)
    finalize.assert_called_once_with([])
    _cleanup_player()


def test_finalize_success_continues_to_boot_validation(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None, iso="/fake.iso")
    issues: list[str] = []
    with patch.object(win, "_fetch_boot_status_async") as boot_status:
        win._on_finalize_result({"success": True, "adoptedDisk": "/tmp/windows.qcow2"}, 0, issues)
    assert win._adopted_ok is True
    assert issues == []
    boot_status.assert_called_once_with(issues)
    _cleanup_player()


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


def test_cancel_failure_transitions_to_failed(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_PROVISIONING
    win._operation_id = "op-test"
    with patch.dict("os.environ", {"PZ_FAKE_CANCEL_FAIL": "1"}):
        win._on_cancel()
    for _ in range(100):
        QApplication.processEvents()
        if win._state in (ST_FAILED, ST_CANCELLED):
            break
        time.sleep(0.05)
    assert win._state == ST_FAILED, "cancel failure must not mark cancelled"
    assert "Cancelamento falhou" in win._checkpoint_label.text()
    _cleanup_player()


def test_cancel_failure_keeps_player_state(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_PROVISIONING
    win._operation_id = "op-test"
    win._save_state()
    with patch.dict("os.environ", {"PZ_FAKE_CANCEL_FAIL": "1"}):
        win._on_cancel()
    for _ in range(100):
        QApplication.processEvents()
        if win._state in (ST_FAILED, ST_CANCELLED):
            break
        time.sleep(0.05)
    assert win._state == ST_FAILED
    assert PLAYER_STATE_PATH.exists(), "player.json must survive a failed cancel (attach/resume)"
    _cleanup_player()


def test_discard_success_removes_state_and_closes(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_FAILED
    win._operation_id = "op-test"
    win._save_state()
    assert PLAYER_STATE_PATH.exists()
    with patch("linux.ui_native.provision_player.QMessageBox.question",
               return_value=QMessageBox.Yes):
        win._on_discard()
    for _ in range(100):
        QApplication.processEvents()
        if win._discarding:
            break
        time.sleep(0.05)
    assert win._discarding, "discard must close after removal confirmed"
    assert not PLAYER_STATE_PATH.exists()
    _cleanup_player()


def test_discard_failure_keeps_window_and_state(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_FAILED
    win._operation_id = "op-test"
    win._save_state()
    with (
        patch.dict("os.environ", {"PZ_FAKE_CANCEL_NO_REMOVE": "1"}),
        patch("linux.ui_native.provision_player.QMessageBox.question",
              return_value=QMessageBox.Yes),
    ):
        win._on_discard()
    for _ in range(100):
        QApplication.processEvents()
        if "Descarte falhou" in win._checkpoint_label.text():
            break
        time.sleep(0.05)
    assert win._state == ST_FAILED, "discard failure must not close the window"
    assert not win._discarding
    assert PLAYER_STATE_PATH.exists(), "player.json must survive a failed discard"
    assert "Descarte falhou" in win._checkpoint_label.text()
    _cleanup_player()


def test_shutdown_requires_json_success(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_DONE
    win._operation_id = "op-test"
    win._on_shutdown_vm()
    for _ in range(100):
        QApplication.processEvents()
        if win._async_proc is None:
            break
        time.sleep(0.05)
    assert win._vm_running is False
    assert win._state in (ST_DONE, ST_VALIDATING)
    _cleanup_player()


def test_shutdown_failure_stays_failed(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_DONE
    win._operation_id = "op-test"
    win._vm_running = True
    with patch.dict("os.environ", {"PZ_FAKE_SHUTDOWN_FAIL": "1"}):
        win._on_shutdown_vm()
    for _ in range(100):
        QApplication.processEvents()
        if win._async_proc is None:
            break
        time.sleep(0.05)
    assert win._vm_running is True, "failed shutdown must not clear vm_running"
    assert "Desligamento falhou" in win._checkpoint_label.text()
    _cleanup_player()


def test_reboot_stores_proc_and_error_restores_ui(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_DONE
    win._one_shot_ready = True
    win._vm_running = False
    win._reboot_btn.setEnabled(True)
    bridge = fake_root / "bridge"
    bridge.write_text("#!/usr/bin/env bash\nexit 3\n")
    bridge.chmod(0o755)
    with (
        patch("linux.ui_native.provision_player.admin_bridge", return_value=str(bridge)),
        patch("linux.ui_native.provision_player.QMessageBox.question",
              return_value=QMessageBox.Yes),
    ):
        win._on_reboot()
    assert win._reboot_proc is not None, "reboot QProcess must be stored"
    for _ in range(100):
        QApplication.processEvents()
        if win._reboot_proc is None:
            break
        time.sleep(0.05)
    assert win._reboot_proc is None, "reboot proc must be released after finished"
    assert "Rein\u00edcio falhou" in win._checkpoint_label.text()
    assert win._progress_bar.maximum() == 100, "UI must be restored after reboot failure"
    assert win._reboot_btn.isEnabled(), "reboot button must be re-enabled"
    _cleanup_player()


def test_reboot_success_message(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_DONE
    win._one_shot_ready = True
    win._vm_running = False
    bridge = fake_root / "bridge-ok"
    bridge.write_text("#!/usr/bin/env bash\nexit 0\n")
    bridge.chmod(0o755)
    with (
        patch("linux.ui_native.provision_player.admin_bridge", return_value=str(bridge)),
        patch("linux.ui_native.provision_player.QMessageBox.question",
              return_value=QMessageBox.Yes),
    ):
        win._on_reboot()
    for _ in range(100):
        QApplication.processEvents()
        if win._reboot_proc is None:
            break
        time.sleep(0.05)
    assert "Rein\u00edcio agendado" in win._checkpoint_label.text()
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


def test_open_params_beat_persisted_state(qapp) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    try:
        PLAYER_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        PLAYER_STATE_PATH.write_text(json.dumps({
            "state": "failed",
            "iso": "/old.iso",
            "graphics": "virtio-gl",
            "imageIndex": "99",
            "operationId": "",
        }))
        win = ProvisionPlayerWindow(ROOT, MagicMock(), None,
                                    iso="/new.iso", graphics="compat",
                                    image_index="2")
        assert win._iso == "/new.iso", f"expected /new.iso, got {win._iso}"
        assert win._graphics == "compat", f"expected compat, got {win._graphics}"
        assert win._image_index == "2", f"expected 2, got {win._image_index}"
    finally:
        _cleanup_player()
