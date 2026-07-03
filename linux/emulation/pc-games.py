#!/usr/bin/env python3
"""Discover local PC games and expose them to Linux gaming frontends."""
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import unicodedata
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


EXCLUDED_FILE_PREFIXES = (
    "unins",
    "uninstall",
    "setup",
    "install",
    "installer",
    "unitycrashhandler",
    "crashhandler",
    "vc_redist",
    "vcredist",
    "dxsetup",
    "dotnet",
    "oalinst",
)
EXCLUDED_FILE_NAMES = {
    "metadata.txt",
    "systeminfo.txt",
    "steam_appid.txt",
    "local_save.txt",
    "desktop.ini",
}
EXCLUDED_DIR_NAMES = {
    ".git",
    ".hg",
    ".svn",
    "media",
    "metadata",
    "tools",
    "cache",
    "caches",
    "redist",
    "redistributables",
    "support",
    "manuals",
    "soundtrack",
    "wallpapers",
    "screenshots",
    "videos",
    "mods",
    "dlc",
    "update",
    "updates",
    "patches",
    "saves",
    "backup",
    "backups",
    "temp",
    "tmp",
    "__pycache__",
}
SCRIPT_EXTENSIONS = {".sh"}
DESKTOP_EXTENSIONS = {".desktop"}
WINDOWS_EXTENSIONS = {".exe", ".bat", ".cmd"}
NATIVE_EXTENSIONS = {".appimage"}
ROOT_FILE_EXTENSIONS = SCRIPT_EXTENSIONS | DESKTOP_EXTENSIONS | WINDOWS_EXTENSIONS | NATIVE_EXTENSIONS
GENERATED_MARKER = "X-PhaseZero-PC-Game=true"


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def norm_name(value: str) -> str:
    value = unicodedata.normalize("NFKD", value)
    value = value.encode("ascii", "ignore").decode("ascii")
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return " ".join(value.split())


def slugify(value: str, fallback: str) -> str:
    base = norm_name(value).replace(" ", "-").strip("-")
    if not base:
        base = "game-" + hashlib.sha1(fallback.encode("utf-8", "ignore")).hexdigest()[:10]
    return base[:90].strip("-") or "game"


def title_from_path(path: Path) -> str:
    if path.is_file():
        return path.stem
    return path.name


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    except Exception:
        return default


def write_json(path: Path, data: Any, dry_run: bool = False, backup: bool = True) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if backup and path.exists():
        shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def write_text(path: Path, text: str, mode: int = 0o644, dry_run: bool = False, backup: bool = True) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if backup and path.exists() and path.read_text(encoding="utf-8", errors="replace") != text:
        shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, mode)
    tmp.replace(path)
    os.chmod(path, mode)


def is_generated_desktop(path: Path) -> bool:
    try:
        return GENERATED_MARKER in path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return False


def is_aux_dir(path: Path) -> bool:
    name = path.name.lower()
    if name.startswith(".phasezero"):
        return True
    if name.endswith("_data") or name.endswith("_data".lower()):
        return True
    return name in EXCLUDED_DIR_NAMES


def is_bad_file(path: Path) -> bool:
    name = path.name.lower()
    stem = path.stem.lower()
    if name in EXCLUDED_FILE_NAMES:
        return True
    if name.startswith("."):
        return True
    if path.suffix.lower() in {".dll", ".ini", ".txt", ".dat", ".pak", ".bin", ".sav", ".url", ".lnk"}:
        return True
    if any(stem.startswith(prefix) for prefix in EXCLUDED_FILE_PREFIXES):
        return True
    if path.suffix.lower() == ".desktop" and is_generated_desktop(path):
        return True
    return False


def same_title_score(title: str, candidate: Path) -> int:
    title_norm = norm_name(title)
    cand_norm = norm_name(candidate.stem)
    if not title_norm or not cand_norm:
        return 0
    if cand_norm == title_norm:
        return 80
    if cand_norm.startswith(title_norm) or title_norm.startswith(cand_norm):
        return 45
    title_tokens = set(title_norm.split())
    cand_tokens = set(cand_norm.split())
    if title_tokens and cand_tokens:
        overlap = len(title_tokens & cand_tokens)
        if overlap:
            return min(35, overlap * 10)
    return 0


