#!/usr/bin/env python3
"""Mark non-game entries as hidden and non-scrapable in an ES-DE gamelist."""

from __future__ import annotations

import argparse
import os
import shutil
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


EXCLUSION_FIELDS = ("hidden", "nogamecount", "nomultiscrape")


def normalized_rom_path(value: str) -> str:
    value = value.strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value.lstrip("/")


def load_ignored(path: Path) -> set[str]:
    return {
        normalized_rom_path(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }


def set_true(entry: ET.Element, field: str) -> bool:
    node = entry.find(field)
    if node is None:
        node = ET.SubElement(entry, field)
        node.text = "true"
        return True
    if (node.text or "").strip().lower() != "true":
        node.text = "true"
        return True
    return False


def load_gamelist(gamelist: Path) -> tuple[ET.ElementTree, str, str]:
    text = gamelist.read_text(encoding="utf-8")
    try:
        return ET.ElementTree(ET.fromstring(text)), "", ""
    except ET.ParseError:
        start = text.find("<gameList")
        end = text.rfind("</gameList>")
        if start < 0 or end < start:
            raise
        end += len("</gameList>")
        return ET.ElementTree(ET.fromstring(text[start:end])), text[:start], text[end:]


def update_gamelist(gamelist: Path, ignored: set[str]) -> int:
    tree, prefix, suffix = load_gamelist(gamelist)
    root = tree.getroot()
    changed = 0

    for entry in root.findall("./game") + root.findall("./folder"):
        path_node = entry.find("path")
        if path_node is None or normalized_rom_path(path_node.text or "") not in ignored:
            continue
        entry_changed = False
        for field in EXCLUSION_FIELDS:
            entry_changed = set_true(entry, field) or entry_changed
        changed += int(entry_changed)

    if not changed:
        return 0

    backup = gamelist.with_suffix(gamelist.suffix + ".phasezero.bak")
    shutil.copy2(gamelist, backup)
    ET.indent(tree, space="\t")
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{gamelist.name}.", dir=gamelist.parent
    )
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        if prefix or suffix:
            serialized = ET.tostring(root, encoding="unicode")
            tmp_path.write_text(prefix + serialized + suffix, encoding="utf-8")
        else:
            tree.write(tmp_path, encoding="utf-8", xml_declaration=True)
        os.replace(tmp_path, gamelist)
    finally:
        tmp_path.unlink(missing_ok=True)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gamelist", required=True, type=Path)
    parser.add_argument("--ignored-file", required=True, type=Path)
    args = parser.parse_args()

    if not args.gamelist.is_file():
        return 0
    ignored = load_ignored(args.ignored_file)
    if not ignored:
        return 0
    print(update_gamelist(args.gamelist, ignored))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
