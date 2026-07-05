#!/usr/bin/env python3
"""Tune Heroic defaults and keep PhaseZero KDE launchers organized."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any


ICON_SPECS = {
    "phasezero": ("PZ", "#24292f", "#f6f8fa"),
    "heroic": ("HL", "#5d3fd3", "#ffffff"),
    "frontends": ("FE", "#0f766e", "#ffffff"),
    "pc-game": ("PC", "#7c2d12", "#ffffff"),
    "bigbox": ("BB", "#111827", "#facc15"),
    "launchbox": ("LB", "#1d4ed8", "#ffffff"),
    "es-de": ("ES", "#047857", "#ffffff"),
    "srm": ("SR", "#2563eb", "#ffffff"),
    "steam": ("ST", "#0f172a", "#ffffff"),
    "emulator": ("EM", "#6d28d9", "#ffffff"),
}

DUPLICATE_TARGETS = [
    ("phasezero-es-de.desktop", ["es-de", "emulationstation"]),
    ("phasezero-steam-rom-manager.desktop", ["steam rom manager", "steam-rom-manager", "steam_rom_manager"]),
    ("phasezero-heroic.desktop", ["heroic"]),
    ("phasezero-launchbox.desktop", ["launchbox"]),
    ("phasezero-bigbox.desktop", ["big box", "bigbox"]),
    ("phasezero-emudeck.desktop", ["emudeck"]),
    ("phasezero-hydra.desktop", ["hydra"]),
    ("phasezero-eden.desktop", ["eden"]),
    ("phasezero-citron.desktop", ["citron"]),
    ("phasezero-duckstation.desktop", ["duckstation"]),
    ("phasezero-pcsx2.desktop", ["pcsx2"]),
    ("phasezero-rpcs3.desktop", ["rpcs3"]),
    ("phasezero-cemu.desktop", ["cemu"]),
    ("phasezero-azahar.desktop", ["azahar"]),
    ("phasezero-shadps4.desktop", ["shadps4"]),
    ("phasezero-ryujinx.desktop", ["ryujinx"]),
    ("phasezero-vita3k.desktop", ["vita3k"]),
    ("phasezero-bigpemu.desktop", ["bigpemu", "bigpemu"]),
]

SESSION_MUTABLE_DEFAULTS = {"startInConsoleMode"}


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path: Path, data: Any, dry_run: bool = False, backup: bool = True) -> bool:
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if path.exists() and path.read_text(encoding="utf-8", errors="replace") == text:
        return False
    if dry_run:
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    if backup and path.exists():
        shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
    return True


def svg_icon(label: str, bg: str, fg: str) -> str:
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
<rect x="8" y="8" width="112" height="112" rx="24" fill="{bg}"/>
<rect x="18" y="18" width="92" height="92" rx="18" fill="none" stroke="{fg}" stroke-width="6" opacity="0.55"/>
<text x="64" y="76" text-anchor="middle" font-family="Inter,Arial,sans-serif" font-size="38" font-weight="800" fill="{fg}">{label}</text>
</svg>
"""


class Context:
    def __init__(self) -> None:
        self.home = Path(os.environ.get("HOME", str(Path.home()))).expanduser()
        self.repo_root = Path(os.environ.get("PZ_ROOT", Path(__file__).resolve().parents[2]))
        self.xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", self.home / ".config"))
        self.xdg_data = Path(os.environ.get("XDG_DATA_HOME", self.home / ".local" / "share"))
        self.emulation_root = Path(os.environ.get("PZ_EMULATION_ROOT", self.home / "Emulation"))
        self.desktop_dir = self.xdg_data / "applications"
        self.icon_dir = self.emulation_root / "media" / "icons" / "phasezero"
        self.heroic_config = self.xdg_config / "heroic" / "config.json"
        self.heroic_store_config = self.xdg_config / "heroic" / "store" / "config.json"
        self.heroic_library = self.xdg_config / "heroic" / "sideload_apps" / "library.json"
        self.steam_root = Path(os.environ.get("STEAM_ROOT", self.home / ".local" / "share" / "Steam"))
        self.state = self.xdg_config / "phasezero" / "emulation" / "heroic.json"


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def steam_path(ctx: Context) -> str:
    for path in [ctx.steam_root, ctx.home / ".steam" / "steam", ctx.home / ".steam" / "root"]:
        if path.exists():
            return str(path)
    return str(ctx.steam_root)