@dataclass
class Candidate:
    path: Path
    runner: str
    score: int
    args: list[str] = field(default_factory=list)
    source: str = "scan"


@dataclass
class Game:
    slug: str
    title: str
    root: Path
    target: Path
    runner: str
    args: list[str]
    source: str
    confidence: int
    launch_script: Path
    desktop_file: Path
    menu_file: Path
    wine_prefix: Path
    warnings: list[str] = field(default_factory=list)

    def to_json(self) -> dict[str, Any]:
        return {
            "slug": self.slug,
            "title": self.title,
            "root": str(self.root),
            "target": str(self.target),
            "runner": self.runner,
            "args": self.args,
            "source": self.source,
            "confidence": self.confidence,
            "launchScript": str(self.launch_script),
            "desktopFile": str(self.desktop_file),
            "menuFile": str(self.menu_file),
            "winePrefix": str(self.wine_prefix),
            "warnings": self.warnings,
        }


@dataclass
class Context:
    repo_root: Path
    home: Path
    xdg_config_home: Path
    xdg_data_home: Path
    emulation_root: Path
    applications_dir: Path
    local_bin: Path
    desktop_dir: Path
    state_dir: Path
    steam_root: Path

    @property
    def steam_roms(self) -> Path:
        return self.emulation_root / "roms" / "steam"

    @property
    def pc_tools(self) -> Path:
        return self.emulation_root / "tools" / "pc-games"

    @property
    def launchers_dir(self) -> Path:
        return self.pc_tools / "launchers"

    @property
    def desktops_dir(self) -> Path:
        return self.pc_tools / "desktops"

    @property
    def catalog_path(self) -> Path:
        return self.emulation_root / "metadata" / "pc-games" / "catalog.json"

    @property
    def gamelist_path(self) -> Path:
        return self.emulation_root / "metadata" / "gamelists" / "steam" / "gamelist.xml"

    @property
    def wine_prefix_root(self) -> Path:
        return self.emulation_root / "storage" / "pc-prefixes"

    @property
    def launcher_bin(self) -> Path:
        return self.local_bin / "phasezero-pc-game-launch"


def context_from_env() -> Context:
    home = Path(os.environ.get("HOME", str(Path.home()))).expanduser()
    repo_root = Path(os.environ.get("PZ_ROOT", Path(__file__).resolve().parents[2]))
    xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    xdg_data = Path(os.environ.get("XDG_DATA_HOME", home / ".local" / "share"))
    emu = Path(os.environ.get("PZ_EMULATION_ROOT", home / "Emulation"))
    apps = Path(os.environ.get("PZ_APPLICATIONS_DIR", home / "Applications"))
    local_bin = Path(os.environ.get("PZ_LOCAL_BIN", home / ".local" / "bin"))
    desktop = xdg_data / "applications"
    state = xdg_config / "phasezero" / "emulation"
    steam_root = Path(os.environ.get("STEAM_ROOT", home / ".local" / "share" / "Steam"))
    return Context(repo_root, home, xdg_config, xdg_data, emu, apps, local_bin, desktop, state, steam_root)


def primary_gog_task(root: Path) -> Candidate | None:
    for info in sorted(root.glob("goggame-*.info")):
        data = load_json(info, {})
        if not isinstance(data, dict):
            continue
        tasks = data.get("playTasks") or []
        if not isinstance(tasks, list):
            continue
        preferred = [task for task in tasks if isinstance(task, dict) and task.get("category") == "game"]
        preferred.sort(key=lambda t: 0 if t.get("isPrimary") else 1)
        for task in preferred:
            rel = task.get("path")
            if not rel:
                continue
            target = root / str(rel)
            if not target.exists():
                continue
            args = shlex.split(str(task.get("arguments") or ""))
            runner = runner_for_target(target)
            return Candidate(target, runner, 1000, args, "gog-playtask")
    return None


