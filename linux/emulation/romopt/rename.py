from __future__ import annotations
import re
import hashlib
import zlib
from pathlib import Path

PLATFORM_REGIONS: dict[str, list[str]] = {
    "nes": ["USA", "Europe", "Japan", "World"],
    "snes": ["USA", "Europe", "Japan"],
    "genesis": ["USA", "Europe", "Japan", "World"],
    "ps1": ["USA", "Europe", "Japan", "Asia"],
    "ps2": ["USA", "Europe", "Japan", "Asia"],
}

SERIAL_PATTERNS: dict[str, list[str]] = {
    "ps1": [r"SCUS-\d{5}", r"SLUS-\d{5}", r"SCES-\d{5}", r"SLES-\d{5}"],
    "ps2": [r"SCUS_\d{3}\.\d{2}", r"SLUS_\d{3}\.\d{2}"],
    "psp": [r"UCES\d{5}", r"ULUS\d{5}", r"NPUZ\d{5}"],
    "dreamcast": [r"T\d{6}"],
}

GAME_ID_PATTERNS: dict[str, list[tuple[int, int]]] = {
    "wii": [(0, 6)],
    "gc": [(0, 6)],
}


def extract_serial(path: Path, platform: str) -> str:
    patterns = SERIAL_PATTERNS.get(platform, [])
    # First, try filename
    for p in patterns:
        m = re.search(p, path.name, re.IGNORECASE)
        if m:
            return m.group(0).upper()

    # Try binary header
    try:
        data = _safe_read(path, 0x10000)
        if data:
            for p in patterns:
                m = re.search(p.encode(), data)
                if m:
                    return m.group(0).decode().upper()
    except Exception:
        pass
    return ""


def extract_game_id(path: Path, platform: str) -> str:
    offsets = GAME_ID_PATTERNS.get(platform, [])
    try:
        data = _safe_read(path, 0x20)
        if not data:
            return ""
        for off, length in offsets:
            if off + length <= len(data):
                gid = data[off:off + length].decode("ascii", errors="replace").strip()
                if gid and len(gid) == length:
                    return gid
    except Exception:
        pass
    return ""


def detect_region(filename: str) -> str:
    markers = {
        "USA": [r"\(USA\)", r"\(US\)", r"\(U\)"],
        "Europe": [r"\(Europe\)", r"\(E\)", r"\(EU\)"],
        "Japan": [r"\(Japan\)", r"\(J\)", r"\(JP\)"],
        "World": [r"\(World\)", r"\(W\)"],
        "Asia": [r"\(Asia\)"],
        "Australia": [r"\(Australia\)", r"\(AUS\)"],
    }
    for region, patterns in markers.items():
        for p in patterns:
            if re.search(p, filename, re.IGNORECASE):
                return region
    return ""


def clean_title(stem: str) -> str:
    cleaned = re.sub(r"\([^)]*\)", "", stem)
    cleaned = re.sub(r"\[[^\]]*\]", "", cleaned)
    cleaned = re.sub(r"[!_]+", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def build_no_intro_name(
    old_path: Path, serial: str = "", game_id: str = "",
    region: str = "", revision: str = "",
) -> str:
    title = clean_title(old_path.stem) or old_path.stem
    parts = [title]
    if region:
        parts.append(f"({region})")
    if serial:
        parts.append(f"({serial})")
    elif game_id:
        parts.append(f"({game_id})")
    if revision:
        parts.append(f"(Rev {revision})")
    return " ".join(parts)


def _safe_read(path: Path, size: int) -> bytes | None:
    try:
        with open(path, "rb") as f:
            return f.read(size)
    except OSError:
        return None


def compute_crc32(path: Path) -> str:
    try:
        checksum = 0
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                checksum = zlib.crc32(chunk, checksum)
        return f"{checksum & 0xffffffff:08x}"
    except OSError:
        return ""


def compute_sha1(path: Path) -> str:
    try:
        digest = hashlib.sha1()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return ""
