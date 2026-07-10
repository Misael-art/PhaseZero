from __future__ import annotations

import re
import shlex
import time

from PySide6.QtCore import (
    QEasingCurve,
    QEvent,
    QPoint,
    QPropertyAnimation,
    Qt,
    QTimer,
    Signal,
    QUrl,
)
from PySide6.QtGui import QColor, QDesktopServices, QIcon, QMouseEvent
from PySide6.QtWidgets import (
    QApplication,
    QDialog,
    QDialogButtonBox,
    QCheckBox,
    QComboBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QGraphicsDropShadowEffect,
    QGraphicsOpacityEffect,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QStyle,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from .models import ActionSpec, OperationResult


def themed_icon(widget: QWidget, name: str, fallback: QStyle.StandardPixmap) -> QIcon:
    icon = QIcon.fromTheme(name)
    return icon if not icon.isNull() else widget.style().standardIcon(fallback)


def _repolish(widget: QWidget) -> None:
    widget.style().unpolish(widget)
    widget.style().polish(widget)


class HeaderBar(QFrame):
    minimize_requested = Signal()
    maximize_requested = Signal()
    close_requested = Signal()

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("headerBar")
        self._drag_position: QPoint | None = None
        layout = QHBoxLayout(self)
        layout.setContentsMargins(18, 8, 10, 8)
        mark = QLabel("PZ")
        mark.setObjectName("brandMark")
        title = QLabel("PhaseZero")
        title.setObjectName("windowTitle")
        subtitle = QLabel("Central de Controle")
        subtitle.setObjectName("windowSubtitle")
        title_box = QVBoxLayout()
        title_box.setSpacing(0)
        title_box.addWidget(title)
        title_box.addWidget(subtitle)
        layout.addWidget(mark)
        layout.addLayout(title_box)
        layout.addStretch()
        # Language chips stay visible (EmuDeck keeps locale selection in the open).
        for flag in ("🇧🇷", "🇺🇸"):
            chip = QLabel(flag)
            chip.setObjectName("langChip")
            layout.addWidget(chip)
        for icon_name, fallback, signal, object_name in [
            ("window-minimize", QStyle.SP_TitleBarMinButton, self.minimize_requested, "windowButton"),
            ("window-maximize", QStyle.SP_TitleBarMaxButton, self.maximize_requested, "windowButton"),
            ("window-close", QStyle.SP_TitleBarCloseButton, self.close_requested, "closeButton"),
        ]:
            button = QPushButton()
            button.setObjectName(object_name)
            button.setIcon(themed_icon(self, icon_name, fallback))
            button.setFixedSize(34, 32)
            button.clicked.connect(signal.emit)
            layout.addWidget(button)

    def mousePressEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            handle = self.window().windowHandle()
            if handle is not None and handle.startSystemMove():
                self._drag_position = None
            else:
                self._drag_position = (
                    event.globalPosition().toPoint() - self.window().frameGeometry().topLeft()
                )
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent) -> None:
        if self._drag_position is not None and event.buttons() & Qt.LeftButton:
            self.window().move(event.globalPosition().toPoint() - self._drag_position)
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        self._drag_position = None
        super().mouseReleaseEvent(event)

    def mouseDoubleClickEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            self.maximize_requested.emit()
        super().mouseDoubleClickEvent(event)


class SectionHeader(QWidget):
    """A dashboard section heading: bold title + subtle caption."""

    def __init__(self, title: str, caption: str = "", parent: QWidget | None = None) -> None:
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(2, 8, 2, 2)
        layout.setSpacing(1)
        label = QLabel(title)
        label.setObjectName("sectionHeading")
        layout.addWidget(label)
        if caption:
            cap = QLabel(caption)
            cap.setObjectName("sectionCaption")
            layout.addWidget(cap)


