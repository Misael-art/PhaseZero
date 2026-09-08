"""UX-005/007/009 — installing is a journey that ends with the app open.

These tests drive the same controls the operator sees: they read the labels
rendered on the cards, click the presented button, and never call an internal
state machine that has no reachable control.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication, QLabel, QPushButton
from PySide6.QtTest import QTest

from linux.ui_native import journey


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    """First-access marks must never touch the real host state."""
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    yield


class BusyProc:  # noqa: N801
    def state(self):
        return 1  # Running


def _app_row(**over) -> dict:
    row = {
        "key": "jellyfin",
        "title": "Jellyfin",
        "layer": "core",
        "enabled": False,
        "running": False,
        "budgetMB": 2048,
        "url": "http://127.0.0.1:8096",
        "openUrl": "http://127.0.0.1:8096/",
        "governor": {"verdict": "pass", "reasons": []},
        "firstUse": {
            "openPath": "/",
            "steps": [
                "Abra e conclua o assistente inicial.",
                "Aponte uma biblioteca para sua pasta de mídia.",
            ],
        },
    }
    row.update(over)
    return row


def _page():
    from linux.ui_native.pages.homelab import HomelabPage

    page = HomelabPage(ROOT, None, [], by_id={})
    page.build()
    page._proc = BusyProc()
    return page


def _card_texts(page) -> list[str]:
    return [lbl.text() for lbl in page._cards_host.findChildren(QLabel)]


def _card_buttons(page) -> dict[str, QPushButton]:
    return {
        btn.text(): btn
        for btn in page._cards_host.findChildren(QPushButton)
        if btn.isVisible() or btn.parent() is not None
    }


# ------------------------------------------------------------------ UX-009
def test_journey_states_follow_probe_not_container(app):
    row = _app_row()
    assert journey.app_journey(row, {})[0] == journey.NOT_INSTALLED

    row = _app_row(enabled=True)
    assert journey.app_journey(row, {})[0] == journey.PREPARING

    # Running is NOT ready: without a passing functional probe the journey
    # is still in "preparando".
    row = _app_row(enabled=True, running=True)
    status = {"functionalProbes": {"passed": [], "failed": ["jellyfin"]}}
    assert journey.app_journey(row, status)[0] == journey.PREPARING
    assert journey.app_journey(row, {})[0] == journey.PREPARING

    status = {"functionalProbes": {"passed": ["jellyfin"], "failed": []}}
    state, explanation = journey.app_journey(row, status)
    assert state == journey.CONFIGURE_ACCESS
    assert explanation == "Abra e conclua o assistente inicial."

    state, _ = journey.app_journey(row, status, first_access_done=True)
    assert state == journey.READY


def test_card_offers_install_then_configure_then_open(app, monkeypatch):
    page = _page()
    page._last_status = {"functionalProbes": {"passed": [], "failed": []}}
    page._rebuild_cards([_app_row()])
    texts = " | ".join(_card_texts(page))
    assert "Não instalado" in texts
    assert "Instalar" in _card_buttons(page)

    page._last_status = {"functionalProbes": {"passed": ["jellyfin"], "failed": []}}
    row = _app_row(enabled=True, running=True)
    page._rebuild_cards([row])
    texts = " | ".join(_card_texts(page))
    assert "Configurar acesso" in texts
    # The remaining first-use steps are on the card, not only in a log.
    assert "Aponte uma biblioteca para sua pasta de mídia." in texts

    opened: list[str] = []
    monkeypatch.setattr(
        "PySide6.QtGui.QDesktopServices.openUrl",
        lambda url: opened.append(url.toString()) or True,
    )
    button = _card_buttons(page)["Configurar acesso"]
    QTest.mouseClick(button, Qt.LeftButton)
    assert opened == ["http://127.0.0.1:8096/"]

    # After first access the journey ends on the solution itself.
    assert "jellyfin" in page._first_access
    assert "Abrir solução" in _card_buttons(page)
    assert "Pronto para usar" in " | ".join(_card_texts(page))


def test_first_access_is_persisted_between_pages(app):
    page = _page()
    page._mark_first_access("jellyfin")
    stored = json.loads(page._first_access_path().read_text(encoding="utf-8"))
    assert stored == {"apps": ["jellyfin"]}
    assert _page()._first_access == {"jellyfin"}


# ------------------------------------------------------------------ UX-005
def test_simple_mode_lists_only_installable_profiles(app):
    page = _page()
    payload = {
        "profiles": [
            {"key": "assistant-private", "title": "Assistente", "installable": True,
             "maturity": "stable"},
            {"key": "studio", "title": "Studio", "installable": False,
             "maturity": "preview", "installNote": "sem receita ainda"},
        ]
    }
    page._on_profiles_done(0, json.dumps(payload).encode(), b"")
    keys = [page._profile_combo.itemData(i) for i in range(page._profile_combo.count())]
    assert keys == ["assistant-private"]
    assert not page._profile_note.isVisible()

    page._simulate_check.setChecked(True)
    keys = [page._profile_combo.itemData(i) for i in range(page._profile_combo.count())]
    assert keys == ["assistant-private", "studio"]
    labels = [page._profile_combo.itemText(i) for i in range(page._profile_combo.count())]
    assert any("simulação" in label for label in labels)

    page._profile_combo.setCurrentIndex(keys.index("studio"))
    note = page._profile_note.text()
    assert "não instala" in note and "sem receita ainda" in note
    # The warning is on the page, not only in the output pane.
    assert page._profile_note.isVisibleTo(page)


def test_budget_only_profile_cannot_be_applied_in_simple_mode(app):
    page = _page()
    payload = {
        "profiles": [
            {"key": "assistant-private", "title": "Assistente", "installable": True},
            {"key": "studio", "title": "Studio", "installable": False,
             "installNote": "sem receita ainda"},
        ]
    }
    page._on_profiles_done(0, json.dumps(payload).encode(), b"")
    assert page._profile_combo.findData("studio") < 0


# ------------------------------------------------------------------ UX-007
@pytest.mark.parametrize(
    "raw,expected",
    [
        ("Error: no space left on device", "Espaço em disco"),
        ("Cannot connect to the Docker daemon at unix:///var/run/docker.sock", "contêineres"),
        ("unauthorized: authentication required", "credenciais"),
        ("net/http: TLS handshake timeout", "download"),
    ],
)
def test_failure_states_cause_and_next_action(raw, expected):
    cause, action = journey.failure_cause(raw)
    assert expected in cause
    assert "tente de novo" in action.casefold()


def test_failure_banner_is_visible_and_offers_retry(app):
    page = _page()
    page._last_cmd = (["apps", "enable", "jellyfin", "--json"], None)
    page._show_failure("Error: no space left on device")
    assert page._error_frame.isVisibleTo(page)
    assert "Espaço em disco" in page._error_banner.text()
    assert page._error_retry.isVisibleTo(page)

    page._clear_failure()
    assert not page._error_frame.isVisibleTo(page)


def test_onboarding_copy_is_task_oriented(app):
    page = _page()
    jargon = ("argv", "dry-run", "bind", "mDNS", "UPnP", "--yes")
    for index in range(len(page.ONBOARD_STEPS)):
        page._onboard_step = index
        text = page._onboard_prompt()
        assert f"Passo {index + 1} de {len(page.ONBOARD_STEPS)}" in text
        assert not [word for word in jargon if word in text]
