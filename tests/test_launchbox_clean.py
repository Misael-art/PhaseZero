from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.emulation import launchbox_import


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_esde_datetime_is_normalized_for_launchbox():
    assert launchbox_import.launchbox_datetime("19940623T000000") == "1994-06-23T00:00:00"
    assert launchbox_import.launchbox_datetime("19940623") == "1994-06-23T00:00:00"
    assert launchbox_import.launchbox_datetime("") == ""


def test_esde_import_is_tolerant_complete_and_idempotent(tmp_path, monkeypatch):
    home = tmp_path / "home"
    roms = tmp_path / "roms"
    media = tmp_path / "media"
    metadata = tmp_path / "metadata"
    launchbox = tmp_path / "LaunchBox"
    compat = tmp_path / "Roms"
    system = roms / "sample"
    system.mkdir(parents=True)
    for name in ("Disc.cue", "Disc.bin", "First.zip", "Second.zip"):
        (system / name).write_text(name, encoding="utf-8")
    covers = media / "sample" / "covers"
    covers.mkdir(parents=True)
    (covers / "Disc.png").write_bytes(b"disc")
    (covers / "First.png").write_bytes(b"first")
    gamelist = metadata / "sample" / "gamelist.xml"
    gamelist.parent.mkdir(parents=True)
    gamelist.write_text(
        """<?xml version="1.0"?>
<alternativeEmulator><label>ignored irregular prefix</label></alternativeEmulator>
<gameList>
  <game><path>./Disc.cue</path><name>Shared Title</name><rating>0.8</rating></game>
  <game><path>./First.zip</path><name>Shared Title</name></game>
  <game><path>./Second.zip</path><name>No Artwork</name></game>
</gameList>
""",
        encoding="utf-8",
    )
    systems = tmp_path / "es_systems.xml"
    systems.write_text(
        f"""<systemList><system>
<name>sample</name><fullname>Sample System</fullname>
<path>{system}</path><extension>.cue .bin .zip</extension>
</system></systemList>""",
        encoding="utf-8",
    )
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("PZ_ESDE_SYSTEMS_XML", str(systems))
    monkeypatch.setenv("PZ_EMULATION_ROOT", str(tmp_path))
    monkeypatch.setenv("PZ_ESDE_ROM_ROOT", str(roms))
    monkeypatch.setenv("PZ_ESDE_MEDIA_ROOT", str(media))
    monkeypatch.setenv("PZ_ESDE_METADATA_ROOT", str(metadata))
    monkeypatch.setenv("PZ_LAUNCHBOX_ROOT", str(launchbox))
    monkeypatch.setenv("PZ_LAUNCHBOX_COMPAT_ROMS", str(compat))
    monkeypatch.setenv("PZ_ROOT", str(ROOT))

    assert launchbox_import.import_esde(True) == 0
    report = json.loads((launchbox / ".phasezero/esde-import.json").read_text())
    assert report["platforms"] == 1
    assert report["games"] == 3
    assert report["romLinks"] == 4
    assert report["mediaLinks"] == 2
    platform_xml = launchbox / "Data/Platforms/Sample System.xml"
    first_digest = digest(platform_xml)
    assert launchbox_import.import_esde(False) == 0
    assert digest(platform_xml) == first_digest
    assert len(list((launchbox / "Images/Sample System/Box - Front").glob("*.png"))) == 2


def test_import_refuses_unmanaged_alias(tmp_path, monkeypatch):
    roms = tmp_path / "roms"
    system = roms / "sample"
    system.mkdir(parents=True)
    (system / "game.zip").write_text("rom")
    systems = tmp_path / "systems.xml"
    systems.write_text(
        f"<systemList><system><name>sample</name><fullname>Sample</fullname>"
        f"<path>{system}</path><extension>.zip</extension></system></systemList>"
    )
    alias = tmp_path / "compat" / "Sample"
    alias.mkdir(parents=True)
    (alias / "keep.txt").write_text("user data")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("PZ_ESDE_SYSTEMS_XML", str(systems))
    monkeypatch.setenv("PZ_EMULATION_ROOT", str(tmp_path))
    monkeypatch.setenv("PZ_ESDE_ROM_ROOT", str(roms))
    monkeypatch.setenv("PZ_LAUNCHBOX_ROOT", str(tmp_path / "LaunchBox"))
    monkeypatch.setenv("PZ_LAUNCHBOX_COMPAT_ROMS", str(tmp_path / "compat"))
    monkeypatch.setenv("PZ_ROOT", str(ROOT))
    with pytest.raises(RuntimeError, match="unmanaged ROM alias"):
        launchbox_import.import_esde(False)
    assert (alias / "keep.txt").read_text() == "user data"


def test_empty_installer_is_rejected_before_root_mutation(tmp_path):
    root = tmp_path / "LaunchBox"
    installer = root / "_hidden/_hidden/LaunchBox-13.5-Setup.exe"
    installer.parent.mkdir(parents=True)
    installer.write_bytes(b"")
    license_path = root / "License.xml"
    license_path.write_text("keep", encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "PZ_EMULATION_ROOT": str(tmp_path),
            "PZ_LAUNCHBOX_ROOT": str(root),
            "PZ_LAUNCHBOX_INSTALLER": str(installer),
            "PZ_LAUNCHBOX_SKIP_WINEBOOT": "1",
            "PZ_LAUNCHBOX_SKIP_FONTS": "1",
            "PZ_LAUNCHBOX_SKIP_RUNTIME": "1",
        }
    )
    result = subprocess.run(
        [str(ROOT / "linux/pz"), "emulation", "launchbox", "install-clean"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0
    assert "installer invalid" in result.stderr
    assert license_path.read_text(encoding="utf-8") == "keep"
    assert not list(tmp_path.glob(".LaunchBox.stage.*"))
