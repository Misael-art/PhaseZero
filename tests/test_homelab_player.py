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
        "profile": "assistant-private",
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


class BusyProc:  # noqa: N801
    """A fake process that reports Running, blocking every spawn."""
    def state(self):
        return 1  # Running != NotRunning(0)


def _page() -> "object":
    from linux.ui_native.pages.homelab import HomelabPage

    page = HomelabPage(ROOT, None, [], by_id={})
    page.build()
    page._proc = BusyProc()
    return page


class FakeSignal:  # noqa: N801
    def __init__(self, calls):
        self.calls = calls

    def connect(self, slot):
        self.calls.append(("connect", slot))


class FakeQProcess:  # noqa: N801
    """Records QProcess usage without ever starting a real binary."""
    MergedChannels = 0
    SeparateChannels = 1
    NotRunning = 0
    Running = 1
    FailedToStart = 1

    _calls: list = []

    def __init__(self, parent=None):
        self.parent = parent
        self.readyReadStandardOutput = FakeSignal(self._calls)
        self.readyReadStandardError = FakeSignal(self._calls)
        self.finished = FakeSignal(self._calls)
        self.errorOccurred = FakeSignal(self._calls)
        self._state = 0

    def setProcessChannelMode(self, *a):
        self._calls.append(("mode", a))

    def state(self):
        return self._state

    def start(self, program, args):
        self._calls.append(("start", program, list(args)))

    def kill(self):
        self._calls.append(("kill",))
        self._state = 0

    def readAllStandardOutput(self):
        return b""

    def readAllStandardError(self):
        return b""


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

    import linux.ui_native.pages.homelab as mod

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    try:
        page._proc = BusyProc()
        FakeQProcess._calls = started
        page.run_cmd(["plan"])
    finally:
        mod.QProcess = real_qprocess
    assert started == []  # no new process while one is running


def test_homelab_page_run_cmd_spawns_process(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.run_cmd(["profile", "set", "core"])
    finally:
        mod.QProcess = real_qprocess
    assert calls[0] == ("mode", (1,))  # SeparateChannels
    assert calls[-1][1].endswith("linux/pz")
    assert calls[-1][2] == ["server", "homelab", "profile", "set", "core"]
    # finished, error and both read channels are wired
    assert any(c[0] == "connect" for c in calls)


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


def test_homelab_page_pick_restore_never_passes_yes(app):
    # The Player must never append --yes: restore goes through --plan and the
    # CLI requires its own confirmation before applying.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page._last_status = {
        "backupState": {"lastBackup": {"latest": "/tmp/fake-backup"}},
    }
    calls = []

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None

    class FakeQMessageBox:  # noqa: N801
        Yes = 1
        No = 2

        @staticmethod
        def question(*a, **k):
            return 1

        @staticmethod
        def information(*a, **k):
            pass

        @staticmethod
        def warning(*a, **k):
            pass

    real_box = mod.QMessageBox
    mod.QMessageBox = FakeQMessageBox
    try:
        page.pick_restore()
    finally:
        mod.QMessageBox = real_box
        mod.QProcess = real_qprocess
    assert calls
    assert "--yes" not in calls[-1][2]
    assert "--plan" in calls[-1][2]


def test_homelab_page_never_spawns_resume_flag(app):
    # CCS-004: the stack never parsed `up --resume`; the Player must not send a
    # flag the CLI rejects. Plain `up` is already idempotent/convergent.
    import inspect

    from PySide6.QtWidgets import QPushButton

    import linux.ui_native.pages.homelab as mod

    src = inspect.getsource(mod)
    assert "--resume" not in src, "Player ainda envia up --resume (flag inexistente)"
    page = _page()
    resume_buttons = [b for b in page.findChildren(QPushButton) if b.text() == "Resume"]
    assert resume_buttons == []
    up_buttons = [b for b in page.findChildren(QPushButton) if b.text() == "Up"]
    assert up_buttons, "ação Up convergente deve existir no Player"


def test_homelab_restore_catalog_action_is_plan_only(by_id_catalog):
    action = by_id_catalog["homelab.restore"]
    joined = " ".join(action.args)
    assert "--yes" not in joined, "catálogo não pode disparar restore com --yes"
    assert "--plan" in action.args
    assert not action.mutable, "restore --plan é leitura; mutável só na CLI com --yes"


@pytest.fixture(scope="module")
def by_id_catalog(app):
    from pathlib import Path as _Path

    from linux.ui_native.catalog import build_catalog

    return {a.id: a for a in build_catalog(_Path(ROOT))}


def test_homelab_page_restore_without_backup_warns(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page._last_status = {}
    warned = []

    class FakeBox:  # noqa: N801
        @staticmethod
        def warning(*a, **k):
            warned.append(1)

    real = mod.QMessageBox
    mod.QMessageBox = FakeBox
    try:
        page.pick_restore()
    finally:
        mod.QMessageBox = real
    assert warned == [1]


def test_homelab_page_show_policy_uses_qprocess_not_subprocess(app):
    import inspect

    import linux.ui_native.pages.homelab as mod

    src = inspect.getsource(mod)
    assert "import subprocess" not in src
    assert "subprocess.run" not in src
    assert "QFileDialog" not in src


def test_homelab_page_timeout_kills(app):
    page = _page()
    calls = []
    import linux.ui_native.pages.homelab as mod

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.run_cmd(["plan"])
    finally:
        mod.QProcess = real_qprocess
    # Simulate the timeout firing for the spawned proc while it is running.
    proc = page._proc
    proc._state = FakeQProcess.Running
    page._kill_timed_out(proc)
    assert any(c[0] == "kill" for c in calls)
    assert page._proc is None


def test_homelab_page_cancel_timeout_on_finish(app):
    page = _page()
    calls = []
    import linux.ui_native.pages.homelab as mod

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.run_cmd(["plan"])
        proc = page._proc
        page._cancel_timeout(proc)
    finally:
        mod.QProcess = real_qprocess
    assert id(proc) not in page._timeouts


def test_homelab_page_refresh_profiles_uses_roadmap_contract(app):
    # The CLI contract is `pz server homelab profiles --json`; the page must
    # spawn exactly that, not the legacy singular `profile list`.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.refresh_profiles()
    finally:
        mod.QProcess = real_qprocess
    assert calls[-1][1].endswith("linux/pz")
    assert calls[-1][2] == ["server", "homelab", "profiles", "--json"]


def test_homelab_page_no_blocking_event_loop(app):
    # Operations are spawned, never run synchronously: with a fake process the
    # call returns immediately and the GUI can keep processing events.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    calls = []

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.run_cmd(["plan"])
        QTest.qWait(0)
        assert calls[-1][0] == "start"
    finally:
        mod.QProcess = real_qprocess
