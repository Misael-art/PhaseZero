from __future__ import annotations

from pathlib import Path
from types import ModuleType

import pytest
from PySide6.QtCore import Qt
from PySide6.QtGui import QTextCursor
from PySide6.QtWidgets import QApplication, QPlainTextEdit, QTextEdit

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.windows_vm import WindowsVMPage
from linux.ui_native.result_parser import severity_for


ROOT = Path(__file__).resolve().parents[1]

# Module paths under linux/ui_native/ to audit for import-time AttributeError
UI_MODULES: list[str] = [
    "linux.ui_native.catalog",
    "linux.ui_native.command_runner",
    "linux.ui_native.main_window",
    "linux.ui_native.models",
    "linux.ui_native.platform",
    "linux.ui_native.result_parser",
    "linux.ui_native.status_loader",
    "linux.ui_native.widgets",
    "linux.ui_native.tokens",
    "linux.ui_native.pages.base",
    "linux.ui_native.pages.overview",
    "linux.ui_native.pages.dashboard",
    "linux.ui_native.pages.windows_vm",
    "linux.ui_native.pages.profiles",
    "linux.ui_native.pages.steamdeck",
    "linux.ui_native.pages.waydroid",
    "linux.ui_native.pages.server",
    "linux.ui_native.pages.emulation",
    "linux.ui_native.pages.boot",
    "linux.ui_native.pages.flatpak",
    "linux.ui_native.pages.tuning",
    "linux.ui_native.pages.ai_dev",
    "linux.ui_native.pages.applications",
    "linux.ui_native.pages.results",
    "linux.ui_native.pages.workspace",
    "linux.ui_native.pages.ai_proxies",
]


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


