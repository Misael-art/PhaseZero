from __future__ import annotations

import json
import subprocess
import sys
import zipfile
from pathlib import Path

from linux.emulation.romopt import __main__ as romopt_main
from linux.emulation.romopt import convert, sync
from linux.emulation.romopt.profile import Profile


ROOT = Path(__file__).resolve().parents[1]


def test_pz_romopt_runs_outside_repository_and_emits_json(tmp_path):
    rom_dir = tmp_path / "roms"
    rom_dir.mkdir()
    (rom_dir / "game.sfc").write_bytes(b"rom")
    result = subprocess.run(
        [
            str(ROOT / "linux" / "pz"),
            "emulation",
            "romopt",
            str(rom_dir),
            "--platform",
            "snes",
            "--dry-run",
            "--json",
        ],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout.strip().splitlines()[-1])
    assert payload["status"] == "ok"
    assert payload["summary"]["planned"] == 1


def test_failed_conversion_does_not_rename_source(tmp_path, monkeypatch):
    source = tmp_path / "old.iso"
    source.write_bytes(b"disc")
    renamed = tmp_path / "new.iso"
    monkeypatch.setattr(romopt_main.detect, "find_roms", lambda _root: [source])
    monkeypatch.setattr(
        romopt_main.detect, "detect", lambda _path, _root: ("ps2", "iso", "test", 1.0)
    )
    monkeypatch.setattr(romopt_main, "_rename_target", lambda *_args, **_kwargs: renamed)
    monkeypatch.setattr(
        romopt_main.convert,
        "convert",
        lambda *_args, **_kwargs: (127, "", "converter missing"),
    )
    rc = romopt_main.main(["--rom-dir", str(tmp_path), "--platform", "ps2", "--rename"])
    assert rc == 1
    assert source.is_file()
    assert not renamed.exists()


def test_rezip_keep_original_uses_distinct_destination(tmp_path):
    source = tmp_path / "game.zip"
    with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("game.sfc", b"rom data")
    rc = romopt_main.main(["--rom-dir", str(tmp_path), "--platform", "snes"])
    assert rc == 0
    assert source.is_file()
    output = tmp_path / "game.optimized.zip"
    assert output.is_file()
    with zipfile.ZipFile(output) as archive:
        assert archive.read("game.sfc") == b"rom data"


def test_cleanup_has_checkpoint_and_final_manifest(tmp_path, monkeypatch):
    source = tmp_path / "game.iso"
    source.write_bytes(b"source disc")
    manifest_dir = tmp_path / "journal"
    monkeypatch.setattr(romopt_main.detect, "find_roms", lambda _root: [source])
    monkeypatch.setattr(
        romopt_main.detect, "detect", lambda _path, _root: ("ps2", "iso", "test", 1.0)
    )

    def fake_convert(_fmt, _source, destination, _profile, **_kwargs):
        destination.write_bytes(b"valid chd")
        return 0, "", ""

    monkeypatch.setattr(romopt_main.convert, "convert", fake_convert)
    monkeypatch.setattr(
        romopt_main.verify, "verify_format", lambda *_args, **_kwargs: (True, "verified")
    )
    rc = romopt_main.main(
        [
            "--rom-dir",
            str(tmp_path),
            "--platform",
            "ps2",
            "--clean",
            "--manifest",
            str(manifest_dir),
        ]
    )
    assert rc == 0
    assert not source.exists()
    entries = [json.loads(path.read_text()) for path in manifest_dir.glob("*.json")]
    assert any(entry.get("status") == "output_committed" and entry["cleanupPending"] for entry in entries)
    assert any(entry.get("type") == "final" and entry["sourceRemoved"] is True for entry in entries)


def test_nsz_uses_output_directory_and_moves_single_artifact(tmp_path, monkeypatch):
    source = tmp_path / "game.xci"
    source.write_bytes(b"xci")
    destination = tmp_path / "stage.xcz"
    observed = {}

    def fake_run(command, **_kwargs):
        output_dir = Path(command[command.index("-o") + 1])
        observed["output"] = output_dir
        (output_dir / "game.xcz").write_bytes(b"compressed")
        return 0, "", ""

    monkeypatch.setattr(convert, "_run", fake_run)
    rc, _stdout, stderr = convert.convert_nsz_compress(
        source, destination, Profile.load("balanced")
    )
    assert rc == 0, stderr
    assert observed["output"].is_dir() is False  # Temporary directory cleaned.
    assert destination.read_bytes() == b"compressed"


def test_chd_media_detection_handles_small_ps2_dvds(tmp_path):
    cd = tmp_path / "cd.iso"
    dvd = tmp_path / "dvd.iso"
    cd.write_bytes(b"")
    dvd.write_bytes(b"")
    cd.open("r+b").truncate(700_000_000)
    dvd.open("r+b").truncate(1_200_000_000)
    assert convert._detect_chd_input(cd) == "cd"
    assert convert._detect_chd_input(dvd) == "dvd"


def test_sync_updates_only_exact_references(tmp_path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
    root = tmp_path / "emu"
    roms = root / "roms" / "snes"
    roms.mkdir(parents=True)
    m3u = roms / "Game.m3u"
    m3u.write_text("Game.cue\nGame Plus.cue\n# Game.cue\n")
    gamelist = root / "metadata/gamelists/frontends/snes/gamelist.xml"
    gamelist.parent.mkdir(parents=True)
    gamelist.write_text(
        "<gameList><game><path>./Game.zip</path><name>Game Plus</name></game>"
        "<game><path>./Game Plus.zip</path></game></gameList>"
    )
    playlists = root / "retroarch/playlists"
    playlists.mkdir(parents=True)
    playlist = playlists / "Nintendo.lpl"
    playlist.write_text(
        json.dumps(
            {
                "items": [
                    {"path": "/roms/Game.zip", "label": "Game"},
                    {"path": "/roms/Game Plus.zip", "label": "Game Plus"},
                ]
            }
        )
    )
    changed = sync.sync_related_assets("Game", "Renamed", "snes", root, roms / "Game.zip")
    assert changed == 3
    renamed_m3u = roms / "Renamed.m3u"
    assert renamed_m3u.read_text() == "Renamed.cue\nGame Plus.cue\n# Game.cue\n"
    assert "./Renamed.zip" in gamelist.read_text()
    assert "./Game Plus.zip" in gamelist.read_text()
    data = json.loads(playlist.read_text())
    assert data["items"][0] == {"path": "/roms/Renamed.zip", "label": "Renamed"}
    assert data["items"][1] == {"path": "/roms/Game Plus.zip", "label": "Game Plus"}
