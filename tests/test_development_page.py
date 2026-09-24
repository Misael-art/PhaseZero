from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QComboBox, QLabel, QPushButton


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _window(qapp):
    from linux.ui_native.main_window import MainWindow

    host_patcher = patch.object(MainWindow, "_host_summary")
    status_patcher = patch("linux.ui_native.status_loader.StatusLoader.fetch_product_status")
    host_patcher.start()
    status_patcher.start()
    return MainWindow(ROOT), host_patcher, status_patcher


def test_development_controls_build_optional_editor_plan_validate_and_open(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        assert page is not None
        objective = page.findChild(QComboBox, "developmentObjective")
        editor = page.findChild(QComboBox, "developmentEditor")
        prepare = page.findChild(QPushButton, "prepareDevelopment")
        validate = page.findChild(QPushButton, "validateDevelopment")
        open_tool = page.findChild(QPushButton, "openDevelopmentTool")
        assert objective is not None and editor is not None
        assert prepare is not None and validate is not None and open_tool is not None

        editor.setCurrentIndex(1)
        with patch.object(window.runner, "start") as start:
            prepare.click()
        action = start.call_args.args[0]
        assert action.id == "development.recipe.development-web-js.development.vscode"
        assert start.call_args.kwargs["preview"] is True
        assert action.resolved_args(preview=True) == [
            "capabilities", "plan", "--profile", "development-web-js",
            "--capability", "development.vscode",
        ]

        with patch.object(window.runner, "start") as start:
            validate.click()
        assert start.call_args.args[0].id == "capability.status"
        assert start.call_args.kwargs["preview"] is False

        open_tool.click()
        assert window.stack.currentWidget() is window.registry.page_for("Aplicativos")
        assert window.registry.page_for("Aplicativos").selected_app_id == "app.vscode"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_development_python_recipe_preserves_os_runtime_copy(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        objective = page.findChild(QComboBox, "developmentObjective")
        objective.setCurrentIndex(1)
        description = page.findChild(QLabel, "developmentRecipeDescription")
        assert "não altera o Python do sistema" in description.text()
        with patch.object(window.runner, "start") as start:
            page.findChild(QPushButton, "prepareDevelopment").click()
        action = start.call_args.args[0]
        assert action.id == "capability.profile.development-python"
        assert action.resolved_args(preview=True) == [
            "capabilities", "plan", "--profile", "development-python",
        ]
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


@pytest.mark.parametrize(
    ("objective_index", "profile_id", "app_id"),
    (
        (2, "development-java", "app.maven"),
        (3, "development-dotnet", "app.dotnet"),
    ),
)
def test_development_objectives_create_profile_plan_and_open_canonical_detail(
    qapp, objective_index, profile_id, app_id,
):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        objective = page.findChild(QComboBox, "developmentObjective")
        objective.setCurrentIndex(objective_index)

        with patch.object(window.runner, "start") as start:
            page.findChild(QPushButton, "prepareDevelopment").click()
        action = start.call_args.args[0]
        assert action.resolved_args(preview=True) == [
            "capabilities", "plan", "--profile", profile_id,
        ]
        assert start.call_args.kwargs["preview"] is True

        page.findChild(QPushButton, "openDevelopmentTool").click()
        assert window.stack.currentWidget() is window.registry.page_for("Aplicativos")
        assert window.registry.page_for("Aplicativos").selected_app_id == app_id
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()