class Breadcrumb(QFrame):
    """Compact, accessible location indicator for category navigation."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("breadcrumb")
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        self._label = QLabel("PhaseZero")
        self._label.setObjectName("breadcrumbText")
        self._label.setAccessibleName("Localização atual")
        layout.addWidget(self._label)
        layout.addStretch()

    def set_path(self, section: str, page: str) -> None:
        parts = ["PhaseZero", section, page]
        text = "  ›  ".join(part for index, part in enumerate(parts) if part and part not in parts[:index])
        self._label.setText(text)
        self._label.setAccessibleDescription(f"Página atual: {page}; seção: {section}")

    @property
    def text(self) -> str:
        return self._label.text()


class ActionCard(QFrame):
    requested = Signal(object)

    def __init__(self, action: ActionSpec, *, hero: bool = False, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.action = action
        self.setObjectName("actionCard")
        self.setProperty("variant", action.variant)
        self.setProperty("hero", hero)
        if hero:
            self.setMinimumSize(300, 150)
            self.setMaximumHeight(172)
        else:
            self.setMinimumSize(272, 168)
            self.setMaximumHeight(196)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setCursor(Qt.PointingHandCursor)
        self.installEventFilter(self)
        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(26 if hero else 20)
        shadow.setOffset(0, 6)
        shadow.setColor(QColor(0, 0, 0, 110 if hero else 80))
        self.setGraphicsEffect(shadow)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(18, 16, 18, 16)
        outer.setSpacing(9)

        heading = QHBoxLayout()
        heading.setSpacing(12)
        icon_tile = QLabel()
        icon_tile.setObjectName("cardIconHero" if hero else "cardIcon")
        px = 34 if hero else 28
        icon_tile.setPixmap(themed_icon(self, action.icon, QStyle.SP_ComputerIcon).pixmap(px, px))
        icon_tile.setFixedSize(56 if hero else 46, 56 if hero else 46)
        icon_tile.setAlignment(Qt.AlignCenter)
        heading.addWidget(icon_tile)
        title_box = QVBoxLayout()
        title_box.setSpacing(1)
        title = QLabel(action.title)
        title.setObjectName("cardTitleHero" if hero else "cardTitle")
        title.setWordWrap(True)
        title_box.addWidget(title)
        if action.elevated:
            lock = QLabel("🔒 requer admin")
            lock.setObjectName("cardLock")
            title_box.addWidget(lock)
        heading.addLayout(title_box, 1)
        if action.badge:
            badge = QLabel(action.badge)
            badge.setObjectName("badge")
            badge.setProperty("state", action.state)
            badge.setAlignment(Qt.AlignCenter)
            heading.addWidget(badge, 0, Qt.AlignTop)
        outer.addLayout(heading)

        description = QLabel(action.description)
        description.setObjectName("cardDescription")
        description.setWordWrap(True)
        outer.addWidget(description, 1)

        button = QPushButton("Pré-visualizar" if action.mutable else "Executar")
        button.setObjectName(
            {"danger": "dangerButton", "primary": "primaryButton"}.get(action.variant, "secondaryButton")
        )
        button.setCursor(Qt.PointingHandCursor)
        button.setIcon(
            themed_icon(
                self,
                "document-preview" if action.mutable else "media-playback-start",
                QStyle.SP_MediaPlay,
            )
        )
        button.clicked.connect(lambda: self.requested.emit(self.action))
        outer.addWidget(button)

    def eventFilter(self, watched: object, event: QEvent) -> bool:
        if watched is self and event.type() == QEvent.KeyPress:
            if event.key() in (Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space):
                self.requested.emit(self.action)
                return True
        return super().eventFilter(watched, event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        # Clicking anywhere on the card (not just the button) triggers it.
        if event.button() == Qt.LeftButton and self.rect().contains(event.position().toPoint()):
            self.requested.emit(self.action)
        super().mouseReleaseEvent(event)


class StatusPill(QFrame):
    """A coloured status chip for checklists (BIOS Checker style)."""

    def __init__(self, label: str, state: str, detail: str = "", parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("statusPill")
        self.setProperty("state", state)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(12, 7, 12, 7)
        dot = QLabel("●")
        dot.setObjectName("pillDot")
        dot.setProperty("state", state)
        text = QLabel(label)
        text.setObjectName("pillLabel")
        layout.addWidget(dot)
        layout.addWidget(text)
        layout.addStretch()
        if detail:
            det = QLabel(detail)
            det.setObjectName("pillDetail")
            layout.addWidget(det)


class AdvancedActionsPanel(QFrame):
    """Collapsed contextual access to uncommon or administrative actions."""

    requested = Signal(object)

    def __init__(self, actions: list[ActionSpec], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("advancedPanel")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        toggle = QToolButton()
        toggle.setObjectName("advancedToggle")
        toggle.setText(f"Avançado ({len(actions)})")
        toggle.setCheckable(True)
        toggle.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        toggle.setArrowType(Qt.RightArrow)
        toggle.setAccessibleName("Mostrar ações avançadas")
        layout.addWidget(toggle)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setMaximumHeight(300)
        content = QWidget()
        rows = QVBoxLayout(content)
        rows.setContentsMargins(4, 4, 4, 4)
        rows.setSpacing(6)
        for action in actions:
            button = QPushButton(f"{action.title}  —  {action.description}")
            button.setObjectName("advancedAction")
            button.setProperty("actionId", action.id)
            button.setToolTip(" ".join(action.args))
            button.setAccessibleName(action.title)
            button.clicked.connect(lambda _checked=False, item=action: self.requested.emit(item))
            rows.addWidget(button)
        rows.addStretch()
        scroll.setWidget(content)
        scroll.hide()
        toggle.toggled.connect(scroll.setVisible)
        toggle.toggled.connect(lambda checked: toggle.setArrowType(Qt.DownArrow if checked else Qt.RightArrow))
        layout.addWidget(scroll)


class ParameterDialog(QDialog):
    """Typed argument form; command tokens are never evaluated by a shell."""

    def __init__(self, action: ActionSpec, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.action = action
        self.setWindowTitle(action.title)
        self.setMinimumWidth(560)
        layout = QVBoxLayout(self)
        description = QLabel(action.description)
        description.setWordWrap(True)
        description.setObjectName("cardDescription")
        layout.addWidget(description)
        form = QFormLayout()
        self._fields: dict[str, QWidget] = {}
        for parameter in action.parameters:
            if parameter.kind == "choice":
                field = QComboBox()
                field.addItems(parameter.choices)
            elif parameter.kind == "boolean":
                field = QCheckBox(parameter.label)
            else:
                field = QLineEdit()
                field.setPlaceholderText(parameter.placeholder)
                if parameter.kind in {"file", "path"}:
                    row = QWidget()
                    row_layout = QHBoxLayout(row)
                    row_layout.setContentsMargins(0, 0, 0, 0)
                    row_layout.addWidget(field, 1)
                    browse = QPushButton("Selecionar…")
                    browse.clicked.connect(
                        lambda _checked=False, item=parameter, target=field: self._browse(item.kind, target)
                    )
                    row_layout.addWidget(browse)
                    form.addRow(parameter.label + (":" if parameter.required else " (opcional):"), row)
                    self._fields[parameter.name] = field
                    continue
            field.setAccessibleName(parameter.label)
            form.addRow(parameter.label + (":" if parameter.required else " (opcional):"), field)
            self._fields[parameter.name] = field
        layout.addLayout(form)
        self.error = QLabel("")
        self.error.setObjectName("errorTitle")
        layout.addWidget(self.error)
        buttons = QDialogButtonBox(QDialogButtonBox.Cancel | QDialogButtonBox.Ok)
        buttons.button(QDialogButtonBox.Ok).setText("Continuar")
        buttons.accepted.connect(self._validate)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _browse(self, kind: str, target: QLineEdit) -> None:
        if kind == "file":
            value, _ = QFileDialog.getOpenFileName(self, "Selecionar arquivo")
        else:
            value = QFileDialog.getExistingDirectory(self, "Selecionar pasta")
        if value:
            target.setText(value)

    def _validate(self) -> None:
        values = self.values()
        missing = [parameter.label for parameter in self.action.parameters if parameter.required and not values.get(parameter.name)]
        if missing:
            self.error.setText("Preencha: " + ", ".join(missing))
            return
        self.accept()

    def values(self) -> dict[str, str]:
        values: dict[str, str] = {}
        for name, field in self._fields.items():
            if isinstance(field, QComboBox):
                values[name] = field.currentText()
            elif isinstance(field, QCheckBox):
                values[name] = "true" if field.isChecked() else ""
            elif isinstance(field, QLineEdit):
                values[name] = field.text().strip()
        return values


class SkeletonTile(QFrame):
    """Gray pulsing block that mimics a layout element during loading."""

    def __init__(self, width: int, height: int, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("skeletonTile")
        self.setFixedSize(width, height)


def start_shimmer(widget: QWidget) -> None:
    """Start a shimmer opacity loop on a skeleton widget."""
    existing = getattr(widget, "_phasezero_shimmer", None)
    if existing is not None:
        return
    effect = QGraphicsOpacityEffect(widget)
    widget.setGraphicsEffect(effect)
    anim = QPropertyAnimation(effect, b"opacity", widget)
    anim.setDuration(1200)
    anim.setStartValue(0.4)
    anim.setKeyValueAt(0.5, 1.0)
    anim.setEndValue(0.4)
    anim.setEasingCurve(QEasingCurve.InOutSine)
    anim.setLoopCount(-1)
    widget.setProperty("shimmer", "true")
    widget.style().unpolish(widget)
    widget.style().polish(widget)
    anim.start()
    widget._phasezero_shimmer = anim  # type: ignore[attr-defined]


def stop_shimmer(widget: QWidget) -> None:
    """Stop shimmer on a widget and reset its appearance."""
    anim = getattr(widget, "_phasezero_shimmer", None)
    if anim is not None:
        anim.stop()
        anim.deleteLater()
        widget._phasezero_shimmer = None  # type: ignore[attr-defined]
    widget.setProperty("shimmer", "")
    widget.style().unpolish(widget)
    widget.style().polish(widget)


class SkeletonCard(QFrame):
    """Mimics an ActionCard: icon tile + title + description + button placeholder."""

    def __init__(self, *, hero: bool = False, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("skeletonCard")
        self.setProperty("hero", hero)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(18, 16, 18, 16)
        outer.setSpacing(9)
        heading = QHBoxLayout()
        heading.setSpacing(12)
        heading.addWidget(SkeletonTile(46, 46))
        title_col = QVBoxLayout()
        title_col.setSpacing(4)
        title_col.addWidget(SkeletonTile(160, 14))
        title_col.addWidget(SkeletonTile(100, 10))
        heading.addLayout(title_col, 1)
        outer.addLayout(heading)
        outer.addWidget(SkeletonTile(220, 12))
        outer.addWidget(SkeletonTile(120, 32))

    def showEvent(self, event) -> None:
        super().showEvent(event)
        for tile in self.findChildren(SkeletonTile):
            start_shimmer(tile)

    def hideEvent(self, event) -> None:
        for tile in self.findChildren(SkeletonTile):
            stop_shimmer(tile)
        super().hideEvent(event)


class SkeletonPill(QFrame):
    """Mimics a StatusPill: dot + label + detail placeholders."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("skeletonPill")
        layout = QHBoxLayout(self)
        layout.setContentsMargins(12, 7, 12, 7)
        layout.addWidget(SkeletonTile(8, 8))   # dot
        layout.addWidget(SkeletonTile(140, 14))  # label
        layout.addStretch()
        layout.addWidget(SkeletonTile(80, 10))   # detail

    def showEvent(self, event) -> None:
        super().showEvent(event)
        for tile in self.findChildren(SkeletonTile):
            start_shimmer(tile)

    def hideEvent(self, event) -> None:
        for tile in self.findChildren(SkeletonTile):
            stop_shimmer(tile)
        super().hideEvent(event)


