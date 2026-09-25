from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import QEventLoop, QTimer
from PySide6.QtWidgets import QApplication, QLabel, QMessageBox, QPushButton


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_development_public_journey_reviews_applies_validates_and_opens(
    qapp, tmp_path, monkeypatch,
):
    from linux.ui_native.main_window import MainWindow
    from linux.ui_native.widgets import PreviewDialog, ResultDialog

    home = tmp_path / "home"
    config = home / ".config"
    data = home / ".local" / "share"
    state = home / ".local" / "state"
    for path in (home, config, data, state):
        path.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(config))
    monkeypatch.setenv("XDG_DATA_HOME", str(data))
    monkeypatch.setenv("XDG_STATE_HOME", str(state))

    events_file = tmp_path / "fake-operations.jsonl"
    fake = tmp_path / "fake_capabilities.py"
    fake.write_text(
        "import json, sys\n"
        "from pathlib import Path\n"
        "events, action_id, phase = sys.argv[1:4]\n"
        "with Path(events).open('a', encoding='utf-8') as stream:\n"
        " stream.write(json.dumps({'action': action_id, 'phase': phase, 'extra': sys.argv[4:]}) + '\\n')\n"
        "if phase == 'preview':\n"
        " payload = {'kind': 'plan', 'status': 'ready', 'summary': 'Plano isolado pronto.', 'blockers': [], 'id': 'fixture-plan-1', 'confirmToken': 'fixture-confirm-1'}\n"
        "elif action_id == 'capability.status':\n"
        " payload = {'kind': 'status', 'status': 'ok', 'capabilities': [{'id': 'development.nodejs', 'installed': True}, {'id': 'development.pnpm', 'installed': True}]}\n"
        "else:\n"
        " payload = {'kind': 'operation', 'status': 'completed', 'ok': True, 'summary': 'Preparação isolada concluída.'}\n"
        "print(json.dumps(payload))\n",
        encoding="utf-8",
    )

    def fake_build_program(_root, action, *, preview, value="", values=None):
        phase = "preview" if preview else "status" if action.id == "capability.status" else "apply"
        args = [str(fake), str(events_file), action.id, phase]
        for key, flag in (("plan_id", "--bound-plan-id"), ("confirm", "--bound-confirm-token")):
            if values and values.get(key):
                args.extend((flag, values[key]))
        return sys.executable, args

    host_patcher = patch.object(MainWindow, "_host_summary")
    status_patcher = patch("linux.ui_native.status_loader.StatusLoader.fetch_product_status")
    host_patcher.start()
    status_patcher.start()
    monkeypatch.setattr("linux.ui_native.command_runner.build_program", fake_build_program)
    window = MainWindow(ROOT)
    results = []
    dialogs_seen = []
    dialog_errors = []
    window.runner.completed.connect(results.append)
    modal_driver = QTimer(window)

    def click_modal_controls() -> None:
        dialog = qapp.activeModalWidget()
        if isinstance(dialog, PreviewDialog):
            if "preview" not in dialogs_seen:
                dialogs_seen.append("preview")
                if not dialog.confirm.isEnabled() or not any(
                    label.text() == "Plano isolado pronto." for label in dialog.findChildren(QLabel)
                ):
                    dialog_errors.append("preview não exibiu plano confirmável")
                    dialog.reject()
                    return
            dialog.confirm.click()
        elif isinstance(dialog, ResultDialog):
            close = next(
                (button for button in dialog.findChildren(QPushButton) if button.text() == "Fechar"),
                None,
            )
            if close is None:
                dialog_errors.append("resultado sem botão Fechar")
                dialog.reject()
            else:
                dialogs_seen.append("result")
                close.click()
        elif isinstance(dialog, QMessageBox):
            dialog_errors.append(dialog.text())
            dialog.accept()

    modal_driver.timeout.connect(click_modal_controls)
    modal_driver.start(10)

    def wait_for_results(count: int) -> None:
        if len(results) >= count:
            return
        loop = QEventLoop()

        def check(_result) -> None:
            if len(results) >= count:
                loop.quit()

        window.runner.completed.connect(check)
        QTimer.singleShot(10000, loop.quit)
        loop.exec()
        window.runner.completed.disconnect(check)
        assert len(results) >= count

    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        page.reload = lambda: None

        page.findChild(QPushButton, "prepareDevelopment").click()
        wait_for_results(2)
        assert [result.preview for result in results[:2]] == [True, False]
        assert results[1].ok, (results[1].exit_code, results[1].stdout, results[1].stderr, results[1].parsed)
        assert "Preparação concluída" in page.status.text()

        page.findChild(QPushButton, "validateDevelopment").click()
        wait_for_results(3)
        assert results[2].action_id == "capability.status"
        assert [item["id"] for item in results[2].parsed["capabilities"]] == [
            "development.nodejs", "development.pnpm",
        ]
        assert "Validação consultada" in page.status.text()

        page.findChild(QPushButton, "openDevelopmentTool").click()
        assert window.stack.currentWidget() is window.registry.page_for("Aplicativos")
        assert window.registry.page_for("Aplicativos").selected_app_id == "app.nodejs"
        assert dialogs_seen.count("preview") == 1
        assert dialogs_seen.count("result") == 2
        assert not dialog_errors, dialog_errors
        events = [json.loads(line) for line in events_file.read_text(encoding="utf-8").splitlines()]
        assert [(event["phase"], event["action"]) for event in events] == [
            ("preview", "capability.profile.development-web-js"),
            ("apply", "capability.profile.development-web-js"),
            ("status", "capability.status"),
        ]
        cancel_args = events[1]["extra"]
        assert cancel_args[:4] == [
            "--bound-plan-id", "fixture-plan-1",
            "--bound-confirm-token", "fixture-confirm-1",
        ]
        assert cancel_args[4] == "--cancel-file"
        assert not Path(cancel_args[5]).exists()
    finally:
        modal_driver.stop()
        window.close()
        host_patcher.stop()
        status_patcher.stop()
