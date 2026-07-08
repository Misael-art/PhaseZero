#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QColor, QPalette
from PySide6.QtWidgets import QApplication

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from linux.ui_native.boot_selector import BootSelectorWindow
    from linux.ui_native.main_window import MainWindow
else:
    from .boot_selector import BootSelectorWindow
    from .main_window import MainWindow


ROOT = Path(__file__).resolve().parents[2]
STYLE = Path(__file__).with_name("theme.qss")


def stylesheet(theme: str) -> str:
    text = STYLE.read_text()
    text = text.replace("@THEME@", theme)
    if theme == "light":
        # Map the EmuDeck dark palette onto a light one. #7c4dff (accent) and pure
        # #ffffff (text on accent) are intentionally kept so buttons stay legible.
        replacements = {
            # backgrounds / surfaces
            "#1e1e2e": "#f1f1f6",
            "#232336": "#ffffff",
            "#191926": "#e8e8f0",
            "#2a2a3c": "#ffffff",
            "#252536": "#ffffff",
            "#15151f": "#f6f6fa",
            "#2d2747": "#ece7fb",
            "#33334a": "#e0e0ea",
            "#32324a": "#eeeef6",
            "#262636": "#f4f4f8",
            "#22222f": "#eeeef4",
            # borders
            "#34344a": "#d5d5e0",
            "#2e2e44": "#d8d8e2",
            "#2b2b40": "#d8d8e2",
            "#3a3a4c": "#d0d0dc",
            "#45455c": "#c6c6d4",
            "#4a4a60": "#c6c6d4",
            "#4a3d7a": "#c9bdf0",
            # text
            "#f4f4fa": "#1a1a24",
            "#f5f5fa": "#1a1a24",
            "#f2f2f7": "#1c1c26",
            "#e8e8f0": "#20202c",
            "#dcdce6": "#24242e",
            "#cfcfe0": "#2a2a36",
            "#b7b7c8": "#3a3a48",
            "#a0a0b0": "#5a5a68",
            "#8a8aa0": "#6a6a78",
            "#6a6a82": "#8a8a98",
        }
        # Single-pass substitution: a replacement's output must never be re-mapped
        # by a later rule (e.g. sidebar bg #191926 -> #e8e8f0 must not then be
        # re-darkened by the #e8e8f0 text rule).
        pattern = re.compile("|".join(re.escape(key) for key in replacements))
        text = pattern.sub(lambda match: replacements[match.group(0)], text)
    return text


def apply_theme(app: QApplication, theme: str) -> None:
    app.setStyle("Fusion")
    app.setStyleSheet(stylesheet(theme))
    palette = QPalette()
    if theme == "dark":
        palette.setColor(QPalette.Window, QColor("#1e1e2e"))
        palette.setColor(QPalette.WindowText, QColor("#f2f2f7"))
        palette.setColor(QPalette.Base, QColor("#191926"))
        palette.setColor(QPalette.Text, QColor("#f2f2f7"))
        palette.setColor(QPalette.Button, QColor("#3a3a4c"))
        palette.setColor(QPalette.ButtonText, QColor("#f2f2f7"))
        palette.setColor(QPalette.Highlight, QColor("#7c4dff"))
        palette.setColor(QPalette.HighlightedText, QColor("#ffffff"))
    app.setPalette(palette)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="PhaseZero Central de Controle")
    parser.add_argument("--category", default="")
    parser.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--screenshot", default="")
    parser.add_argument("--light", action="store_true")
    parser.add_argument("--boot-selector", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)
    app.setApplicationName("PhaseZero")
    app.setOrganizationName("PhaseZero")
    app.setDesktopFileName("io.phasezero.ControlCenter")
    app.setQuitOnLastWindowClosed(True)
    apply_theme(app, "light" if args.light else "dark")
    if args.boot_selector:
        window = BootSelectorWindow(ROOT, smoke_test=args.smoke_test)
    else:
        window = MainWindow(ROOT, initial_category=args.category)
        window.theme_changed.connect(lambda theme: apply_theme(app, theme))
    window.show()
    if args.smoke_test:
        def finish() -> None:
            if args.screenshot:
                target = Path(args.screenshot).expanduser().resolve()
                target.parent.mkdir(parents=True, exist_ok=True)
                window.grab().save(str(target))
            window.close()
            app.quit()

        QTimer.singleShot(900, finish)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
