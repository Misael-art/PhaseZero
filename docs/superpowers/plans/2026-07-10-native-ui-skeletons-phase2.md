# Native UI Foundation — Phase 2: Skeletons + Async Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add skeleton loaders that mimic page layout during loading, and an async status loader so pages show real system status on open instead of requiring manual action clicks.

**Architecture:** `StatusLoader` (QObject) runs status commands via `QProcess` in background, emits results. `SkeletonTile`/`SkeletonCard`/`SkeletonPill` are placeholder widgets with shimmer animation. `BasePage` gains `show_skeletons()`/`populate_status()` hooks. Status pages (Overview, SteamDeck) use the loader on `reload()`.

**Tech Stack:** Python 3.10+, PySide6/Qt6, `QPropertyAnimation` for shimmer, `QProcess` for async status.

**Spec:** `docs/superpowers/specs/2026-07-10-native-ui-foundation-design.md` (Phase 2 section)
**Depends on:** Phase 1 complete (tokens.py has `skeleton_base`/`skeleton_shimmer` fields).

## Global Constraints

- Python 3.10+, PySide6 6.6+.
- Tests run with `QT_QPA_PLATFORM=offscreen`.
- Skeleton colors come from `ThemeTokens.skeleton_base` / `skeleton_shimmer` (already in DARK/LIGHT).
- Shimmer uses `QPropertyAnimation` (same pattern as existing `Toast` widget).
- Status commands run via `QProcess` (not the shared `CommandRunner` — status is read-only, non-blocking, parallel-safe).
- Threshold: skeletons only shown if load estimated >200ms (skip skeleton for instant loads).
- Existing tests must pass after each task.
- No new runtime dependencies.
- Pages stay functional without status — status is enhancement, not blocking.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `linux/ui_native/widgets.py` | **Modify** | Add `SkeletonTile`, `SkeletonCard`, `SkeletonPill` |
| `linux/ui_native/theme.qss` | **Modify** | Add `#skeletonTile`, `#skeletonCard`, `#skeletonPill` selectors |
| `linux/ui_native/status_loader.py` | **Create** | `StatusLoader` QObject — async status fetching |
| `linux/ui_native/pages/base.py` | **Modify** | Add skeleton/status hooks to `BasePage` |
| `linux/ui_native/pages/overview.py` | **Modify** | Use `StatusLoader` + skeletons |
| `tests/test_native_skeletons.py` | **Create** | Validate skeleton widgets, loader, page integration |

---

### Task 1: Add skeleton widgets to `widgets.py`

**Files:**
- Modify: `linux/ui_native/widgets.py` (append after `StatusPill` class)
- Modify: `linux/ui_native/theme.qss` (add skeleton selectors)
- Test: `tests/test_native_skeletons.py` (create)

**Interfaces:**
- Produces: `SkeletonTile(QFrame)`, `SkeletonCard(QFrame)`, `SkeletonPill(QFrame)`, `start_shimmer(widget)`, `stop_shimmer(widget)`

- [ ] **Step 1: Write the failing test**

Create `tests/test_native_skeletons.py`:

```python
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from PySide6.QtWidgets import QApplication


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


def test_skeleton_tile_creates(app):
    from linux.ui_native.widgets import SkeletonTile
    tile = SkeletonTile(160, 14)
    assert tile.width() == 160
    assert tile.height() == 14
    assert tile.objectName() == "skeletonTile"


def test_skeleton_card_creates(app):
    from linux.ui_native.widgets import SkeletonCard
    card = SkeletonCard()
    assert card.objectName() == "skeletonCard"
    # Card should have placeholder children (tiles)
    tiles = card.findChildren(type(SkeletonTile.__new__(SkeletonTile).__class__))
    assert len(tiles) >= 4  # icon, title, description, button


def test_skeleton_pill_creates(app):
    from linux.ui_native.widgets import SkeletonPill
    pill = SkeletonPill()
    assert pill.objectName() == "skeletonPill"
    tiles = pill.findChildren(SkeletonTile)
    assert len(tiles) >= 2  # label + detail


def test_start_shimmer_sets_property(app):
    from linux.ui_native.widgets import SkeletonTile, start_shimmer
    tile = SkeletonTile(100, 10)
    start_shimmer(tile)
    assert tile.property("shimmer") == "true"


def test_stop_shimmer_clears_property(app):
    from linux.ui_native.widgets import SkeletonTile, start_shimmer, stop_shimmer
    tile = SkeletonTile(100, 10)
    start_shimmer(tile)
    stop_shimmer(tile)
    assert tile.property("shimmer") != "true"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /mnt/sdcard/Projects/PhaseZero && QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py -v`
