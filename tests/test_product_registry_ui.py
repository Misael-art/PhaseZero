from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton
from linux.ui_native.models import ProductInstance

ROOT = Path(__file__).resolve().parents[1]

from linux.ui_native.widgets import ActionListRow


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _window(qapp):
    from linux.ui_native.main_window import MainWindow

    patcher = patch.object(MainWindow, "_host_summary")
    patcher.start()
    status_patcher = patch("linux.ui_native.status_loader.StatusLoader.fetch_product_status")
    status_patcher.start()
    window = MainWindow(ROOT)
    return window, patcher, status_patcher


@pytest.mark.parametrize("action_id", ["ai.ollama", "server.llm"])
def test_legacy_app_routes_open_same_product_and_preserve_context(qapp, action_id):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.search.setText("Ollama")
        row = next(row for row in window._search_cards if row.action.id == action_id)
        row.selected.emit(row.action)
        page = window.registry.page_for("Aplicativos")
        assert window.stack.currentWidget() is page
        assert page.selected_app_id == "app.ollama"
        assert page.context_action_id == action_id
        assert "Ollama" in window.page_title.text()
        assert "Atalho de origem" in page._context_label.text()
        assert page._status_label.text() == "Instalação, configuração e saúde: desconhecidas"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_product_detail_back_returns_to_search_context(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.search.setText("Ollama")
        search_page = window.search_page
        row = next(row for row in window._search_cards if row.action.id == "server.llm")
        row.selected.emit(row.action)
        page = window.registry.page_for("Aplicativos")
        assert window.stack.currentWidget() is page
        back = page.findChild(QPushButton, "productDetailBack")
        assert back is not None
        back.click()
        assert window.stack.currentWidget() is search_page
        assert window.search.text() == "Ollama"
        assert window.page_title.text() == "Busca"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_legacy_page_action_routes_to_detail_and_detail_keeps_execute_path(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Servidor")
        action = window.registry.by_id["server.llm"]
        server_page = window.registry.page_for("Servidor")
        window.inspect_action(action)
        products = window.registry.page_for("Aplicativos")
        assert window.stack.currentWidget() is products
        assert products.selected_app_id == "app.ollama"
        assert products.context_action_id == "server.llm"
        row = next(row for row in products.findChildren(ActionListRow) if row.action.id == "server.llm")
        with patch.object(window.runner, "start") as start:
            row.selected.emit(row.action)
        start.assert_called_once()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_registry_has_all_manifest_products_and_unknown_is_not_absent(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        assert page.__class__.__name__ == "ProductRegistryPage"
        assert len(page.products) == 101
        assert page._product_by_id["app.ollama"]["canonicalActionId"] == "ai.ollama"
        window.open_product("app.ollama", "server.llm")
        assert not page.instances
        assert "desconhecidas" in page._status_label.text()
        assert page._detail_layout.indexOf(page._status_label) >= 0
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_comparison_only_enables_curated_functional_alternatives(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        assert "app.vscode" in page._compare_checks
        assert "app.vscodium" in page._compare_checks
        assert "app.ollama" not in page._compare_checks
        page._compare_checks["app.vscode"].setChecked(True)
        page._compare_checks["app.vscodium"].setChecked(True)
        assert page._compare_button.isEnabled()
        page._compare_button.click()
        assert any(
            "Comparar Visual Studio Code e VSCodium" in label.text()
            for label in page._comparison_page.findChildren(QLabel)
        )
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_primary_action_waits_for_observed_state_then_prepares_absent_app(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode", "capability.plan.development.vscode")
        assert page._primary_button.text() == "Verificar"
        assert page._primary_button.isEnabled()
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:host:app.vscode", "app.vscode", "local", "host",
            installation="absent",
        ),))
        assert page._primary_button.text() == "Preparar"
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.kwargs["preview"] is True
        assert start.call_args.args[0].id == "capability.plan.development.vscode"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_primary_open_uses_installed_desktop_entry_without_shell(qapp, tmp_path, monkeypatch):
    from linux.ui_native.main_window import QProcess

    window, host_patcher, status_patcher = _window(qapp)
    try:
        apps = tmp_path / "applications"
        apps.mkdir()
        entry = apps / "com.visualstudio.code.desktop"
        entry.write_text("[Desktop Entry]\nType=Application\nName=VS Code\n", encoding="utf-8")
        monkeypatch.setattr("linux.ui_native.pages.product_registry.desktop_dirs", lambda: (apps,))
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "host:app.vscode", "app.vscode", "local", "host",
            installation="present", origin="external", configuration="ready", health="online",
        ),))
        assert page._primary_button.text() == "Abrir"
        assert page._primary_button.isEnabled()
        with patch.object(QProcess, "startDetached", return_value=(True, 42)) as start:
            page._primary_button.click()
        start.assert_called_once_with("gio", ["launch", str(entry)])
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_recovery_state_does_not_auto_select_restore(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.ollama", "server.llm")
        assert page._action_for_state("resolve") is None
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_desktop_launcher_rejects_entry_symlink_outside_xdg_root(tmp_path):
    from linux.ui_native.icons import find_desktop_entry

    apps = tmp_path / "applications"
    apps.mkdir()
    outside = tmp_path / "outside.desktop"
    outside.write_text("[Desktop Entry]\nType=Application\n", encoding="utf-8")
    (apps / "com.visualstudio.code.desktop").symlink_to(outside)
    assert find_desktop_entry("flatpak", "com.visualstudio.code", (apps,)) is None
