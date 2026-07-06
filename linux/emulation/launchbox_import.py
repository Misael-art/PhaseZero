#!/usr/bin/env python3
"""Build a clean LaunchBox data set from the canonical ES-DE library."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


NAMESPACE = uuid.UUID("fd8088e4-8a28-4b7c-935f-e4770d256fa9")
MEDIA_MAP = {
    "covers": ("Images", "Box - Front"),
    "backcovers": ("Images", "Box - Back"),
    "3dboxes": ("Images", "Box - 3D"),
    "fanart": ("Images", "Fanart - Background"),
    "physicalmedia": ("Images", "Cart - Front"),
    "marquees": ("Images", "Clear Logo"),
    "screenshots": ("Images", "Screenshot - Gameplay"),
    "titlescreens": ("Images", "Screenshot - Game Title"),
    "videos": ("Videos", ""),
    "manuals": ("Manuals", ""),
}
DISPLAY_OVERRIDES = {
    "frontends": "PhaseZero Frontends",
    "emulators": "PhaseZero Emulators",
    "sfc": "Nintendo Super Famicom",
    "snes": "Super Nintendo",
    "snesna": "Super Nintendo North America",
    "saturnjp": "Sega Saturn Japan",
    "neogeocdjp": "SNK Neo Geo CD Japan",
}
SYSTEM_LAUNCH = {
    "mastersystem": ("retroarch", "genesis_plus_gx"),
    "genesis": ("retroarch", "genesis_plus_gx"),
    "gamegear": ("retroarch", "genesis_plus_gx"),
    "megadrive": ("retroarch", "genesis_plus_gx"),
    "sfc": ("retroarch", "snes9x"),
    "snes": ("retroarch", "snes9x"),
    "snesna": ("retroarch", "snes9x"),
    "saturn": ("retroarch", "mednafen_saturn"),
    "saturnjp": ("retroarch", "mednafen_saturn"),
    "x68000": ("retroarch", "px68k"),
    "naomi": ("flycast", ""),
    "dreamcast": ("flycast", ""),
    "atomiswave": ("flycast", ""),
    "sega32xna": ("retroarch", "picodrive"),
    "neogeocdjp": ("retroarch", "neocd"),
    "switch": ("eden", ""),
    "psx": ("duckstation", ""),
    "n3ds": ("azahar", ""),
    "ps2": ("pcsx2", ""),
    "ps3": ("rpcs3", ""),
    "wii": ("dolphin", ""),
    "wiiu": ("cemu", ""),
    "model2": ("model2", ""),
    "model3": ("supermodel", ""),
    "steam": ("shell", ""),
    "frontends": ("shell", ""),
    "emulators": ("shell", ""),
}
ARCADE = {"atomiswave", "model2", "model3", "naomi"}
HANDHELDS = {"gamegear", "n3ds"}
COMPUTERS = {"emulators", "frontends", "steam", "x68000"}


@dataclass(frozen=True)
class System:
    key: str
    name: str
    rom_dir: Path
    extensions: frozenset[str]


@dataclass
class Game:
    system: System
    path: Path
    title: str
    metadata: dict[str, str]


def env_path(name: str, default: Path) -> Path:
    return Path(os.environ.get(name, str(default))).expanduser()


def write_xml(root: ET.Element, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    body = ET.tostring(root, encoding="unicode")
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        '<?xml version="1.0" standalone="yes"?>\n' + body + "\n",
        encoding="utf-8",
    )
    os.replace(tmp, path)


def text(node: ET.Element | None) -> str:
    return (node.text or "").strip() if node is not None else ""


def esde_settings(home: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    path = home / "ES-DE" / "settings" / "es_settings.xml"
    try:
        root = ET.parse(path).getroot()
    except (FileNotFoundError, ET.ParseError):
        return values
    for node in root:
        name = node.attrib.get("name", "")
        value = node.attrib.get("value", "")
        if name:
            values[name] = value
    return values


def builtin_systems_xml(home: Path) -> str:
    explicit = os.environ.get("PZ_ESDE_SYSTEMS_XML")
    if explicit:
        return Path(explicit).read_text(encoding="utf-8")
    appimage = env_path("PZ_ESDE_APPIMAGE", home / "Applications" / "ES-DE.AppImage")
    if not appimage.is_file():
        raise RuntimeError(f"ES-DE AppImage missing: {appimage}")
    offset = subprocess.check_output(
        [str(appimage), "--appimage-offset"], text=True, timeout=30
    ).strip()
    return subprocess.check_output(
        [
            "unsquashfs",
            "-o",
            offset,
            "-cat",
            str(appimage),
            "usr/share/es-de/resources/systems/linux/es_systems.xml",
        ],
        text=True,
        stderr=subprocess.DEVNULL,
        timeout=60,
    )


def parse_system_nodes(content: str) -> list[ET.Element]:
    try:
        return list(ET.fromstring(content).findall(".//system"))
    except ET.ParseError as exc:
        raise RuntimeError(f"invalid ES-DE systems XML: {exc}") from exc


def load_systems(home: Path, rom_root: Path) -> list[System]:
    nodes = parse_system_nodes(builtin_systems_xml(home))
    by_key = {text(node.find("name")): node for node in nodes}
    custom_paths = [
        home / "ES-DE" / "custom_systems" / "es_systems.xml",
        home / ".emulationstation" / "custom_systems" / "es_systems.xml",
    ]
    for path in custom_paths:
        if not path.is_file():
            continue
        try:
            custom = ET.parse(path).getroot()
        except ET.ParseError:
            continue
        for node in custom.findall(".//system"):
            key = text(node.find("name"))
            if key:
                by_key[key] = node

    systems: list[System] = []
    for key, node in by_key.items():
        if not key:
            continue
        raw_path = text(node.find("path")).replace("%ROMPATH%", str(rom_root))
        raw_path = os.path.expandvars(os.path.expanduser(raw_path))
        extension_text = text(node.find("extension"))
        extensions = frozenset(
            token.casefold() for token in extension_text.split() if token.startswith(".")
        )
        if not raw_path or not extensions:
            continue
        name = DISPLAY_OVERRIDES.get(key, text(node.find("fullname")) or key)
        systems.append(System(key, name, Path(raw_path), extensions))
    return sorted(systems, key=lambda item: item.key.casefold())


def tolerant_gamelist(path: Path) -> list[ET.Element]:
    if not path.is_file():
        return []
    raw = path.read_text(encoding="utf-8", errors="replace")
    raw = re.sub(r"^\s*<\?xml[^>]*\?>", "", raw, count=1)
    try:
        root = ET.fromstring(raw)
        return list(root.findall(".//game"))
    except ET.ParseError:
        try:
            root = ET.fromstring(f"<phasezero>{raw}</phasezero>")
            return list(root.findall(".//game"))
        except ET.ParseError:
            return []


def metadata_for(system: System, metadata_root: Path) -> dict[Path, dict[str, str]]:
    path = metadata_root / system.key / "gamelist.xml"
    rows: dict[Path, dict[str, str]] = {}
    for game in tolerant_gamelist(path):
        game_path = text(game.find("path"))
        if not game_path:
            continue
        resolved = Path(game_path)
        if not resolved.is_absolute():
            resolved = system.rom_dir / resolved
        values = {child.tag: text(child) for child in game}
        rows[resolved.resolve(strict=False)] = values
    return rows


def iter_launchable(system: System) -> list[Path]:
    if not system.rom_dir.is_dir():
        return []
    rows: list[Path] = []
    for path in system.rom_dir.rglob("*"):
        if path.name.startswith("."):
            continue
        suffix = path.suffix.casefold()
        if path.is_file() and suffix in system.extensions:
            rows.append(path)
        elif path.is_dir() and suffix in system.extensions:
            rows.append(path)
    return sorted(rows, key=lambda item: str(item).casefold())


def select_games(system: System, metadata_root: Path) -> list[Game]:
    metadata = metadata_for(system, metadata_root)
    candidates = iter_launchable(system)
    selected: list[Game] = []
    cue_stems = {
        path.with_suffix("").resolve(strict=False)
        for path in candidates
        if path.suffix.casefold() in {".cue", ".m3u"}
    }
    for path in candidates:
        if path.suffix.casefold() == ".bin" and path.with_suffix("").resolve(strict=False) in cue_stems:
            continue
        values = metadata.get(path.resolve(strict=False), {})
        title = values.get("name") or path.stem
        selected.append(Game(system, path, title, values))
    return selected


def category_for(key: str) -> str:
    if key in ARCADE:
        return "Arcade"
    if key in HANDHELDS:
        return "Handhelds"
    if key in COMPUTERS:
        return "Computers"
    return "Consoles"


def stable_id(kind: str, value: str) -> str:
    return str(uuid.uuid5(NAMESPACE, f"{kind}:{value}"))


def add_text(parent: ET.Element, tag: str, value: str) -> None:
    ET.SubElement(parent, tag).text = value


def game_node(game: Game, emulator_id: str) -> ET.Element:
    node = ET.Element("Game")
    relative = game.path.relative_to(game.system.rom_dir)
    app_path = rf"..\Roms\{game.system.name}\{str(relative).replace('/', chr(92))}"
    game_id = stable_id("game", f"{game.system.key}:{relative.as_posix()}")
    add_text(node, "ApplicationPath", app_path)
    add_text(node, "CommandLine", "")
    add_text(node, "ConfigurationPath", "")
    add_text(node, "Emulator", emulator_id)
    add_text(node, "ID", game_id)
    add_text(node, "Title", game.title)
    add_text(node, "Platform", game.system.name)
    add_text(node, "SortTitle", game.title)
    add_text(node, "Notes", game.metadata.get("desc", ""))
    add_text(node, "Developer", game.metadata.get("developer", ""))
    add_text(node, "Publisher", game.metadata.get("publisher", ""))
    add_text(node, "Genre", game.metadata.get("genre", ""))
    add_text(node, "ReleaseDate", game.metadata.get("releasedate", ""))
    add_text(node, "PlayMode", game.metadata.get("players", ""))
    add_text(node, "Favorite", str(game.metadata.get("favorite", "") == "true").lower())
    add_text(node, "Completed", str(game.metadata.get("completed", "") == "true").lower())
    rating = game.metadata.get("rating", "")
    try:
        rating = f"{float(rating) * 5:g}" if rating else ""
    except ValueError:
        rating = ""
    add_text(node, "CommunityStarRating", rating)
    add_text(node, "UseDosBox", "false")
    add_text(node, "UseScummVm", "false")
    add_text(node, "Hide", "false")
    add_text(node, "Broken", "false")
    return node


def replace_managed_dir(path: Path) -> None:
    if path.exists() and not path.is_dir():
        raise RuntimeError(f"managed path is not a directory: {path}")
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def unique_media_name(directory: Path, title: str, source: Path) -> Path:
    safe = re.sub(r'[<>:"/\\|?*]', "_", title).strip().rstrip(".") or source.stem
    candidate = directory / f"{safe}{source.suffix.lower()}"
    if not candidate.exists() and not candidate.is_symlink():
        return candidate
    token = stable_id("media", str(source))[:8]
    candidate = directory / f"{safe} ({token}){source.suffix.lower()}"
    index = 2
    while candidate.exists() or candidate.is_symlink():
        candidate = directory / f"{safe} ({token}-{index}){source.suffix.lower()}"
        index += 1
    return candidate


def link_media(root: Path, media_root: Path, games: list[Game]) -> int:
    linked = 0
    by_system: dict[str, list[Game]] = {}
    for game in games:
        by_system.setdefault(game.system.key, []).append(game)
    for rows in by_system.values():
        platform = rows[0].system.name
        for target_kind in {value[0] for value in MEDIA_MAP.values()}:
            platform_dir = root / target_kind / platform
            marker = platform_dir / ".phasezero-managed"
            if platform_dir.exists():
                if not marker.is_file():
                    raise RuntimeError(f"refusing to replace unmanaged media directory: {platform_dir}")
                shutil.rmtree(platform_dir)
            platform_dir.mkdir(parents=True, exist_ok=True)
            marker.write_text("Managed by PhaseZero ES-DE import.\n", encoding="utf-8")
    for key, rows in by_system.items():
        platform = rows[0].system.name
        for source_kind, (target_kind, target_subdir) in MEDIA_MAP.items():
            source_dir = media_root / key / source_kind
            if not source_dir.is_dir():
                continue
            target_dir = root / target_kind / platform
            if target_subdir:
                target_dir /= target_subdir
            target_dir.mkdir(parents=True, exist_ok=True)
            source_by_stem = {
                p.stem.casefold(): p
                for p in sorted(source_dir.iterdir(), key=lambda item: item.name.casefold())
                if p.is_file()
            }
            for game in rows:
                source = source_by_stem.get(game.path.stem.casefold())
                if source is None:
                    continue
                target = unique_media_name(target_dir, game.title, source)
                target.symlink_to(source)
                linked += 1
    return linked


def write_compat_roms(compat_root: Path, systems: list[System]) -> int:
    links = 0
    compat_root.mkdir(parents=True, exist_ok=True)
    for system in systems:
        alias = compat_root / system.name
        if alias.exists() and not (alias / ".phasezero-managed").is_file():
            raise RuntimeError(f"refusing to replace unmanaged ROM alias: {alias}")
        replace_managed_dir(alias)
        (alias / ".phasezero-managed").write_text(
            "Managed by PhaseZero. Canonical content remains in ES-DE ROM path.\n",
            encoding="utf-8",
        )
        for source in iter_launchable(system):
            relative = source.relative_to(system.rom_dir)
            target = alias / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(source)
            links += 1
    return links


def write_data(root: Path, systems: list[System], games: list[Game]) -> dict[str, int]:
    data = root / "Data"
    replace_managed_dir(data)
    platforms_root = ET.Element("LaunchBox")
    parents_root = ET.Element("LaunchBox")
    emulators_root = ET.Element("LaunchBox")
    categories = ("Arcade", "Computers", "Consoles", "Handhelds")
    for category in categories:
        node = ET.SubElement(platforms_root, "PlatformCategory")
        add_text(node, "Name", category)
        add_text(node, "NestedName", category)

    emulator_ids: dict[str, str] = {}
    for system in systems:
        emulator_id = stable_id("emulator", system.key)
        emulator_ids[system.key] = emulator_id
        platform_id = stable_id("platform", system.key)
        platform = ET.SubElement(platforms_root, "Platform")
        add_text(platform, "Name", system.name)
        add_text(platform, "NestedName", system.name)
        add_text(platform, "Category", category_for(system.key))
        add_text(platform, "ScrapeAs", system.name)
        add_text(platform, "SortTitle", system.name)
        add_text(platform, "StartupFile", "")
        add_text(platform, "Notes", f"Imported from ES-DE system {system.key}")
        add_text(platform, "Id", platform_id)

        parent = ET.SubElement(parents_root, "Parent")
        add_text(parent, "PlatformName", system.name)
        add_text(parent, "PlaylistId", "")
        add_text(parent, "PlatformCategoryName", "")
        add_text(parent, "ParentPlatformName", "")
        add_text(parent, "ParentPlaylistId", "")
        add_text(parent, "ParentPlatformCategoryName", category_for(system.key))

        emulator_platform = ET.SubElement(emulators_root, "EmulatorPlatform")
        add_text(emulator_platform, "EmulatorId", emulator_id)
        add_text(emulator_platform, "Platform", system.name)
        add_text(emulator_platform, "CommandLine", system.key)
        add_text(emulator_platform, "UseFilenameWithoutExtension", "false")
        add_text(emulator_platform, "UseMameFiles", "false")

        emulator = ET.SubElement(emulators_root, "Emulator")
        add_text(emulator, "ID", emulator_id)
        add_text(emulator, "Title", f"PhaseZero - {system.name}")
        add_text(emulator, "ApplicationPath", r"..\emulators\PhaseZero\system.bat")
        add_text(emulator, "CommandLine", "")
        add_text(emulator, "DefaultPlatform", system.name)
        add_text(emulator, "NoQuotes", "false")

    grouped: dict[str, list[Game]] = {}
    for game in games:
        grouped.setdefault(game.system.key, []).append(game)
    for system in systems:
        platform_games = ET.Element("LaunchBox")
        for game in grouped.get(system.key, []):
            platform_games.append(game_node(game, emulator_ids[system.key]))
        write_xml(platform_games, data / "Platforms" / f"{system.name}.xml")

    write_xml(platforms_root, data / "Platforms.xml")
    write_xml(parents_root, data / "Parents.xml")
    write_xml(emulators_root, data / "Emulators.xml")
    return {"platforms": len(systems), "games": len(games)}


def write_bridge(root: Path, repo_root: Path) -> Path:
    wrapper = root.parent / "emulators" / "PhaseZero" / "system.bat"
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    script = repo_root / "linux" / "emulation" / "launchbox.sh"
    wrapper.write_text(
        "\r\n".join(
            [
                "@echo off",
                "setlocal",
                f'start /wait /unix /usr/bin/env bash "{script}" system %*',
                "endlocal",
                "",
            ]
        ),
        encoding="ascii",
        newline="",
    )
    return wrapper


def import_esde(json_output: bool) -> int:
    home = Path.home()
    settings = esde_settings(home)
    emulation_root = env_path("PZ_EMULATION_ROOT", home / "Emulation")
    root = env_path("PZ_LAUNCHBOX_ROOT", emulation_root / "tools" / "launchers" / "LaunchBox")
    rom_root = env_path(
        "PZ_ESDE_ROM_ROOT",
        Path(settings.get("ROMDirectory", str(emulation_root / "roms"))),
    )
    media_root = env_path(
        "PZ_ESDE_MEDIA_ROOT",
        Path(settings.get("MediaDirectory", str(emulation_root / "tools" / "downloaded_media"))),
    )
    metadata_root = env_path("PZ_ESDE_METADATA_ROOT", emulation_root / "metadata" / "gamelists")
    compat_root = env_path(
        "PZ_LAUNCHBOX_COMPAT_ROMS", emulation_root / "tools" / "launchers" / "Roms"
    )
    repo_root = env_path("PZ_ROOT", Path(__file__).resolve().parents[2])

    all_systems = load_systems(home, rom_root)
    systems = [system for system in all_systems if iter_launchable(system)]
    games = [game for system in systems for game in select_games(system, metadata_root)]
    stats = write_data(root, systems, games)
    stats["romLinks"] = write_compat_roms(compat_root, systems)
    stats["mediaLinks"] = link_media(root, media_root, games)
    bridge = write_bridge(root, repo_root)
    report = {
        **stats,
        "launchboxRoot": str(root),
        "romRoot": str(rom_root),
        "mediaRoot": str(media_root),
        "bridge": str(bridge),
        "systems": {system.key: len(select_games(system, metadata_root)) for system in systems},
    }
    report_path = root / ".phasezero" / "esde-import.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if json_output:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(
            f"LaunchBox ES-DE import: {stats['platforms']} platforms, "
            f"{stats['games']} games, {stats['mediaLinks']} media links"
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["import-esde"])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    return import_esde(args.json)


if __name__ == "__main__":
    sys.exit(main())
