from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QTimer, Signal
from shiboken6 import isValid

from .models import ActionSpec
from .result_parser import parse_json_output

_SECRET_PATTERNS = (
    (r"(?i)(token|secret|password|api[_-]?key)\s*[:=]\s*\S+", r"\1=[REDACTED]"),
    (r"(?:sk-|ghp_|github_pat_)[A-Za-z0-9_-]{16,}", "[REDACTED]"),
)


def redact(text: str) -> str:
    import re

    for pattern, replacement in _SECRET_PATTERNS:
        text = re.sub(pattern, replacement, text)
    return text


def report_outcome(stdout: str, stderr: str, exit_code: int) -> tuple[str, object, str]:
    """Decide whether a finished status run produced a usable report.

    Returns ("ready", parsed, "") when the command reported state as JSON —
    even with a non-zero exit code, because readiness lives in the payload —
    and ("failed", None, message) when there is no report to show.
    """
    parsed = parse_json_output(stdout)
    if isinstance(parsed, dict) and parsed:
        return "ready", parsed, ""
    if exit_code != 0:
        detail = redact(stderr.strip())[:500]
        return "failed", None, f"exit code {exit_code}" + (f": {detail}" if detail else "")
    return "ready", parsed, ""

_DEFAULT_TIMEOUT_MS = 15_000
_ACTION_TIMEOUT_MS = {
    # Windows status includes bounded libvirt, Samba, disk and boot probes.
    # Slower storage/daemon recovery can legitimately exceed the generic UI
    # budget without meaning that the VM state is unavailable.
    "windows.status": 45_000,
}


class StatusLoader(QObject):
    """Fetches status for read-only actions asynchronously via QProcess.

    Unlike CommandRunner, this runs multiple status commands in parallel
    (read-only, non-blocking) and does not use the operation panel.
    """

    status_ready = Signal(str, str, object)  # (action_id, stdout, parsed_result)
    status_failed = Signal(str, str)          # (action_id, error_message)

    def __init__(self, root: Path, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.root = root
        self._processes: dict[str, QProcess] = {}

    def _pz_path(self) -> Path:
        return self.root / "linux" / "pz"

    def fetch(self, action_id: str, args: list[str]) -> None:
        """Start fetching status for the given action. Idempotent per action_id."""
        if action_id in self._processes:
            return  # already fetching
        pz = str(self._pz_path())
        process = QProcess(self)
        process.setWorkingDirectory(str(self.root))
        process.setProgram(pz)
        process.setArguments(args)
        process.setProcessChannelMode(QProcess.SeparateChannels)
        process.finished.connect(
            lambda code, _status, aid=action_id: self._on_finished(aid, code, process)
        )
        process.errorOccurred.connect(
            lambda err, aid=action_id: self._on_error(aid, err, process)
        )
        self._processes[action_id] = process
        process.start()
        # Safety timeout remains bounded, but complex aggregate probes receive
        # an explicit budget instead of being reported as unavailable at 15s.
        timer = QTimer(self)
        timer.setSingleShot(True)
        timer.timeout.connect(lambda: self._on_timeout(action_id, process))
        timer.start(self.timeout_ms(action_id))
        process.setProperty("timeout_timer", timer)

    def fetch_action(self, action: ActionSpec) -> None:
        """Fetch status using the action's explicit read-only status contract."""
        args = action.status_args or action.args
        if any(token.startswith("{") and token.endswith("}") for token in args):
            self.status_failed.emit(action.id, "status requires parameters")
            return
        self.fetch(action.id, list(args))

    def cancel(self, action_id: str) -> None:
        process = self._processes.pop(action_id, None)
        if process is not None and isValid(process) and process.state() != QProcess.NotRunning:
            process.kill()
            process.waitForFinished(1000)
        self._cleanup_process(action_id, process)

    def cancel_all(self) -> None:
        for action_id in list(self._processes.keys()):
            self.cancel(action_id)

    def running(self, action_id: str) -> bool:
        return action_id in self._processes

    @staticmethod
    def timeout_ms(action_id: str) -> int:
        return _ACTION_TIMEOUT_MS.get(action_id, _DEFAULT_TIMEOUT_MS)

    def _on_finished(self, action_id: str, exit_code: int, process: QProcess) -> None:
        if action_id not in self._processes or not isValid(process):
            return  # already handled by timeout/error
        stdout = bytes(process.readAllStandardOutput().data()).decode("utf-8", errors="replace")
        stderr = bytes(process.readAllStandardError().data()).decode("utf-8", errors="replace")
        self._cleanup_process(action_id, process)
        outcome, parsed, message = report_outcome(stdout, stderr, exit_code)
        if outcome == "ready":
            self.status_ready.emit(action_id, stdout, parsed)
        else:
            self.status_failed.emit(action_id, message)

    def _on_error(self, action_id: str, error: QProcess.ProcessError, process: QProcess) -> None:
        if action_id not in self._processes or not isValid(process):
            return
        if error == QProcess.FailedToStart:
            self._cleanup_process(action_id, process)
            self.status_failed.emit(action_id, "failed to start")

    def _on_timeout(self, action_id: str, process: QProcess) -> None:
        if action_id not in self._processes or not isValid(process):
            return
        if process.state() != QProcess.NotRunning:
            process.kill()
            process.waitForFinished(1000)
        self._cleanup_process(action_id, process)
        self.status_failed.emit(action_id, "timed out")

    def _cleanup_process(self, action_id: str, process: QProcess | None) -> None:
        timer = process.property("timeout_timer") if process is not None and isValid(process) else None
        if timer is not None:
            timer.stop()
            timer.deleteLater()
        self._processes.pop(action_id, None)
        if process is not None and isValid(process):
            process.deleteLater()
