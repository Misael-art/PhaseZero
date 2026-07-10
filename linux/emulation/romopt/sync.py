from __future__ import annotations
import json
import os
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

from .manifest import log_sync_ops, load_sync_ops

SAVES_EXTENSIONS = {".sav", ".srm", ".dsv", ".eep", ".fra", ".psv", ".auto"}
MEMCARD_EXTENSIONS = {".mcr", ".ps2", ".vmp", ".card"}
STATE_EXTENSIONS = {".state", ".st", ".net", ".yaz0", ".time"}
STATE_PREVIEW_EXTENSIONS = {".png", ".jpg"}
CHEAT_EXTENSIONS = {".cht", ".pnach"}
PATCH_EXTENSIONS = {".bps", ".ips", ".ppf", ".xdelta", ".ups"}
ALL_RELATED_EXTENSIONS = (
    SAVES_EXTENSIONS | MEMCARD_EXTENSIONS | STATE_EXTENSIONS |
    STATE_PREVIEW_EXTENSIONS | CHEAT_EXTENSIONS | PATCH_EXTENSIONS
)

SYNC_SCOPE = {
    "m3u": True,
    "saves": True,
    "states": True,
    "media": True,
    "gamelists": True,
    "playlists": True,
    "cheats": True,
    "configs": False,
    "mods": False,
}


def _replace_path_stem(value: str, old_stem: str, new_stem: str) -> tuple[str, bool]:
    """Replace only an exact filename stem, preserving directory and suffix."""
    query_at = min(
        (index for index in (value.find("?"), value.find("#")) if index >= 0),
        default=len(value),
    )
    path_part, trailer = value[:query_at], value[query_at:]
    separator = max(path_part.rfind("/"), path_part.rfind("\\"))
    prefix, filename = path_part[: separator + 1], path_part[separator + 1 :]
    suffix = Path(filename).suffix
    stem = filename[: -len(suffix)] if suffix else filename
    if stem != old_stem:
        return value, False
    return f"{prefix}{new_stem}{suffix}{trailer}", True


