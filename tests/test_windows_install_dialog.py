from __future__ import annotations

import json
from pathlib import Path

import pytest
from PySide6.QtCore import Qt
from PySide6.QtGui import QStandardItemModel
from PySide6.QtWidgets import QApplication

from linux.ui_native.windows_install_dialog import WindowsInstallDialog, completed_image_indices


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_completed_indices_only_include_finished_operations(tmp_path: Path) -> None:
    complete = tmp_path / "op-complete"
    complete.mkdir()
    (complete / "operation.json").write_text(json.dumps({"state": "completed"}))
    (complete / "plan.json").write_text(json.dumps({"imageIndex": 4}))
    failed = tmp_path / "op-failed"
    failed.mkdir()
    (failed / "operation.json").write_text(json.dumps({"state": "failed"}))
    (failed / "plan.json").write_text(json.dumps({"imageIndex": 5}))
    assert completed_image_indices(tmp_path) == {4}


def test_removed_or_missing_vm_releases_completed_index(tmp_path: Path) -> None:
    removed = tmp_path / "op-removed"
    removed.mkdir()
    (removed / "operation.json").write_text(json.dumps({
        "state": "completed", "vmRemovedAt": "2026-08-16T12:00:00Z",
    }))
    (removed / "plan.json").write_text(json.dumps({"imageIndex": 2}))

    missing = tmp_path / "op-missing"
    missing.mkdir()
    (missing / "operation.json").write_text(json.dumps({"state": "completed"}))
    (missing / "plan.json").write_text(json.dumps({"imageIndex": 3}))
    (missing / "vm_dir").write_text(str(tmp_path / "no-longer-present"))

    active = tmp_path / "op-active"
    active.mkdir()
    vm_dir = tmp_path / "existing-vm"
    vm_dir.mkdir()
    (active / "operation.json").write_text(json.dumps({"state": "completed"}))
    (active / "plan.json").write_text(json.dumps({"imageIndex": 4}))
    (active / "vm_dir").write_text(str(vm_dir))

    assert completed_image_indices(tmp_path) == {4}


def test_dialog_limits_editions_and_disables_used_index(qapp) -> None:
    dialog = WindowsInstallDialog(used_indices={2, 7})
    assert dialog.isWindow()
    assert dialog.testAttribute(Qt.WA_StyledBackground)
    assert dialog.autoFillBackground()
    assert dialog.edition_combo.count() == 10
    model = dialog.edition_combo.model()
    assert isinstance(model, QStandardItemModel)
    assert not model.item(1).isEnabled()
    assert not model.item(6).isEnabled()
    assert dialog.edition_combo.currentData() == 1
    dialog.close()
    dialog.deleteLater()
    QApplication.processEvents()


def test_dialog_exposes_only_installable_profiles_and_returns_iso_before_player(qapp, tmp_path: Path) -> None:
    iso = tmp_path / "Windows.iso"
    iso.touch()
    dialog = WindowsInstallDialog(used_indices=set())
    dialog.iso_edit.setText(str(iso))
    ids = [dialog.graphics_combo.itemData(index)[0] for index in range(dialog.graphics_combo.count())]
    labels = [dialog.graphics_combo.itemText(index) for index in range(dialog.graphics_combo.count())]
    assert ids == ["compat", "virtio-gl"]
    assert labels == ["compat — máxima compatibilidade", "virtio-gl — aceleração OpenGL"]
    assert not hasattr(dialog, "custom_graphics")
    assert not hasattr(dialog, "custom_label")
    dialog.graphics_combo.setCurrentIndex(1)
    values = dialog.values()
    assert values["input"] == str(iso)
    assert values["graphics"] == "virtio-gl"
    assert values["image_index"] == "1"
    dialog.close()
    dialog.deleteLater()
    QApplication.processEvents()
