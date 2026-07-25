from __future__ import annotations

import stat
from pathlib import Path
from unittest.mock import Mock, patch

from PySide6.QtCore import QProcess

from linux.ui_native.catalog import build_catalog
from linux.ui_native.platform import (
    configure_process_group,
    current_platform,
    secure_file,
    state_dir,
    terminate_process_group,
)


ROOT = Path(__file__).resolve().parents[1]


def test_catalog_filters_linux_only_actions_for_windows():
    linux = build_catalog(ROOT, "linux")
    windows = build_catalog(ROOT, "win32")
    assert linux
    assert all("linux" in action.platforms for action in linux)
    assert windows == []


def test_windows_state_directory_uses_local_app_data(monkeypatch, tmp_path):
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    assert state_dir("windows") == tmp_path / "PhaseZero" / "control-center"


def test_linux_state_directory_uses_xdg(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    assert state_dir("linux") == tmp_path / "phasezero" / "control-center"


def test_secure_file_is_private_and_atomic(tmp_path):
    target = secure_file(tmp_path / "private" / "result.json", "{}\n")
    assert target.read_text(encoding="utf-8") == "{}\n"
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert not list(target.parent.glob("*.tmp"))


def test_windows_process_helpers_do_not_touch_unix_primitives():
    process = Mock(spec=QProcess)
    process.state.return_value = QProcess.Running
    process.processId.return_value = 123
    with patch("linux.ui_native.platform.current_platform", return_value="windows"), patch(
        "linux.ui_native.platform.os.killpg"
    ) as killpg:
        configure_process_group(process)
        terminate_process_group(process)
    killpg.assert_not_called()
    process.terminate.assert_called_once()


def test_platform_name_normalization():
    assert current_platform("win32") == "windows"
    assert current_platform("linux") == "linux"
