#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
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
        replacements = {
            "#111820": "#eef3f5",
            "#18222b": "#f7fafb",
            "#273640": "#cbd8de",
            "#eef8fb": "#14242c",
            "#91a6b3": "#5c707a",
            "#0c1218": "#e2eaee",
            "#25323b": "#c4d1d7",
            "#627985": "#607681",
            "#aabcc6": "#40545e",
            "#effbff": "#10242d",
            "#17242d": "#d5e4e9",
            "#e8fbff": "#062f3a",
            "#16333c": "#bfeef4",
            "#607781": "#60737b",
            "#f4fbfd": "#10232c",
            "#31434e": "#afc1c9",
            "#e8f2f7": "#172932",
            "#172129": "#f8fbfc",
            "#1a2730": "#ffffff",
            "#1a252e": "#ffffff",
            "#2b3a45": "#c8d6dc",
            "#202e38": "#edf7f8",
            "#f0f8fb": "#152832",
            "#dceaf0": "#1a3039",
            "#25323d": "#dae5e9",
            "#344652": "#b5c7ce",
            "#30424e": "#cbdde3",
            "#151f27": "#f6f9fa",
            "#293943": "#c6d5db",
            "#d8e6eb": "#20343d",
            "#091016": "#f8fbfc",
            "#c9e4ec": "#18313b",
        }
        for old, new in replacements.items():
            text = text.replace(old, new)
    return text


def apply_theme(app: QApplication, theme: str) -> None:
    app.setStyle("Fusion")
    app.setStyleSheet(stylesheet(theme))
    palette = QPalette()
    if theme == "dark":
        palette.setColor(QPalette.Window, QColor("#111820"))
        palette.setColor(QPalette.WindowText, QColor("#e8f2f7"))
        palette.setColor(QPalette.Base, QColor("#0c1218"))
        palette.setColor(QPalette.Text, QColor("#e8f2f7"))
        palette.setColor(QPalette.Button, QColor("#202c36"))
        palette.setColor(QPalette.ButtonText, QColor("#e8f2f7"))
        palette.setColor(QPalette.Highlight, QColor("#00bcd4"))
        palette.setColor(QPalette.HighlightedText, QColor("#071116"))
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