def runner_for_target(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".desktop":
        return "desktop"
    if suffix == ".sh":
        return "script"
    if suffix in WINDOWS_EXTENSIONS:
        return "wine"
    if suffix == ".appimage":
        return "native"
    if os.access(path, os.X_OK):
        return "native"
    return "script"


def candidate_score(title: str, path: Path, depth: int) -> Candidate | None:
    if is_bad_file(path):
        return None
    suffix = path.suffix.lower()
    if suffix == ".sh":
        declared = script_declared_target(path, title, depth)
        if declared:
            return declared
    runner = runner_for_target(path)
    score = same_title_score(title, path) - (depth * 8)
    if suffix == ".sh":
        score += 760
    elif suffix == ".desktop":
        score += 720
    elif suffix == ".appimage":
        score += 700
    elif suffix == ".exe":
        score += 640
    elif suffix in {".bat", ".cmd"}:
        score += 580
    elif os.access(path, os.X_OK):
        score += 620
    else:
        return None
    stem = path.stem.lower()
    if "launcher" in stem:
        score -= 90
    if "config" in stem or "settings" in stem:
        score -= 160
    if path.parent.name.lower().endswith("_data"):
        score -= 500
    return Candidate(path, runner, score, [], "scan")


def script_declared_target(path: Path, title: str, depth: int) -> Candidate | None:
    try:
        text = "\n".join(path.read_text(encoding="utf-8", errors="replace").splitlines()[:80])
    except Exception:
        return None
    game_name = re.search(r'^\s*GAMENAME=["\']?([^"\'\n]+)["\']?', text, re.M)
    game_path = re.search(r'^\s*GAMEPATH=["\']?([^"\'\n]+)["\']?', text, re.M)
    if not game_name:
        return None
    rel_dir = game_path.group(1).strip() if game_path else "."
    target = (path.parent / rel_dir / game_name.group(1).strip()).resolve()
    if not target.exists() or target.suffix.lower() not in WINDOWS_EXTENSIONS:
        return None
    score = 820 + same_title_score(title, path) - (depth * 8)
    return Candidate(target, "wine", score, [], "shell-gamename")


def walk_candidate_files(root: Path, max_depth: int = 4) -> list[tuple[Path, int]]:
    out: list[tuple[Path, int]] = []
    root_depth = len(root.parts)
    for current, dirs, files in os.walk(root):
        cur = Path(current)
        depth = len(cur.parts) - root_depth
        dirs[:] = [d for d in dirs if depth < max_depth and not is_aux_dir(cur / d)]
        if depth > max_depth:
            continue
        for name in files:
            path = cur / name
            suffix = path.suffix.lower()
            if suffix in ROOT_FILE_EXTENSIONS or os.access(path, os.X_OK):
                out.append((path, depth))
    return out


def override_for_root(root: Path) -> dict[str, Any]:
    if root.is_dir():
        return load_json(root / "phasezero-pc.json", {})
    return {}


def select_candidate(root: Path, title: str) -> Candidate | None:
    override = override_for_root(root)
    if isinstance(override, dict):
        if override.get("skip") is True:
            return None
        rel = override.get("executable") or override.get("launcher")
        if rel:
            target = (root / str(rel)).resolve() if not Path(str(rel)).is_absolute() else Path(str(rel))
            if target.exists():
                runner = str(override.get("runner") or runner_for_target(target))
                args = [str(x) for x in override.get("args", [])] if isinstance(override.get("args"), list) else []
                return Candidate(target, runner, 1200, args, "override")

    if root.is_file():
        return candidate_score(title, root, 0)

    gog = primary_gog_task(root)
    if gog:
        return gog

    candidates: list[Candidate] = []
    for path, depth in walk_candidate_files(root):
        cand = candidate_score(title, path, depth)
        if cand:
            candidates.append(cand)
    if not candidates:
        return None
    candidates.sort(key=lambda c: (c.score, -len(c.path.parts)), reverse=True)
    return candidates[0]


def discover_games(ctx: Context) -> list[Game]:
    if not ctx.steam_roms.exists():
        return []
    found: dict[str, Game] = {}
    for item in sorted(ctx.steam_roms.iterdir(), key=lambda p: p.name.casefold()):
        if item.name.startswith(".") or is_aux_dir(item):
            continue
        if item.is_file() and item.suffix.lower() not in ROOT_FILE_EXTENSIONS:
            continue
        title = title_from_path(item)
        override = override_for_root(item)
        if isinstance(override, dict) and override.get("title"):
            title = str(override["title"])
        cand = select_candidate(item, title)
        if not cand:
            continue
        slug = slugify(title, str(item))
        wine_prefix = ctx.wine_prefix_root / slug
        game = Game(
            slug=slug,
            title=title,
            root=item,
            target=cand.path,
            runner=cand.runner,
            args=cand.args,
            source=cand.source,
            confidence=cand.score,
            launch_script=ctx.launchers_dir / f"{slug}.sh",
            desktop_file=ctx.desktops_dir / f"{slug}.desktop",
            menu_file=ctx.desktop_dir / f"phasezero-pc-{slug}.desktop",
            wine_prefix=wine_prefix,
        )
        if cand.score < 650:
            game.warnings.append("low-confidence-launcher")
        previous = found.get(slug)
        if previous is None or (game.confidence, -len(str(game.root))) > (previous.confidence, -len(str(previous.root))):
            found[slug] = game
    return sorted(found.values(), key=lambda g: g.title.casefold())


def shell_quote(value: str | Path) -> str:
    return shlex.quote(str(value))


def launch_script_text(ctx: Context, game: Game) -> str:
    return f"""#!/usr/bin/env bash
set -euo pipefail
exec {shell_quote(ctx.launcher_bin)} {shell_quote(game.slug)} "$@"
"""


def desktop_text(ctx: Context, game: Game) -> str:
    icon = ctx.emulation_root / "media" / "icons" / "phasezero" / "pc-game.svg"
    return f"""[Desktop Entry]
Type=Application
Name={game.title}
Comment=PC game managed by PhaseZero
Exec={game.launch_script}
Path={game.root if game.root.is_dir() else game.root.parent}
Terminal=false
Icon={icon}
Categories=Game;X-PhaseZero-PC;
NoDisplay=true
StartupNotify=false
X-PhaseZero-Managed=true
X-PhaseZero-PC-Game=true
X-PhaseZero-Slug={game.slug}
"""


def launcher_bin_text(ctx: Context) -> str:
    return f"""#!/usr/bin/env bash
set -euo pipefail
exec python3 {shell_quote(ctx.repo_root / "linux" / "emulation" / "pc-games.py")} launch "$@"
"""


def catalog_json(ctx: Context, games: list[Game]) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "generatedAt": now_iso(),
        "policy": "local-user-owned-games-only",
        "root": str(ctx.steam_roms),
        "launchersDir": str(ctx.launchers_dir),
        "desktopsDir": str(ctx.desktops_dir),
        "heroicLibrary": str(ctx.xdg_config_home / "heroic" / "sideload_apps" / "library.json"),
        "hydraEmulatorsConfig": str(ctx.xdg_config_home / "hydralauncher" / "emulators_config.json"),
        "gamelist": str(ctx.gamelist_path),
        "games": [game.to_json() for game in games],
    }


