from __future__ import annotations

from PySide6.QtCore import QEvent, QPoint, Qt, Signal
from PySide6.QtGui import QColor, QIcon, QMouseEvent
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFrame,
    QGraphicsDropShadowEffect,
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
            # startSystemMove works on Wayland, where manual move() is ignored.
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


class ActionCard(QFrame):
    requested = Signal(object)

    def __init__(self, action: ActionSpec, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.action = action
        self.setObjectName("actionCard")
        self.setProperty("mutable", action.mutable)
        self.setMinimumSize(270, 172)
        self.setMaximumHeight(196)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setFocusPolicy(Qt.StrongFocus)
        self.installEventFilter(self)
        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(22)
        shadow.setOffset(0, 5)
        shadow.setColor(QColor(0, 0, 0, 80))
        self.setGraphicsEffect(shadow)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(18, 16, 18, 16)
        outer.setSpacing(9)
        heading = QHBoxLayout()
        icon = QLabel()
        icon.setPixmap(themed_icon(self, action.icon, QStyle.SP_ComputerIcon).pixmap(30, 30))
        icon.setFixedSize(38, 38)
        icon.setObjectName("cardIcon")
        heading.addWidget(icon)
        heading.addStretch()
        if action.badge:
            badge = QLabel(action.badge)
            badge.setObjectName("badge")
            heading.addWidget(badge)
        outer.addLayout(heading)
        title = QLabel(action.title)
        title.setObjectName("cardTitle")
        outer.addWidget(title)
        description = QLabel(action.description)
        description.setObjectName("cardDescription")
        description.setWordWrap(True)
        description.setMinimumHeight(38)
        outer.addWidget(description)
        outer.addStretch()
        button = QPushButton("Pré-visualizar" if action.mutable else "Executar")
        button.setObjectName("primaryButton" if action.mutable else "secondaryButton")
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


class PreviewDialog(QDialog):
    def __init__(self, result: OperationResult, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Confirmar operação")
        self.setMinimumSize(720, 520)
        layout = QVBoxLayout(self)
        title = QLabel("Preview concluído")
        title.setObjectName("dialogTitle")
        summary = QLabel(
            "Nenhuma mutação executada. Revise saída abaixo. Confirmação executará comando real."
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