def wine_version(current: dict[str, Any] | None) -> dict[str, str]:
    if current and current.get("bin") and Path(str(current["bin"])).exists():
        return {
            "bin": str(current["bin"]),
            "name": str(current.get("name") or Path(str(current["bin"])).name),
            "type": str(current.get("type") or "wine"),
            **({"wineserver": str(current["wineserver"])} if current.get("wineserver") else {}),
        }
    wine = shutil.which("wine") or "/usr/bin/wine"
    wineserver = shutil.which("wineserver") or "/usr/bin/wineserver"
    return {"bin": wine, "name": Path(wine).name, "type": "wine", "wineserver": wineserver}


def desired_experimental_features(current: Any) -> dict[str, Any]:
    features = dict(current) if isinstance(current, dict) else {}
    features["cometSupport"] = True
    features["zoomPlatform"] = False
    features["helpComponent"] = False
    return features


def desired_defaults(ctx: Context, current: dict[str, Any]) -> dict[str, Any]:
    prefix_root = ctx.emulation_root / "storage" / "pc-prefixes" / "heroic"
    use_gamemode = command_exists("gamemoderun")
    return {
        "addDesktopShortcuts": False,
        "addStartMenuShortcuts": False,
        "addSteamShortcuts": False,
        "autoInstallDxvk": True,
        "autoInstallVkd3d": True,
        "autoInstallDxvkNvapi": True,
        "preferSystemLibs": False,
        "checkForUpdatesOnStartup": True,
        "autoUpdateGames": False,
        "hideChangelogsOnStartup": True,
        "defaultInstallPath": str(ctx.emulation_root / "roms" / "steam"),
        "defaultSteamPath": steam_path(ctx),
        "defaultWinePrefix": str(prefix_root),
        "defaultWinePrefixDir": str(prefix_root),
        "winePrefix": str(prefix_root / "shared"),
        "wineVersion": wine_version(current.get("wineVersion") if isinstance(current.get("wineVersion"), dict) else None),
        "enableEsync": True,
        "enableFsync": True,
        "enableMsync": False,
        "enableWineWayland": False,
        "enableHDR": False,
        "enableWoW64": False,
        "enableFSRHack": False,
        "FsrSharpnessStrenght": 2,
        "eacRuntime": True,
        "battlEyeRuntime": True,
        "nvidiaPrime": False,
        "showFps": False,
        "showMangohud": False,
        "useGameMode": use_gamemode,
        "startInConsoleMode": False,
        "minimizeOnLaunch": True,
        "hideWindowOnProtocolLaunch": True,
        "disableUMU": False,
        "verboseLogs": False,
        "downloadProtonToSteam": ctx.steam_root.exists(),
        "showValveProton": True,
        "noTrayIcon": True,
        "exitToTray": False,
        "startInTray": False,
        "darkTrayIcon": False,
        "framelessWindow": False,
        "downloadNoHttps": False,
        "disableGOGPresence": True,
        "discordRPC": False,
        "disable_controller": False,
        "allowInstallationBrokenAnticheat": False,
        "experimentalFeatures": desired_experimental_features(current.get("experimentalFeatures")),
        "enviromentOptions": current.get("enviromentOptions") if isinstance(current.get("enviromentOptions"), list) else [],
        "wrapperOptions": current.get("wrapperOptions") if isinstance(current.get("wrapperOptions"), list) else [],
    }


def flag_value(value: str | None) -> bool | None:
    if value is None:
        return None
    text = value.strip().lower()
    if text in {"1", "true", "yes", "on", "game", "console"}:
        return True
    if text in {"0", "false", "no", "off", "desktop"}:
        return False
    return None


