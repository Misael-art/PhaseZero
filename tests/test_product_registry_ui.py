from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QComboBox, QLabel, QPushButton
from linux.ui_native.models import ProductInstance
from linux.ui_native.product_inventory import target_for

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


def _detail_action_rows(page):
    rows = []
    for index in range(page._detail_actions_start, page._detail_layout.count()):
        widget = page._detail_layout.itemAt(index).widget()
        if isinstance(widget, ActionListRow):
            rows.append(widget)
    return rows


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


def test_every_app_action_resolves_to_canonical_detail_with_source_context(qapp):
    from linux.ui_native.product_inventory import target_for

    window, host_patcher, status_patcher = _window(qapp)
    routes = []
    try:
        product_page = window.registry.page_for("Aplicativos")
        expected = {
            action.id: target_for(action).target_id
            for action in window.registry.by_id.values()
            if target_for(action).target_kind == "app"
        }
        window.open_product = lambda app_id, context_action_id="": routes.append(
            (app_id, context_action_id)
        )
        for action_id in expected:
            window.inspect_action(window.registry.by_id[action_id])

        assert set(expected.values()) == {
            product["appId"] for product in product_page.products
        }
        assert routes == [(expected[action_id], action_id) for action_id in expected]
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_registry_has_all_manifest_products_and_unknown_is_not_absent(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        assert page.__class__.__name__ == "ProductRegistryPage"
        assert len(page.products) == 103
        assert page._product_by_id["app.ollama"]["canonicalActionId"] == "ai.ollama"
        window.open_product("app.ollama", "server.llm")
        assert not page.instances
        assert "desconhecidas" in page._status_label.text()
        assert page._detail_layout.indexOf(page._status_label) >= 0
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_product_search_indexes_purpose_synonyms(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page._filter_products("chat local")
        assert not page._cards["app.ollama"].isHidden()
        assert page._cards["app.vscode"].isHidden()

        page._filter_products("agente de código")
        assert not page._cards["app.claude-code"].isHidden()
        assert not page._cards["app.opencode"].isHidden()
        assert page._cards["app.ollama"].isHidden()

        page._filter_products("programar")
        assert not page._cards["app.vscode"].isHidden()
        assert not page._cards["app.vscodium"].isHidden()
        assert page._cards["app.ollama"].isHidden()
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


def test_open_webui_status_gates_its_local_dashboard_action(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.open-webui")
        assert page._status_action_id == "ai.webui-status"
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.open-webui", "app.open-webui", "local", "local",
            installation="present", origin="unknown", configuration="ready", health="online",
        ),))
        assert page._primary_button.text() == "Abrir"
        assert page._primary_action is not None
        assert page._primary_action.id == "ai.webui-open"
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.webui-open"

        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.open-webui", "app.open-webui", "local", "local",
            installation="present", origin="unknown", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert not page._primary_button.isEnabled()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_resolve_uses_read_only_diagnostic_and_never_starts_external_proxy(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.9router")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:local:app.9router", "app.9router", "local", "local",
            installation="present", origin="external", configuration="ready", health="failed",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == "ai.9router-doctor"
        assert not page._primary_action.mutable
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.9router-doctor"

        page.open_product("app.qwen-proxy")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:local:app.qwen-proxy", "app.qwen-proxy", "local", "local",
            installation="present", origin="external", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_multiple_instances_require_explicit_local_scope_selection(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode")
        page._instances_ready(page._status_action_id, (
            ProductInstance(
                "local:host:app.vscode", "app.vscode", "local", "host",
                installation="absent",
            ),
            ProductInstance(
                "homelab:host:app.vscode", "app.vscode", "homelab", "host",
                installation="present", origin="phasezero", configuration="ready", health="online",
            ),
        ))
        selector = page.findChild(QComboBox, "productInstanceSelector")
        assert selector is not None and selector.count() == 3
        assert page._status_label.text().startswith("2 instâncias observadas")
        assert page._primary_button.text() == "Selecionar instância"
        assert not page._primary_button.isEnabled()
        assert not _detail_action_rows(page)

        local_index = next(
            index for index in range(1, selector.count())
            if selector.itemData(index) == "local:host:app.vscode"
        )
        selector.setCurrentIndex(local_index)
        assert "Instância: local · escopo host" in page._status_label.text()
        assert page._primary_button.text() == "Preparar"
        assert page._primary_button.isEnabled()
        assert page._primary_action.id == "capability.plan.development.vscode"
        rows = _detail_action_rows(page)
        assert rows
        assert all(target_for(row.action).instance_scope == "host" for row in rows)

        remote_index = next(
            index for index in range(1, selector.count())
            if selector.itemData(index) == "homelab:host:app.vscode"
        )
        selector.setCurrentIndex(remote_index)
        assert page._primary_button.text() == "Abrir"
        assert not page._primary_button.isEnabled()
        assert not _detail_action_rows(page)
        notice = page.findChild(QLabel, "productInstanceActionNotice")
        assert notice is not None and "remotas" in notice.text()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_duplicate_instances_in_same_scope_block_unscoped_actions(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode")
        page._instances_ready(page._status_action_id, (
            ProductInstance(
                "local:first:app.vscode", "app.vscode", "local", "host",
                installation="absent",
            ),
            ProductInstance(
                "local:second:app.vscode", "app.vscode", "local", "host",
                installation="present", origin="phasezero", configuration="ready", health="online",
            ),
        ))
        selector = page.findChild(QComboBox, "productInstanceSelector")
        index = next(
            index for index in range(1, selector.count())
            if selector.itemData(index) == "local:first:app.vscode"
        )
        selector.setCurrentIndex(index)
        assert page._primary_button.text() == "Preparar"
        assert not page._primary_button.isEnabled()
        notice = page.findChild(QLabel, "productInstanceActionNotice")
        assert notice is not None and "várias instâncias neste escopo" in notice.text()
        assert not _detail_action_rows(page)
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_verify_uses_selected_instance_scope(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode")
        page._instances_ready(page._status_action_id, (
            ProductInstance(
                "local:host:app.vscode", "app.vscode", "local", "host",
                installation="unknown",
            ),
            ProductInstance(
                "local:project:app.vscode", "app.vscode", "local", "project",
                installation="unknown",
            ),
        ))
        selector = page.findChild(QComboBox, "productInstanceSelector")
        index = next(
            index for index in range(1, selector.count())
            if selector.itemData(index) == "local:project:app.vscode"
        )
        selector.setCurrentIndex(index)
        assert page._primary_button.text() == "Verificar"
        with patch.object(page.status_loader, "fetch_product_status") as fetch:
            page._primary_button.click()
        fetch.assert_called_once()
        assert fetch.call_args.kwargs["host_id"] == "local"
        assert fetch.call_args.kwargs["scope"] == "project"
        assert fetch.call_args.kwargs["instance_key"] == "local:project:app.vscode"
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


def test_offline_ollama_uses_canonical_setup_as_confirmed_recovery(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.ollama")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:host:app.ollama", "app.ollama", "local", "host",
            installation="present", origin="phasezero", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == "ai.ollama"
        assert page._primary_action.impact
        assert "Nenhum modelo é baixado" in page._primary_action.impact
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.ollama"
        assert start.call_args.kwargs["preview"] is True
        assert page._primary_action.id != "server.llm.restore"

        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:host:app.ollama", "app.ollama", "local", "host",
            installation="present", origin="external", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_offline_managed_opencode_uses_configure_recovery_but_external_is_untouched(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.opencode")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.opencode", "app.opencode", "local", "local",
            installation="present", origin="phasezero", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == "ai.opencode-install"
        assert "rollback" in page._primary_action.impact
        assert "Não inicia login" in page._primary_action.impact
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.opencode-install"
        assert start.call_args.kwargs["preview"] is True

        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:local:app.opencode", "app.opencode", "local", "local",
            installation="present", origin="external", configuration="ready", health="offline",
        ),))
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_ready_9router_uses_dashboard_as_simple_open_route(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.9router")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.9router", "app.9router", "local", "local",
            installation="present", origin="phasezero", configuration="ready", health="online",
        ),))
        assert page._primary_button.text() == "Abrir"
        assert page._primary_action.id == "ai.9router-dashboard"
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.9router-dashboard"
        assert start.call_args.kwargs["preview"] is False
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_ready_odysseus_uses_registered_open_route(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.odysseus")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.odysseus", "app.odysseus", "local", "local",
            installation="present", origin="phasezero", configuration="ready", health="online",
        ),))
        assert page._primary_button.text() == "Abrir"
        assert page._primary_action.id == "ai.odysseus-open"
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.odysseus-open"
        assert start.call_args.kwargs["preview"] is False
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
