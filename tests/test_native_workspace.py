from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtTest import QSignalSpy
from PySide6.QtWidgets import QApplication

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.workspace import CatalogWorkspacePage, grouped_actions
from linux.ui_native.widgets import ActionInspector, ActionListRow, ContextRail


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


def test_workspace_grouping_never_loses_actions(catalog):
    for category in {action.category for action in catalog}:
        actions = [action for action in catalog if action.category == category]
        grouped = grouped_actions(category, actions)
        rendered = [action.id for rows in grouped.values() for action in rows]
        assert len(rendered) == len(actions)
        assert set(rendered) == {action.id for action in actions}


def test_emulation_uses_customer_context_sections(catalog):
    actions = [action for action in catalog if action.category == "Emulação"]
    sections = grouped_actions("Emulação", actions)
    assert {"Visão geral", "Biblioteca e mídia", "Frontends", "Controles"} <= set(sections)
    assert "Avançado" in sections


def test_workspace_renders_every_action_and_selects_without_executing(qapp, catalog):
    actions = [action for action in catalog if action.category == "Emulação"]
    by_id = {action.id: action for action in catalog}
    page = CatalogWorkspacePage(ROOT, CommandRunner(ROOT), actions, by_id)
    page.build()
    assert len(page.findChildren(ActionListRow)) == len(actions)
    assert page.represented_action_ids == {action.id for action in actions}
    spy = QSignalSpy(page.action_selected)
    first = page.findChildren(ActionListRow)[0]
    first.selected.emit(first.action)
    assert spy.count() == 1
    assert first.property("selected") is True


def test_context_rail_has_large_labeled_targets(qapp):
    rail = ContextRail(["Visão geral", "Manutenção", "Avançado"])
    assert all(button.minimumHeight() >= 48 for button in rail.buttons)
    assert all(button.accessibleName() for button in rail.buttons)
    rail.select(2)
    assert rail.buttons[2].isChecked()


def test_inspector_is_single_execution_surface(qapp, catalog):
    action = next(action for action in catalog if action.id == "emulation.setup")
    inspector = ActionInspector()
    spy = QSignalSpy(inspector.requested)
    inspector.set_action(action)
    assert inspector.execute.text() == "Pré-visualizar"
    assert inspector.execute.minimumHeight() >= 48
    assert "linux/pz" in inspector.command.text()
    inspector.execute.click()
    assert spy.count() == 1
    assert spy.at(0)[0].id == action.id
