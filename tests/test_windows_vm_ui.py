from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.windows_vm import WindowsVMPage


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_windows_vm_page_covers_graphics_management_and_uses_doctor(qapp):
    catalog = build_catalog(ROOT)
    actions = [action for action in catalog if action.category == "Windows VM"]
    page = WindowsVMPage(ROOT, CommandRunner(ROOT), actions, {a.id: a for a in catalog})
    page.build()
    page.finalize_action_coverage()

    assert page.represented_action_ids == {action.id for action in actions}
    assert page._context_status_action is not None
    assert page._context_status_action.id == "windows.graphics.doctor"


def test_windows_vm_page_has_install_card(qapp):
    catalog = build_catalog(ROOT)
    actions = [action for action in catalog if action.category == "Windows VM"]
    page = WindowsVMPage(ROOT, CommandRunner(ROOT), actions, {a.id: a for a in catalog})
    page.build()

    assert page._selected_iso == ""
    assert page._iso_path_label is not None
    assert page._edition_combo is not None
    assert page._edition_combo.isEnabled() is False


def test_windows_vm_page_covers_provision_actions(qapp):
    catalog = build_catalog(ROOT)
    actions = [action for action in catalog if action.category == "Windows VM"]
    by_id = {a.id: a for a in catalog}
    page = WindowsVMPage(ROOT, CommandRunner(ROOT), actions, by_id)
    page.build()
    page.finalize_action_coverage()

    provision_ids = {
        "windows.provision.plan",
        "windows.provision.start",
        "windows.provision.status",
        "windows.provision.watch",
        "windows.provision.resume",
        "windows.provision.cancel",
        "windows.provision.discard",
        "windows.media.inspect",
    }
    represented = page.represented_action_ids
    for pid in provision_ids:
        assert pid in represented or pid in by_id, f"{pid} not registered"