def first_media_uri(ctx: Context, game: Game, kinds: list[str]) -> str | None:
    names = {
        game.title.casefold(),
        game.root.name.casefold(),
        game.slug.casefold(),
        norm_name(game.title).casefold(),
    }
    roots = [
        ctx.emulation_root / "tools" / "downloaded_media" / "steam",
        ctx.emulation_root / "media" / "steamgrid" / "steam",
    ]
    for root in roots:
        for kind in kinds:
            folder = root / kind
            if not folder.is_dir():
                continue
            for path in sorted(folder.iterdir(), key=lambda item: item.name.casefold()):
                if not path.is_file():
                    continue
                stems = {path.stem.casefold(), norm_name(path.stem).casefold()}
                if names & stems:
                    return path.resolve().as_uri()
    return None


def heroic_art(ctx: Context, game: Game) -> dict[str, str]:
    square = first_media_uri(ctx, game, ["covers", "3dboxes", "miximages", "grid", "icon"])
    cover = first_media_uri(ctx, game, ["fanart", "screenshots", "titlescreens", "hero", "miximages", "covers"])
    data: dict[str, str] = {}
    if square:
        data["art_square"] = square
    if cover:
        data["art_cover"] = cover
    elif square:
        data["art_cover"] = square
    return data


def esde_system_block(ctx: Context, flatpak: bool = False) -> ET.Element:
    system = ET.Element("system")
    values = {
        "name": "steam",
        "fullname": "PC Games",
        "path": str(ctx.launchers_dir),
        "extension": ".sh .SH",
        "platform": "pc",
        "theme": "steam",
    }
    for key in ["name", "fullname", "path", "extension"]:
        child = ET.SubElement(system, key)
        child.text = values[key]
    command = ET.SubElement(system, "command")
    command.set("label", "PhaseZero PC Launcher")
    if flatpak:
        command.text = "flatpak-spawn --host /bin/bash %ROM%"
    else:
        command.text = "/bin/bash %ROM%"
    for key in ["platform", "theme"]:
        child = ET.SubElement(system, key)
        child.text = values[key]
    return system


