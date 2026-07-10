from __future__ import annotations

from PySide6.QtCore import (
    QEasingCurve,
    QEvent,
    QPoint,
    QPropertyAnimation,
    Qt,
    QTimer,
    Signal,
)
from PySide6.QtGui import QColor, QIcon, QMouseEvent
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFrame,
    QGraphicsDropShadowEffect,
    QGraphicsOpacityEffect,
    QHBoxLayout,
    QLabel,
    QPlainTextEdit,
    QPushButton,
    QSizePolicy,
    QStyle,
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


class SkeletonTile(QFrame):
    """Gray pulsing block that mimics a layout element during loading."""

    def __init__(self, width: int, height: int, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("skeletonTile")
        self.setFixedSize(width, height)


_SHIMMER_ANIMATIONS: dict[int, QPropertyAnimation] = {}


def start_shimmer(widget: QWidget) -> None:
    """Start a shimmer opacity loop on a skeleton widget."""
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
    _SHIMMER_ANIMATIONS[id(widget)] = anim


def stop_shimmer(widget: QWidget) -> None:
    """Stop shimmer on a widget and reset its appearance."""
    anim = _SHIMMER_ANIMATIONS.pop(id(widget), None)
    if anim is not None:
        anim.stop()
        anim.deleteLater()
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


class PreviewDialog(QDialog):
    def __init__(self, result: OperationResult, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Confirmar operação")
        self.setMinimumSize(720, 520)
        layout = QVBoxLayout(self)
        title = QLabel("Preview concluído")
        title.setObjectName("dialogTitle")
        summary = QLabel(
            "Nenhuma mutação executada. Revise a saída abaixo. Confirmar executará o comando real."
        )
        summary.setWordWrap(True)
        summary.setObjectName("cardDescription")
        output = QPlainTextEdit()
        output.setReadOnly(True)
        output.setObjectName("logView")
        output.setPlainText(result.stdout + ("\n[stderr]\n" + result.stderr if result.stderr else ""))
        buttons = QDialogButtonBox()
        cancel = buttons.addButton("Voltar", QDialogButtonBox.RejectRole)
        confirm = buttons.addButton("Confirmar e aplicar", QDialogButtonBox.AcceptRole)
        confirm.setObjectName("dangerButton")
        confirm.setEnabled(result.ok)
        cancel.clicked.connect(self.reject)
        confirm.clicked.connect(self.accept)
        layout.addWidget(title)
        layout.addWidget(summary)
        layout.addWidget(output, 1)
        layout.addWidget(buttons)


class ResultDialog(QDialog):
    def __init__(self, result: OperationResult, formatted: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Resultado")
        self.setMinimumSize(720, 520)
        layout = QVBoxLayout(self)
        title = QLabel("Operação concluída" if result.ok else "Operação falhou")
        title.setObjectName("successTitle" if result.ok else "errorTitle")
        path = QLabel(f"result.json: {result.result_path}")
        path.setObjectName("pathLabel")
        path.setTextInteractionFlags(Qt.TextSelectableByMouse)
        output = QPlainTextEdit()
        output.setReadOnly(True)
        output.setObjectName("logView")
        output.setPlainText(formatted)
        close = QPushButton("Fechar")
        close.clicked.connect(self.accept)
        layout.addWidget(title)
        layout.addWidget(path)
        layout.addWidget(output, 1)
        layout.addWidget(close)
