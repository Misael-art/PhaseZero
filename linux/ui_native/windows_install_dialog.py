from __future__ import annotations

import json
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QStandardItemModel
from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from .catalog import WINDOWS_VM_GRAPHICS_OPTIONS
from .platform import state_dir


def completed_image_indices(operations_dir: Path | None = None) -> set[int]:
    """Return Windows image indices consumed by completed provision operations."""
    root = operations_dir or state_dir().parent / "operations"
    used: set[int] = set()
    if not root.is_dir():
        return used
    for operation_file in root.glob("*/operation.json"):
        try:
            operation = json.loads(operation_file.read_text(encoding="utf-8"))
            if operation.get("state") != "completed":
                continue
            plan = json.loads((operation_file.parent / "plan.json").read_text(encoding="utf-8"))
            index = int(plan.get("imageIndex", 0))
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            continue
        if 1 <= index <= 10:
            used.add(index)
    return used


class WindowsInstallDialog(QDialog):
    """Collect the complete install contract before the provision player opens."""

    def __init__(self, parent: QWidget | None = None, *, used_indices: set[int] | None = None) -> None:
        super().__init__(parent, Qt.Dialog)
        self.setObjectName("windowsInstallDialog")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self.setAutoFillBackground(True)
        self.setWindowTitle("Instalar Windows automaticamente")
        self.setWindowModality(Qt.WindowModal)
        self.setMinimumWidth(620)
        self._used_indices = set(used_indices if used_indices is not None else completed_image_indices())

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 18, 20, 18)
        layout.setSpacing(14)

        title = QLabel("Preparar instalação do Windows 11")
        title.setObjectName("sectionHeading")
        layout.addWidget(title)
        intro = QLabel(
            "Escolha a ISO e as opções antes de iniciar. O PhaseZero valida o arquivo "
            "e impede combinações já usadas."
        )
        intro.setObjectName("cardDescription")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        form = QFormLayout()
        form.setHorizontalSpacing(16)
        form.setVerticalSpacing(12)

        iso_row = QHBoxLayout()
        self.iso_edit = QLineEdit()
        self.iso_edit.setObjectName("windowsIsoPath")
        self.iso_edit.setReadOnly(True)
        self.iso_edit.setPlaceholderText("Nenhuma ISO selecionada")
        choose = QPushButton("Escolher ISO…")
        choose.setObjectName("secondaryButton")
        choose.clicked.connect(self.choose_iso)
        iso_row.addWidget(self.iso_edit, 1)
        iso_row.addWidget(choose)
        form.addRow("ISO do Windows:", iso_row)

        self.graphics_combo = QComboBox()
        self.graphics_combo.setObjectName("windowsGraphicsProfile")
        for value, label, helper in WINDOWS_VM_GRAPHICS_OPTIONS:
            self.graphics_combo.addItem(label, (value, helper))
        self.graphics_combo.currentIndexChanged.connect(self._graphics_changed)
        form.addRow("Aceleração gráfica:", self.graphics_combo)

        self.graphics_help = QLabel()
        self.graphics_help.setObjectName("cardDescription")
        self.graphics_help.setWordWrap(True)
        form.addRow("", self.graphics_help)

        self.edition_combo = QComboBox()
        self.edition_combo.setObjectName("windowsEditionIndex")
        for index in range(1, 11):
            suffix = " — já instalado" if index in self._used_indices else ""
            self.edition_combo.addItem(f"Edição {index}{suffix}", index)
        model = self.edition_combo.model()
        if isinstance(model, QStandardItemModel):
            for row in range(self.edition_combo.count()):
                if int(self.edition_combo.itemData(row)) in self._used_indices:
                    model.item(row).setEnabled(False)
        first_available = next(
            (row for row in range(self.edition_combo.count())
             if int(self.edition_combo.itemData(row)) not in self._used_indices),
            -1,
        )
        self.edition_combo.setCurrentIndex(first_available)
        form.addRow("Edição do Windows:", self.edition_combo)

        self.login_combo = QComboBox()
        self.login_combo.setObjectName("windowsGuestLogin")
        self.login_combo.addItem("Entrar automaticamente", "auto")
        self.login_combo.addItem("Exigir senha", "password")
        form.addRow("Login no Windows:", self.login_combo)
        layout.addLayout(form)

        self.buttons = QDialogButtonBox(QDialogButtonBox.Cancel | QDialogButtonBox.Ok)
        install = self.buttons.button(QDialogButtonBox.Ok)
        cancel = self.buttons.button(QDialogButtonBox.Cancel)
        if install:
            install.setText("Instalar automaticamente")
            install.setObjectName("primaryButton")
            install.setEnabled(first_available >= 0)
        if cancel:
            cancel.setText("Cancelar")
        self.buttons.accepted.connect(self._accept_if_valid)
        self.buttons.rejected.connect(self.reject)
        layout.addWidget(self.buttons)
        self._graphics_changed(self.graphics_combo.currentIndex())

    def choose_iso(self) -> None:
        path, _selected_filter = QFileDialog.getOpenFileName(
            self,
            "Escolha a ISO do Windows",
            str(Path.home()),
            "Imagens ISO (*.iso);;Todos os arquivos (*)",
        )
        if path:
            self.iso_edit.setText(path)

    def _graphics_changed(self, index: int) -> None:
        data = self.graphics_combo.itemData(index)
        value, helper = data if isinstance(data, tuple) and len(data) == 2 else ("compat", "")
        self.graphics_help.setText(str(helper))

    def _accept_if_valid(self) -> None:
        iso = Path(self.iso_edit.text()).expanduser()
        if not self.iso_edit.text() or not iso.is_file() or iso.suffix.casefold() != ".iso":
            QMessageBox.warning(
                self,
                "ISO necessária",
                "Escolha um arquivo .iso do Windows válido antes de continuar.",
            )
            return
        if self.edition_combo.currentIndex() < 0:
            QMessageBox.warning(self, "Edições indisponíveis", "Os dez índices já foram usados.")
            return
        self.accept()

    def graphics_value(self) -> str:
        data = self.graphics_combo.currentData()
        value = data[0] if isinstance(data, tuple) and data else "compat"
        return str(value)

    def values(self) -> dict[str, str]:
        return {
            "input": self.iso_edit.text(),
            "graphics": self.graphics_value(),
            "image_index": str(self.edition_combo.currentData()),
            "guest_login": str(self.login_combo.currentData()),
        }
