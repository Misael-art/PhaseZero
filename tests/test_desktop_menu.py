from __future__ import annotations

import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

from linux.ui import menu


@pytest.fixture
def xdg(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    apps = tmp_path / "data" / "applications"
    apps.mkdir(parents=True)
    return tmp_path, apps


def desktop(apps: Path, name: str, *, title: str, exec_: str, categories: str, extra: str = "") -> Path:
    path = apps / name
    path.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        f"Name={title}\n"
        f"Exec={exec_}\n"
        "Icon=test\n"
        f"Categories={categories}\n"
        f"{extra}",
        encoding="utf-8",
    )
    return path


def test_scan_is_read_only_and_hides_individual_games(xdg):
    root, apps = xdg
    desktop(apps, "phz-whatsapp.desktop", title="WhatsApp", exec_="xdg-open https://web.whatsapp.com", categories="X-PhaseZero-WebApp;", extra="X-PHZ-Group=Comunicação\n")
    desktop(apps, "phasezero-pc-game.desktop", title="Game", exec_="wine game.exe", categories="Game;X-PhaseZero-PC;")
    payload = menu.scan()
    assert payload["readOnly"] is True
    assert payload["summary"]["managedVisible"] == 1
    assert payload["summary"]["hidden"] == 1
    assert not (root / "config" / "menus").exists()
    assert not (root / "state").exists()


def test_apply_creates_one_root_and_deduplicates_exec(xdg):
    root, apps = xdg
    desktop(apps, "phz-game-steam.desktop", title="Steam wrapper", exec_="/usr/bin/steam %f", categories="X-PhaseZero-Game;", extra="X-PHZ-Group=Jogos PC\n")
    desktop(apps, "phasezero-steam.desktop", title="Steam", exec_="/usr/bin/steam", categories="X-PhaseZero-Game;", extra="X-PHZ-Group=Jogos PC\n")
    legacy = root / "config" / "menus" / "applications-merged" / "phz-games.menu"
    legacy.parent.mkdir(parents=True)
    legacy.write_text("legacy", encoding="utf-8")

    payload = menu.apply()
    assert payload["status"] == "ok"
    assert payload["duplicatesSuppressed"] == 1
    target = Path(payload["menu"])
    tree = ET.parse(target).getroot()
    assert tree.findtext("Name") == "Applications"
    phasezero = next(node for node in tree.findall("Menu") if node.findtext("Name") == "PhaseZero")
    filenames = [node.text for node in phasezero.findall(".//Filename")]
    assert filenames == ["phasezero-steam.desktop"]
    assert "Categories=X-PhaseZero;" in (apps / "phasezero-steam.desktop").read_text(encoding="utf-8")
    assert "X-PhaseZero-MenuGroup=games.library" in (apps / "phasezero-steam.desktop").read_text(encoding="utf-8")
    duplicate_text = (apps / "phz-game-steam.desktop").read_text(encoding="utf-8")
    assert "NoDisplay=true" in duplicate_text
    assert "X-PhaseZero-SuppressedBy=phasezero-steam.desktop" in duplicate_text
    assert not legacy.exists()
    manifest = Path(payload["manifest"])
    assert manifest.stat().st_mode & 0o777 == 0o600

    rolled = menu.rollback()
    assert rolled["status"] == "ok"
    assert legacy.read_text(encoding="utf-8") == "legacy"
    assert not target.exists()
    assert "Categories=X-PhaseZero-Game;" in (apps / "phasezero-steam.desktop").read_text(encoding="utf-8")
    assert "NoDisplay=true" not in (apps / "phz-game-steam.desktop").read_text(encoding="utf-8")


def test_apply_is_idempotent_and_preserves_web_group(xdg):
    _root, apps = xdg
    desktop(
        apps, "phz-whatsapp.desktop", title="WhatsApp",
        exec_="xdg-open https://web.whatsapp.com", categories="X-PhaseZero-WebApp;",
        extra="X-PHZ-Group=Comunicação\n",
    )
    first = menu.apply()
    first_xml = Path(first["menu"]).read_text(encoding="utf-8")
    second = menu.apply()
    second_xml = Path(second["menu"]).read_text(encoding="utf-8")
    assert first_xml == second_xml
    assert "Apps web" in second_xml
    assert "Comunicação" in second_xml


def test_favorite_individual_game_is_visible(xdg):
    _root, apps = xdg
    desktop(
        apps, "phasezero-pc-favorite.desktop", title="Favorite", exec_="wine favorite.exe",
        categories="Game;X-PhaseZero-PC;", extra="X-PhaseZero-Favorite=true\n",
    )
    payload = menu.scan()
    assert payload["summary"]["managedVisible"] == 1
    assert payload["summary"]["hidden"] == 0
