"""LUX-013 — Início no primeiro uso: sem duplicatas, sem promessa falsa."""
from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _page(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "empty"))
    from linux.ui_native.pages.dashboard import DashboardPage

    catalog = build_catalog(ROOT)
    page = DashboardPage(ROOT, CommandRunner(ROOT), catalog, by_id={a.id: a for a in catalog})
    page.build()
    return page


def test_first_use_has_no_duplicate_entries_and_few_ctas(qapp, tmp_path, monkeypatch):
    page = _page(tmp_path, monkeypatch)
    assert page.first_use is True
    assert page.dashboard_cards == [], "atalhos só depois do primeiro trabalho"
    primaries = [b for b in page.findChildren(QPushButton) if b.objectName() == "primaryButton"]
    assert len(primaries) <= 8
    journey_titles = [
        card.findChildren(QLabel)[0].text() for card in page.journey_cards
    ]
    assert "Preparar este computador" not in journey_titles  # já é o passo 2


def test_play_goal_promises_only_what_it_runs(qapp, tmp_path, monkeypatch):
    from linux.ui_native.pages.dashboard import JOURNEYS

    play = next(row for row in JOURNEYS if row[0] == "play")
    assert play[2] == "profile.gaming"
    assert "Android" not in play[1] and "VM" not in play[1]
