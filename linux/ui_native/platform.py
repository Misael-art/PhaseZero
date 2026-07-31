from __future__ import annotations

import os
import shutil
import signal
import sys
from pathlib import Path


def current_platform(value: str | None = None) -> str:
    if value:
        normalized = value.casefold()
        return "windows" if normalized.startswith("win") else "linux"
    return "windows" if sys.platform.startswith("win") else "linux"


def state_dir(platform_name: str | None = None) -> Path:
    if current_platform(platform_name) == "windows":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / "PhaseZero" / "control-center"
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")).expanduser()
    return base / "phasezero" / "control-center"


def secure_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if current_platform() == "linux":
        try:
            path.chmod(0o700)
        except OSError:
            pass
    return path


def secure_file(path: Path, content: str) -> Path:
    secure_directory(path.parent)
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        if current_platform() == "linux":
            temporary.chmod(0o600)
        temporary.replace(path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return path


def admin_bridge() -> str:
    return shutil.which("phasezero-admin") or shutil.which("bigsudo") or shutil.which("pkexec") or ""


def configure_process_group(process: QProcess) -> None:
    from PySide6.QtCore import QProcess
    if current_platform() != "linux" or not hasattr(process, "setUnixProcessParameters"):
        return
    parameters = QProcess.UnixProcessParameters()
    parameters.flags = QProcess.UnixProcessFlag.CreateNewSession
    process.setUnixProcessParameters(parameters)


def terminate_process_group(process: QProcess, *, force: bool = False) -> None:
    from PySide6.QtCore import QProcess
    if process.state() == QProcess.NotRunning:
        return
    pid = process.processId()
    if current_platform() == "linux" and pid:
        try:
            os.killpg(pid, signal.SIGKILL if force else signal.SIGTERM)
            return
        except OSError:
            pass
    if force:
        process.kill()
    else:
        process.terminate()


def open_path(path: Path) -> bool:
    from PySide6.QtCore import QUrl
    from PySide6.QtGui import QDesktopServices
    return QDesktopServices.openUrl(QUrl.fromLocalFile(str(path.resolve())))
