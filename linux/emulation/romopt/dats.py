from __future__ import annotations
import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

# v1 = user-supplied DATs only. Verified 2026-07-09: datomatic.redump.org is
# dead (HTTPS refused, Apache default page) and No-Intro's GET ?file= form
# returns 404 (now POST-based). Auto-download URLs removed to avoid silent
# failures; users drop .dat.xml files into <dats_dir>/<source>/.

PLATFORM_DATS: dict[str, tuple[str, str]] = {
    "nes": ("no-intro", "Nintendo - Nintendo Entertainment System"),
    "snes": ("no-intro", "Nintendo - Super Nintendo Entertainment System"),
    "n64": ("no-intro", "Nintendo - Nintendo 64"),
    "gb": ("no-intro", "Nintendo - Game Boy"),
    "gbc": ("no-intro", "Nintendo - Game Boy Color"),
    "gba": ("no-intro", "Nintendo - Game Boy Advance"),
    "nds": ("no-intro", "Nintendo - Nintendo DS"),
    "n3ds": ("no-intro", "Nintendo - Nintendo 3DS"),
    "genesis": ("no-intro", "Sega - Mega Drive - Genesis"),
    "megadrive": ("no-intro", "Sega - Mega Drive - Genesis"),
    "mastersystem": ("no-intro", "Sega - Master System - Mark III"),
    "gamegear": ("no-intro", "Sega - Game Gear"),
    "ps1": ("redump", "Sony - PlayStation"),
    "ps2": ("redump", "Sony - PlayStation 2"),
    "psp": ("redump", "Sony - PlayStation Portable"),
    "dreamcast": ("redump", "Sega - Dreamcast"),
    "saturn": ("redump", "Sega - Saturn"),
    "switch": ("no-intro", "Nintendo - Nintendo Switch"),
    "gc": ("redump", "Nintendo - GameCube"),
    "wii": ("redump", "Nintendo - Wii"),
}


def dat_path(dats_dir: Path, platform: str) -> Path:
    source, name = PLATFORM_DATS.get(platform, ("no-intro", platform))
    return dats_dir / source / f"{name}.dat.xml"


def dat_index_path(dats_dir: Path, platform: str) -> Path:
    return dat_path(dats_dir, platform).with_suffix(".index.json")


def download_dat(dats_dir: Path, platform: str, *, force: bool = False) -> str:
    """v1: no network. Returns 'cached' if a user-supplied DAT is present,
    'missing' otherwise. Auto-download is deferred to v2 (No-Intro POST form
    + optional Redump authenticated download)."""
    dp = dat_path(dats_dir, platform)
    return "cached" if dp.exists() else "missing"


def parse_no_intro_dat(xml_path: Path) -> dict[str, Any]:
    index: dict[str, Any] = {}
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        games = list(root.findall(".//game")) + list(root.findall(".//machine"))
        for game in games:
            name = game.attrib.get("name", "")
            for rom in game.findall("rom"):
                crc = rom.attrib.get("crc", "").lower()
                if crc:
                    index[crc] = {
                        "name": name,
                        "size": int(rom.attrib.get("size", 0)),
                        "sha1": rom.attrib.get("sha1", "").lower(),
                    }
    except (ET.ParseError, OSError, ValueError):
        return {}
    return index


def parse_redump_dat(xml_path: Path) -> dict[str, Any]:
    index: dict[str, Any] = {}
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        for game in root.findall(".//game"):
            name = game.attrib.get("name", "")
            serial = _extract_serial_from_name(name)
            for rom in game.findall("rom"):
                sha1 = rom.attrib.get("sha1", "").lower()
                if sha1:
                    index[sha1] = {
                        "name": name,
                        "serial": serial,
                        "size": int(rom.attrib.get("size", 0)),
                        "md5": rom.attrib.get("md5", "").lower(),
                        "crc": rom.attrib.get("crc", "").lower(),
                    }
    except (ET.ParseError, OSError, ValueError):
        return {}
    return index


def _extract_serial_from_name(name: str) -> str:
    import re
    m = re.search(r"\(([A-Z]{2,4}-\d{3,5})\)", name)
    return m.group(1) if m else ""


def build_index(dats_dir: Path, platform: str, *, cache: bool = True) -> dict[str, Any]:
    dp = dat_path(dats_dir, platform)
    if not dp.exists():
        return {}
    source, _ = PLATFORM_DATS.get(platform, ("no-intro", platform))
    if source == "no-intro":
        index = parse_no_intro_dat(dp)
    else:
        index = parse_redump_dat(dp)
    if cache:
        ip = dat_index_path(dats_dir, platform)
        ip.parent.mkdir(parents=True, exist_ok=True)
        tmp = ip.with_name(f".{ip.name}.tmp")
        tmp.write_text(json.dumps(index, indent=2), encoding="utf-8")
        os.replace(tmp, ip)
    return index


def load_index(dats_dir: Path, platform: str, *, cache: bool = True) -> dict[str, Any]:
    ip = dat_index_path(dats_dir, platform)
    dp = dat_path(dats_dir, platform)
    if ip.exists() and (not dp.exists() or ip.stat().st_mtime_ns >= dp.stat().st_mtime_ns):
        try:
            value = json.loads(ip.read_text("utf-8"))
            if isinstance(value, dict):
                return value
        except (json.JSONDecodeError, OSError):
            pass
    return build_index(dats_dir, platform, cache=cache)


def match_by_crc32(index: dict[str, Any], crc32: str) -> dict | None:
    return index.get(crc32.lower())


def match_by_sha1(index: dict[str, Any], sha1: str) -> dict | None:
    for k, v in index.items():
        if v.get("sha1", "").lower() == sha1.lower():
            return v
    return None


def match_by_serial(index: dict[str, Any], serial: str) -> dict | None:
    for v in index.values():
        if v.get("serial", "").upper() == serial.upper():
            return v
    return None
