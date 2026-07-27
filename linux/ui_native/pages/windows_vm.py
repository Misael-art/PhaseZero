from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox, QFileDialog, QFormLayout, QFrame, QGroupBox,
    QHBoxLayout, QLabel, QPushButton, QScrollArea, QStyle,
    QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec, OperationResult
from ..widgets import SectionHeader, themed_icon
from .base import BasePage


class WindowsVMPage(BasePage):
    """Windows VM lifecycle page."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        # Install card (main flow)
        install_card = QFrame()
        install_card.setObjectName("installCard")
        install_card.setStyleSheet(
            "#installCard { background: palette(window); border: 1px solid palette(mid); "
            "border-radius: 8px; padding: 16px; }"
        )
        card_layout = QVBoxLayout(install_card)
        card_layout.setSpacing(10)

        title_row = QHBoxLayout()
        icon = QLabel()
        icon.setPixmap(themed_icon(install_card, "system-software-install",
                                   QStyle.SP_ComputerIcon).pixmap(32, 32))
        icon.setFixedSize(40, 40)
        title_row.addWidget(icon)
        texts = QVBoxLayout()
        title = QLabel("Instalar e otimizar Windows")
        title.setObjectName("installCardTitle")
        title.setStyleSheet("font-size: 16px; font-weight: bold;")
        desc = QLabel("Selecionar ISO, escolher edição e instalar.")
        desc.setObjectName("installCardDesc")
        desc.setStyleSheet("font-size: 12px; color: palette(mid);")
        texts.addWidget(title)
        texts.addWidget(desc)
        title_row.addLayout(texts, 1)
        card_layout.addLayout(title_row)

        form = QFormLayout()
        form.setSpacing(8)

        self._iso_path_label = QLabel("Nenhum ISO selecionado")
        self._iso_path_label.setObjectName("isoPath")
        self._iso_path_label.setWordWrap(True)
        iso_row = QHBoxLayout()
        iso_btn = QPushButton("Selecionar ISO")
        iso_btn.setObjectName("primaryButton")
        iso_btn.clicked.connect(self._select_iso)
        iso_row.addWidget(self._iso_path_label, 1)
        iso_row.addWidget(iso_btn)
        form.addRow("ISO:", iso_row)

        self._edition_combo = QComboBox()
        self._edition_combo.setEnabled(False)
        self._edition_combo.currentIndexChanged.connect(self._on_edition_changed)
        form.addRow("Edição:", self._edition_combo)

        self._graphics_combo = QComboBox()
        self._graphics_combo.addItem("compat (QXL, software)", "compat")
        self._graphics_combo.addItem("virtio-gl (OpenGL, requer GPU host compatível)", "virtio-gl")
        self._graphics_combo.currentIndexChanged.connect(self._on_graphics_changed)
        form.addRow("Aceleração:", self._graphics_combo)

        plan_btn = QPushButton("Planejar instalação")
        plan_btn.setObjectName("secondaryButton")
        plan_btn.clicked.connect(self._request_plan)
        form.addRow("", plan_btn)

        card_layout.addLayout(form)
        layout.addWidget(install_card)

        # Status
        layout.addWidget(SectionHeader("Status", "Estado da VM Windows"))
        for aid in ("windows.status", "windows.discover"):
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))

        # Provision actions
        layout.addWidget(SectionHeader("Instalação automática", "Acompanhe ou retome"))
        for aid in ("windows.provision.plan", "windows.provision.start",
                     "windows.provision.status", "windows.provision.watch",
                     "windows.provision.resume", "windows.provision.cancel",
                     "windows.provision.discard"):
            action = self.find(aid)
            if action:
                layout.addWidget(self._action_row(action))

        # Install & Launch (legacy)
        install_box = QGroupBox("Instalação manual e inicialização")
        install_layout = QVBoxLayout(install_box)
        for aid in ("windows.plan", "windows.install", "windows.adopt", "windows.launch", "windows.optimize"):
            action = self.find(aid)
            if action:
                install_layout.addWidget(self._action_row(action))
        layout.addWidget(install_box)

        # Graphics
        graphics_box = QGroupBox("Gráficos e aceleração")
        graphics_layout = QVBoxLayout(graphics_box)
        for aid in (
            "windows.graphics.doctor",
            "windows.graphics.status",
            "windows.graphics.plan-gl",
            "windows.graphics.plan-venus",
            "windows.graphics.test-gl",
            "windows.graphics.plan-vfio",
            "windows.graphics.compat",
            "windows.graphics.runtime-status",
            "windows.graphics.runtime-install",
            "windows.graphics.runtime-rollback",
            "windows.graphics.guest-guide",
        ):
            action = self.find(aid)
            if action:
                if aid == "windows.graphics.doctor":
                    self._context_status_action = action
                graphics_layout.addWidget(self._action_row(action))
        layout.addWidget(graphics_box)

        # WinBoat/WinPodX
        apps_box = QGroupBox("WinBoat e WinPodX")
        apps_layout = QVBoxLayout(apps_box)
        for aid in ("windows.apps.status", "windows.apps.setup", "windows.apps.configure"):
            action = self.find(aid)
            if action:
                apps_layout.addWidget(self._action_row(action))
        layout.addWidget(apps_box)

        # System
        system_box = QGroupBox("Sistema")
        system_layout = QVBoxLayout(system_box)
        for aid in ("windows.host-access", "windows.boot.install", "windows.boot.next"):
            action = self.find(aid)
            if action:
                system_layout.addWidget(self._action_row(action))
        layout.addWidget(system_box)

        # Media
        media_box = QGroupBox("Mídia")
        media_layout = QVBoxLayout(media_box)
        for aid in ("windows.media.inspect",):
            action = self.find(aid)
            if action:
                media_layout.addWidget(self._action_row(action))
        layout.addWidget(media_box)

        layout.addStretch()

        scroll.setWidget(inner)
        self._layout.addWidget(scroll)

        self._selected_iso = ""
        self._selected_graphics = "compat"
        self._selected_image_index = 1
        self._inspect_result_pending = False
        self.runner.completed.connect(self._on_op_complete)

    def _action_row(self, action: ActionSpec) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        row = QHBoxLayout(card)
        row.setContentsMargins(14, 10, 14, 10)
        icon = QLabel()
        icon.setPixmap(themed_icon(card, action.icon, QStyle.SP_ComputerIcon).pixmap(24, 24))
        icon.setFixedSize(34, 34)
        row.addWidget(icon)
        text = QLabel(action.title)
        text.setObjectName("cardTitle")
        text.setToolTip(action.description)
        row.addWidget(text, 1)
        btn = QPushButton("Executar")
        btn.setObjectName("primaryButton" if action.mutable else "secondaryButton")
        btn.clicked.connect(lambda: self.request_action(action))
        row.addWidget(btn)
        return card

    def _on_edition_changed(self, index: int) -> None:
        data = self._edition_combo.itemData(index)
        if data is not None:
            self._selected_image_index = int(data)

    def _on_graphics_changed(self, index: int) -> None:
        data = self._graphics_combo.itemData(index)
        if data is not None:
            self._selected_graphics = str(data)

    def _select_iso(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Selecionar ISO do Windows", "",
            "ISO files (*.iso);;All files (*.*)"
        )
        if not path:
            return
        self._selected_iso = path
        self._iso_path_label.setText(path)
        self._edition_combo.setEnabled(True)
        self._edition_combo.clear()
        self._selected_image_index = 1
        self._inspect_result_pending = True

        inspect = self.by_id.get("windows.media.inspect")
        if inspect:
            self.request_action(inspect)

    def _apply_inspect_result(self, result: dict | None) -> None:
        self._edition_combo.blockSignals(True)
        self._edition_combo.clear()
        self._inspect_result_pending = False
        images = []
        if result and isinstance(result, dict):
            images = result.get("images") or []
            if not isinstance(images, list):
                images = []
        if images:
            for img in images:
                idx = img.get("index", 1)
                name = img.get("name", f"Image {idx}")
                self._edition_combo.addItem(f"{idx}: {name}", idx)
        else:
            self._edition_combo.addItem("1: Padrão", 1)
        self._edition_combo.blockSignals(False)
        self._selected_image_index = int(self._edition_combo.currentData() or 1)

    def _on_op_complete(self, result: OperationResult) -> None:
        if self._inspect_result_pending and result.action_id == "windows.media.inspect":
            self._apply_inspect_result(result.parsed if result.ok else None)

    def _request_plan(self) -> None:
        if not self._selected_iso:
            return
        plan = self.by_id.get("windows.provision.plan")
        if not plan:
            return
        try:
            self.runner.start(
                plan,
                value=self._selected_iso,
                values={
                    "input": self._selected_iso,
                    "graphics": self._selected_graphics,
                    "image_index": str(self._selected_image_index),
                },
            )
        except (ValueError, RuntimeError) as exc:
            from PySide6.QtWidgets import QMessageBox
            QMessageBox.warning(self, "Não foi possível iniciar", str(exc))

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