def indent_xml(elem: ET.Element, level: int = 0) -> None:
    pad = "\n" + level * "  "
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = pad + "  "
        for child in elem:
            indent_xml(child, level + 1)
        if not child.tail or not child.tail.strip():
            child.tail = pad
    if level and (not elem.tail or not elem.tail.strip()):
        elem.tail = pad


def upsert_esde_system(path: Path, ctx: Context, flatpak: bool, dry_run: bool) -> None:
    if path.exists():
        try:
            tree = ET.parse(path)
            root = tree.getroot()
        except ET.ParseError:
            backup = path.with_name(f"{path.name}.invalid.{int(time.time())}.bak")
            if not dry_run:
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, backup)
            root = ET.Element("systemList")
            tree = ET.ElementTree(root)
    else:
        root = ET.Element("systemList")
        tree = ET.ElementTree(root)
    if root.tag != "systemList":
        root = ET.Element("systemList")
        tree = ET.ElementTree(root)
    for system in list(root.findall("system")):
        name = system.findtext("name")
        if name == "steam":
            root.remove(system)
    root.append(esde_system_block(ctx, flatpak))
    indent_xml(root)
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))
    tree.write(path, encoding="utf-8", xml_declaration=True)


def write_esde_configs(ctx: Context, dry_run: bool) -> list[Path]:
    paths: list[tuple[Path, bool]] = [
        (ctx.home / "ES-DE" / "custom_systems" / "es_systems.xml", False),
        (ctx.home / ".emulationstation" / "custom_systems" / "es_systems.xml", False),
        (Path(os.environ.get("PZ_RETRODECK_ROOT", str(ctx.home / "retrodeck"))) / "ES-DE" / "custom_systems" / "es_systems.xml", True),
    ]
    written: list[Path] = []
    seen: set[Path] = set()
    for path, flatpak in paths:
        if path in seen:
            continue
        seen.add(path)
        if path.exists() or "ES-DE" in str(path):
            upsert_esde_system(path, ctx, flatpak, dry_run)
            written.append(path)
    return written


def gamelist_text(games: list[Game]) -> str:
    root = ET.Element("gameList")
    for game in games:
        item = ET.SubElement(root, "game")
        ET.SubElement(item, "path").text = f"./{game.slug}.sh"
        ET.SubElement(item, "name").text = game.title
        ET.SubElement(item, "desc").text = f"PhaseZero launcher for {game.title}."
        ET.SubElement(item, "genre").text = "PC"
    indent_xml(root)
    return ET.tostring(root, encoding="unicode") + "\n"


