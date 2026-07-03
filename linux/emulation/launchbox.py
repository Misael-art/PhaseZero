#!/usr/bin/env python3
"""Integrate portable LaunchBox with PhaseZero Linux emulation content."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path


ROM_EXTENSIONS = {
    ".3ds",
    ".3dsx",
    ".7z",
    ".a26",
    ".a52",
    ".a78",
    ".adf",
    ".adz",
    ".app",
    ".bin",
    ".ccd",
    ".cdi",
    ".chd",
    ".cso",
    ".cue",
    ".d64",
    ".d88",
    ".dim",
    ".elf",
    ".fds",
    ".fig",
    ".gcm",
    ".gb",
    ".gba",
    ".gbc",
    ".gg",
    ".img",
    ".iso",
    ".lnx",
    ".m3u",
    ".md",
    ".mdf",
    ".n64",
    ".nds",
    ".nes",
    ".ngc",
    ".ngp",
    ".nrg",
    ".nro",
    ".nsp",
    ".nsz",
    ".pbp",
    ".pce",
    ".prg",
    ".rpx",
    ".rvz",
    ".sfc",
    ".smc",
    ".smd",
    ".sms",
    ".st",
    ".tzx",
    ".v64",
    ".vec",
    ".wad",
    ".wbfs",
    ".ws",
    ".wsc",
    ".wua",
    ".wud",
    ".wux",
    ".xdf",
    ".xci",
    ".xex",
    ".zip",
    ".z64",
    ".zar",
}


EMULATOR_TITLE_TO_KEY = {
    "citra": "azahar",
    "azahar": "azahar",
    "cemu": "cemu",
    "pcsx2": "pcsx2",
    "retroarch": "retroarch",
    "retroarch64": "retroarch",
    "vita3k": "vita3k",
    "xemu": "xemu",
    "xenia": "xenia",
    "yuzu": os.environ.get("PZ_LAUNCHBOX_SWITCH_EMULATOR", "eden"),
    "eden": "eden",
    "citron": "citron",
    "ryujinx": "ryujinx",
}


EMULATOR_KEY_TO_BAT = {
    "azahar": "azahar.bat",
    "cemu": "cemu.bat",
    "citron": "citron.bat",
    "duckstation": "duckstation.bat",
    "eden": "eden.bat",
    "pcsx2": "pcsx2.bat",
    "retroarch": "retroarch.bat",
    "rpcs3": "rpcs3.bat",
    "ryujinx": "ryujinx.bat",
    "vita3k": "vita3k.bat",
    "xemu": "xemu.bat",
    "xenia": "xenia.bat",
}


SYSTEM_RULES = [
    ("phasezerofrontends", "frontends"),
    ("microsoftxbox360livearcade", "xbox360"),
    ("microsoftxbox360", "xbox360"),
    ("microsoftxbox", "xbox"),
    ("nintendoswitch", "switch"),
    ("nintendo3ds", "n3ds"),
    ("nintendo64dd", "n64dd"),
    ("nintendo64", "n64"),
    ("nintendods", "nds"),
    ("nintendogameboyadvance", "gba"),
    ("nintendogameboycolor", "gbc"),
    ("nintendogameboy", "gb"),
    ("nintendogamecube", "gc"),
    ("nintendowiiware", "wii"),
    ("nintendowiiu", "wiiu"),
    ("nintendowii", "wii"),
    ("nintendofamicomdisksystem", "fds"),
    ("nintendofamicom", "famicom"),
    ("nintendoentertainmentsystem", "nes"),
    ("supernintendoentertainmentsystem", "snes"),
    ("nintendosuperfamicom", "snesna"),
    ("segamegadrive", "megadrive"),
    ("segagenesis", "genesis"),
    ("segacd", "megacd"),
    ("segadreamcast", "dreamcast"),
    ("segadreamcast", "dreamcast"),
    ("segagamegear", "gamegear"),
    ("segamarkiii", "mark3"),
    ("segamastersystem", "mastersystem"),
    ("samsunggamboy", "mastersystem"),
    ("segamodel2", "model2"),
    ("segamodel3", "model3"),
    ("segasaturn", "saturn"),
    ("segasg1000", "sg-1000"),
    ("snkneogeocd", "neogeocd"),
    ("snkneogeoaes", "neogeo"),
    ("sammyatomiswave", "atomiswave"),
    ("capcomplaysystemiii", "cps3"),
    ("capcomplaysystemii", "cps2"),
    ("capcomplaysystem", "cps1"),
    ("arcade", "arcade"),
    ("3dointeractivemultiplayer", "3do"),
    ("amstradcpc", "amstradcpc"),
    ("atari2600", "atari2600"),
    ("atari5200", "atari5200"),
    ("atari7800", "atari7800"),
    ("atarijaguarcd", "atarijaguarcd"),
    ("atarijaguar", "atarijaguar"),
    ("atarilynx", "atarilynx"),
    ("atarist", "atarist"),
    ("colecovision", "colecovision"),
    ("commodoreamigacd32", "amigacd32"),
    ("commodoreamiga", "amiga"),
    ("commodore64", "c64"),
    ("fujitsufmtowns", "fmtowns"),
    ("microsoftmsxturbor", "msxturbor"),
    ("microsoftmsx2", "msx2"),
    ("microsoftmsx", "msx"),
    ("necpc9801", "pc98"),
    ("necpc8801", "pc88"),
    ("necpc8001", "pc88"),
    ("necpcfx", "pcfx"),
    ("necturbografxcd", "tg-cd"),
    ("necturbografx16", "tg16"),
    ("necpcengine", "pcengine"),
    ("sonyplaystationportable", "psp"),
    ("sonypsp", "psp"),
    ("sonyplaystationvita", "psvita"),
    ("sonyplaystation2", "ps2"),
    ("sonyplaystation", "psx"),
    ("sharpx68000", "x68000"),
    ("sinclairzxspectrum", "zxspectrum"),
]

IGNORED_ALIASES = {"Computers", "Consoles", "Handhelds", "Windows"}
IGNORED_ROM_NAMES = {
    ".directory",
    ".phasezero-managed",
    "metadata.txt",
    "readme.txt",
    "systeminfo.txt",
}
IGNORED_ROM_DIRS = {
    "cache",
    "cache0",
    "cache1",
    "logs",
    "patches",
}
SYSTEM_SOURCE_SUBDIRS = {
    "xbox360": "roms",
}
SPECIAL_SYSTEM_DIRS = {
    "frontends": ("tools", "launchers", "frontends"),
}


def norm(value: str) -> str:
    value = unicodedata.normalize("NFKD", value)
    value = value.encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "", value.lower())


def system_for_alias(alias: str) -> str | None:
    n = norm(alias)
    for needle, system in SYSTEM_RULES:
        if needle in n:
            return system
    return None


def env_path(name: str, default: str) -> Path:
    return Path(os.environ.get(name, default)).expanduser()


class LaunchBoxContext:
    def __init__(self) -> None:
        home = Path.home()
        self.emulation_root = env_path("PZ_EMULATION_ROOT", str(home / "Emulation"))
        self.launchbox_root = env_path(
            "PZ_LAUNCHBOX_ROOT",
            str(self.emulation_root / "tools" / "launchers" / "LaunchBox"),
        )
        self.repo_root = env_path(
            "PZ_ROOT",
            str(Path(__file__).resolve().parents[2]),
        )
        self.compat_roms = env_path(
            "PZ_LAUNCHBOX_COMPAT_ROMS",
            str(self.emulation_root / "tools" / "launchers" / "Roms"),
        )
        self.wrapper_dir = env_path(
            "PZ_LAUNCHBOX_EMULATORS_DIR",
            str(self.emulation_root / "tools" / "launchers" / "emulators" / "PhaseZero"),
        )
        self.backup_dir = self.emulation_root / ".phasezero" / "backups"
        self.media_root = self.emulation_root / "tools" / "downloaded_media"
        self.roms_root = self.emulation_root / "roms"
        self.phasezero_dir = self.launchbox_root / ".phasezero"
        self.drive_root = self.phasezero_dir / "drives"
        self.data_dir = self.launchbox_root / "Data"
        self.emulators_xml = self.data_dir / "Emulators.xml"


def backup_path(path: Path, ctx: LaunchBoxContext, label: str) -> Path:
    ctx.backup_dir.mkdir(parents=True, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label).strip("_") or "launchbox"
    target = ctx.backup_dir / f"launchbox-{safe}-{int(time.time())}-{os.getpid()}"
    if path.exists() or path.is_symlink():
        if path.is_dir() and not path.is_symlink():
            shutil.move(str(path), str(target))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
    return target


def iter_xml_files(ctx: LaunchBoxContext) -> list[Path]:
    files: list[Path] = []
    if ctx.data_dir.exists():
        for item in ("Platforms.xml", "Emulators.xml"):
            path = ctx.data_dir / item
            if path.exists():
                files.append(path)
        platforms = ctx.data_dir / "Platforms"
        if platforms.exists():
            files.extend(sorted(platforms.glob("*.xml")))
    return files


def collect_aliases(ctx: LaunchBoxContext) -> tuple[dict[str, str], set[str]]:
    aliases: dict[str, str] = {}
    unresolved: set[str] = set()
    marker = "..\\Roms\\"

    def add_alias(value: str) -> None:
        value = value.strip().strip("\\/")
        if not value:
            return
        if value in IGNORED_ALIASES:
            return
        system = system_for_alias(value)
        if system:
            aliases.setdefault(value, system)
        else:
            unresolved.add(value)

    for xml_file in iter_xml_files(ctx):
        try:
            tree = ET.parse(xml_file)
        except ET.ParseError:
            continue
        for node in tree.iter():
            if xml_file.name == "Platforms.xml" and node.tag == "Name" and node.text:
                add_alias(node.text)
            if node.tag not in {
                "ApplicationPath",
                "Folder",
                "ManualPath",
                "MusicPath",
                "VideoPath",
                "ThemeVideoPath",
            }:
                continue
            text = (node.text or "").strip()
            if not text:
                continue
            lower = text.lower()
            needle = marker.lower()
            index = lower.find(needle)
            if index >= 0:
                rest = text[index + len(marker) :]
                add_alias(rest.split("\\", 1)[0])
                continue
            if re.match(r"^[Ll]:\\Roms\\", text):
                rest = text[8:]
                add_alias(rest.split("\\", 1)[0])
    return aliases, unresolved


def link_replace(target: Path, link: Path) -> str:
    if link.is_symlink():
        if os.readlink(link) == str(target):
            return "ok"
        link.unlink()
    elif link.exists():
        return "conflict"
    link.symlink_to(target)
    return "linked"


def clear_managed_symlinks(directory: Path) -> None:
    if not (directory / ".phasezero-managed").exists():
        return
    for child in directory.iterdir():
        if child.name == ".phasezero-managed":
            continue
        if child.is_symlink():
            child.unlink()


def source_rom_dir(ctx: LaunchBoxContext, system: str) -> Path:
    special = SPECIAL_SYSTEM_DIRS.get(system)
    if special:
        return ctx.emulation_root.joinpath(*special)
    root = ctx.roms_root / system
    subdir = SYSTEM_SOURCE_SUBDIRS.get(system)
    if subdir and (root / subdir).is_dir():
        return root / subdir
    return root


def has_rom_content(path: Path) -> bool:
    if path.is_file():
        return path.suffix.lower() in ROM_EXTENSIONS
    if not path.is_dir():
        return False
    for root, dirs, files in os.walk(path):
        dirs[:] = [name for name in dirs if name.casefold() not in IGNORED_ROM_DIRS]
        for filename in files:
            if filename.casefold() in IGNORED_ROM_NAMES:
                continue
            if Path(filename).suffix.lower() in ROM_EXTENSIONS:
                return True
    return False


def should_link_rom_entry(path: Path) -> bool:
    folded = path.name.casefold()
    if folded in IGNORED_ROM_NAMES:
        return False
    if path.is_dir() and folded in IGNORED_ROM_DIRS:
        return False
    return has_rom_content(path)


def should_link_entry(path: Path, system: str) -> bool:
    if system == "frontends":
        return path.is_file() and path.suffix.lower() == ".sh"
    return should_link_rom_entry(path)


def ensure_compat_alias(ctx: LaunchBoxContext, alias: str, system: str, apply: bool) -> dict[str, object]:
    alias_dir = ctx.compat_roms / alias
    rom_dir = source_rom_dir(ctx, system)
    media_dir = ctx.media_root / system
    result: dict[str, object] = {
        "alias": alias,
        "system": system,
        "romDir": str(rom_dir),
        "mediaDir": str(media_dir),
        "exists": rom_dir.exists(),
        "links": 0,
        "mediaLinked": False,
        "status": "planned",
    }
    if not apply:
        return result
    if alias_dir.exists() and not alias_dir.is_dir():
        backup_path(alias_dir, ctx, f"compat-{alias}")
    if alias_dir.exists() and alias_dir.is_dir() and not (alias_dir / ".phasezero-managed").exists():
        if any(alias_dir.iterdir()):
            backup_path(alias_dir, ctx, f"compat-{alias}")
    alias_dir.mkdir(parents=True, exist_ok=True)
    (alias_dir / ".phasezero-managed").write_text(
        "Managed by PhaseZero LaunchBox integration. Do not place ROMs here.\n",
        encoding="utf-8",
    )
    clear_managed_symlinks(alias_dir)
    if rom_dir.exists():
        for child in sorted(rom_dir.iterdir(), key=lambda p: p.name.casefold()):
            if child.name == "media":
                continue
            if not should_link_entry(child, system):
                continue
            link = alias_dir / child.name
            status = link_replace(child, link)
            if status in {"linked", "ok"}:
                result["links"] = int(result["links"]) + 1
    if media_dir.exists():
        status = link_replace(media_dir, alias_dir / "media")
        result["mediaLinked"] = status in {"linked", "ok"}
    result["status"] = "applied"
    return result


def ensure_wine_drives(ctx: LaunchBoxContext, apply: bool) -> dict[str, object]:
    drive_f = ctx.drive_root / "F"
    drive_l = ctx.drive_root / "L"
    target_f = drive_f / "@" / "deck" / "Emulation"
    target_l = drive_l / "Roms"
    result = {
        "driveF": str(drive_f),
        "driveL": str(drive_l),
        "legacyFPath": str(target_f),
        "legacyLRoms": str(target_l),
        "applied": False,
    }
    if not apply:
        return result
    target_f.parent.mkdir(parents=True, exist_ok=True)
    if target_f.is_symlink() or target_f.exists():
        if target_f.is_symlink() and os.readlink(target_f) == str(ctx.emulation_root):
            pass
        elif target_f.is_symlink():
            target_f.unlink()
        elif target_f.exists():
            backup_path(target_f, ctx, "drive-f-legacy")
    if not target_f.exists():
        target_f.symlink_to(ctx.emulation_root)

    drive_l.mkdir(parents=True, exist_ok=True)
    if target_l.is_symlink() or target_l.exists():
        if target_l.is_symlink() and os.readlink(target_l) == str(ctx.compat_roms):
            pass
        elif target_l.is_symlink():
            target_l.unlink()
        elif target_l.exists():
            backup_path(target_l, ctx, "drive-l-roms")
    if not target_l.exists():
        target_l.symlink_to(ctx.compat_roms)
    result["applied"] = True
    return result


def write_bat_wrappers(ctx: LaunchBoxContext, apply: bool) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for key, filename in sorted(EMULATOR_KEY_TO_BAT.items()):
        path = ctx.wrapper_dir / filename
        rows.append({"key": key, "path": str(path)})
        if not apply:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        script = ctx.repo_root / "linux" / "emulation" / "launchbox.sh"
        path.write_text(
            "\r\n".join(
                [
                    "@echo off",
                    "setlocal",
                    f'start /wait /unix /usr/bin/env bash "{script}" game {key} %*',
                    "endlocal",
                    "",
                ]
            ),
            encoding="ascii",
            newline="",
        )
    return rows


def parse_xml(path: Path) -> ET.ElementTree | None:
    try:
        return ET.parse(path)
    except (ET.ParseError, FileNotFoundError):
        return None


def write_launchbox_xml(tree: ET.ElementTree, path: Path) -> None:
    ET.indent(tree, space="  ")
    body = ET.tostring(tree.getroot(), encoding="unicode")
    path.write_text('<?xml version="1.0" standalone="yes"?>\n' + body + "\n", encoding="utf-8")


def normalize_emulator_title(title: str) -> str:
    title = title.strip().lower()
    title = title.replace(" ", "")
    return re.sub(r"[^a-z0-9]+", "", title)


def update_emulators_xml(ctx: LaunchBoxContext, apply: bool) -> dict[str, object]:
    changed = 0
    configured: list[dict[str, str]] = []
    tree = parse_xml(ctx.emulators_xml)
    if tree is None:
        return {
            "path": str(ctx.emulators_xml),
            "exists": False,
            "configured": configured,
            "changed": changed,
        }
    for emulator in tree.getroot().findall("Emulator"):
        title = emulator.findtext("Title") or ""
        key = EMULATOR_TITLE_TO_KEY.get(normalize_emulator_title(title))
        if not key:
            continue
        bat = EMULATOR_KEY_TO_BAT.get(key)
        if not bat:
            continue
        app_node = emulator.find("ApplicationPath")
        if app_node is None:
            app_node = ET.SubElement(emulator, "ApplicationPath")
        desired = rf"..\emulators\PhaseZero\{bat}"
        configured.append({"title": title, "key": key, "path": desired})
        if app_node.text != desired:
            changed += 1
            if apply:
                app_node.text = desired
    if apply and changed:
        backup_path(ctx.emulators_xml, ctx, "Emulators.xml")
        write_launchbox_xml(tree, ctx.emulators_xml)
    return {
        "path": str(ctx.emulators_xml),
        "exists": True,
        "configured": configured,
        "changed": changed,
    }


def path_from_launchbox(ctx: LaunchBoxContext, value: str) -> Path | None:
    raw = value.strip().strip('"')
    if not raw or raw.startswith("steam://"):
        return None
    raw = raw.replace("/", "\\")
    lower = raw.lower()
    if lower.startswith("..\\roms\\"):
        rest = raw[8:].replace("\\", "/")
        return ctx.compat_roms / rest
    if re.match(r"^[Ll]:\\Roms\\", raw):
        rest = raw[8:].replace("\\", "/")
        return ctx.compat_roms / rest
    legacy = "f:\\@\\deck\\emulation\\"
    if lower.startswith(legacy):
        rest = raw[len(legacy) :].replace("\\", "/")
        return ctx.emulation_root / rest
    if re.match(r"^[Zz]:\\", raw):
        return Path("/") / raw[3:].replace("\\", "/")
    return None


def sample_path_status(ctx: LaunchBoxContext, limit: int = 400) -> dict[str, object]:
    total = resolved = missing = media_entries = skipped = 0
    examples: list[dict[str, str]] = []
    for xml_file in iter_xml_files(ctx):
        if "Platforms" not in str(xml_file):
            continue
        tree = parse_xml(xml_file)
        if tree is None:
            continue
        for node in tree.iter("ApplicationPath"):
            text = (node.text or "").strip()
            if not text:
                continue
            total += 1
            stop = total >= limit
            if Path(text.replace("\\", "/")).suffix.lower() in {".mp4", ".mkv", ".xml", ".txt"}:
                media_entries += 1
            path = path_from_launchbox(ctx, text)
            if path is None:
                skipped += 1
                if stop:
                    break
                continue
            if path.exists():
                resolved += 1
            else:
                missing += 1
                if len(examples) < 10:
                    examples.append({"source": text, "expected": str(path)})
            if stop:
                break
        if total >= limit:
            break
    return {
        "sampled": total,
        "resolved": resolved,
        "missing": missing,
        "mediaEntries": media_entries,
        "skipped": skipped,
        "missingExamples": examples,
    }


def compat_tree_status(ctx: LaunchBoxContext) -> dict[str, int]:
    managed_aliases = links = media_links = 0
    if not ctx.compat_roms.exists():
        return {"managedAliases": 0, "links": 0, "mediaLinks": 0}
    for alias_dir in ctx.compat_roms.iterdir():
        if not alias_dir.is_dir() or not (alias_dir / ".phasezero-managed").exists():
            continue
        managed_aliases += 1
        for child in alias_dir.iterdir():
            if child.name == ".phasezero-managed":
                continue
            if not child.is_symlink():
                continue
            links += 1
            if child.name == "media":
                media_links += 1
    return {"managedAliases": managed_aliases, "links": links, "mediaLinks": media_links}


def run(action: str, json_output: bool) -> int:
    ctx = LaunchBoxContext()
    apply = action in {"apply", "integrate", "repair"}
    aliases, unresolved = collect_aliases(ctx)
    compat = [
        ensure_compat_alias(ctx, alias, system, apply)
        for alias, system in sorted(aliases.items(), key=lambda item: item[0].casefold())
    ]
    data = {
        "launchboxRoot": str(ctx.launchbox_root),
        "installed": (ctx.launchbox_root / "LaunchBox.exe").exists(),
        "bigBoxInstalled": (ctx.launchbox_root / "BigBox.exe").exists(),
        "compatRoms": str(ctx.compat_roms),
        "wrapperDir": str(ctx.wrapper_dir),
        "aliases": compat,
        "aliasesResolved": len(aliases),
        "aliasesUnresolved": sorted(unresolved),
        "wineDrives": ensure_wine_drives(ctx, apply),
        "batWrappers": write_bat_wrappers(ctx, apply),
        "emulatorsXml": update_emulators_xml(ctx, apply),
        "compatTree": compat_tree_status(ctx),
        "paths": sample_path_status(ctx),
    }
    if json_output:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print("=== LaunchBox Integration ===")
        print(f"  root: {data['launchboxRoot']}")
        print(f"  installed: {data['installed']}")
        print(f"  compat ROMs: {data['compatRoms']}")
        print(f"  aliases: {data['aliasesResolved']} resolved, {len(data['aliasesUnresolved'])} unresolved")
        tree = data["compatTree"]
        print(
            "  compat tree: "
            f"{tree['managedAliases']} managed aliases, "
            f"{tree['links']} links, {tree['mediaLinks']} media links"
        )
        print(f"  wrappers: {len(data['batWrappers'])} planned")
        print(f"  emulators: {len(data['emulatorsXml']['configured'])} configured")
        paths = data["paths"]
        print(
            "  sampled LaunchBox DB paths: "
            f"{paths['resolved']} resolved, {paths['missing']} missing, "
            f"{paths['mediaEntries']} media-like entries"
        )
        if data["aliasesUnresolved"]:
            print("  unresolved aliases:")
            for alias in data["aliasesUnresolved"][:20]:
                print(f"    {alias}")
        if paths["missingExamples"]:
            print("  missing samples:")
            for example in paths["missingExamples"][:5]:
                print(f"    {example['source']} -> {example['expected']}")
    return 0 if data["installed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["status", "plan", "apply", "integrate", "repair"])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    return run(args.action, args.json)


if __name__ == "__main__":
    sys.exit(main())