class Toast(QFrame):
    """Auto-dismissing toast in the top-right of its parent."""

    def __init__(self, parent: QWidget, message: str, state: str = "success") -> None:
        super().__init__(parent)
        self.setObjectName("toast")
        self.setProperty("state", state)
        self.setAttribute(Qt.WA_StyledBackground, True)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(14, 10, 14, 10)
        icon = QLabel({"success": "✓", "error": "✕", "warning": "!"}.get(state, "ℹ"))
        icon.setObjectName("toastIcon")
        icon.setProperty("state", state)
        text = QLabel(message)
        text.setObjectName("toastText")
        text.setWordWrap(True)
        layout.addWidget(icon)
        layout.addWidget(text, 1)
        self._effect = QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(self._effect)
        self._anim = QPropertyAnimation(self._effect, b"opacity", self)

    def popup(self, msecs: int = 3200) -> None:
        self.adjustSize()
        parent = self.parentWidget()
        if parent is not None:
            self.move(parent.width() - self.width() - 26, 20)
        self.show()
        self.raise_()
        self._effect.setOpacity(0.0)
        self._anim.stop()
        self._anim.setDuration(220)
        self._anim.setStartValue(0.0)
        self._anim.setEndValue(1.0)
        self._anim.setEasingCurve(QEasingCurve.OutCubic)
        self._anim.start()
        QTimer.singleShot(msecs, self._fade_out)

    def _fade_out(self) -> None:
        self._anim.stop()
        self._anim.setDuration(320)
        self._anim.setStartValue(1.0)
        self._anim.setEndValue(0.0)
        self._anim.setEasingCurve(QEasingCurve.InCubic)
        self._anim.finished.connect(self.deleteLater)
        self._anim.start()


