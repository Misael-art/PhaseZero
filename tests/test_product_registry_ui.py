from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton

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
        assert len(page.products) == 99
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
