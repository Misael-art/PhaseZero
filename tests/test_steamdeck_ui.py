from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtTest import QSignalSpy
from PySide6.QtWidgets import QApplication, QRadioButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.registry import PageRegistry
from linux.ui_native.pages.steamdeck import MODE_ACTIONS, SteamDeckPage


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


@pytest.fixture
def page(qapp, catalog):
    actions = [action for action in catalog if action.category == "Steam Deck"]
    built = SteamDeckPage(ROOT, CommandRunner(ROOT), actions, by_id={a.id: a for a in catalog})
    built.build()
    built.finalize_action_coverage()
    return built


def _payload() -> dict:
    return {
        "mode": "handheld",
        "automation": {
            "watcherActive": True,
            "kdeHotkeys": True,
            "privilegedHelperInstalled": False,
            "steamPlusFallback": True,
        },
        "virtualKeyboard": {
            "provider": "kde-kwin",
            "kde": {"supported": True, "available": True, "enabled": True},
        },
        "plugins": {
            "decky": {
                "installed": True,
                "service": {"active": True},
            },
        },
        "boot": {"grubCfgEntry": "active", "nextEntry": "none"},
        "display": {"profile": "steamdeck-oled-handheld"},
    }


def test_steamdeck_page_covers_all_category_actions(page, catalog):
    actions = [action for action in catalog if action.category == "Steam Deck"]
    assert page.represented_action_ids == {action.id for action in actions}


def test_status_payload_drives_mode_radios_and_facts(page):
    page._on_status_ready("steamdeck.status", "", _payload())
    assert page._mode_radios["handheld"].isChecked()
    assert not page._mode_radios["docked-tv"].isChecked()
    assert page.watcher_label.text() == "Ativo (aplica o modo sozinho)"
    assert "Ligado" in page.keyboard_label.text()
    assert page.decky_label.text() == "Instalado e serviço ativo"
    assert page.boot_label.text() == "Entrada GRUB presente e marcada"
    assert "OLED" in page.display_label.text()


def test_docked_payload_moves_the_radio(page):
    payload = _payload()
    payload["mode"] = "docked-monitor"
    payload["automation"]["watcherActive"] = False
    page._on_status_ready("steamdeck.status", "", payload)
    assert page._mode_radios["docked-monitor"].isChecked()
    assert not page._mode_radios["handheld"].isChecked()
    assert page.watcher_label.text() == "Inativo"


def test_unknown_mode_leaves_radios_clear_and_explains(page):
    page._on_status_ready("steamdeck.status", "", {"mode": "teleport"})
    assert all(not radio.isChecked() for radio in page._mode_radios.values())
    assert "desconhecido" in page.mode_note.text().casefold()


def test_clicking_a_mode_radio_dispatches_its_action(page):
    page._on_status_ready("steamdeck.status", "", _payload())
    spy = QSignalSpy(page.action_requested)
    page._mode_radios["docked-tv"].setChecked(True)
    assert spy.count() == 1
    assert spy.at(0)[0].id == "steamdeck.docked-tv"
    # otimista: radios ficam travados até a próxima leitura de status
    assert all(not radio.isEnabled() for radio in page._mode_radios.values())


def test_cancel_pending_restores_sync_from_last_status(page, qapp=None):
    page._on_status_ready("steamdeck.status", "", _payload())
    page._on_mode_toggled(True, "docked-tv")
    page.cancel_pending_action("steamdeck.docked-tv")
    assert all(radio.isEnabled() for radio in page._mode_radios.values())
    assert page._mode_radios["handheld"].isChecked()


def test_status_failure_reports_without_touching_config(page):
    page._on_status_failed("steamdeck.status", "timed out")
    assert page.state_label.text() == "● Estado indisponível"
    assert "demorou demais" in page.mode_note.text()
    assert all(radio.isEnabled() for radio in page._mode_radios.values())


def test_registry_maps_steam_deck_to_live_page():
    registry = PageRegistry(ROOT, CommandRunner(ROOT))
    page = registry.page_for("Steam Deck")
    assert isinstance(page, SteamDeckPage)


def test_mode_actions_match_catalog_ids(catalog):
    by_id = {a.id: a for a in catalog}
    for mode, action_id in MODE_ACTIONS.items():
        assert f"steamdeck.{mode}" == action_id
        assert action_id in by_id, f"{action_id} ausente no catálogo"
