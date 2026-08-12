from __future__ import annotations

from pathlib import Path
from types import ModuleType

import pytest
from PySide6.QtCore import Qt
from PySide6.QtGui import QTextCursor
from PySide6.QtWidgets import QApplication, QComboBox, QLabel, QPlainTextEdit, QPushButton, QTextEdit
from PySide6.QtTest import QSignalSpy

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.provision_player import ProvisionPlayerWindow, ST_IDLE, ST_DONE
from linux.ui_native.pages.windows_vm import WindowsVmPage
from linux.ui_native.result_parser import severity_for
from linux.ui_native.status_loader import StatusLoader
from linux.ui_native.widgets import HeaderBar, ParameterDialog
from linux.ui_native import __version__


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
    "linux.ui_native.provision_player",
    "linux.ui_native.pages.profiles",
    "linux.ui_native.pages.emulation",
    "linux.ui_native.pages.tuning",
    "linux.ui_native.pages.results",
    "linux.ui_native.pages.workspace",
    "linux.ui_native.pages.ai_proxies",
    "linux.ui_native.pages.windows_vm",
    "linux.ui_native.pages.service_control",
    "linux.ui_native.health_models",
]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def catalog():
    return build_catalog(ROOT)


@pytest.fixture
def by_id(catalog):
    return {a.id: a for a in catalog}


# ── Windows VM rendered through the friendly service page ──

@pytest.fixture
def ws_page(qapp, catalog):
    actions = [action for action in catalog if action.category == "Windows VM"]
    page = WindowsVmPage(ROOT, CommandRunner(ROOT), actions, by_id={a.id: a for a in catalog})
    page.build()
    page.finalize_action_coverage()
    return page, actions


def test_workspace_page_covers_all_windows_vm_actions(ws_page):
    page, actions = ws_page
    assert page.represented_action_ids == {action.id for action in actions}


def test_windows_vm_page_translates_status_json_into_visual_controls(ws_page):
    page, _actions = ws_page
    page._on_status_ready("windows.status", "", {
        "config": {"installed": True},
        "vm": {
            "diskExists": True, "installedLike": True, "ramMb": 10240, "cpus": 7,
            "graphicsProfile": "virtio-gl",
        },
        "libvirt": {"state": "running"},
        "host": {"qemu": "/usr/bin/qemu-system-x86_64"},
        "access": {
            "shareLinksReady": True, "sambaManaged": True,
            "sambaPolicyCompliant": True, "sambaReachable": True,
            "usbRedirChannels": 2, "usbUdevManaged": True,
        },
    })
    assert page.state_label.text() == "● Rodando"
    assert page.power_button.text() == "Desligar"
    assert page.ram_value.text() == "Memória: 10 GB"
    assert page.cpu_value.text() == "Processadores: 7"
    assert page.share_toggle.isChecked()
    assert page.gpu_toggle.isChecked()
    assert page.usb_toggle.isChecked()


def test_windows_vm_primary_actions_are_ordered_and_launch_requires_disk(ws_page):
    page, _actions = ws_page
    hero = page.refresh_button.parentWidget()
    labels = [
        hero.layout().itemAt(index).widget().text()
        for index in range(hero.layout().count())
        if isinstance(hero.layout().itemAt(index).widget(), QPushButton)
    ]
    assert labels == ["Atualizar", "Instalar automaticamente", "Iniciar VM"]
    page._on_status_ready("windows.status", "", {
        "config": {"installed": False}, "vm": {"diskExists": False},
        "libvirt": {"state": "missing"}, "host": {"qemu": "/usr/bin/qemu"},
    })
    assert not page.power_button.isEnabled()


def test_windows_integration_toggle_dispatches_real_reverse_action(ws_page):
    page, _actions = ws_page
    page._on_status_ready("windows.status", "", {
        "config": {"installed": True}, "vm": {"diskExists": True, "installedLike": True, "graphicsProfile": "compat"},
        "libvirt": {"state": "shut off"}, "host": {"qemu": "/usr/bin/qemu"},
        "access": {
            "shareLinksReady": True, "sambaManaged": True,
            "sambaPolicyCompliant": True, "sambaReachable": True,
            "usbUdevManaged": False,
        },
    })
    spy = QSignalSpy(page.action_requested)
    page.share_toggle.click()
    assert not page.share_toggle.isChecked()
    assert page.share_toggle.property("pending") is True
    assert not page.share_toggle.isEnabled()
    assert page.share_toggle.accessibleDescription() == "Desligado"
    assert spy.at(0)[0].id == "windows.shares.disable"
    page.cancel_pending_action("windows.shares.disable")
    assert page.share_toggle.isChecked()
    assert page.share_toggle.property("pending") is False
    assert page.share_toggle.isEnabled()