def process_matches(pattern: str) -> bool:
    try:
        proc = subprocess.run(
            ["pgrep", "-f", pattern],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return proc.returncode == 0
    except Exception:
        return False


def detect_game_session() -> bool:
    forced = flag_value(os.environ.get("PZ_HEROIC_CONSOLE_MODE"))
    if forced is not None:
        return forced
    for name in ["SteamGamepadUI", "STEAM_GAMEPADUI", "SteamDeck", "STEAMOS", "PZ_GAME_SESSION"]:
        value = flag_value(os.environ.get(name))
        if value:
            return True
    if any(os.environ.get(name) for name in ["SteamAppId", "SteamGameId", "GAMESCOPE_WAYLAND_DISPLAY"]):
        return True
    session_text = " ".join(
        os.environ.get(name, "")
        for name in ["XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION"]
    ).lower()
    if re.search(r"(gamescope|steamos|steam|gamepad)", session_text):
        return True
    return process_matches(r"(gamescope-session|steam.*-gamepadui)")


def optimize_config(path: Path, ctx: Context, dry_run: bool) -> dict[str, Any]:
    data = load_json(path, {})
    if not isinstance(data, dict):
        data = {}
    defaults = data.setdefault("defaultSettings", {})
    if not isinstance(defaults, dict):
        defaults = {}
        data["defaultSettings"] = defaults
    before = json.dumps(defaults, sort_keys=True, default=str)
    for key, value in desired_defaults(ctx, defaults).items():
        defaults[key] = value
    data.setdefault("version", "unknown")
    changed = before != json.dumps(defaults, sort_keys=True, default=str)
    write_json(path, data, dry_run=dry_run, backup=True)
    return {"path": str(path), "exists": path.exists(), "changed": changed}


def apply_session(ctx: Context, mode: str) -> dict[str, Any]:
    if mode == "game":
        game_session = True
    elif mode == "desktop":
        game_session = False
    else:
        game_session = detect_game_session()

    data = load_json(ctx.heroic_config, {})
    if not isinstance(data, dict):
        data = {}
    defaults = data.setdefault("defaultSettings", {})
    if not isinstance(defaults, dict):
        defaults = {}
        data["defaultSettings"] = defaults

    before = json.dumps(defaults, sort_keys=True, default=str)
    defaults["startInConsoleMode"] = game_session
    defaults["hideWindowOnProtocolLaunch"] = True
    defaults["minimizeOnLaunch"] = True
    defaults["noTrayIcon"] = True
    defaults["exitToTray"] = False
    defaults["startInTray"] = False
    changed = before != json.dumps(defaults, sort_keys=True, default=str)
    write_json(ctx.heroic_config, data, dry_run=False, backup=False)
    return {
        "schemaVersion": 1,
        "heroicConfig": str(ctx.heroic_config),
        "mode": mode,
        "gameSession": game_session,
        "startInConsoleMode": defaults["startInConsoleMode"],
        "changed": changed,
    }


def ensure_icons(ctx: Context, dry_run: bool) -> dict[str, str]:
    icons: dict[str, str] = {}
    for name, (label, bg, fg) in ICON_SPECS.items():
        path = ctx.icon_dir / f"{name}.svg"
        icons[name] = str(path)
        if dry_run:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(svg_icon(label, bg, fg), encoding="utf-8")
    return icons


def fallback_icon_for_app(ctx: Context, app_name: str) -> Path:
    if app_name.startswith("phasezero-pc-"):
        name = "pc-game"
    elif app_name.startswith("phasezero-frontend-"):
        frontend = app_name.removeprefix("phasezero-frontend-")
        name = {
            "bigbox": "bigbox",
            "launchbox": "launchbox",
            "es-de": "es-de",
            "steam-big-picture": "steam",
            "srm": "srm",
            "heroic": "heroic",
        }.get(frontend, "frontends")
    else:
        name = "phasezero"
    return ctx.icon_dir / f"{name}.svg"


def ensure_heroic_artwork(ctx: Context, dry_run: bool) -> dict[str, int]:
    data = load_json(ctx.heroic_library, {})
    games = data.get("games", []) if isinstance(data, dict) else []
    if not isinstance(games, list):
        games = []
    counts = {"managed": 0, "complete": 0, "fallbacks": 0}
    changed = False
    for game in games:
        if not isinstance(game, dict):
            continue
        app_name = str(game.get("app_name", ""))
        if not app_name.startswith("phasezero-"):
            continue
        counts["managed"] += 1
        fallback = fallback_icon_for_app(ctx, app_name).resolve().as_uri()
        for field in ("art_square", "art_cover"):
            if not game.get(field):
                game[field] = fallback
                counts["fallbacks"] += 1
                changed = True
        if game.get("art_square") and game.get("art_cover"):
            counts["complete"] += 1
    if changed:
        write_json(ctx.heroic_library, data, dry_run=dry_run, backup=True)
    return counts


def desktop_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""


def desktop_lower(path: Path) -> str:
    text = desktop_text(path)
    return f"{path.name}\n{text}".lower()


def icon_for_desktop(path: Path, ctx: Context) -> str:
    name = path.name
    mapping = {
        "phasezero-heroic.desktop": "heroic",
        "phasezero-frontends.desktop": "frontends",
        "phasezero-bigbox.desktop": "bigbox",
        "phasezero-launchbox.desktop": "launchbox",
        "phasezero-es-de.desktop": "es-de",
        "phasezero-steam-rom-manager.desktop": "srm",
        "phasezero-steam-big-picture.desktop": "steam",
        "phasezero-steam-gamepad-ui.desktop": "steam",
    }
    if name.startswith("phasezero-pc-"):
        return str(ctx.icon_dir / "pc-game.svg")
    if name in mapping:
        return str(ctx.icon_dir / f"{mapping[name]}.svg")
    if re.search(r"phasezero-(eden|citron|ryujinx|duckstation|pcsx2|rpcs3|cemu|azahar|shadps4|vita3k|bigpemu)", name):
        return str(ctx.icon_dir / "emulator.svg")
    return str(ctx.icon_dir / "phasezero.svg")


def set_desktop_keys(path: Path, keys: dict[str, str | None], dry_run: bool) -> bool:
    lines = desktop_text(path).splitlines()
    if not lines:
        return False
    out: list[str] = []
    in_entry = False
    seen: set[str] = set()
    changed = False
    for line in lines:
        stripped = line.strip()
        if stripped == "[Desktop Entry]":
            in_entry = True
            out.append(line)
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_entry:
                for key, value in keys.items():
                    if value is not None and key not in seen:
                        out.append(f"{key}={value}")
                        changed = True
                in_entry = False
            out.append(line)
            continue
        if in_entry and "=" in line:
            key = line.split("=", 1)[0].strip()
            if key in keys:
                seen.add(key)
                value = keys[key]
                if value is None:
                    changed = True
                    continue
                newline = f"{key}={value}"
                if line != newline:
                    changed = True
                out.append(newline)
                continue
        out.append(line)
    if in_entry:
        for key, value in keys.items():
            if value is not None and key not in seen:
                out.append(f"{key}={value}")
                changed = True
    new_text = "\n".join(out) + "\n"
    if new_text != desktop_text(path):
        changed = True
    if changed and not dry_run:
        shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))
        path.write_text(new_text, encoding="utf-8")
    return changed


