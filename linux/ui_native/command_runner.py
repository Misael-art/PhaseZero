from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import signal
from datetime import datetime, timezone
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, Signal

from .models import ActionSpec, OperationResult
from .result_parser import parse_json_output

CAPTURE_LIMIT = 8 * 1024 * 1024


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def state_dir() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")).expanduser()
    return base / "phasezero" / "control-center"


def build_program(
    root: Path, action: ActionSpec, *, preview: bool, value: str = ""
) -> tuple[str, list[str]]:
    pz = str(root / "linux" / "pz")
    args = action.resolved_args(value, preview=preview)
    if "{input}" in args or (action.input_kind and not value):
        raise ValueError(f"input required for {action.id}")
    if action.elevated and not preview:
        bridge = shutil.which("phasezero-admin") or shutil.which("bigsudo") or shutil.which("pkexec")
        if not bridge:
            raise RuntimeError("elevação indisponível; execute `linux/pz ai setup admin`")
        return bridge, [pz, *args]
    return pz, args


class CommandRunner(QObject):
    output = Signal(str, bool)
    progress = Signal(int)
    started = Signal(str)
    completed = Signal(object)
    failed_to_start = Signal(str)

    def __init__(
        self, root: Path, parent: QObject | None = None, *, timeout_ms: int = 30 * 60 * 1000
    ) -> None:
        super().__init__(parent)
        self.root = root
        self.process: QProcess | None = None
        self.action: ActionSpec | None = None
        self.preview = False
        self.command: list[str] = []
        self.stdout_parts: list[str] = []
        self.stderr_parts: list[str] = []
        self._stdout_size = 0
        self._stderr_size = 0
        self.started_at = ""
        self.timeout_ms = timeout_ms
        self.timeout_timer = QTimer(self)
        self.timeout_timer.setSingleShot(True)
        self.timeout_timer.timeout.connect(self._timeout)

    @property
    def running(self) -> bool:
        return self.process is not None and self.process.state() != QProcess.NotRunning

    def start(self, action: ActionSpec, *, preview: bool = False, value: str = "") -> None:
        if self.running:
            raise RuntimeError("operation already running")
        program, args = build_program(self.root, action, preview=preview, value=value)
        self.action = action
        self.preview = preview
        self.command = [program, *args]
        self.stdout_parts = []
        self.stderr_parts = []
        self._stdout_size = 0
        self._stderr_size = 0
        self.started_at = utc_now()
        process = QProcess(self)
        process.setWorkingDirectory(str(self.root))
        env = QProcessEnvironment.systemEnvironment()
        env.insert("PYTHONUNBUFFERED", "1")
        env.insert("PZ_UI", "native")
        admin_bin = str(self.root / "linux" / "ui_native" / "admin-bin")
        env.insert("PATH", admin_bin + os.pathsep + env.value("PATH"))
        process.setProcessEnvironment(env)
        if hasattr(process, "setUnixProcessParameters"):
            parameters = QProcess.UnixProcessParameters()
            parameters.flags = QProcess.UnixProcessFlag.CreateNewSession
            process.setUnixProcessParameters(parameters)
        process.setProgram(program)
        process.setArguments(args)
        process.setProcessChannelMode(QProcess.SeparateChannels)
        process.readyReadStandardOutput.connect(self._stdout)
        process.readyReadStandardError.connect(self._stderr)
        process.errorOccurred.connect(self._error)
        process.finished.connect(self._finished)
        self.process = process
        display = shlex.join(self.command)
        self.started.emit(display)
        process.start()
        self.timeout_timer.start(self.timeout_ms)

    def cancel(self) -> None:
        if not self.running or self.process is None:
            return
        process = self.process
        pid = process.processId()
        if pid:
            try:
                os.killpg(pid, signal.SIGTERM)
            except OSError:
                process.terminate()
        else:
            process.terminate()
        QTimer.singleShot(
            2000,
            lambda: process.kill() if process.state() != QProcess.NotRunning else None,
        )

    def shutdown(self, timeout_ms: int = 2500) -> None:
        """Stop the whole process group before the application exits."""
        process = self.process
        if process is None or process.state() == QProcess.NotRunning:
            return
        self.cancel()
        if process.waitForFinished(timeout_ms):
            return
        pid = process.processId()
        if pid:
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                process.kill()
        else:
            process.kill()
        process.waitForFinished(1000)

    def _capture(self, text: str, *, stderr: bool) -> None:
        parts = self.stderr_parts if stderr else self.stdout_parts
        size_name = "_stderr_size" if stderr else "_stdout_size"
        current = getattr(self, size_name)
        if current >= CAPTURE_LIMIT:
            return
        remaining = CAPTURE_LIMIT - current
        encoded = text.encode("utf-8", errors="replace")
        if len(encoded) <= remaining:
            parts.append(text)
            setattr(self, size_name, current + len(encoded))
            return
        captured = encoded[:remaining].decode("utf-8", errors="ignore")
        parts.append(captured + "\n[saída truncada pelo limite da interface]\n")
        setattr(self, size_name, CAPTURE_LIMIT)

    def _decode(self, data: bytes) -> str:
        return bytes(data).decode("utf-8", errors="replace")

    def _stdout(self) -> None:
        if self.process is None:
            return
        text = self._decode(self.process.readAllStandardOutput().data())
        self._capture(text, stderr=False)
        self.output.emit(text, False)
        matches = re.findall(r"(?<!\d)(100|[1-9]?\d)%", text)
        if matches:
            self.progress.emit(int(matches[-1]))

    def _stderr(self) -> None:
        if self.process is None:
            return
        text = self._decode(self.process.readAllStandardError().data())
        self._capture(text, stderr=True)
        self.output.emit(text, True)

    def _error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.FailedToStart and self.process is not None:
            message = self.process.errorString()
            self._capture(message, stderr=True)
            self.failed_to_start.emit(message)
            self._finished(127, QProcess.CrashExit)

    def _timeout(self) -> None:
        if not self.running:
            return
        message = f"operation timed out after {self.timeout_ms // 1000}s\n"
        self._capture(message, stderr=True)
        self.output.emit(message, True)
        self.cancel()

    def _finished(self, code: int, _status: QProcess.ExitStatus) -> None:
        if self.action is None:
            return
        # QProcess may report completion before the final readyRead callback.
        self._stdout()
        self._stderr()
        self.timeout_timer.stop()
        action = self.action
        self.action = None
        stdout = "".join(self.stdout_parts)
        stderr = "".join(self.stderr_parts)
        parsed = parse_json_output(stdout)
        result = OperationResult(
            action_id=action.id,
            command=self.command,
            preview=self.preview,
            exit_code=code,
            started_at=self.started_at,
            finished_at=utc_now(),
            stdout=stdout,
            stderr=stderr,
            parsed=parsed,
        )
        try:
            private_state = state_dir()
            private_state.mkdir(parents=True, exist_ok=True, mode=0o700)
            destination = private_state / "results"
            destination.mkdir(exist_ok=True, mode=0o700)
            try:
                private_state.chmod(0o700)
                destination.chmod(0o700)
            except OSError:
                pass
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            safe_id = re.sub(r"[^a-zA-Z0-9_.-]", "-", action.id)
            result_path = destination / f"{stamp}-{safe_id}.json"
            temporary = result_path.with_suffix(".tmp")
            payload = json.dumps(result.to_dict(), ensure_ascii=False, indent=2) + "\n"
            with temporary.open("x", encoding="utf-8") as handle:
                try:
                    os.chmod(handle.fileno(), 0o600)
                except OSError:
                    pass
                handle.write(payload)
            temporary.replace(result_path)
            result.result_path = result_path
        except OSError as exc:
            result.stderr += f"\nfailed to persist result: {exc}\n"
        self.process = None
        self.completed.emit(result)
