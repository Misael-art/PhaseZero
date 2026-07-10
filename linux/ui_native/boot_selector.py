from __future__ import annotations

import os
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QButtonGroup,
    QDialog,
    QDialogButtonBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QMessageBox,
    QPushButton,
    QRadioButton,
    QStyle,
    QVBoxLayout,
)

from .widgets import themed_icon
from .platform import admin_bridge


@dataclass(frozen=True)
class BootChoice:
    key: str
    title: str
    description: str
    icon: str


BOOT_CHOICES = (
    BootChoice("normal", "Linux normal", "Limpa one-shot e usa padrão da distro.", "computer"),
    BootChoice("steamos", "SteamOS", "Próximo boot abre Steam/Gamepad UI.", "input-gaming"),
    BootChoice("windows", "Windows VM", "Próximo boot abre Windows VM fullscreen.", "computer"),
    BootChoice("waydroid", "Waydroid", "Próximo boot abre Android kiosk.", "phone"),
    BootChoice("emergency", "Emergência", "Próximo boot entra em rescue.target.", "dialog-warning"),
)


def build_boot_selector_program(root: Path, choice: str, *, reboot: bool) -> tuple[str, list[str]]:
    bridge = admin_bridge()
    if not bridge:
        raise RuntimeError("elevação indisponível; execute `linux/pz ai setup admin`")
    pz = str(root / "linux" / "pz")
    args = [pz, "boot", "choose", choice]
    if reboot:
        args.append("--reboot")
    return bridge, args


class BootSelectorWindow(QDialog):
    def __init__(self, root: Path, *, smoke_test: bool = False) -> None:
        super().__init__()
        self.root = root
        self.choice_buttons: dict[int, str] = {}
        self.group = QButtonGroup(self)
        self.setWindowTitle("PhaseZero - Seletor de Boot")
        self.setMinimumSize(560, 560)
        self._build_ui()
        if smoke_test:
            self.setProperty("smokeTest", True)

    def _build_ui(self) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(18, 18, 18, 18)
        outer.setSpacing(12)
        title = QLabel("Seletor de boot")
        title.setObjectName("pageTitle")
        subtitle = QLabel("Escolha a próxima sessão antes de reiniciar.")
        subtitle.setObjectName("pageSubtitle")
        outer.addWidget(title)
        outer.addWidget(subtitle)

        for index, choice in enumerate(BOOT_CHOICES):
            card = QFrame()
            card.setObjectName("actionCard")
            row = QHBoxLayout(card)
            row.setContentsMargins(14, 12, 14, 12)
            icon = QLabel()
            icon.setPixmap(themed_icon(card, choice.icon, QStyle.SP_ComputerIcon).pixmap(30, 30))
            icon.setFixedSize(38, 38)
            row.addWidget(icon)
            text_box = QVBoxLayout()
            label = QLabel(choice.title)
            label.setObjectName("cardTitle")
            desc = QLabel(choice.description)
            desc.setObjectName("cardDescription")
            desc.setWordWrap(True)
            text_box.addWidget(label)
            text_box.addWidget(desc)
            row.addLayout(text_box, 1)
            radio = QRadioButton()
            radio.setAccessibleName(choice.title)
            self.group.addButton(radio, index)
            self.choice_buttons[index] = choice.key
            row.addWidget(radio)
            card.mousePressEvent = lambda _event, button=radio: button.setChecked(True)  # type: ignore[method-assign]
            outer.addWidget(card)
            if index == 0:
                radio.setChecked(True)

        buttons = QDialogButtonBox()
        schedule = QPushButton("Agendar")
        schedule.setObjectName("primaryButton")
        schedule.clicked.connect(lambda: self.run_choice(reboot=False))
        reboot = QPushButton("Agendar + reiniciar")
        reboot.setObjectName("dangerButton")
        reboot.clicked.connect(lambda: self.run_choice(reboot=True))
        cancel = buttons.addButton("Cancelar", QDialogButtonBox.RejectRole)
        cancel.clicked.connect(self.reject)
        buttons.addButton(schedule, QDialogButtonBox.ActionRole)
        buttons.addButton(reboot, QDialogButtonBox.ActionRole)
        outer.addWidget(buttons)

    def selected_choice(self) -> str:
        return self.choice_buttons.get(self.group.checkedId(), "normal")

    def run_choice(self, *, reboot: bool) -> None:
        choice = self.selected_choice()
        try:
            program, args = build_boot_selector_program(self.root, choice, reboot=reboot)
        except RuntimeError as exc:
            QMessageBox.critical(self, "Elevação indisponível", str(exc))
            return
        display = shlex.join([program, *args])
        env = os.environ.copy()
        env["PZ_UI"] = "native-boot-selector"
        result = subprocess.run(
            [program, *args],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        if result.returncode == 0:
            QMessageBox.information(self, "Boot agendado", result.stdout.strip() or display)
            self.accept()
            return
        QMessageBox.critical(
            self,
            "Falha ao agendar boot",
            "\n\n".join(part for part in (display, result.stdout.strip(), result.stderr.strip()) if part),
        )