def test_graphics_combo_exists_with_4_items(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    combo = page._graphics_combo
    assert combo is not None
    assert combo.count() == 4
    assert combo.itemData(0) == "compat"
    assert combo.itemData(1) == "virtio-gl"
    assert combo.itemData(2) == "virtio-venus"
    assert combo.itemData(3) == "custom"
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


# ── PySide6 6.11 cursor-enum regression tests ──────────────────────

def test_qtextcursor_moveoperation_end_accessible():
    assert QTextCursor.MoveOperation.End is not None
    assert isinstance(QTextCursor.MoveOperation.End, QTextCursor.MoveOperation)


def test_append_output_cursor_path(qapp):
    edit = QPlainTextEdit()
    cursor = edit.textCursor()
    cursor.movePosition(QTextCursor.MoveOperation.End)
    cursor.insertText("cursor-path-ok")
    edit.setTextCursor(cursor)
    assert edit.toPlainText() == "cursor-path-ok"


def test_qtextcursor_enums_at_runtime(qapp):
    edit = QPlainTextEdit("hello world")
    cursor = edit.textCursor()
    cursor.movePosition(QTextCursor.MoveOperation.End)
    assert cursor.position() == len("hello world")


def test_ui_modules_import():
    for mod_name in UI_MODULES:
        mod = __import__(mod_name, fromlist=["_trash"])
        assert isinstance(mod, ModuleType), f"{mod_name} did not import as module"


# ── Graphics pedagogy tests ─────────────────────────────────────────

def test_graphics_helper_label_updates_on_selection_change(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    combo = page._graphics_combo
    helper = page._graphics_helper
    # compat (index 0) by default
    assert "lenta em 3D" in helper.text() or "Microsoft Basic" in helper.text()
    # virtio-gl (index 1)
    combo.setCurrentIndex(1)
    assert "OpenGL" in helper.text() and "virgl" in helper.text()
    # virtio-venus (index 2)
    combo.setCurrentIndex(2)
    assert "EXPERIMENTAL" in helper.text() and "Vulkan" in helper.text()
    # custom (index 3)
    combo.setCurrentIndex(3)
    assert "customizado" in helper.text() or "personalizado" in helper.text()


def test_custom_reveals_advanced_line_edit(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    combo = page._graphics_combo
    custom_field = page._custom_field
    # default (compat) — custom field hidden (not explicitly shown)
    assert custom_field.isHidden()
    # custom — field visible (not hidden)
    combo.setCurrentIndex(3)
    assert not custom_field.isHidden()
    # virtio-gl — field hidden again
    combo.setCurrentIndex(1)
    assert custom_field.isHidden()


def test_edition_combo_placeholder_when_no_iso(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    assert page._edition_combo.count() == 1
    assert page._edition_combo.itemText(0) == "Selecione uma ISO primeiro"
    assert not page._edition_combo.isEnabled()


def test_catalog_graphics_param_kind_is_choice(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    plan = by_id["windows.provision.plan"]
    graphics_param = next(p for p in plan.parameters if p.name == "graphics")
    assert graphics_param.kind == "choice"
    assert "compat" in graphics_param.choices
    assert "virtio-gl" in graphics_param.choices
    assert "virtio-venus" in graphics_param.choices
    assert "custom" in graphics_param.choices
    assert len(graphics_param.choices) == 4


def test_parameter_dialog_renders_combo_for_graphics(qapp):
    from PySide6.QtWidgets import QComboBox
    from linux.ui_native.widgets import ParameterDialog
    from linux.ui_native.catalog import build_catalog
    catalog = build_catalog(ROOT)
    plan = next(a for a in catalog if a.id == "windows.provision.plan")
    dialog = ParameterDialog(plan)
    field = dialog._fields.get("graphics")
    assert field is not None
    assert isinstance(field, QComboBox)
    assert field.count() == 4


def test_parameter_dialog_custom_support(qapp):
    from PySide6.QtWidgets import QComboBox, QLineEdit
    from linux.ui_native.widgets import ParameterDialog
    from linux.ui_native.catalog import build_catalog
    catalog = build_catalog(ROOT)
    plan = next(a for a in catalog if a.id == "windows.provision.plan")
    dialog = ParameterDialog(plan)
    custom_field = dialog._fields.get("graphics.custom")
    assert custom_field is not None
    assert isinstance(custom_field, QLineEdit)
    # custom field is disabled by default (compat selected)
    assert not custom_field.isEnabled()
    combo = dialog._fields["graphics"]
    combo.setCurrentText("custom")
    assert custom_field.isEnabled()
    custom_field.setText("my-profile")
    # selecting compat disables custom
    combo.setCurrentText("compat")
    assert not custom_field.isEnabled()


def test_custom_flow_passes_custom_value_in_plan(page_and_catalog):
    page, by_id, catalog = page_and_catalog
    page._selected_iso = "/fake.iso"
    page._graphics_combo.setCurrentIndex(3)  # custom
    page._custom_field.setText("my-custom-profile")
    page._custom_field.setVisible(True)
    graphics = page._custom_field.text().strip() if page._selected_graphics == "custom" else page._selected_graphics
    assert graphics == "my-custom-profile"
    plan = by_id["windows.provision.plan"]
    args = plan.resolved_args(
        value="/fake.iso",
        values={"input": "/fake.iso", "graphics": graphics, "image_index": "1"},
    )
    assert "--graphics" in args
    idx = args.index("--graphics") + 1
    assert args[idx] == "my-custom-profile"


# ── Severity classification tests ───────────────────────────────────

def test_severity_diagnostic_nonzero_with_output_warning():
    assert severity_for({"status": "ok", "checks": []}, exit_code=1, mutable=False) == "warning"
    assert severity_for(["check1", "check2"], exit_code=1, mutable=False) == "warning"
    assert severity_for("some output", exit_code=1, mutable=False) == "warning"
    assert severity_for({"status": "ok"}, exit_code=1, mutable=False) == "warning"


def test_severity_diagnostic_nonzero_no_output_error():
    assert severity_for(None, exit_code=1, mutable=False) == "error"
    assert severity_for({}, exit_code=1, mutable=False) == "error"
    assert severity_for([], exit_code=1, mutable=False) == "error"
    assert severity_for("", exit_code=1, mutable=False) == "error"


def test_severity_mutable_nonzero_error():
    assert severity_for({"k": 1}, exit_code=1, mutable=True) == "error"
    assert severity_for(None, exit_code=1, mutable=True) == "error"


def test_severity_exit_zero_success():
    assert severity_for({"x": 1}, exit_code=0, mutable=False) == "success"
    assert severity_for({"x": 1}, exit_code=0, mutable=True) == "success"
    assert severity_for(None, exit_code=0, mutable=True) == "success"


def test_severity_status_field_respected_on_exit_zero():
    assert severity_for({"status": "degraded"}, exit_code=0, mutable=True) == "warning"
    assert severity_for({"status": "failed"}, exit_code=0, mutable=True) == "error"
    assert severity_for({"status": "warn"}, exit_code=0, mutable=False) == "warning"


def test_severity_doctor_realworld_fixture():
    fixture = [
        "[FAIL] CPU01: CPU temperature <= 85°C — 95°C",
        "[WARN] MEM01: Total RAM >= 4GB — 0GB",
        "[PASS] DISK01: Disk space >= 10GB — 250GB",
    ]
    assert severity_for(fixture, exit_code=1, mutable=False) == "warning"


def test_result_dialog_renders_warning_tone(qapp):
    from linux.ui_native.widgets import ResultDialog
    from linux.ui_native.models import OperationResult
    result = OperationResult("system.doctor", ["doctor"], False, 1, "", "", "", "", parsed=["check"], result_path=None)
    dialog = ResultDialog(result, "output", severity="warning")
    assert "Concluído com avisos" in dialog.windowTitle()
    assert dialog.property("state") == "warning"


def test_mutable_install_failure_stays_error(qapp):
    from linux.ui_native.widgets import ResultDialog
    from linux.ui_native.models import OperationResult
    result = OperationResult("windows.provision.start", ["provision"], False, 1, "", "", "", "", parsed=None, result_path=None)
    dialog = ResultDialog(result, "output")
    assert "Operação falhou" in dialog.windowTitle()
    assert dialog.property("state") == "error"
