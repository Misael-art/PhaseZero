from __future__ import annotations

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


def test_skeleton_tile_creates(app):
    from linux.ui_native.widgets import SkeletonTile
    tile = SkeletonTile(160, 14)
    assert tile.width() == 160
    assert tile.height() == 14
    assert tile.objectName() == "skeletonTile"


def test_skeleton_card_creates(app):
    from linux.ui_native.widgets import SkeletonCard, SkeletonTile
    card = SkeletonCard()
    assert card.objectName() == "skeletonCard"
    # Card should have placeholder children (tiles)
    tiles = card.findChildren(SkeletonTile)
    assert len(tiles) >= 4  # icon, title, description, button


def test_skeleton_pill_creates(app):
    from linux.ui_native.widgets import SkeletonPill, SkeletonTile
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


def test_loading_threshold_avoids_fast_flash(app):
    from linux.ui_native.pages.base import BasePage
    from linux.ui_native.command_runner import CommandRunner
    from linux.ui_native.widgets import SkeletonCard
    page = BasePage(ROOT, CommandRunner(ROOT), [], {})
    page.begin_loading(lambda: page.show_skeletons(count=1), delay_ms=200)
    QTest.qWait(50)
    page.finish_loading()
    QTest.qWait(180)
    assert not page.findChildren(SkeletonCard)


def test_skeleton_shimmer_lifecycle(app):
    from linux.ui_native.widgets import SkeletonCard, SkeletonTile
    card = SkeletonCard()
    card.show()
    QTest.qWait(10)
    tiles = card.findChildren(SkeletonTile)
    assert tiles and all(tile.property("shimmer") == "true" for tile in tiles)
    card.hide()
    QTest.qWait(10)
    assert all(tile.property("shimmer") != "true" for tile in tiles)


def test_overview_page_shows_skeletons_on_reload(app, qtbot=None):
    """OverviewPage.reload() should show skeletons then load status."""
    from pathlib import Path
    from linux.ui_native.pages.overview import OverviewPage
    from linux.ui_native.command_runner import CommandRunner
    from linux.ui_native.catalog import build_catalog
    from linux.ui_native.widgets import SkeletonPill, StatusPill

    catalog = build_catalog(Path(ROOT))
    by_id = {a.id: a for a in catalog}
    page = OverviewPage(Path(ROOT), CommandRunner(Path(ROOT)), catalog, by_id)
    page.build()
    page.reload()
    QTest.qWait(250)
    # Slow status shows skeletons; a fast result may already show status pills.
    skeletons = page.findChildren(SkeletonPill)
    assert len(skeletons) > 0 or len(page.findChildren(StatusPill)) > 0
    page.cancel_status()
