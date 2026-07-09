#!/usr/bin/env python3
"""Build PhaseZero media index from NUL-delimited scan records."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path

ESDE_TYPES = (
    "3dboxes",
    "backcovers",
    "covers",
    "custom",
    "fanart",
    "manuals",
    "marquees",
    "miximages",
    "physicalmedia",
    "screenshots",
    "titlescreens",
    "videos",
)
STEAMGRID_TYPES = ("grid", "hero", "logo", "icon")


def media_lookup(root: Path, media_types: tuple[str, ...]) -> dict[tuple[str, str], dict[str, list[str]]]:
    result: dict[tuple[str, str], dict[str, list[str]]] = {}
    if not root.is_dir():
        return result
    for system_dir in root.iterdir():
        if not system_dir.is_dir():
            continue
        for media_type in media_types:
            type_dir = system_dir / media_type
            if not type_dir.is_dir():
                continue
            try:
                entries = sorted(os.scandir(type_dir), key=lambda item: item.name.casefold())
            except OSError:
                continue
            for item in entries:
                if not item.is_file(follow_symlinks=True):
                    continue
                stem = os.path.splitext(item.name)[0]
                key = (system_dir.name.casefold(), stem.casefold())
                result.setdefault(key, {}).setdefault(media_type, []).append(item.name)
    return result


def media_file_list(root: Path, media_types: tuple[str, ...]) -> list[dict[str, str]]:
    """Flat list of every media file under root, with its system/stem/type/path."""
    files: list[dict[str, str]] = []
    if not root.is_dir():
        return files
    for system_dir in root.iterdir():
        if not system_dir.is_dir():
            continue
        for media_type in media_types:
            type_dir = system_dir / media_type
            if not type_dir.is_dir():
                continue
            try:
                entries = sorted(os.scandir(type_dir), key=lambda item: item.name.casefold())
            except OSError:
                continue
            for item in entries:
                if not item.is_file(follow_symlinks=True):
                    continue
                stem = os.path.splitext(item.name)[0]
                files.append({
                    "system": system_dir.name.casefold(),
                    "stem": stem.casefold(),
                    "type": media_type,
                    "path": str(item.path),
                })
    return files


def read_records(path: Path, width: int) -> list[tuple[str, ...]]:
    fields = path.read_bytes().split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % width:
        raise ValueError(f"invalid record stream: {len(fields)} fields, width {width}")
    decoded = [field.decode("utf-8", errors="surrogateescape") for field in fields]
    return [tuple(decoded[index : index + width]) for index in range(0, len(decoded), width)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--records", type=Path, required=True)
    parser.add_argument("--ignored", type=Path, required=True)
    parser.add_argument("--media-root", type=Path, required=True)
    parser.add_argument("--steamgrid-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    esde_media = media_lookup(args.media_root, ESDE_TYPES)
    steamgrid_media = media_lookup(args.steamgrid_root, STEAMGRID_TYPES)
    systems: dict[str, dict[str, object]] = {}
    total_roms = 0
    total_ignored = 0
    total_media = 0
    # (system, stem) keys that have at least one indexed rom — used to detect
    # media files whose rom no longer exists (orphaned media).
    rom_keys: set[tuple[str, str]] = set()

    for system, count in read_records(args.ignored, 2):
        ignored_count = int(count)
        if ignored_count:
            systems[system] = {"roms": {}, "rom_count": 0, "ignored_count": ignored_count}
            total_ignored += ignored_count

    for system, stem, relative_path, kind in read_records(args.records, 4):
        system_entry = systems.setdefault(system, {"roms": {}, "rom_count": 0, "ignored_count": 0})
        roms = system_entry["roms"]
        if stem in roms:
            roms[stem]["conflicts"].append(relative_path)
            continue

        key = (system.casefold(), stem.casefold())
        rom_keys.add(key)
        esde = esde_media.get(key, {})
        steamgrid = steamgrid_media.get(key, {})
        roms[stem] = {
            "stem": stem,
            "relative_path": relative_path,
            "kind": kind,
            "es_de_media": esde,
            "steamgrid_media": steamgrid,
            "conflicts": [],
        }
        system_entry["rom_count"] += 1
        total_roms += 1
        total_media += sum(len(files) for files in esde.values())
        total_media += sum(len(files) for files in steamgrid.values())

    # Orphaned media: files whose (system, stem) has no indexed rom.
    orphaned: list[dict[str, str]] = []
    for entry in media_file_list(args.media_root, ESDE_TYPES):
        if (entry["system"], entry["stem"]) not in rom_keys:
            orphaned.append({"source": "es-de", **entry})
    for entry in media_file_list(args.steamgrid_root, STEAMGRID_TYPES):
        if (entry["system"], entry["stem"]) not in rom_keys:
            orphaned.append({"source": "steamgrid", **entry})

    output = {
        "version": 2,
        "generated": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "systems": systems,
        "orphanedMedia": orphaned,
        "stats": {
            "roms_indexed": total_roms,
            "roms_ignored": total_ignored,
            "media_files": total_media,
            "orphaned_media": len(orphaned),
        },
    }
    args.output.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
