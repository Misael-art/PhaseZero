#!/usr/bin/env python3
"""Expose PhaseZero frontends to ES-DE, Steam, SRM, Heroic and LaunchBox."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


FRONTENDS = [
    {
        "id": "bigbox",
        "title": "Big Box",
        "file": "bigbox.sh",
        "description": "Launch Big Box through PhaseZero.",
        "icon": "launchbox",
    },
    {
        "id": "launchbox",
        "title": "LaunchBox",
        "file": "launchbox.sh",
        "description": "Launch LaunchBox through PhaseZero.",
        "icon": "launchbox",
    },
    {
        "id": "es-de",
        "title": "ES-DE",
        "file": "es-de.sh",
        "description": "Launch ES-DE through PhaseZero.",
        "icon": "es-de",
    },
    {
        "id": "steam-big-picture",
        "title": "Steam Big Picture",
        "file": "steam-big-picture.sh",
        "description": "Open Steam Big Picture mode.",
        "icon": "steam",
    },
    {
        "id": "srm",
        "title": "Steam ROM Manager",
        "file": "srm.sh",
        "description": "Launch Steam ROM Manager through PhaseZero.",
        "icon": "steam-rom-manager",
    },
    {
        "id": "heroic",
        "title": "Heroic Launcher",
        "file": "heroic.sh",
        "description": "Launch Heroic through PhaseZero.",
        "icon": "heroic",
    },
]


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
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
    if backup and path.exists():
        shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, mode)
    tmp.replace(path)
    os.chmod(path, mode)


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


def parse_xml(path: Path, root_name: str) -> ET.ElementTree:
    if path.exists():
        try:
            tree = ET.parse(path)
            if tree.getroot().tag:
                return tree
        except ET.ParseError:
            pass
    return ET.ElementTree(ET.Element(root_name))


def write_xml(path: Path, tree: ET.ElementTree, dry_run: bool, standalone: bool = False) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))
    indent_xml(tree.getroot())
    body = ET.tostring(tree.getroot(), encoding="unicode")
    header = '<?xml version="1.0" standalone="yes"?>\n' if standalone else '<?xml version="1.0"?>\n'
    path.write_text(header + body + "\n", encoding="utf-8")


class Context:
    def __init__(self) -> None:
        self.home = Path(os.environ.get("HOME", str(Path.home()))).expanduser()
        self.repo_root = Path(os.environ.get("PZ_ROOT", Path(__file__).resolve().parents[2]))
        self.xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", self.home / ".config"))
        self.xdg_data = Path(os.environ.get("XDG_DATA_HOME", self.home / ".local" / "share"))
        self.emulation_root = Path(os.environ.get("PZ_EMULATION_ROOT", self.home / "Emulation"))
        self.local_bin = Path(os.environ.get("PZ_LOCAL_BIN", self.home / ".local" / "bin"))
        self.desktop_dir = self.xdg_data / "applications"
        self.steam_root = Path(os.environ.get("STEAM_ROOT", self.home / ".local" / "share" / "Steam"))
        self.retrodeck_root = Path(os.environ.get("PZ_RETRODECK_ROOT", self.home / "retrodeck"))
        self.launchbox_root = Path(
            os.environ.get(
                "PZ_LAUNCHBOX_ROOT",
                self.emulation_root / "tools" / "launchers" / "LaunchBox",
            )
        )
        self.compat_roms = Path(
            os.environ.get(
                "PZ_LAUNCHBOX_COMPAT_ROMS",
                self.emulation_root / "tools" / "launchers" / "Roms",
            )
        )
        self.frontends_dir = Path(
            os.environ.get(
                "PZ_FRONTENDS_DIR",
                self.emulation_root / "tools" / "launchers" / "frontends",
            )
        )
        self.gamelist = self.emulation_root / "metadata" / "gamelists" / "frontends" / "gamelist.xml"
        self.catalog = self.emulation_root / "metadata" / "frontends" / "catalog.json"
        self.srm_configs = self.xdg_config / "steam-rom-manager" / "userData" / "userConfigurations.json"
        self.srm_settings = self.xdg_config / "steam-rom-manager" / "userData" / "userSettings.json"
        self.heroic_library = self.xdg_config / "heroic" / "sideload_apps" / "library.json"
        self.launchbox_platform = self.launchbox_root / "Data" / "Platforms" / "PhaseZero Frontends.xml"
        self.launchbox_platforms = self.launchbox_root / "Data" / "Platforms.xml"
        self.launchbox_emulators = self.launchbox_root / "Data" / "Emulators.xml"
        self.launchbox_emulator_bat = (
            self.emulation_root / "tools" / "launchers" / "emulators" / "PhaseZero" / "frontend.bat"
        )
        self.steam_shortcut_tool = self.repo_root / "linux" / "emulation" / "steam-shortcut.py"


def frontend_launcher(ctx: Context, row: dict[str, str]) -> Path:
    return ctx.frontends_dir / row["file"]


def frontend_router(ctx: Context) -> Path:
    return ctx.local_bin / "phasezero-frontend"


def gamelist_text(ctx: Context) -> str:
    root = ET.Element("gameList")
    for row in FRONTENDS:
        item = ET.SubElement(root, "game")
        ET.SubElement(item, "path").text = f"./{row['file']}"
        ET.SubElement(item, "name").text = row["title"]
        ET.SubElement(item, "desc").text = row["description"]
        ET.SubElement(item, "genre").text = "Frontend"
    indent_xml(root)
    return ET.tostring(root, encoding="unicode") + "\n"


def esde_system_block(ctx: Context, flatpak: bool = False) -> ET.Element:
    system = ET.Element("system")
    values = {
        "name": "frontends",
        "fullname": "Frontends",
        "path": str(ctx.frontends_dir),
        "extension": ".sh .SH",
        "platform": "pc",
        "theme": "ports",
    }
    for key in ["name", "fullname", "path", "extension"]:
        child = ET.SubElement(system, key)
        child.text = values[key]
    command = ET.SubElement(system, "command")
    command.set("label", "PhaseZero Frontend")
    command.text = "flatpak-spawn --host /bin/bash %ROM%" if flatpak else "/bin/bash %ROM%"
    for key in ["platform", "theme"]:
        child = ET.SubElement(system, key)
        child.text = values[key]
    return system


def upsert_esde_system(path: Path, ctx: Context, flatpak: bool, dry_run: bool) -> None:
    tree = parse_xml(path, "systemList")
    root = tree.getroot()
    if root.tag != "systemList":
        root = ET.Element("systemList")
        tree = ET.ElementTree(root)
    for system in list(root.findall("system")):
        if system.findtext("name") == "frontends":
            root.remove(system)
    root.append(esde_system_block(ctx, flatpak))
    write_xml(path, tree, dry_run)


def esde_paths(ctx: Context) -> list[tuple[Path, bool]]:
    return [
        (ctx.home / "ES-DE" / "custom_systems" / "es_systems.xml", False),
        (ctx.home / ".emulationstation" / "custom_systems" / "es_systems.xml", False),
        (ctx.retrodeck_root / "ES-DE" / "custom_systems" / "es_systems.xml", True),
    ]


def merge_srm_parser(ctx: Context, dry_run: bool) -> Path:
    data = load_json(ctx.srm_configs, [])
    if not isinstance(data, list):
        data = []
    parser = {
        "configTitle": "Frontends - PhaseZero",
        "parserType": "Glob",
        "steamDirectory": "${steamdirglobal}",
        "romDirectory": str(ctx.frontends_dir),
        "parserInputs": {"glob": "${title}@(.sh|.SH)"},
        "executable": {"path": "/bin/bash"},
        "executableArgs": '"${filePath}"',
        "userAccounts": {"specifiedAccounts": ["Global"]},
        "steamCategories": ["${Frontends}", "${PhaseZero}"],
        "disabled": False,
        "phasezeroManaged": True,
    }
    found = False
    for index, item in enumerate(data):
        if isinstance(item, dict) and item.get("configTitle") == parser["configTitle"]:
            data[index] = {**item, **parser}
            found = True
            break
    if not found:
        data.append(parser)
    write_json(ctx.srm_configs, data, dry_run=dry_run)

    settings = load_json(ctx.srm_settings, {})
    if not isinstance(settings, dict):
        settings = {}
    env = settings.setdefault("environmentVariables", {})
    if isinstance(env, dict):
        env["steamDirectory"] = str(ctx.steam_root)
        env["romsDirectory"] = str(ctx.emulation_root / "roms")
    settings["autoKillSteam"] = True
    settings["autoRestartSteam"] = True
    settings["phasezeroManagedFrontends"] = True
    write_json(ctx.srm_settings, settings, dry_run=dry_run)
    return ctx.srm_configs


def merge_heroic_library(ctx: Context, dry_run: bool) -> Path:
    data = load_json(ctx.heroic_library, {})
    if not isinstance(data, dict):
        data = {}
    existing = data.get("games")
    if not isinstance(existing, list):
        existing = []
    by_app: dict[str, dict[str, Any]] = {
        str(item.get("app_name")): item
        for item in existing
        if isinstance(item, dict) and item.get("app_name")
    }
    managed = {f"phasezero-frontend-{row['id']}" for row in FRONTENDS}
    for key in list(by_app):
        if key.startswith("phasezero-frontend-") and key not in managed:
            by_app.pop(key, None)
    for row in FRONTENDS:
        app_name = f"phasezero-frontend-{row['id']}"
        launcher = frontend_launcher(ctx, row)
        by_app[app_name] = {
            **by_app.get(app_name, {}),
            "runner": "sideload",
            "app_name": app_name,
            "title": row["title"],
            "install": {
                "executable": str(launcher),
                "platform": "Linux",
                "is_dlc": False,
            },
            "folder_name": str(ctx.frontends_dir),
            "is_installed": True,
            "canRunOffline": True,
            "description": row["description"],
        }
    data["games"] = sorted(by_app.values(), key=lambda item: str(item.get("title", "")).casefold())
    write_json(ctx.heroic_library, data, dry_run=dry_run)
    return ctx.heroic_library


def steam_shortcut_files(ctx: Context) -> list[Path]:
    userdata = ctx.steam_root / "userdata"
    if not userdata.exists():
        return []
    return sorted(userdata.glob("*/config/shortcuts.vdf"))


def apply_steam_shortcuts(ctx: Context, dry_run: bool) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    if not steam_shortcut_files(ctx):
        return rows
    for row in FRONTENDS:
        launcher = frontend_launcher(ctx, row)
        cmd = [
            sys.executable,
            str(ctx.steam_shortcut_tool),
            "add",
            "--steam-root",
            str(ctx.steam_root),
            "--app-name",
            row["title"],
            "--exe",
            str(launcher),
            "--start-dir",
            str(ctx.frontends_dir),
            "--icon",
            row["icon"],
            "--tag",
            "PhaseZero",
            "--tag",
            "Frontends",
        ]
        if dry_run:
            cmd.append("--dry-run")
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        rows.append(
            {
                "title": row["title"],
                "returncode": str(proc.returncode),
                "stdout": proc.stdout.strip(),
                "stderr": proc.stderr.strip(),
            }
        )
    return rows


def safe_symlink(target: Path, link: Path, dry_run: bool) -> None:
    if dry_run:
        return
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink():
        if os.readlink(link) == str(target):
            return
        link.unlink()
    elif link.exists():
        return
    link.symlink_to(target)


def update_launchbox_emulator(ctx: Context, dry_run: bool) -> bool:
    tree = parse_xml(ctx.launchbox_emulators, "LaunchBox")
    root = tree.getroot()
    title = "PhaseZero Frontend Switcher"
    emulator = None
    for item in root.findall("Emulator"):
        if item.findtext("Title") == title:
            emulator = item
            break
    if emulator is None:
        emulator = ET.SubElement(root, "Emulator")
    fields = {
        "ApplicationPath": r"..\emulators\PhaseZero\frontend.bat",
        "CommandLine": '"%romfile%"',
        "Title": title,
    }
    for key, value in fields.items():
        node = emulator.find(key)
        if node is None:
            node = ET.SubElement(emulator, key)
        node.text = value
    write_xml(ctx.launchbox_emulators, tree, dry_run, standalone=True)
    return True


def update_launchbox_platforms(ctx: Context, dry_run: bool) -> bool:
    tree = parse_xml(ctx.launchbox_platforms, "LaunchBox")
    root = tree.getroot()
    platform = None
    for item in root.findall("Platform"):
        if item.findtext("Name") == "PhaseZero Frontends":
            platform = item
            break
    if platform is None:
        platform = ET.SubElement(root, "Platform")
    fields = {
        "Name": "PhaseZero Frontends",
        "NestedName": "PhaseZero Frontends",
        "SortTitle": "PhaseZero Frontends",
        "Notes": "Managed by PhaseZero. Switch between emulation frontends.",
    }
    for key, value in fields.items():
        node = platform.find(key)
        if node is None:
            node = ET.SubElement(platform, key)
        node.text = value
    write_xml(ctx.launchbox_platforms, tree, dry_run, standalone=True)
    return True


def write_launchbox_platform(ctx: Context, dry_run: bool) -> bool:
    if not (ctx.launchbox_root / "LaunchBox.exe").exists():
        return False
    compat = ctx.compat_roms / "PhaseZero Frontends"
    if not dry_run:
        compat.mkdir(parents=True, exist_ok=True)
        (compat / ".phasezero-managed").write_text(
            "Managed by PhaseZero frontend switcher. Do not place games here.\n",
            encoding="utf-8",
        )
    for row in FRONTENDS:
        safe_symlink(frontend_launcher(ctx, row), compat / row["file"], dry_run)

    write_text(
        ctx.launchbox_emulator_bat,
        "\r\n".join(
            [
                "@echo off",
                "setlocal",
                f'start /wait /unix /usr/bin/env bash "{ctx.repo_root / "linux" / "emulation" / "launchbox.sh"}" frontend %*',
                "endlocal",
                "",
            ]
        ),
        mode=0o644,
        dry_run=dry_run,
        backup=False,
    )
    update_launchbox_emulator(ctx, dry_run)
    update_launchbox_platforms(ctx, dry_run)

    root = ET.Element("LaunchBox")
    for row in FRONTENDS:
        game = ET.SubElement(root, "Game")
        ET.SubElement(game, "Title").text = row["title"]
        ET.SubElement(game, "Platform").text = "PhaseZero Frontends"
        ET.SubElement(game, "ApplicationPath").text = rf"..\Roms\PhaseZero Frontends\{row['file']}"
        ET.SubElement(game, "Emulator").text = "PhaseZero Frontend Switcher"
        ET.SubElement(game, "Notes").text = row["description"]
    write_xml(ctx.launchbox_platform, ET.ElementTree(root), dry_run, standalone=True)
    return True


def apply(ctx: Context, dry_run: bool = False) -> dict[str, Any]:
    if not dry_run:
        for directory in [
            ctx.frontends_dir,
            ctx.gamelist.parent,
            ctx.catalog.parent,
            ctx.desktop_dir,
            ctx.local_bin,
        ]:
            directory.mkdir(parents=True, exist_ok=True)
    write_text(ctx.gamelist, gamelist_text(ctx), dry_run=dry_run, backup=True)
    esde_written = []
    for path, flatpak in esde_paths(ctx):
        upsert_esde_system(path, ctx, flatpak, dry_run)
        esde_written.append(str(path))
    srm_path = merge_srm_parser(ctx, dry_run)
    heroic_path = merge_heroic_library(ctx, dry_run)
    steam_rows = apply_steam_shortcuts(ctx, dry_run)
    launchbox_written = write_launchbox_platform(ctx, dry_run)
    data = {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "frontendsDir": str(ctx.frontends_dir),
        "router": str(frontend_router(ctx)),
        "frontends": [
            {
                **row,
                "launcher": str(frontend_launcher(ctx, row)),
            }
            for row in FRONTENDS
        ],
        "esde": esde_written,
        "srm": str(srm_path),
        "heroic": str(heroic_path),
        "steamShortcuts": steam_rows,
        "launchbox": {
            "installed": launchbox_written,
            "platform": str(ctx.launchbox_platform),
            "emulator": str(ctx.launchbox_emulator_bat),
        },
    }
    write_json(ctx.catalog, data, dry_run=dry_run, backup=False)
    return data


def srm_parser_installed(ctx: Context) -> bool:
    data = load_json(ctx.srm_configs, [])
    return isinstance(data, list) and any(
        isinstance(item, dict) and item.get("configTitle") == "Frontends - PhaseZero"
        for item in data
    )


def heroic_count(ctx: Context) -> int:
    data = load_json(ctx.heroic_library, {})
    games = data.get("games", []) if isinstance(data, dict) else []
    return len(
        [
            item
            for item in games
            if isinstance(item, dict) and str(item.get("app_name", "")).startswith("phasezero-frontend-")
        ]
    )


def esde_installed(ctx: Context) -> list[str]:
    installed: list[str] = []
    for path, _flatpak in esde_paths(ctx):
        if path.exists() and "<name>frontends</name>" in path.read_text(encoding="utf-8", errors="replace"):
            installed.append(str(path))
    return installed


def steam_shortcut_status(ctx: Context) -> dict[str, int]:
    files = steam_shortcut_files(ctx)
    found = 0
    for row in FRONTENDS:
        proc = subprocess.run(
            [
                sys.executable,
                str(ctx.steam_shortcut_tool),
                "status",
                "--steam-root",
                str(ctx.steam_root),
                "--app-name",
                row["title"],
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if proc.returncode == 0:
            found += 1
    return {"files": len(files), "frontendsFound": found}


def status(ctx: Context) -> dict[str, Any]:
    launchers = [
        str(frontend_launcher(ctx, row))
        for row in FRONTENDS
        if frontend_launcher(ctx, row).exists()
    ]
    return {
        "schemaVersion": 1,
        "frontendsDir": str(ctx.frontends_dir),
        "router": str(frontend_router(ctx)),
        "routerInstalled": frontend_router(ctx).exists(),
        "launcherCount": len(launchers),
        "expectedLaunchers": len(FRONTENDS),
        "launchers": launchers,
        "esde": esde_installed(ctx),
        "srmParserInstalled": srm_parser_installed(ctx),
        "heroicManagedFrontends": heroic_count(ctx),
        "steamShortcuts": steam_shortcut_status(ctx),
        "launchbox": {
            "platformInstalled": ctx.launchbox_platform.exists(),
            "emulatorInstalled": ctx.launchbox_emulator_bat.exists(),
        },
        "catalogInstalled": ctx.catalog.exists(),
    }


def print_plan(data: dict[str, Any]) -> None:
    print("Frontend switcher plan")
    print(f"  launchers: {data['frontendsDir']}")
    print(f"  router:    {data['router']}")
    print(f"  frontends: {len(data['frontends'])}")
    print(f"  ES-DE:     {len(data['esde'])} custom system files")
    print(f"  SRM:       {data['srm']}")
    print(f"  Heroic:    {data['heroic']}")
    print(f"  LaunchBox: {data['launchbox']['platform']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["status", "plan", "apply", "repair", "integrate"])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    ctx = Context()
    if args.action == "status":
        data = status(ctx)
        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
        else:
            print(
                "Frontends: "
                f"{data['launcherCount']}/{data['expectedLaunchers']} launchers, "
                f"ES-DE {len(data['esde'])}, "
                f"SRM {data['srmParserInstalled']}, "
                f"Heroic {data['heroicManagedFrontends']}, "
                f"Steam {data['steamShortcuts']['frontendsFound']}/{data['steamShortcuts']['files']}, "
                f"LaunchBox {data['launchbox']['platformInstalled']}"
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
