from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton, QScrollArea

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
        assert window.global_state.parent() is not None
        assert window.global_context.parent() is not None
        assert "Plataformas" in window.breadcrumb.text
        assert "Steam Deck" in window.breadcrumb.text
        assert window.sidebar_buttons["Steam Deck"].isChecked()
        window.close()


@pytest.mark.parametrize("width,height", [(949, 593), (800, 1280), (474, 296), (400, 640)])
def test_main_window_supports_documented_narrow_viewport(qapp, width, height):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show()
        window.resize(width, height)
        qapp.processEvents()
        assert window.size().width() == width
        # Window managers may clamp an oversized portrait request to a bound
        # between availableGeometry and the requested size. Exact height is
        # meaningful only when Qt can honor it; width/reflow assertions below
        # remain strict in either case.
        actual_height = window.size().height()
        available_height = qapp.primaryScreen().availableGeometry().height()
        assert actual_height == height or (
            height > available_height and available_height <= actual_height < height
        )
        assert not window.sidebar.isVisible()
        assert not window.compact_menu.isHidden()
        assert window.search.isVisible()
        assert window.mode_switch.isVisible()
        assert window.theme_button.isVisible()
        assert window.search.height() >= 25
        assert window.theme_button.height() >= 25
        if width < 450:
            assert window.search.geometry().bottom() < window.mode_switch.geometry().top()
            assert window.mode_switch.geometry().right() < window.theme_button.geometry().left()
        else:
            assert window.search.geometry().right() < window.mode_switch.geometry().left()
        assert window.compact_menu.menu() is not None
        assert len(window.compact_menu.menu().actions()) == len(window.sidebar_buttons)
        window.compact_menu.menu().actions()[1].trigger()
        assert window.current_category == "Visão geral"
        window.show_category("Início")
        qapp.processEvents()
        dashboard_scroll = window.registry.page_for("Início").findChild(QScrollArea)
        assert dashboard_scroll.horizontalScrollBar().maximum() == 0
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


def test_routing_page_registered_in_sidebar_and_builds(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show_category("IA & Dev")
        assert "Roteamento IA" in window.sidebar_buttons
        page = window.registry.page_for("Roteamento IA")
        assert page is not None
        assert page.__class__.__name__ == "AiRoutingPage"
        for aid in ("ai.routing-status", "ai.routing-inventory", "ai.routing-verify",
                    "ai.routing-plan", "ai.routing-apply-all", "ai.routing-rollback"):
            assert aid in window.registry.by_id, aid
        window.close()


def test_homelab_reachable_from_sidebar_and_registry(qapp):
    """CCS-013: Homelab é uma superfície alcançável — sidebar + registry."""
    from linux.ui_native.catalog import CATEGORIES, SIDEBAR_GROUPS
    from linux.ui_native.main_window import MainWindow

    sidebar_categories = {cat for _title, cats in SIDEBAR_GROUPS for cat in cats}
    assert "Homelab" in sidebar_categories, "Homelab ausente da navegação (SIDEBAR_GROUPS)"
    # Toda categoria registrada deve ser navegável; nada pode ficar órfão.
    orphans = [name for name, *_ in CATEGORIES if name not in sidebar_categories]
    assert orphans == [], f"categorias fora do menu: {orphans}"

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show_category("Homelab")
        assert "Homelab" in window.sidebar_buttons
        page = window.registry.page_for("Homelab")
        assert page is not None
        assert page.__class__.__name__ == "HomelabPage"
        window.close()


def test_home_journeys_cover_objectives_with_single_entry(qapp):
    """PZ-AUD-029: Início mostra objetivos (não taxonomias), cada um com
    UMA ação de entrada real mais requisito, custo e maturidade."""
    from linux.ui_native.main_window import MainWindow
    from unittest.mock import patch

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        page = window.registry.page_for("Início")
        assert page is not None
        cards = getattr(page, "journey_cards", [])
        assert len(cards) == 5, f"expected 5 journey cards, got {len(cards)}"
        seen_actions = set()
        for card in cards:
            labels = [w.text() for w in card.findChildren(QLabel)]
            joined = "\n".join(labels)
            assert "Precisa:" in joined
            assert "Custo:" in joined
            assert "Maturidade:" in joined
            buttons = [b for b in card.findChildren(QPushButton)
                       if b.text() == "Preparar e usar"]
            assert len(buttons) == 1
        from linux.ui_native.pages.dashboard import JOURNEYS

        for _key, _title, action_id, _req, _cost, _mat in JOURNEYS:
            assert action_id in window.registry.by_id, action_id
            seen_actions.add(action_id)
        assert len(seen_actions) == 5
        window.close()
