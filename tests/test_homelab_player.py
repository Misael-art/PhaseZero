from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from PySide6.QtWidgets import QApplication
from PySide6.QtTest import QTest


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


def _payload() -> dict:
    return {
        "schemaVersion": "1",
        "tool": "homelab-status",
        "profile": "media",
        "ready": False,
        "degraded": True,
        "accessMode": {"requested": "local", "effective": "local"},
        "resourceBudget": {
            "budgetMB": 3072, "availableMB": 8192, "verdict": "pass",
        },
        "stack": {
            "apps": [
                {
                    "key": "jellyfin", "layer": "core", "bind": "127.0.0.1",
                    "url": "http://127.0.0.1:8096", "running": False,
                },
                {
                    "key": "vaultwarden", "layer": "core", "bind": "127.0.0.1",
                    "url": "http://127.0.0.1:8222", "running": True,
                },
            ]
        },
    }


def _page() -> "object":
    from linux.ui_native.pages.homelab import HomelabPage

    page = HomelabPage(ROOT, None, [], by_id={})
    page.build()
    return page


def test_homelab_page_registered(app):
    from linux.ui_native.pages.registry import PageRegistry
    from linux.ui_native.command_runner import CommandRunner

    reg = PageRegistry(ROOT, CommandRunner(ROOT))
    assert "Homelab" in reg._pages
    assert "Homelab" in {r[0] for r in reg.cat_meta.values()}


def test_homelab_page_builds_widgets(app):
    page = _page()
    assert page._table.columnCount() == 5
    assert page._profile_combo is not None
    assert page._output is not None


def test_homelab_page_applies_status(app):
    page = _page()
    page._apply_status(json.dumps(_payload()).encode())
    assert page._table.rowCount() == 2
    assert page._budget_label.text() == "3072 / 8192 MiB [pass]"
    assert page._state_label.text().startswith("não pronto")
    assert page._table.item(1, 4).text() == "sim"
    assert page._table.item(0, 4).text() == "não"


def test_homelab_page_run_cmd_guard_blocks_running(app):
    page = _page()
    started = []

    class BusyProc:  # noqa: N801
        def state(self):
            return 1  # Running != NotRunning(0)

    class FakeQProcess:  # noqa: N801
        MergedChannels = 0
        NotRunning = 0

        def __init__(self, parent):
            started.append(1)

        def setProcessChannelMode(self, *a):
            pass

        def start(self, *a):
            started.append("start")

    import linux.ui_native.pages.homelab as mod

    real_qprocess = mod.QProcess
    page._proc = BusyProc()
    mod.QProcess = FakeQProcess
    try:
        page.run_cmd(["plan"])
    finally:
        mod.QProcess = real_qprocess
    assert started == []  # no new process while one is running


def test_homelab_page_run_cmd_spawns_process(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    calls = []

    class FakeSignal:  # noqa: N801
        def __init__(self, calls):
            self.calls = calls

        def connect(self, slot):
            self.calls.append(("connect", slot))

    class FakeQProcess:  # noqa: N801
        MergedChannels = 0

        def __init__(self, parent):
            self.parent = parent
            self.readyReadStandardOutput = FakeSignal(calls)
            self.finished = FakeSignal(calls)

        def setProcessChannelMode(self, *a):
            calls.append(("mode", a))

        def start(self, program, args):
            calls.append(("start", program, list(args)))

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    try:
        page.run_cmd([  "profile", "set", "core"])
    finally:
        mod.QProcess = real_qprocess
    assert calls[0] == ("mode", (0,))
    assert calls[-1][1].endswith("linux/pz")
    assert calls[-1][2] == ["server", "homelab", "profile", "set", "core"]
    assert calls[2] == ("connect", calls[2][1])  # finished signal wired


def test_homelab_page_modal_free_profile_empty(app):
    # Empty combo must warn instead of spawning a process.
    page = _page()
    warned = []

    import linux.ui_native.pages.homelab as mod

    class Fake:  # noqa: N801
        def addItem(self, *a):
            pass

        def findData(self, *a):
            return -1

        def currentData(self):
            return None

    page._profile_combo = Fake()

    class FakeBox:  # noqa: N801
        @staticmethod
        def warning(*a, **k):
            warned.append(1)

    real = mod.QMessageBox
    mod.QMessageBox = FakeBox
    try:
        page.apply_profile()
    finally:
        mod.QMessageBox = real
    assert warned == [1]