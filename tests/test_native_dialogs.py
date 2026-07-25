from __future__ import annotations

from pathlib import Path

import pytest

from linux.ui_native.models import ActionSpec, OperationResult


@pytest.fixture
def qapp():
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def _result(*, ok: bool = True) -> OperationResult:
    return OperationResult(
        action_id="test.action",
        command=["linux/pz", "test", "--token", "secret-value"],
        preview=True,
        exit_code=0 if ok else 1,
        started_at="2026-07-10T00:00:00Z",
        finished_at="2026-07-10T00:00:01Z",
        stdout="preview ok",
        stderr="",
        result_path=Path("/tmp/result.json"),
    )


def test_stateful_preview_redacts_command(qapp):
    from linux.ui_native.widgets import PreviewDialog
    from PySide6.QtWidgets import QLineEdit

    dialog = PreviewDialog(_result())
    command = dialog.findChild(QLineEdit, "commandBar")
    assert command is not None
    assert "secret-value" not in command.text()
    assert "[REDACTED]" in command.text()


def test_high_risk_requires_explicit_confirmation(qapp):
    from linux.ui_native.widgets import PreviewDialog

    action = ActionSpec(
        id="danger",
        category="Boot Direto",
        title="Danger",
        description="Danger",
        args=("boot", "danger"),
        icon="warning",
        mutable=True,
        preview_args=("boot", "status"),
        risk="high",
    )
    dialog = PreviewDialog(_result(), action)
    assert not dialog.confirm.isEnabled()
    dialog.confirmation.setText("CONFIRMAR")
    assert dialog.confirm.isEnabled()


def test_progress_dialog_emits_cancel_and_updates(qapp):
    from PySide6.QtTest import QSignalSpy
    from linux.ui_native.widgets import ProgressDialog

    dialog = ProgressDialog("Teste", "linux/pz test")
    spy = QSignalSpy(dialog.cancel_requested)
    dialog.set_progress(42)
    dialog.append_output("linha")
    dialog.cancel_requested.emit()
    assert dialog.progress.value() == 42
    assert "linha" in dialog.log.toPlainText()
    assert spy.count() == 1
    dialog.finish()


def test_result_dialog_offers_history(qapp):
    from PySide6.QtTest import QSignalSpy
    from linux.ui_native.widgets import ResultDialog

    dialog = ResultDialog(_result(), "resultado")
    spy = QSignalSpy(dialog.history_requested)
    dialog.history_requested.emit()
    assert spy.count() == 1
