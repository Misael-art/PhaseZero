from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtTest import QSignalSpy
from PySide6.QtWidgets import QApplication

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.service_control import ServerPage, WaydroidPage


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


def _page(page_type, category: str, catalog):
    actions = [action for action in catalog if action.category == category]
    page = page_type(ROOT, CommandRunner(ROOT), actions, by_id={a.id: a for a in catalog})
    page.build()
    page.finalize_action_coverage()
    return page, actions


def test_waydroid_page_covers_catalog_and_maps_visual_status(qapp, catalog):
    page, actions = _page(WaydroidPage, "Waydroid", catalog)
    assert page.represented_action_ids == {action.id for action in actions}
    page.apply_payload({
        "config": {"installed": True},
        "android": {"initialized": True, "imageType": "GAPPS", "serviceActive": "active"},
        "host": {"binderDevices": True},
        "access": {"sharesReady": True, "mountCount": 4, "usbBusShared": True},
        "boot": {"helperInstalled": True, "artifactsCurrent": True},
    })
    assert page.state_label.text() == "● Rodando"
    assert page.power_button.text() == "Parar"
    assert all(toggle.isChecked() for toggle, _detail in page.feature_controls)
    spy = QSignalSpy(page.action_requested)
    page._power_action()
    assert spy.at(0)[0].id == "waydroid.stop"


def test_waydroid_prevents_launch_before_configuration(qapp, catalog):
    page, _actions = _page(WaydroidPage, "Waydroid", catalog)
    page.apply_payload({"config": {"installed": False}, "android": {"initialized": False}})
    assert not page.shortcut_buttons["waydroid.launch"].isEnabled()
    assert page.shortcut_buttons["waydroid.repair"].isEnabled()


def test_server_page_uses_single_power_control_and_visual_facts(qapp, catalog):
    page, actions = _page(ServerPage, "Servidor", catalog)
    assert page.represented_action_ids == {action.id for action in actions}
    page.apply_payload({
        "configured": True,
        "ready": True,
        "profile": "assistant-private",
        "accessMode": {"effective": "tailscale"},
        "stack": {"apps": [
            {"key": "jellyfin", "running": True},
            {"key": "vaultwarden", "running": False},
        ]},
        "backupState": {"lastBackup": {"latest": "/safe/backup"}},
    })
    assert page.state_label.text() == "● Rodando"
    assert page.power_button.text() == "Parar"
    assert page.fact_labels[0].text() == "Perfil: assistant-private"
    spy = QSignalSpy(page.action_requested)
    page._power_action()
    assert spy.at(0)[0].id == "server.homelab.down"
    assert page.shortcut_buttons["server.homelab.open-jellyfin"].isEnabled()


def test_waydroid_stop_action_is_preview_protected(catalog):
    action = next(action for action in catalog if action.id == "waydroid.stop")
    assert action.mutable
    assert action.args == ("waydroid", "stop", "--json")
    assert action.preview_args == ("waydroid", "status", "--json")