def merge_heroic_library(ctx: Context, games: list[Game], dry_run: bool) -> Path:
    path = ctx.xdg_config_home / "heroic" / "sideload_apps" / "library.json"
    data = load_json(path, {})
    if not isinstance(data, dict):
        data = {}
    existing = data.get("games")
    if not isinstance(existing, list):
        existing = []
    by_app: dict[str, dict[str, Any]] = {
        str(item.get("app_name")): item for item in existing if isinstance(item, dict) and item.get("app_name")
    }
    managed_apps = {f"phasezero-pc-{game.slug}" for game in games}
    for key in list(by_app):
        if str(key).startswith("phasezero-pc-") and key not in managed_apps:
            by_app.pop(key, None)
    for game in games:
        app_name = f"phasezero-pc-{game.slug}"
        by_app[app_name] = {
            **by_app.get(app_name, {}),
            **heroic_art(ctx, game),
            "runner": "sideload",
            "app_name": app_name,
            "title": game.title,
            "install": {
                "executable": str(game.launch_script),
                "platform": "Linux",
                "is_dlc": False,
            },
            "folder_name": str(game.root if game.root.is_dir() else game.root.parent),
            "is_installed": True,
            "canRunOffline": True,
            "description": "Managed by PhaseZero from /Emulation/roms/steam.",
        }
    data["games"] = sorted(by_app.values(), key=lambda x: str(x.get("title", "")).casefold())
    write_json(path, data, dry_run=dry_run)
    return path


def merge_hydra_emulators(ctx: Context, games: list[Game], dry_run: bool) -> Path:
    path = ctx.xdg_config_home / "hydralauncher" / "emulators_config.json"
    data = load_json(path, {})
    if not isinstance(data, dict):
        data = {}
    data["pcgames"] = {
        "enabled": True,
        "emulator_name": "PhaseZero PC Games",
        "executable_path": "/bin/bash",
        "roms_directory": str(ctx.launchers_dir),
        "default_flags": '"{filePath}"',
        "phasezero_managed": True,
        "game_count": len(games),
        "policy": "local-user-owned-games-only",
    }
    write_json(path, data, dry_run=dry_run)
    return path


def merge_srm_parser(ctx: Context, dry_run: bool) -> Path:
    path = ctx.xdg_config_home / "steam-rom-manager" / "userData" / "userConfigurations.json"
    data = load_json(path, [])
    if not isinstance(data, list):
        data = []
    parser = {
        "configTitle": "PC Games - PhaseZero",
        "parserType": "Glob",
        "executableModifier": '"${exePath}"',
        "steamDirectory": "${steamdirglobal}",
        "romDirectory": str(ctx.launchers_dir),
        "startInDirectory": str(ctx.launchers_dir),
        "titleModifier": "${fuzzyTitle}",
        "onlineImageQueries": ["${fuzzyTitle}"],
        "imagePool": "${fuzzyTitle}",
        "imageProviders": ["sgdb"],
        "parserInputs": {"glob": "${title}@(.sh|.SH)"},
        "executable": {"path": "/bin/bash", "shortcutPassthrough": False, "appendArgsToExecutable": True},
        "executableArgs": '"${filePath}"',
        "userAccounts": {"specifiedAccounts": ["Global"]},
        "steamCategories": ["${PC Games}", "${PhaseZero}"],
        "titleFromVariable": {
            "caseInsensitiveVariables": False,
            "skipFileIfVariableWasNotFound": False,
            "limitToGroups": [],
        },
        "fuzzyMatch": {"replaceDiacritics": True, "removeCharacters": True, "removeBrackets": True},
        "imageProviderAPIs": {
            "sgdb": {
                "nsfw": False,
                "humor": False,
                "imageMotionTypes": ["static"],
                "styles": [],
                "stylesHero": [],
                "stylesLogo": [],
                "stylesIcon": [],
            }
        },
        "controllers": {
            "ps4": None,
            "ps5": None,
            "xbox360": None,
            "xboxone": None,
            "switch_joycon_left": None,
            "switch_joycon_right": None,
            "switch_pro": None,
            "neptune": None,
        },
        "defaultImage": {"long": "", "tall": "", "hero": "", "logo": "", "icon": ""},
        "localImages": {"long": "", "tall": "", "hero": "", "logo": "", "icon": ""},
        "steamInputEnabled": "1",
        "drmProtect": False,
        "disabled": False,
        "version": 25,
        "presetVersion": 19,
        "phasezeroManaged": True,
    }
    found = False
    for i, item in enumerate(data):
        if isinstance(item, dict) and item.get("configTitle") == parser["configTitle"]:
            data[i] = {**item, **parser}
            found = True
            break
    if not found:
        data.append(parser)
    write_json(path, data, dry_run=dry_run)
    settings = path.with_name("userSettings.json")
    sdata = load_json(settings, {})
    if isinstance(sdata, dict):
        env = sdata.setdefault("environmentVariables", {})
        if isinstance(env, dict):
            env["steamDirectory"] = str(ctx.steam_root)
            env["romsDirectory"] = str(ctx.emulation_root / "roms")
        write_json(settings, sdata, dry_run=dry_run)
    return path