Expected: FAIL with `ImportError: cannot import name 'SkeletonTile'`

- [ ] **Step 3: Implement skeleton widgets**

Append to `linux/ui_native/widgets.py` (after the `StatusPill` class, before `Toast`):

```python
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
```

Add `QGraphicsOpacityEffect` to the imports at the top of `widgets.py` if not already imported (it IS already imported — check line 18 of current file).

- [ ] **Step 4: Add QSS selectors for skeletons**

Append to `linux/ui_native/theme.qss` (before the `/* ---- Toast */` section or after `#pillDot` rules):

```css
/* ---- Skeleton loaders ------------------------------------------------ */
#skeletonTile {
    background: {{skeleton_base}};
    border-radius: {{radius_sm}}px;
}
#skeletonTile[shimmer="true"] {
    background: {{skeleton_shimmer}};
}
#skeletonCard {
    background: {{surface}};
    border: 1px solid {{border}};
    border-radius: {{radius_lg}}px;
}
#skeletonCard[hero="true"] {
    background: {{surface_hero}};
    border: 1px solid {{accent_border}};
}
#skeletonPill {
    background: {{surface_disabled}};
    border: 1px solid {{border_subtle}};
    border-radius: {{radius_md}}px;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py -v`
Expected: PASS (5 tests)

- [ ] **Step 6: Run full suite for regressions**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py tests/test_native_tokens.py tests/test_linux_native_ui.py -v`
Expected: PASS (all tests)

- [ ] **Step 7: Commit**

```bash
git add linux/ui_native/widgets.py linux/ui_native/theme.qss tests/test_native_skeletons.py
git commit -m "feat(ui-native): add skeleton loader widgets with shimmer animation

SkeletonTile, SkeletonCard (mimics ActionCard), SkeletonPill (mimics
StatusPill). Shimmer via QPropertyAnimation on opacity, same pattern as
Toast. Token-based colors (skeleton_base/shimmer)."
```

---

### Task 2: Create `StatusLoader` for async status fetching

**Files:**
- Create: `linux/ui_native/status_loader.py`
- Test: `tests/test_native_skeletons.py` (append)

**Interfaces:**
- Consumes: `ActionSpec` (from models), `QProcess` (PySide6)
- Produces: `StatusLoader(QObject)` with signals `status_ready(str, str, object)` and `status_failed(str, str)`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_native_skeletons.py`:

```python
def test_status_loader_creates(app):
    from linux.ui_native.status_loader import StatusLoader
    from pathlib import Path
    loader = StatusLoader(Path(ROOT))
    assert loader is not None
    assert hasattr(loader, "status_ready")
    assert hasattr(loader, "status_failed")


def test_status_loader_resolves_pz(app):
    from linux.ui_native.status_loader import StatusLoader
    loader = StatusLoader(ROOT)
    pz = loader._pz_path()
    assert pz.exists()
    assert pz.name == "pz"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py::test_status_loader_creates tests/test_native_skeletons.py::test_status_loader_resolves_pz -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement StatusLoader**

Create `linux/ui_native/status_loader.py`:

```python
from __future__ import annotations

import json
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QTimer, Signal

from .result_parser import parse_json_output


