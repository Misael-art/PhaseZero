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
    assert dialog.technical.isHidden()


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


def test_progress_dialog_hides_technical_details_by_default(qapp):
    from linux.ui_native.widgets import ProgressDialog

    dialog = ProgressDialog("Teste", "linux/pz doctor")
    assert not dialog.technical.isVisible()
    dialog.details_toggle.setChecked(True)
    assert not dialog.technical.isHidden()
    dialog.finish()


def test_action_inspector_reveals_command_only_in_advanced_mode(qapp):
    from linux.ui_native.widgets import ActionInspector

    inspector = ActionInspector()
    inspector.set_action(ActionSpec(
        id="status", category="Teste", title="Status", description="Estado",
        args=("version",), icon="dialog-information",
    ))
    assert inspector.command.isHidden()
    assert inspector.command_heading.isHidden()
    inspector.set_advanced_mode(True)
    assert not inspector.command.isHidden()
    assert "linux/pz version" == inspector.command.text()


def test_result_dialog_offers_history(qapp):
    from PySide6.QtTest import QSignalSpy
    from linux.ui_native.widgets import ResultDialog

    dialog = ResultDialog(_result(), "resultado")
    spy = QSignalSpy(dialog.history_requested)
    dialog.history_requested.emit()
    assert spy.count() == 1


def test_result_dialog_translates_json_and_hides_raw_details(qapp):
    from linux.ui_native.widgets import ResultDialog
    from PySide6.QtWidgets import QLabel

    result = _result()
    result.parsed = {
        "vm": {"ramMb": 10240, "cpus": 7, "graphicsProfile": "virtio-gl"},
        "config": {"installed": True},
    }
    dialog = ResultDialog(result, '{"vm":{"ramMb":10240}}')
    labels = [label.text() for label in dialog.findChildren(QLabel)]
    assert "Memória" in labels
    assert "10 GB" in labels
    assert "Processadores" in labels
    assert dialog.view.raw.isHidden()
    dialog.view.details_toggle.setChecked(True)
    assert not dialog.view.raw.isHidden()


def test_error_dialog_prioritizes_resolution_over_logs(qapp):
    from linux.ui_native.widgets import ResultDialog
    from PySide6.QtTest import QSignalSpy

    result = _result(ok=False)
    result.preview = False
    result.parsed = {"error": "Faltam 2 GB de memória"}
    dialog = ResultDialog(result, "raw terminal", severity="error")
    spy = QSignalSpy(dialog.resolution_requested)
    dialog.resolution_requested.emit("windows.status")
    assert spy.count() == 1
    assert dialog.view.raw.isHidden()
    assert "Faltam 2 GB" in dialog.summary_label.text()
