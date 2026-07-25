#!/usr/bin/env python3
"""Add/query a Steam non-Steam shortcut without touching games or content."""
from __future__ import annotations

import argparse
import binascii
import os
import shutil
import struct
import sys
import time
from collections import OrderedDict
from pathlib import Path

T_OBJECT = 0
T_STRING = 1
T_INT = 2
T_UINT64 = 7
T_END = 8


def read_cstr(data: bytes, idx: int) -> tuple[str, int]:
    end = data.index(b"\x00", idx)
    return data[idx:end].decode("utf-8", "replace"), end + 1


def parse_object(data: bytes, idx: int = 0) -> tuple[OrderedDict, int]:
    obj: OrderedDict[str, object] = OrderedDict()
    while idx < len(data):
        typ = data[idx]
        idx += 1
        if typ == T_END:
            return obj, idx
        key, idx = read_cstr(data, idx)
        if typ == T_OBJECT:
            val, idx = parse_object(data, idx)
        elif typ == T_STRING:
            val, idx = read_cstr(data, idx)
        elif typ == T_INT:
            val = struct.unpack_from("<i", data, idx)[0]
            idx += 4
        elif typ == T_UINT64:
            val = struct.unpack_from("<Q", data, idx)[0]
            idx += 8
        else:
            raise ValueError(f"unsupported shortcuts.vdf field type: {typ}")
        obj[key] = val
    return obj, idx


def write_cstr(value: str) -> bytes:
    return value.encode("utf-8") + b"\x00"


def write_object(obj: OrderedDict) -> bytes:
    out = bytearray()
    for key, value in obj.items():
        if isinstance(value, OrderedDict):
            out.append(T_OBJECT)
            out += write_cstr(str(key))
            out += write_object(value)
        elif isinstance(value, int):
            out.append(T_INT)
            out += write_cstr(str(key))
            out += struct.pack("<i", value)
        else:
            out.append(T_STRING)
            out += write_cstr(str(key))
            out += write_cstr(str(value))
    out.append(T_END)
    return bytes(out)


def empty_root() -> OrderedDict:
    return OrderedDict([("shortcuts", OrderedDict())])


def read_vdf(path: Path) -> OrderedDict:
    if not path.exists() or path.stat().st_size == 0:
        return empty_root()
    root, _ = parse_object(path.read_bytes())
    if "shortcuts" not in root or not isinstance(root["shortcuts"], OrderedDict):
        root["shortcuts"] = OrderedDict()
    return root


def write_vdf(path: Path, root: OrderedDict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name(f"{path.name}.phasezero-{int(time.time())}.bak")
        shutil.copy2(path, backup)
    path.write_bytes(write_object(root))


def steam_shortcuts_files(steam_root: Path) -> list[Path]:
    userdata = steam_root / "userdata"
    if not userdata.exists():
        return []
    return sorted(userdata.glob("*/config/shortcuts.vdf"))


def signed_appid(exe: str, app_name: str) -> int:
    crc = binascii.crc32((exe + app_name).encode("utf-8")) | 0x80000000
    return struct.unpack("<i", struct.pack("<I", crc))[0]


def shortcut_entry(args: argparse.Namespace) -> OrderedDict:
    tag_values: list[str] = []
    for tag in args.tag or ["PhaseZero", "SteamOS"]:
        if tag not in tag_values:
            tag_values.append(tag)
    tags = OrderedDict((str(i), tag) for i, tag in enumerate(tag_values))
    exe = f'"{args.exe}"'
    start_dir = f'"{args.start_dir}"'
    return OrderedDict(
        [
            ("appid", signed_appid(exe, args.app_name)),
            ("AppName", args.app_name),
            ("Exe", exe),
            ("StartDir", start_dir),
            ("icon", args.icon or ""),
            ("ShortcutPath", ""),
            ("LaunchOptions", args.launch_options or ""),
            ("IsHidden", 0),
            ("AllowDesktopConfig", 1),
            ("AllowOverlay", 1),
            ("OpenVR", 0),
            ("Devkit", 0),
            ("DevkitGameID", ""),
            ("DevkitOverrideAppID", 0),
            ("LastPlayTime", 0),
            ("FlatpakAppID", ""),
            ("tags", tags),
        ]
    )


def find_entry(shortcuts: OrderedDict, app_name: str) -> str | None:
    for key, value in shortcuts.items():
        if isinstance(value, OrderedDict) and str(value.get("AppName", "")) == app_name:
            return str(key)
    return None


def cmd_status(args: argparse.Namespace) -> int:
    files = steam_shortcuts_files(Path(args.steam_root).expanduser())
    found = False
    for path in files:
        root = read_vdf(path)
        key = find_entry(root["shortcuts"], args.app_name)
        if key is not None:
            found = True
            print(f"found: {path}:{key}")
    if not files:
        print("shortcuts: missing")
    elif not found:
        print("found: no")
    return 0 if found else 1


def cmd_add(args: argparse.Namespace) -> int:
    files = steam_shortcuts_files(Path(args.steam_root).expanduser())
    if not files:
        print(f"Steam userdata shortcuts not found under {args.steam_root}", file=sys.stderr)
        return 1
    for path in files:
        root = read_vdf(path)
        shortcuts: OrderedDict = root["shortcuts"]
        key = find_entry(shortcuts, args.app_name)
        if key is None:
            numeric = [int(k) for k in shortcuts.keys() if str(k).isdigit()]
            key = str((max(numeric) + 1) if numeric else 0)
        shortcuts[key] = shortcut_entry(args)
        if args.dry_run:
            print(f"dry-run: would write {args.app_name} shortcut to {path}:{key}")
        else:
            write_vdf(path, root)
            print(f"wrote {args.app_name} shortcut to {path}:{key}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["add", "status"])
    parser.add_argument("--steam-root", default=str(Path.home() / ".local/share/Steam"))
    parser.add_argument("--app-name", default="Hydra")
    parser.add_argument("--exe", default="")
    parser.add_argument("--start-dir", default="")
    parser.add_argument("--icon", default="")
    parser.add_argument("--launch-options", default="")
    parser.add_argument("--tag", action="append", default=[])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.action == "status":
        return cmd_status(args)
    if not args.exe or not args.start_dir:
        parser.error("--exe and --start-dir are required for add")
    return cmd_add(args)


if __name__ == "__main__":
    raise SystemExit(main())