def canonical_exists(ctx: Context, basename: str) -> bool:
    return (ctx.desktop_dir / basename).exists()


def duplicate_kind(path: Path, ctx: Context) -> str | None:
    if path.name.startswith("phasezero-"):
        return None
    text = desktop_lower(path)
    for canonical, needles in DUPLICATE_TARGETS:
        if not canonical_exists(ctx, canonical):
            continue
        if any(needle in text for needle in needles):
            return canonical
    return None


def organize_desktops(ctx: Context, dry_run: bool) -> dict[str, int]:
    counts = {"phasezero": 0, "pcHidden": 0, "duplicatesHidden": 0, "iconsSet": 0, "changed": 0}
    if not ctx.desktop_dir.exists():
        return counts
    for path in sorted(ctx.desktop_dir.glob("*.desktop")):
        keys: dict[str, str | None] = {}
        if path.name.startswith("phasezero-"):
            counts["phasezero"] += 1
            keys["Icon"] = icon_for_desktop(path, ctx)
            keys["StartupNotify"] = "false"
            keys["X-PhaseZero-Managed"] = "true"
            counts["iconsSet"] += 1
            if path.name.startswith("phasezero-pc-"):
                keys["NoDisplay"] = "true"
                keys["Categories"] = "Game;X-PhaseZero-PC;"
                counts["pcHidden"] += 1
            else:
                keys["NoDisplay"] = None
                keys["Hidden"] = None
                keys["Categories"] = "Game;Emulator;X-PhaseZero;"
        else:
            canonical = duplicate_kind(path, ctx)
            if canonical:
                keys["NoDisplay"] = "true"
                keys["X-PhaseZero-Hidden-Duplicate"] = canonical
                counts["duplicatesHidden"] += 1
        if keys and set_desktop_keys(path, keys, dry_run):
            counts["changed"] += 1
    if not dry_run and shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(ctx.desktop_dir)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return counts


def apply(ctx: Context, dry_run: bool = False) -> dict[str, Any]:
    icons = ensure_icons(ctx, dry_run)
    config = optimize_config(ctx.heroic_config, ctx, dry_run)
    store_config = None
    if ctx.heroic_store_config.exists():
        store_config = optimize_config(ctx.heroic_store_config, ctx, dry_run)
    menu = organize_desktops(ctx, dry_run)
    artwork = ensure_heroic_artwork(ctx, dry_run)
    data = {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "config": config,
        "storeConfig": store_config,
        "icons": icons,
        "menu": menu,
        "artwork": artwork,
        "policy": "safe-defaults-no-game-content-downloads",
    }
    if not dry_run:
        write_json(ctx.state, data, dry_run=False, backup=False)
    return data


