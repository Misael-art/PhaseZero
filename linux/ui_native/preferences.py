from __future__ import annotations

import os

from PySide6.QtCore import QObject, QSettings, Signal


class UiPreferences(QObject):
    """Persistent presentation preferences for progressive disclosure."""

    advanced_mode_changed = Signal(bool)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._settings = QSettings("PhaseZero", "ControlCenter")

    @property
    def advanced_mode(self) -> bool:
        override = os.environ.get("PZ_UI_ADVANCED_MODE", "").strip().casefold()
        if override:
            return override in {"1", "true", "yes", "on"}
        return self._settings.value("interface/advancedMode", False, type=bool)

    def set_advanced_mode(self, enabled: bool) -> None:
        enabled = bool(enabled)
        if enabled == self.advanced_mode:
            return
        self._settings.setValue("interface/advancedMode", enabled)
        self._settings.sync()
        self.advanced_mode_changed.emit(enabled)