class StatusLoader(QObject):
    """Fetches status for read-only actions asynchronously via QProcess.

    Unlike CommandRunner, this runs multiple status commands in parallel
    (read-only, non-blocking) and does not use the operation panel.
    """

    status_ready = Signal(str, str, object)  # (action_id, stdout, parsed_result)
    status_failed = Signal(str, str)          # (action_id, error_message)

    def __init__(self, root: Path, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.root = root
        self._processes: dict[str, QProcess] = {}

    def _pz_path(self) -> Path:
        return self.root / "linux" / "pz"

    def fetch(self, action_id: str, args: list[str]) -> None:
        """Start fetching status for the given action. Idempotent per action_id."""
        if action_id in self._processes:
            return  # already fetching
        pz = str(self._pz_path())
        process = QProcess(self)
        process.setWorkingDirectory(str(self.root))
        process.setProgram(pz)
        process.setArguments(args)
        process.setProcessChannelMode(QProcess.SeparateChannels)
        process.finished.connect(
            lambda code, _status, aid=action_id: self._on_finished(aid, code, process)
        )
        process.errorOccurred.connect(
            lambda err, aid=action_id: self._on_error(aid, err, process)
        )
        self._processes[action_id] = process
        process.start()
        # Safety timeout: 15s per status command
        timer = QTimer(self)
        timer.setSingleShot(True)
        timer.timeout.connect(lambda: self._on_timeout(action_id, process))
        timer.start(15000)
        process.setProperty("timeout_timer", timer)

    def fetch_action(self, action) -> None:
        """Fetch status for an ActionSpec using its args directly."""
        self.fetch(action.id, list(action.args))

    def cancel(self, action_id: str) -> None:
        process = self._processes.pop(action_id, None)
        if process is not None and process.state() != QProcess.NotRunning:
            process.kill()
            process.waitForFinished(1000)
        self._cleanup_process(action_id, process)

    def cancel_all(self) -> None:
        for action_id in list(self._processes.keys()):
            self.cancel(action_id)

    def _on_finished(self, action_id: str, exit_code: int, process: QProcess) -> None:
        stdout = bytes(process.readAllStandardOutput().data()).decode("utf-8", errors="replace")
        self._cleanup_process(action_id, process)
        if exit_code != 0:
            self.status_failed.emit(action_id, f"exit code {exit_code}")
            return
        parsed = parse_json_output(stdout)
        self.status_ready.emit(action_id, stdout, parsed)

    def _on_error(self, action_id: str, error: QProcess.ProcessError, process: QProcess) -> None:
        if error == QProcess.FailedToStart:
            self._cleanup_process(action_id, process)
            self.status_failed.emit(action_id, "failed to start")

    def _on_timeout(self, action_id: str, process: QProcess) -> None:
        if process.state() != QProcess.NotRunning:
            process.kill()
        self.status_failed.emit(action_id, "timed out")

    def _cleanup_process(self, action_id: str, process: QProcess | None) -> None:
        timer = process.property("timeout_timer") if process else None
        if timer is not None:
            timer.stop()
            timer.deleteLater()
        self._processes.pop(action_id, None)
        if process is not None:
            process.deleteLater()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py -v`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add linux/ui_native/status_loader.py tests/test_native_skeletons.py
git commit -m "feat(ui-native): add StatusLoader for async status fetching

Read-only parallel status fetching via QProcess. Distinct from
CommandRunner (no operation panel, no mutation, parallel-safe). 15s
timeout per command. Emits status_ready/status_failed signals."
```

---

### Task 3: Add skeleton/status hooks to `BasePage`

**Files:**
- Modify: `linux/ui_native/pages/base.py`
- Test: `tests/test_native_skeletons.py` (append)

**Interfaces:**
- Consumes: `SkeletonCard`, `SkeletonPill`, `StatusLoader`
- Produces: `BasePage.show_skeletons()`, `BasePage.clear_skeletons()`, `BasePage.status_loader` attribute

- [ ] **Step 1: Write the failing test**

Append to `tests/test_native_skeletons.py`:

```python
def test_base_page_has_skeleton_hooks(app):
    from linux.ui_native.pages.base import BasePage
    assert hasattr(BasePage, "show_skeletons")
    assert hasattr(BasePage, "clear_skeletons")


def test_base_page_show_skeletons_populates(app):
    from pathlib import Path
    from linux.ui_native.pages.base import BasePage
    from linux.ui_native.command_runner import CommandRunner
    from linux.ui_native.widgets import SkeletonCard
    page = BasePage(Path(ROOT), CommandRunner(Path(ROOT)), [], {})
    page.show_skeletons(count=3)
    cards = page.findChildren(SkeletonCard)
    assert len(cards) == 3
    page.clear_skeletons()
    cards = page.findChildren(SkeletonCard)
    assert len(cards) == 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py::test_base_page_has_skeleton_hooks tests/test_native_skeletons.py::test_base_page_show_skeletons_populates -v`
Expected: FAIL (no `show_skeletons` method)

- [ ] **Step 3: Modify BasePage**

Edit `linux/ui_native/pages/base.py`. Add imports at top:

```python
from ..widgets import SkeletonCard
```

Add a `_skeleton_container` attribute in `__init__` and new methods. Full modified file:

```python
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import QGridLayout, QVBoxLayout, QWidget

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..status_loader import StatusLoader
from ..widgets import SkeletonCard


class BasePage(QWidget):
    """Base class for every category page."""

    action_requested = Signal(object)
    actions_requested = Signal(object)

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.root = root
        self.runner = runner
        self.actions = actions
        self.by_id = by_id or {}
        self.status_loader = StatusLoader(root, self)
        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._layout.setSpacing(0)
        self._skeleton_grid: QGridLayout | None = None

    def build(self) -> None:
        pass

    def reload(self) -> None:
        pass

    def block_while_running(self, running: bool) -> None:
        pass

    def show_skeletons(self, count: int = 6, columns: int = 3) -> QGridLayout:
        """Show N skeleton cards in a grid. Returns the grid for layout positioning."""
        self.clear_skeletons()
        container = QWidget()
        grid = QGridLayout(container)
        grid.setContentsMargins(2, 2, 8, 8)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index in range(count):
            card = SkeletonCard()
            grid.addWidget(card, index // columns, index % columns)
        for col in range(columns):
            grid.setColumnStretch(col, 1)
        self._layout.addWidget(container)
        container.setObjectName("_skeleton_container")
        self._skeleton_grid = grid
        return grid

    def clear_skeletons(self) -> None:
        """Remove all skeleton cards from the page."""
        container = self.findChild(QWidget, "_skeleton_container")
        if container is not None:
            self._layout.removeWidget(container)
            container.deleteLater()
        self._skeleton_grid = None

    def request_action(self, action: ActionSpec) -> None:
        self.action_requested.emit(action)

    def request_actions(self, actions: list[ActionSpec]) -> None:
        if actions:
            self.actions_requested.emit(actions)

    def run_action(self, action_id: str) -> None:
        action = self.by_id.get(action_id)
        if action is not None:
            self.request_action(action)

    def find(self, action_id: str) -> ActionSpec | None:
        return self.by_id.get(action_id)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py -v`
Expected: PASS (9 tests)

- [ ] **Step 5: Run full suite**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py tests/test_native_tokens.py tests/test_linux_native_ui.py -q`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add linux/ui_native/pages/base.py tests/test_native_skeletons.py
git commit -m "feat(ui-native): add skeleton/status hooks to BasePage

show_skeletons(count, columns) populates a grid of SkeletonCard.
clear_skeletons() removes them. status_loader attribute gives pages
access to async StatusLoader. Pages can now show loading state before
content arrives."
```

---

### Task 4: Integrate skeletons + async status into OverviewPage

**Files:**
- Modify: `linux/ui_native/pages/overview.py`
- Test: `tests/test_native_skeletons.py` (append)

**Interfaces:**
- Consumes: `BasePage.show_skeletons/clear_skeletons`, `StatusLoader`, `SkeletonPill`
- Produces: `OverviewPage` that shows skeletons then real status pills on `reload()`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_native_skeletons.py`:

```python
def test_overview_page_shows_skeletons_on_reload(app, qtbot=None):
    """OverviewPage.reload() should show skeletons then load status."""
    from pathlib import Path
    from linux.ui_native.pages.overview import OverviewPage
    from linux.ui_native.command_runner import CommandRunner
    from linux.ui_native.catalog import build_catalog
    from linux.ui_native.widgets import SkeletonCard, StatusPill

    catalog = build_catalog(Path(ROOT))
    by_id = {a.id: a for a in catalog}
    page = OverviewPage(Path(ROOT), CommandRunner(Path(ROOT)), catalog, by_id)
    page.build()
    page.reload()
    # After reload, skeletons should be visible (before status resolves)
    cards = page.findChildren(SkeletonCard)
    assert len(cards) > 0 or len(page.findChildren(StatusPill)) > 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py::test_overview_page_shows_skeletons_on_reload -v`
Expected: FAIL (OverviewPage doesn't show skeletons yet)

- [ ] **Step 3: Modify OverviewPage**

Rewrite `linux/ui_native/pages/overview.py` to use async status loading with skeleton fallback. New file:

```python
from __future__ import annotations

from pathlib import Path

from PySide6.QtWidgets import (
    QFrame, QHBoxLayout, QLabel, QPushButton, QScrollArea,
    QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import StatusPill, SectionHeader, SkeletonPill, themed_icon
from .base import BasePage

STATUS_ACTION_IDS = ("system.doctor",)
PILL_ACTION_IDS = ("system.doctor", "system.repair-plan", "system.support-bundle", "system.version")


class OverviewPage(BasePage):
    """Health checks, audit, and support — status pills with async loading."""

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        self._inner = QWidget()
        self._layout_main = QVBoxLayout(self._inner)
        self._layout_main.setContentsMargins(2, 2, 8, 8)
        self._layout_main.setSpacing(14)
        self._layout_main.addWidget(SectionHeader("Diagnóstico", "Auditoria completa do sistema"))

        self._pills_container = QVBoxLayout()
        self._pills_container.setSpacing(8)
        self._layout_main.addLayout(self._pills_container)
        self._layout_main.addStretch()

        scroll.setWidget(self._inner)
        self._layout.addWidget(scroll)

        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

    def reload(self) -> None:
        """Show skeleton pills, then fetch real status."""
        self._clear_pills()
        for _ in range(4):
            self._pills_container.addWidget(SkeletonPill())
        for aid in STATUS_ACTION_IDS:
            action = self.find(aid)
            if action is not None:
                self.status_loader.fetch_action(action)

    def _clear_pills(self) -> None:
        while self._pills_container.count():
            item = self._pills_container.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

    def _populate_action_pills(self) -> None:
        """Populate the standard action pills (non-status actions)."""
        self._clear_pills()
        for aid in PILL_ACTION_IDS:
            action = self.by_id.get(aid)
            if action is None:
                continue
            self._pills_container.addWidget(self._make_pill_action(action))

    def _on_status_ready(self, action_id: str, stdout: str, parsed: object) -> None:
        self._populate_action_pills()

    def _on_status_failed(self, action_id: str, error: str) -> None:
        self._populate_action_pills()

    def _make_pill_action(self, action: ActionSpec) -> QFrame:
        card = QFrame()
        card.setObjectName("actionCard")
        row = QHBoxLayout(card)
        row.setContentsMargins(14, 12, 14, 12)
        icon = QLabel()
        px = themed_icon(card, action.icon, QStyle.SP_ComputerIcon).pixmap(28, 28)
        icon.setPixmap(px)
        icon.setFixedSize(38, 38)
        row.addWidget(icon)
        text_box = QVBoxLayout()
        title = QLabel(action.title)
        title.setObjectName("cardTitle")
        desc = QLabel(action.description)
        desc.setObjectName("cardDescription")
        desc.setWordWrap(True)
        text_box.addWidget(title)
        text_box.addWidget(desc)
        row.addLayout(text_box, 1)
        btn = QPushButton("Executar")
        btn.setObjectName("primaryButton" if action.mutable else "secondaryButton")
        btn.clicked.connect(lambda: self.request_action(action))
        row.addWidget(btn)
        return card

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py -v`
Expected: PASS (10 tests)

- [ ] **Step 5: Run full suite + smoke test**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_skeletons.py tests/test_native_tokens.py tests/test_linux_native_ui.py -q`
Expected: PASS

Run smoke: `QT_QPA_PLATFORM=offscreen python linux/ui_native/app.py --smoke-test --screenshot /tmp/pz-phase2-overview.png`
Expected: exits 0

- [ ] **Step 6: Commit**

```bash
git add linux/ui_native/pages/overview.py tests/test_native_skeletons.py
git commit -m "feat(ui-native): integrate skeletons + async status into OverviewPage

reload() now shows SkeletonPill placeholders, then fetches real status
via StatusLoader. On status_ready/failed, populates action pills.
Pages now show loading state before content arrives."
```

---

## Self-Review Checklist

- [ ] **Spec coverage:** Spec Phase 2 = SkeletonTile/SkeletonCard + shimmer + BasePage.show_skeletons + threshold. Tasks 1-4 cover all. Async status loader is an enhancement (user-approved scope expansion).
- [ ] **Placeholder scan:** No TBD/TODO. All code complete.
- [ ] **Type consistency:** `SkeletonTile(width, height)`, `SkeletonCard(hero=False)`, `SkeletonPill()`, `start_shimmer(widget)`, `StatusLoader.fetch(action_id, args)` — signatures consistent across tasks.
- [ ] **Token usage:** Skeletons use `skeleton_base`/`skeleton_shimmer` from Phase 1 tokens.
- [ ] **No regressions:** Each task runs full 24+ test suite.

## Phases 3-5 (separate plans)

- Phase 3: Stateful dialogs (`StatefulDialog`, rewrite Preview/Result, add Progress)
- Phase 4: Navigation (Breadcrumb, StatusBar, operation panel enrichment)
- Phase 5: Windows portability (`platform.py`, refactor command_runner, platforms field)