def status(ctx: Context) -> dict[str, Any]:
    config = load_json(ctx.heroic_config, {})
    defaults = config.get("defaultSettings", {}) if isinstance(config, dict) else {}
    desktop_files = list(ctx.desktop_dir.glob("*.desktop")) if ctx.desktop_dir.exists() else []
    visible_pc = 0
    hidden_duplicates = 0
    phasezero_without_icon = 0
    for path in desktop_files:
        text = desktop_text(path)
        if path.name.startswith("phasezero-pc-") and "NoDisplay=true" not in text:
            visible_pc += 1
        if "X-PhaseZero-Hidden-Duplicate=" in text:
            hidden_duplicates += 1
        if path.name.startswith("phasezero-") and "Icon=" not in text:
            phasezero_without_icon += 1
    library = load_json(ctx.heroic_library, {})
    library_games = library.get("games", []) if isinstance(library, dict) else []
    managed_library = [
        game
        for game in library_games
        if isinstance(game, dict) and str(game.get("app_name", "")).startswith("phasezero-")
    ]
    artwork_complete = sum(
        bool(game.get("art_square")) and bool(game.get("art_cover"))
        for game in managed_library
    )
    desired = desired_defaults(ctx, defaults if isinstance(defaults, dict) else {})
    optimized = isinstance(defaults, dict) and all(
        defaults.get(k) == v for k, v in desired.items() if k not in SESSION_MUTABLE_DEFAULTS
    )
    return {
        "schemaVersion": 1,
        "heroicConfig": str(ctx.heroic_config),
        "heroicConfigExists": ctx.heroic_config.exists(),
        "optimizedDefaults": optimized,
        "useGameMode": defaults.get("useGameMode") if isinstance(defaults, dict) else None,
        "startInConsoleMode": defaults.get("startInConsoleMode") if isinstance(defaults, dict) else None,
        "defaultInstallPath": defaults.get("defaultInstallPath") if isinstance(defaults, dict) else None,
        "defaultWinePrefixDir": defaults.get("defaultWinePrefixDir") if isinstance(defaults, dict) else None,
        "iconsDir": str(ctx.icon_dir),
        "iconsInstalled": all((ctx.icon_dir / f"{name}.svg").exists() for name in ICON_SPECS),
        "desktopFiles": len(desktop_files),
        "visiblePhaseZeroPcGames": visible_pc,
        "hiddenDuplicates": hidden_duplicates,
        "phasezeroWithoutIcon": phasezero_without_icon,
        "heroicManagedEntries": len(managed_library),
        "heroicArtworkComplete": artwork_complete,
        "heroicWithoutArtwork": len(managed_library) - artwork_complete,
    }


def print_plan(data: dict[str, Any]) -> None:
    print("Heroic optimization plan")
    print(f"  config: {data['config']['path']}")
    print(f"  icons:  {len(data['icons'])} SVG icons")
    print(
        "  menu:   "
        f"{data['menu']['pcHidden']} PC game entries hidden, "
        f"{data['menu']['duplicatesHidden']} duplicates hidden, "
        f"{data['menu']['iconsSet']} icons set"
    )
    print(
        "  artwork: "
        f"{data['artwork']['complete']}/{data['artwork']['managed']} complete, "
        f"{data['artwork']['fallbacks']} fallbacks"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["status", "plan", "apply", "repair", "optimize", "session"])
    parser.add_argument("--mode", choices=["auto", "desktop", "game"], default="auto")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    ctx = Context()
    if args.action == "status":
        data = status(ctx)
        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
        else:
            print(
                "Heroic: "
                f"optimized={data['optimizedDefaults']} "
                f"icons={data['iconsInstalled']} "
                f"visible_pc={data['visiblePhaseZeroPcGames']} "
                f"hidden_duplicates={data['hiddenDuplicates']}"
            )
        return 0
    if args.action == "session":
        data = apply_session(ctx, args.mode)
        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
        else:
            print(
                "Heroic session: "
                f"mode={data['mode']} "
                f"game={data['gameSession']} "
                f"console={data['startInConsoleMode']}"
            )
        return 0
    data = apply(ctx, dry_run=args.action == "plan")
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print_plan(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