def apply(ctx: Context, dry_run: bool = False) -> dict[str, Any]:
    games = discover_games(ctx)
    if not dry_run:
        for directory in [
            ctx.launchers_dir,
            ctx.desktops_dir,
            ctx.catalog_path.parent,
            ctx.gamelist_path.parent,
            ctx.wine_prefix_root,
            ctx.local_bin,
            ctx.desktop_dir,
        ]:
            directory.mkdir(parents=True, exist_ok=True)
    write_text(ctx.launcher_bin, launcher_bin_text(ctx), 0o755, dry_run=dry_run, backup=False)
    for game in games:
        write_text(game.launch_script, launch_script_text(ctx, game), 0o755, dry_run=dry_run, backup=False)
        text = desktop_text(ctx, game)
        write_text(game.desktop_file, text, 0o644, dry_run=dry_run, backup=False)
        write_text(game.menu_file, text, 0o644, dry_run=dry_run, backup=True)
    write_text(ctx.gamelist_path, gamelist_text(games), 0o644, dry_run=dry_run, backup=True)
    esde_paths = write_esde_configs(ctx, dry_run)
    heroic_path = merge_heroic_library(ctx, games, dry_run)
    hydra_path = merge_hydra_emulators(ctx, games, dry_run)
    srm_path = merge_srm_parser(ctx, dry_run)
    catalog = catalog_json(ctx, games)
    catalog["frontends"] = {
        "esde": [str(p) for p in esde_paths],
        "heroic": str(heroic_path),
        "hydra": str(hydra_path),
        "srm": str(srm_path),
    }
    write_json(ctx.catalog_path, catalog, dry_run=dry_run, backup=False)
    if not dry_run and shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(ctx.desktop_dir)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return catalog


def status(ctx: Context) -> dict[str, Any]:
    games = discover_games(ctx)
    catalog = load_json(ctx.catalog_path, {})
    heroic = load_json(ctx.xdg_config_home / "heroic" / "sideload_apps" / "library.json", {})
    heroic_games = heroic.get("games", []) if isinstance(heroic, dict) else []
    heroic_count = len([g for g in heroic_games if isinstance(g, dict) and str(g.get("app_name", "")).startswith("phasezero-pc-")])
    hydra = load_json(ctx.xdg_config_home / "hydralauncher" / "emulators_config.json", {})
    hydra_ok = isinstance(hydra, dict) and "pcgames" in hydra
    return {
        "schemaVersion": 1,
        "root": str(ctx.steam_roms),
        "discovered": len(games),
        "catalogInstalled": bool(isinstance(catalog, dict) and catalog.get("schemaVersion") == 1),
        "launcherInstalled": ctx.launcher_bin.exists(),
        "heroicManagedGames": heroic_count,
        "hydraConfigured": hydra_ok,
        "esdeGamelist": str(ctx.gamelist_path),
        "esdeGamelistInstalled": ctx.gamelist_path.exists(),
        "games": [g.to_json() for g in games],
    }


def desktop_exec_command(path: Path, extra: list[str]) -> tuple[list[str], Path]:
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    parser.read(path, encoding="utf-8")
    entry = parser["Desktop Entry"]
    exec_line = entry.get("Exec", "")
    cleaned = re.sub(r"%[fFuUdDnNickvm]", "", exec_line).strip()
    command = shlex.split(cleaned) + extra
    return command, path.parent