STATE_ICONS = {"success": "✓", "warning": "⚠", "error": "✕", "info": "ℹ", "running": "◐"}


def sanitized_command(command: list[str]) -> str:
    output: list[str] = []
    redact_next = False
    for token in command:
        if redact_next:
            output.append("[REDACTED]")
            redact_next = False
            continue
        output.append(token)
        redact_next = bool(re.search(r"(?i)(token|secret|password|api[_-]?key)$", token.lstrip("-")))
    return shlex.join(output)


class StatefulDialog(QDialog):
    """Accessible dialog foundation with semantic state header and action footer."""

    def __init__(self, title: str, state: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("statefulDialog")
        self.setProperty("state", state)
        self.setWindowTitle(title)
        self.setMinimumSize(760, 540)
        outer = QVBoxLayout(self)
        header = QHBoxLayout()
        icon = QLabel(STATE_ICONS.get(state, "ℹ"))
        icon.setObjectName("dialogStateIcon")
        icon.setProperty("state", state)
        icon.setAccessibleName(f"Estado: {state}")
        heading = QLabel(title)
        heading.setObjectName("dialogTitle")
        header.addWidget(icon)
        header.addWidget(heading, 1)
        outer.addLayout(header)
        self.body = QVBoxLayout()
        outer.addLayout(self.body, 1)
        self.footer = QDialogButtonBox()
        outer.addWidget(self.footer)

    def add_action(
        self,
        label: str,
        role: QDialogButtonBox.ButtonRole,
        *,
        variant: str = "",
        enabled: bool = True,
    ) -> QPushButton:
        button = self.footer.addButton(label, role)
        if variant:
            button.setObjectName(variant)
        button.setEnabled(enabled)
        return button


class PreviewDialog(StatefulDialog):
    def __init__(
        self,
        result: OperationResult,
        action: ActionSpec | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__("Confirmar operação", "success" if result.ok else "error", parent)
        self.action = action
        summary = QLabel("Preview concluído. Nenhuma mutação foi executada.")
        summary.setWordWrap(True)
        summary.setObjectName("cardDescription")
        self.body.addWidget(summary)
        chips = QHBoxLayout()
        chips.addWidget(StatusPill("Preview", "success" if result.ok else "error"))
        chips.addWidget(StatusPill("Admin", "warning" if action and action.elevated else "info", "necessário" if action and action.elevated else "não"))
        chips.addStretch()
        self.body.addLayout(chips)
        command = QLineEdit(sanitized_command(result.command))
        command.setObjectName("commandBar")
        command.setReadOnly(True)
        command.setAccessibleName("Comando sanitizado")
        self.body.addWidget(command)
        self.output = QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.setObjectName("logView")
        self.output.setPlainText(result.stdout + ("\n[stderr]\n" + result.stderr if result.stderr else ""))
        self.body.addWidget(self.output, 1)
        copy = self.add_action("Copiar saída", QDialogButtonBox.ActionRole)
        copy.clicked.connect(lambda: QApplication.clipboard().setText(self.output.toPlainText()))
        cancel = self.add_action("Voltar", QDialogButtonBox.RejectRole)
        self.confirm = self.add_action(
            "Confirmar e aplicar",
            QDialogButtonBox.AcceptRole,
            variant="dangerButton" if action and action.risk == "high" else "primaryButton",
            enabled=result.ok and not (action and action.risk == "high"),
        )
        if action and action.risk == "high":
            warning = QLabel("Alto risco: digite CONFIRMAR para liberar a execução.")
            warning.setObjectName("errorTitle")
            self.confirmation = QLineEdit()
            self.confirmation.setPlaceholderText("CONFIRMAR")
            self.confirmation.setAccessibleName("Confirmação de alto risco")
            self.confirmation.textChanged.connect(
                lambda text: self.confirm.setEnabled(result.ok and text.strip() == "CONFIRMAR")
            )
            self.body.insertWidget(1, warning)
            self.body.insertWidget(2, self.confirmation)
        cancel.clicked.connect(self.reject)
        self.confirm.clicked.connect(self.accept)


class ProgressDialog(StatefulDialog):
    cancel_requested = Signal()

    def __init__(self, title: str, command: str, parent: QWidget | None = None) -> None:
        super().__init__(title, "running", parent)
        self._started = time.monotonic()
        self._running = True
        self.command = QLineEdit(command)
        self.command.setObjectName("commandBar")
        self.command.setReadOnly(True)
        self.body.addWidget(self.command)
        self.elapsed = QLabel("Tempo: 00:00")
        self.elapsed.setObjectName("pathLabel")
        self.body.addWidget(self.elapsed)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.body.addWidget(self.progress)
        self.log = QPlainTextEdit()
        self.log.setObjectName("logView")
        self.log.setReadOnly(True)
        self.log.document().setMaximumBlockCount(300)
        self.body.addWidget(self.log, 1)
        cancel = self.add_action("Cancelar operação", QDialogButtonBox.RejectRole, variant="dangerButton")
        cancel.clicked.connect(self.cancel_requested.emit)
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._tick)
        self._timer.start(1000)

    def _tick(self) -> None:
        elapsed = int(time.monotonic() - self._started)
        self.elapsed.setText(f"Tempo: {elapsed // 60:02d}:{elapsed % 60:02d}")

    def append_output(self, text: str, error: bool = False) -> None:
        prefix = "[stderr] " if error else ""
        self.log.appendPlainText(prefix + text.rstrip())
        scrollbar = self.log.verticalScrollBar()
        scrollbar.setValue(scrollbar.maximum())

    def set_progress(self, value: int) -> None:
        self.progress.setRange(0, 100)
        self.progress.setValue(value)

    def finish(self) -> None:
        self._running = False
        self._timer.stop()
        self.accept()

    def reject(self) -> None:
        if self._running:
            self.cancel_requested.emit()
            return
        super().reject()


class ResultDialog(StatefulDialog):
    history_requested = Signal()

    def __init__(self, result: OperationResult, formatted: str, parent: QWidget | None = None) -> None:
        super().__init__("Operação concluída" if result.ok else "Operação falhou", "success" if result.ok else "error", parent)
        self.formatted = formatted
        path = QLabel(f"result.json: {result.result_path}")
        path.setObjectName("pathLabel")
        path.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.body.addWidget(path)
        output = QPlainTextEdit()
        output.setReadOnly(True)
        output.setObjectName("logView")
        output.setPlainText(formatted)
        self.body.addWidget(output, 1)
        copy = self.add_action("Copiar resultado", QDialogButtonBox.ActionRole)
        copy.clicked.connect(lambda: QApplication.clipboard().setText(formatted))
        if result.result_path is not None:
            open_folder = self.add_action("Abrir pasta", QDialogButtonBox.ActionRole)
            open_folder.clicked.connect(
                lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(result.result_path.parent)))
            )
        history = self.add_action("Ver histórico", QDialogButtonBox.ActionRole)
        history.clicked.connect(self.history_requested.emit)
        close = self.add_action("Fechar", QDialogButtonBox.AcceptRole, variant="primaryButton")
        close.clicked.connect(self.accept)
