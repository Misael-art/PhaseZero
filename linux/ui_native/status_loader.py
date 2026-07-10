from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QTimer, Signal

from .result_parser import parse_json_output


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
        # Safety timeout: 15s per status command
        timer = QTimer(self)
        timer.setSingleShot(True)
        timer.timeout.connect(lambda: self._on_timeout(action_id, process))
        timer.start(15000)
        process.setProperty("timeout_timer", timer)

    def fetch_action(self, action) -> None:
        """Fetch status for an ActionSpec using its args directly."""
        self.fetch(action.id, list(action.args))

    def cancel(self, action_id: str) -> None:
        process = self._processes.pop(action_id, None)
        if process is not None and process.state() != QProcess.NotRunning:
            process.kill()
            process.waitForFinished(1000)
        self._cleanup_process(action_id, process)

    def cancel_all(self) -> None:
        for action_id in list(self._processes.keys()):
            self.cancel(action_id)

    def _on_finished(self, action_id: str, exit_code: int, process: QProcess) -> None:
        if action_id not in self._processes:
            return  # already handled by timeout/error
        stdout = bytes(process.readAllStandardOutput().data()).decode("utf-8", errors="replace")
        self._cleanup_process(action_id, process)
        if exit_code != 0:
            self.status_failed.emit(action_id, f"exit code {exit_code}")
            return
        parsed = parse_json_output(stdout)
        self.status_ready.emit(action_id, stdout, parsed)

    def _on_error(self, action_id: str, error: QProcess.ProcessError, process: QProcess) -> None:
        if action_id not in self._processes:
            return
        if error == QProcess.FailedToStart:
            self._cleanup_process(action_id, process)
            self.status_failed.emit(action_id, "failed to start")

    def _on_timeout(self, action_id: str, process: QProcess) -> None:
        if action_id not in self._processes:
            return
        self._cleanup_process(action_id, process)
        if process.state() != QProcess.NotRunning:
            process.kill()
        self.status_failed.emit(action_id, "timed out")

    def _cleanup_process(self, action_id: str, process: QProcess | None) -> None:
        timer = process.property("timeout_timer") if process else None
        if timer is not None:
            timer.stop()
            timer.deleteLater()
        self._processes.pop(action_id, None)
        if process is not None:
            process.deleteLater()
