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


@pytest.fixture
def page_and_catalog(qapp):
    catalog = build_catalog(ROOT)
    actions = [action for action in catalog if action.category == "Windows VM"]
    by_id = {a.id: a for a in catalog}
    page = WindowsVMPage(ROOT, CommandRunner(ROOT), actions, by_id)
    page.build()
    page.finalize_action_coverage()
    return page, by_id, catalog


def test_windows_vm_page_covers_graphics_management_and_uses_doctor(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    actions = [action for action in catalog if action.category == "Windows VM"]

    assert page.represented_action_ids == {action.id for action in actions}
    assert page._context_status_action is not None
    assert page._context_status_action.id == "windows.graphics.doctor"


def test_windows_vm_page_has_install_card(page_and_catalog):
    page, by_id, catalog = page_and_catalog

    assert page._selected_iso == ""
    assert page._iso_path_label is not None
    assert page._edition_combo is not None
    assert page._edition_combo.isEnabled() is False


def test_windows_vm_page_covers_provision_actions(page_and_catalog):
    page, by_id, catalog = page_and_catalog

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


def test_graphics_combo_exists_with_both_options(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    combo = page._graphics_combo
    assert combo is not None
    assert combo.count() == 2
    assert combo.itemData(0) == "compat"
    assert combo.itemData(1) == "virtio-gl"
    assert combo.currentData() == "compat"


def test_plan_argv_includes_graphics(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    plan = by_id["windows.provision.plan"]
    # Default compat
    args = plan.resolved_args(value="/fake.iso", values={"input": "/fake.iso", "graphics": "compat", "image_index": "1"})
    assert "--graphics" in args
    compat_idx = args.index("--graphics") + 1
    assert args[compat_idx] == "compat"
    # virtio-gl
    args = plan.resolved_args(value="/fake.iso", values={"input": "/fake.iso", "graphics": "virtio-gl", "image_index": "1"})
    gl_idx = args.index("--graphics") + 1
    assert args[gl_idx] == "virtio-gl"


def test_edition_combo_populates_from_inspect_json(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    fake = {"images": [{"index": 1, "name": "Windows 11 Pro"}, {"index": 2, "name": "Windows 11 Home"}]}
    page._apply_inspect_result(fake)
    assert page._edition_combo.count() == 2
    assert page._edition_combo.itemText(0) == "1: Windows 11 Pro"
    assert page._edition_combo.itemData(0) == 1
    assert page._edition_combo.itemText(1) == "2: Windows 11 Home"
    assert page._edition_combo.itemData(1) == 2
    assert page._selected_image_index == 1


def test_plan_argv_includes_image_index(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    plan = by_id["windows.provision.plan"]
    # Default index 1
    args = plan.resolved_args(value="/fake.iso", values={"input": "/fake.iso", "graphics": "compat", "image_index": "1"})
    assert "--image-index" in args
    idx = args.index("--image-index") + 1
    assert args[idx] == "1"
    # Index 2
    args = plan.resolved_args(value="/fake.iso", values={"input": "/fake.iso", "graphics": "compat", "image_index": "2"})
    idx = args.index("--image-index") + 1
    assert args[idx] == "2"


def test_single_image_iso_fallback(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    fake = {"images": [{"index": 1, "name": "Windows 11 Pro"}]}
    page._apply_inspect_result(fake)
    assert page._edition_combo.count() == 1
    assert page._edition_combo.itemText(0) == "1: Windows 11 Pro"
    assert page._edition_combo.itemData(0) == 1
    assert page._selected_image_index == 1


def test_inspect_failure_fallback(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    page._apply_inspect_result(None)
    assert page._edition_combo.count() == 1
    assert page._edition_combo.itemText(0) == "1: Padrão"
    assert page._edition_combo.itemData(0) == 1
    assert page._selected_image_index == 1


def test_venus_plan_action_present_in_graphics_box(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    assert "windows.graphics.plan-venus" in by_id


def test_venus_catalog_entry_correct(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    venus = by_id["windows.graphics.plan-venus"]
    assert venus.args[:4] == ("windows-vm", "graphics", "plan", "--profile")
    assert "virtio-venus" in venus.args
    assert "--json" in venus.args