def command_for_game(ctx: Context, game: dict[str, Any], extra: list[str]) -> tuple[list[str], Path, dict[str, str]]:
    target = Path(str(game["target"]))
    root = Path(str(game["root"]))
    cwd = root if root.is_dir() else root.parent
    runner = str(game.get("runner", runner_for_target(target)))
    args = [str(x) for x in game.get("args", [])] + extra
    env = os.environ.copy()
    if os.environ.get("PZ_PC_MANGOHUD", "1") == "1" and shutil.which("mangohud"):
        env.setdefault("MANGOHUD", "1")
    if runner == "desktop":
        command, cwd = desktop_exec_command(target, args)
    elif runner == "script":
        command = ["/bin/bash", str(target), *args]
    elif runner == "wine":
        wine = os.environ.get("PZ_PC_WINE", shutil.which("wine") or "wine")
        prefix = Path(str(game.get("winePrefix") or (ctx.wine_prefix_root / str(game["slug"]))))
        prefix.mkdir(parents=True, exist_ok=True)
        env.setdefault("WINEPREFIX", str(prefix))
        env.setdefault("WINEDEBUG", "-all")
        command = [wine, str(target), *args]
    else:
        if target.is_file() and not os.access(target, os.X_OK):
            try:
                target.chmod(target.stat().st_mode | 0o755)
            except OSError:
                pass
        command = [str(target), *args]
    if os.environ.get("PZ_PC_GAMEMODE", "1") == "1" and shutil.which("gamemoderun"):
        command = ["gamemoderun", *command]
    return command, cwd, env


def launch(ctx: Context, slug: str, extra: list[str], dry_run: bool = False) -> int:
    catalog = load_json(ctx.catalog_path, {})
    games = catalog.get("games", []) if isinstance(catalog, dict) else []
    game = next((g for g in games if isinstance(g, dict) and g.get("slug") == slug), None)
    if game is None:
        print(f"PC game not found in catalog: {slug}", file=sys.stderr)
        return 1
    command, cwd, env = command_for_game(ctx, game, extra)
    if dry_run:
        print(json.dumps({"command": command, "cwd": str(cwd), "runner": game.get("runner")}, ensure_ascii=False))
        return 0
    os.chdir(cwd)
    os.execvpe(command[0], command, env)
    return 127


def print_plan(catalog: dict[str, Any]) -> None:
    print("PC Games plan")
    print(f"  root: {catalog['root']}")
    print(f"  games: {len(catalog['games'])}")
    print(f"  launchers: {catalog['launchersDir']}")
    print(f"  Heroic: {catalog['heroicLibrary']}")
    print(f"  Hydra: {catalog['hydraEmulatorsConfig']}")
    print(f"  ES-DE: {catalog['gamelist']}")
    for game in catalog["games"][:30]:
        print(f"  - {game['title']} [{game['runner']}] -> {game['target']}")
    if len(catalog["games"]) > 30:
        print(f"  ... {len(catalog['games']) - 30} more")


def main() -> int:
    argv = sys.argv[1:]
    json_flag = "--json" in argv
    dry_run_flag = "--dry-run" in argv
    argv = [arg for arg in argv if arg not in {"--json", "--dry-run"}]
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["status", "plan", "apply", "repair", "integrate", "launch"])
    parser.add_argument("slug", nargs="?")
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    args.json = json_flag
    args.dry_run = dry_run_flag
    ctx = context_from_env()
    if args.action == "status":
        data = status(ctx)
        print(json.dumps(data, ensure_ascii=False, indent=2) if args.json else f"PC games: {data['discovered']} discovered, Heroic {data['heroicManagedGames']}, Hydra {data['hydraConfigured']}, ES-DE {data['esdeGamelistInstalled']}")
        return 0
    if args.action == "plan":
        data = apply(ctx, dry_run=True)
        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
        else:
            print_plan(data)
        return 0
    if args.action in {"apply", "repair", "integrate"}:
        data = apply(ctx, dry_run=args.dry_run)
        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
        else:
            print(f"PC games integrated: {len(data['games'])}")
        return 0
    if args.action == "launch":
        if not args.slug:
            parser.error("launch requires slug")
        return launch(ctx, args.slug, args.extra, dry_run=args.dry_run)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
