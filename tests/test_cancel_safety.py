"""LUX-002 — Esc e fechar nunca abortam; cancelar exige segunda decisão."""
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import QProcess, Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def window(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        win = MainWindow(ROOT)
        yield win
        process = win.runner.process
        if process is not None:
            process.kill()
            process.waitForFinished(2000)
        win.runner.process = None
        win.close()


def _fake_running(win):
    process = QProcess(win)
    process.start("sleep", ["30"])
    assert process.waitForStarted(3000)
    win.runner.process = process
    return process


def test_escape_in_main_window_does_not_cancel(window):
    process = _fake_running(window)
    QTest.keyClick(window, Qt.Key_Escape)
    window.cancel_or_clear()  # o atalho Esc chama isto
    assert process.state() != QProcess.NotRunning
    assert window.runner._cancel_requested is False


def test_escape_in_progress_dialog_hides_without_cancel(window):
    from linux.ui_native.widgets import ProgressDialog

    process = _fake_running(window)
    dialog = ProgressDialog("Instalar", "pz install", window)
    dialog.cancel_requested.connect(window.confirm_cancel)
    hidden = []
    dialog.hidden_while_running.connect(lambda: hidden.append(True))
    dialog.show()
    with patch.object(type(window), "_ask_cancel") as ask:
        dialog.reject()
        ask.assert_not_called()
    assert hidden == [True]
    assert not dialog.isVisible()
    assert process.state() != QProcess.NotRunning


def test_cancel_requires_confirmation(window):
    process = _fake_running(window)
    with patch.object(type(window), "_ask_cancel", return_value=False):
        window.confirm_cancel()
    assert window.runner._cancel_requested is False
    assert process.state() != QProcess.NotRunning
    with patch.object(type(window), "_ask_cancel", return_value=True):
        window.confirm_cancel()
    assert window.runner._cancel_requested is True
