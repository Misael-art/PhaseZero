from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QStatusBar

from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.models import ActionSpec
from linux.ui_native.pages.base import BasePage
from linux.ui_native.widgets import Breadcrumb


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_breadcrumb_exposes_current_location(qapp):
    breadcrumb = Breadcrumb()
    breadcrumb.set_path("Sistema", "Visão geral")
    assert breadcrumb.text == "PhaseZero  ›  Sistema  ›  Visão geral"
    label = breadcrumb.findChild(QLabel, "breadcrumbText")
    assert label.accessibleName() == "Localização atual"
    assert "Visão geral" in label.accessibleDescription()


def test_main_window_has_persistent_status_and_grouped_breadcrumb(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show_category("Steam Deck")
        assert window.statusBar().objectName() == "globalStatusBar"
        assert isinstance(window.statusBar(), QStatusBar)
        assert "Plataformas" in window.breadcrumb.text
        assert "Steam Deck" in window.breadcrumb.text
        assert window.sidebar_buttons["Steam Deck"].isChecked()
        window.close()


def test_base_page_context_health_uses_explicit_status_args(qapp):
    action = ActionSpec(
        id="module.status",
        category="Teste",
        title="Estado do módulo",
        description="Consulta estado",
        args=("module", "mutate"),
        status_args=("module", "status", "--json"),
        icon="system-run",
    )
    page = BasePage(ROOT, CommandRunner(ROOT), [action], {action.id: action})
    page.finalize_action_coverage()
    assert page.findChild(QLabel, "contextStatusText") is not None
    with patch.object(page.status_loader, "fetch") as fetch:
        page.reload_context_status()
    fetch.assert_called_once_with(action.id, ["module", "status", "--json"])
