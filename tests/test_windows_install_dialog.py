from __future__ import annotations

import json
from pathlib import Path

import pytest
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


def test_dialog_limits_editions_and_disables_used_index(qapp) -> None:
    dialog = WindowsInstallDialog(used_indices={2, 7})
    assert dialog.edition_combo.count() == 10
    model = dialog.edition_combo.model()
    assert isinstance(model, QStandardItemModel)
    assert not model.item(1).isEnabled()
    assert not model.item(6).isEnabled()
    assert dialog.edition_combo.currentData() == 1
    dialog.close()
    dialog.deleteLater()
    QApplication.processEvents()


def test_dialog_exposes_custom_profile_and_returns_iso_before_player(qapp, tmp_path: Path) -> None:
    iso = tmp_path / "Windows.iso"
    iso.touch()
    dialog = WindowsInstallDialog(used_indices=set())
    dialog.iso_edit.setText(str(iso))
    assert dialog.custom_graphics.isHidden()
    assert dialog.custom_label.isHidden()
    custom_row = dialog.graphics_combo.findData(next(
        data for index in range(dialog.graphics_combo.count())
        if (data := dialog.graphics_combo.itemData(index))[0] == "custom"
    ))
    dialog.graphics_combo.setCurrentIndex(custom_row)
    assert dialog.custom_graphics.isEnabled()
    assert dialog.custom_graphics.isVisibleTo(dialog)
    assert dialog.custom_label.isVisibleTo(dialog)
    dialog.custom_graphics.setText("my-safe-profile")
    values = dialog.values()
    assert values["input"] == str(iso)
    assert values["graphics"] == "my-safe-profile"
    assert values["image_index"] == "1"
    dialog.close()
    dialog.deleteLater()
    QApplication.processEvents()