def sync_related_assets(
    old_stem: str,
    new_stem: str,
    platform: str,
    emulation_root: Path,
    rom_path: Path,
    *,
    scope: dict[str, bool] | None = None,
    dry_run: bool = False,
    manifest_dir: Path | None = None,
) -> int:
    s = SYNC_SCOPE if scope is None else scope
    ops: list[dict] = []
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    def _rename(base: Path, pattern: str, _extras: set[str] | None = None):
        if not base.exists():
            return
        for f in sorted(base.iterdir()):
            if f.is_file() and _matches_stem(f, old_stem, _extras):
                suffix = _stem_suffix(f, old_stem)
                new = f.parent / f"{new_stem}{suffix}"
                if f == new:
                    continue
                if new.exists():
                    # A rename must never replace an unrelated save/state.
                    continue
                ops.append({"op": "rename", "old": str(f), "new": str(new),
                            "ts": ts, "category": pattern})
                if not dry_run:
                    f.rename(new)

    def _rewrite_m3u():
        m3u = rom_path.parent / f"{old_stem}.m3u"
        if not m3u.is_file():
            return
        content = m3u.read_text(encoding="utf-8")
        changed = False
        output_lines = []
        for line in content.splitlines(keepends=True):
            if line.lstrip().startswith("#"):
                output_lines.append(line)
                continue
            ending = "\n" if line.endswith("\n") else ""
            raw = line[:-1] if ending else line
            replaced, did_change = _replace_path_stem(raw, old_stem, new_stem)
            output_lines.append(replaced + ending)
            changed = changed or did_change
        if not changed:
            return
        new_content = "".join(output_lines)
        new_m3u = m3u.with_name(f"{new_stem}.m3u")
        if new_m3u != m3u and new_m3u.exists():
            return
        ops.append({"op": "rewrite", "old": str(m3u), "new": str(new_m3u),
                    "ts": ts, "category": "m3u"})
        if not dry_run:
            tmp = m3u.with_name(f".{m3u.name}.tmp")
            tmp.write_text(new_content, encoding="utf-8")
            os.replace(tmp, m3u)
            if new_m3u != m3u:
                m3u.rename(new_m3u)

    def _update_gamelist():
        gl = emulation_root / "metadata" / "gamelists" / "frontends" / platform / "gamelist.xml"
        if not gl.exists():
            return
        try:
            tree = ET.parse(gl)
        except (ET.ParseError, OSError):
            return
        changed = False
        reference_tags = {"path", "image", "thumbnail", "marquee", "video", "manual"}
        for element in tree.iter():
            tag = element.tag.rsplit("}", 1)[-1]
            if tag not in reference_tags or not element.text:
                continue
            replaced, did_change = _replace_path_stem(element.text, old_stem, new_stem)
            if did_change:
                element.text = replaced
                changed = True
        if not changed:
            return
        new_content = ET.tostring(tree.getroot(), encoding="unicode")
        ops.append({"op": "rewrite", "old": str(gl), "new": str(gl),
                    "ts": ts, "category": "gamelist"})
        if not dry_run:
            tmp = gl.with_name(f".{gl.name}.tmp")
            tmp.write_text(new_content, encoding="utf-8")
            os.replace(tmp, gl)

    def _update_retroarch_playlists():
        # Common RetroArch playlist dirs
        candidates = [
            Path.home() / ".config/retroarch/playlists",
            Path.home() / ".var/app/org.libretro.RetroArch/config/retroarch/playlists",
            emulation_root / "retroarch/playlists",
        ]
        for base in candidates:
            if not base.exists():
                continue
            for f in sorted(base.iterdir()):
                if f.suffix.lower() != ".lpl":
                    continue
                try:
                    data = json.loads(f.read_text(encoding="utf-8"))
                    items = data.get("items", []) if isinstance(data, dict) else []
                    changed = False
                    for item in items:
                        if not isinstance(item, dict):
                            continue
                        path_value = item.get("path")
                        if isinstance(path_value, str):
                            replaced, did_change = _replace_path_stem(
                                path_value, old_stem, new_stem
                            )
                            if did_change:
                                item["path"] = replaced
                                changed = True
                        if item.get("label") == old_stem:
                            item["label"] = new_stem
                            changed = True
                    if not changed:
                        continue
                    new_content = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
                    ops.append({"op": "rewrite", "old": str(f), "new": str(f),
                                "ts": ts, "category": "playlist"})
                    if not dry_run:
                        tmp = f.with_name(f".{f.name}.tmp")
                        tmp.write_text(new_content, encoding="utf-8")
                        os.replace(tmp, f)
                except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                    pass

    if s.get("m3u", True):
        _rewrite_m3u()

    saves_dir = emulation_root / "saves" / platform
    states_dir = emulation_root / "states" / platform
    media_dir = emulation_root / "tools" / "downloaded_media" / platform
    cheats_dir = emulation_root / "cheats" / platform
    patches_dir = emulation_root / "patches" / platform

    if s.get("saves", True):
        _rename(saves_dir, "saves")
    if s.get("states", True):
        _rename(states_dir, "states", STATE_PREVIEW_EXTENSIONS)
    if s.get("cheats", True):
        _rename(cheats_dir, "cheats", CHEAT_EXTENSIONS | PATCH_EXTENSIONS)
        _rename(patches_dir, "patches", PATCH_EXTENSIONS)
    if s.get("gamelists", True):
        _update_gamelist()
    if s.get("playlists", True):
        _update_retroarch_playlists()

    if s.get("media", True) and media_dir.exists():
        for subdir in sorted(media_dir.iterdir()):
            if subdir.is_dir():
                _rename(subdir, f"media/{subdir.name}")

    if manifest_dir and not dry_run:
        log_sync_ops(manifest_dir, ops)

    return len(ops)


def _matches_stem(f: Path, stem: str, extras: set[str] | None = None) -> bool:
    name = f.name
    # Exact stem match
    if name.startswith(stem):
        rest = name[len(stem):]
        if not rest or rest[0] in (".", " ", "-", "("):
            return True
    # Pattern match: stem + number + ext
    if extras:
        if f.suffix.lower() in extras:
            return f.stem == stem or f.stem.startswith(f"{stem}.")
    return False


def _stem_suffix(f: Path, stem: str) -> str:
    return f.name[len(stem):]