def test_windows_vm_blocks_blank_disk_and_surfaces_stale_boot(ws_page):
    page, _actions = ws_page
    page._on_status_ready("windows.status", "", {
        "status": "needsinstall",
        "health": {
            "readyToLaunch": False,
            "findings": [
                {"id": "guest-not-installed"},
                {"id": "boot-runtime-stale"},
            ],
        },
        "config": {"installed": True},
        "vm": {"diskExists": True, "installedLike": False},
        "libvirt": {"state": "missing"},
        "host": {"qemu": "/usr/bin/qemu"},
        "access": {},
        "boot": {"bootRuntimeStale": True},
    })
    assert page.state_label.text() == "● Instalação incompleta"
    assert not page.power_button.isEnabled()
    assert "conclua a instalação" in page.maintenance_health.text()
    assert not page.repair_boot_button.isHidden()


def test_windows_status_has_budget_for_aggregate_host_probes():
    assert StatusLoader.timeout_ms("windows.status") == 45_000
    assert StatusLoader.timeout_ms("steamdeck.status") == 15_000


def test_windows_status_timeout_explains_safe_retry(ws_page):
    page, _actions = ws_page
    page._on_status_failed("windows.status", "timed out")
    assert page.state_label.text() == "● Estado indisponível"
    assert "demorou demais" in page.state_detail.text()
    assert "nenhuma configuração" in page.maintenance_health.text()


def test_header_shows_installed_version_next_to_product_name(qapp):
    header = HeaderBar()
    title = header.findChild(QLabel, "windowTitle")
    assert title is not None
    assert title.text() == f"PhaseZero v{__version__}"


def test_windows_vm_page_uses_safe_shutdown_action(ws_page):
    from PySide6.QtTest import QSignalSpy

    page, _actions = ws_page
    page._payload = {"libvirt": {"state": "running"}}
    spy = QSignalSpy(page.action_requested)
    page._power_action()
    assert spy.count() == 1
    assert spy.at(0)[0].id == "windows.guest-login.shutdown"


def test_windows_vm_page_offers_image_manager(ws_page):
    from PySide6.QtTest import QSignalSpy

    page, _actions = ws_page
    buttons = [b for b in page.findChildren(QPushButton) if b.text() == "Gerenciar imagens"]
    assert buttons, "página Windows VM deve expor o botão 'Gerenciar imagens'"
    spy = QSignalSpy(page.action_requested)
    buttons[0].click()
    assert spy.count() == 1
    assert spy.at(0)[0].id == "windows.images.manage"


def test_windows_shutdown_action_has_read_only_preview(by_id):
    action = by_id["windows.guest-login.shutdown"]
    assert action.mutable
    assert action.preview_args == ("windows-vm", "guest-login", "status", "--json")
    assert action.args == ("windows-vm", "guest-login", "shutdown", "--json")


def test_windows_vm_category_has_plan_and_provision_actions(by_id):
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
    for pid in provision_ids:
        assert pid in by_id, f"{pid} not registered"


# ── Catalog contract: provision plan argv and graphics options ──────

def test_plan_argv_includes_graphics(by_id):
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


def test_plan_argv_includes_image_index(by_id):
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


def test_venus_plan_action_present(by_id):
    assert "windows.graphics.plan-venus" in by_id


def test_venus_catalog_entry_correct(by_id):
    venus = by_id["windows.graphics.plan-venus"]
    assert venus.args[:4] == ("windows-vm", "graphics", "plan", "--profile")
    assert "virtio-venus" in venus.args
    assert "--json" in venus.args
    assert venus.title == "Ver plano Venus"
    assert venus.badge == "Experimental"
    assert "instalação bloqueada" in venus.description


def test_catalog_graphics_param_kind_is_choice(by_id):
    plan = by_id["windows.provision.plan"]
    graphics_param = next(p for p in plan.parameters if p.name == "graphics")
    assert graphics_param.kind == "choice"
    assert graphics_param.choices == ("compat", "virtio-gl")


# ── ParameterDialog (live path used by the workspace page) ──────────

def test_parameter_dialog_renders_combo_for_graphics(qapp, catalog):
    plan = next(a for a in catalog if a.id == "windows.provision.plan")
    dialog = ParameterDialog(plan)
    field = dialog._fields.get("graphics")
    assert field is not None
    assert isinstance(field, QComboBox)
    assert field.count() == 2
    assert [field.itemText(index) for index in range(field.count())] == ["compat", "virtio-gl"]
    assert dialog._fields.get("graphics.custom") is None


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
