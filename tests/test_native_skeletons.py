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
