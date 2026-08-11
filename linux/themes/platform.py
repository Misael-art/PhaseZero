"""Detecção de plataforma do motor de temas.

Detecta Plasma (6/5), KWin, sessão (Wayland/X11), SteamOS/Steam Deck, Decky,
bateria/tomada, aceleração VA-API/Vulkan e Steam (nativo/Flatpak).

Para testes herméticos, `PZ_THEMES_FAKE_JSON` aponta para um arquivo com os
fatos a simular; `PZ_THEMES_FAKE_BIN_DIR` injeta binários falsos no PATH.
"""

from __future__ import annotations

import json
import os
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

HOME = Path.home()


def _which(name: str) -> str:
    return shutil.which(name) or ""


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _os_release() -> dict:
    payload: dict = {}
    for line in _read_text(Path("/etc/os-release")).splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            payload[key.strip()] = value.strip().strip('"')
    return payload


def _plasma_major() -> int | None:
    for candidate in ("plasma-apply-desktoptheme", "plasma-apply-colorscheme", "plasmashell", "kwriteconfig6"):
        if _which(candidate):
            return 6
    if _which("kwriteconfig5") or _which("kreadconfig5"):
        return 5
    version = os.environ.get("KDE_SESSION_VERSION", "")
    if version.isdigit():
        return int(version)
    return None


def _kwin_running() -> bool:
    return bool(_which("kwin_wayland") or _which("kwin_x11")) or bool(
        _pgrep("kwin_wayland") or _pgrep("kwin_x11")
    )


def _pgrep(pattern: str) -> bool:
    try:
        import subprocess

        result = subprocess.run(
            ["pgrep", "-x", pattern],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        )
        return result.returncode == 0
    except Exception:
        return False


def _session_type() -> str:
    value = os.environ.get("XDG_SESSION_TYPE", "").casefold()
    if value in ("wayland", "x11"):
        return value
    if _pgrep("kwin_wayland"):
        return "wayland"
    if _pgrep("kwin_x11"):
        return "x11"
    return ""


def _game_mode() -> bool:
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").casefold()
    if "gamescope" in desktop or os.environ.get("STEAMOS_GAMESCOPE") == "1":
        return True
    return bool(_pgrep("gamescope")) and bool(_pgrep("steam"))


def _steam_deck() -> bool:
    release = _os_release()
    model = f"{release.get('NAME', '')} {release.get('MODEL', '')} {release.get('VARIANT', '')}".casefold()
    return os.environ.get("STEAMDECK") == "1" or "steam deck" in model


def _steam_os() -> bool:
    release = _os_release()
    identifier = f"{release.get('ID', '')} {release.get('ID_LIKE', '')}".casefold()
    return "steamos" in identifier or "steamlinux" in identifier or _steam_deck()


def _decky_installed() -> bool:
    candidates = (
        Path.home() / ".local" / "share" / "decky-loader",
        Path.home() / ".config" / "decky-loader",
        Path.home() / "homebrew" / "services",
        Path.home() / "homebrew" / "plugins",
    )
    return any(path.is_dir() for path in candidates)


def _battery() -> tuple[bool, int | None]:
    supply = Path("/sys/class/power_supply")
    if not supply.is_dir():
        return False, None
    batteries = sorted(supply.glob("BAT*"))
    if not batteries:
        return False, None
    total = 0
    present = 0
    for battery in batteries:
        status = _read_text(battery / "status").strip().casefold()
        if status == "discharging":
            return True, None
        capacity_text = _read_text(battery / "capacity").strip()
        if capacity_text.isdigit():
            total += int(capacity_text)
            present += 1
    if present:
        return False, round(total / present)
    return False, None


def _battery_percent() -> int | None:
    supply = Path("/sys/class/power_supply")
    if not supply.is_dir():
        return None
    values = []
    for battery in sorted(supply.glob("BAT*")):
        capacity = _read_text(battery / "capacity").strip()
        if capacity.isdigit():
            values.append(int(capacity))
    return round(sum(values) / len(values)) if values else None


def _vaapi() -> bool:
    if os.environ.get("PZ_THEMES_VAAPI") == "1":
        return True
    if os.environ.get("PZ_THEMES_VAAPI") == "0":
        return False
    return bool(_which("vainfo"))


def _vulkan() -> bool:
    if os.environ.get("PZ_THEMES_VULKAN") == "1":
        return True
    if os.environ.get("PZ_THEMES_VULKAN") == "0":
        return False
    return bool(_which("vulkaninfo") or _which("vkcube"))


def _steam_install() -> str:
    native = Path.home() / ".local" / "share" / "Steam"
    legacy = Path.home() / ".steam" / "steam"
    flatpak = Path.home() / ".var" / "app" / "com.valvesoftware.Steam"
    if native.is_dir():
        return str(native)
    if legacy.is_dir():
        return str(legacy)
    if flatpak.is_dir():
        return str(flatpak)
    return ""


def _steam_libraries() -> list[str]:
    libraries: list[str] = []
    root_dir = _steam_install()
    if not root_dir:
        return libraries
    libraries.append(str(Path(root_dir) / "steamapps"))
    vdf = Path(root_dir) / "steamapps" / "libraryfolders.vdf"
    content = _read_text(vdf)
    for match in re.finditer(r'"path"\s+"([^"]+)"', content):
        escaped = match.group(1).replace("\\\\", "\\")
        libraries.append(str(Path(escaped) / "steamapps"))
    flatpak = Path.home() / ".var" / "app" / "com.valvesoftware.Steam" / ".local" / "share" / "Steam"
    if flatpak.is_dir():
        libraries.append(str(flatpak / "steamapps"))
    return libraries


def _plasma_binaries() -> dict:
    candidates = (
        "plasmashell",
        "plasma-apply-desktoptheme",
        "plasma-apply-colorscheme",
        "plasma-apply-cursortheme",
        "plasma-apply-lookandfeel",
        "kwriteconfig6",
        "kwriteconfig5",
        "kreadconfig6",
        "kreadconfig5",
        "qdbus",
        "qdbus6",
        "plasmapkg2",
        "plasmapkg",
        "journalctl",
        "vainfo",
        "vulkaninfo",
    )
    return {name: _which(name) for name in candidates}


@dataclass
class HostFacts:
    plasma_major: int | None = None
    session: str = ""
    kwin: bool = False
    steam_os: bool = False
    steam_deck: bool = False
    game_mode: bool = False
    decky: bool = False
    on_battery: bool = False
    battery_percent: int | None = None
    vaapi: bool = False
    vulkan: bool = False
    steam_install: str = ""
    steam_libraries: list = field(default_factory=list)
    desktop: str = ""
    distribution: str = ""
    binaries: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "plasmaMajor": self.plasma_major,
            "session": self.session,
            "kwin": self.kwin,
            "steamOs": self.steam_os,
            "steamDeck": self.steam_deck,
            "gameMode": self.game_mode,
            "decky": self.decky,
            "onBattery": self.on_battery,
            "batteryPercent": self.battery_percent,
            "vaapi": self.vaapi,
            "vulkan": self.vulkan,
            "steamInstall": self.steam_install,
            "steamLibraries": list(self.steam_libraries),
            "desktop": self.desktop,
            "distribution": self.distribution,
            "binaries": dict(self.binaries),
        }

    def plasma_compatible(self, major: int = 6) -> tuple[bool, str]:
        if self.plasma_major is None:
            return False, "sessão KDE/Plasma não detectada"
        if self.plasma_major != major:
            return False, f"requer Plasma {major}; host detecta Plasma {self.plasma_major}"
        if not self.kwin:
            return False, "KWin não está em execução"
        return True, ""


def detect() -> HostFacts:
    fake = os.environ.get("PZ_THEMES_FAKE_JSON")
    if fake:
        path = Path(fake).expanduser()
        payload = json.loads(path.read_text(encoding="utf-8"))
        facts = HostFacts(
            plasma_major=payload.get("plasmaMajor"),
            session=payload.get("session", ""),
            kwin=payload.get("kwin", False),
            steam_os=payload.get("steamOs", False),
            steam_deck=payload.get("steamDeck", False),
            game_mode=payload.get("gameMode", False),
            decky=payload.get("decky", False),
            on_battery=payload.get("onBattery", False),
            battery_percent=payload.get("batteryPercent"),
            vaapi=payload.get("vaapi", False),
            vulkan=payload.get("vulkan", False),
            steam_install=payload.get("steamInstall", ""),
            steam_libraries=list(payload.get("steamLibraries", [])),
            desktop=payload.get("desktop", ""),
            distribution=payload.get("distribution", ""),
            binaries=dict(payload.get("binaries", {})),
        )
        if not facts.binaries:
            facts.binaries = _plasma_binaries()
        return facts
    release = _os_release()
    on_battery, _ = _battery()
    return HostFacts(
        plasma_major=_plasma_major(),
        session=_session_type(),
        kwin=_kwin_running(),
        steam_os=_steam_os(),
        steam_deck=_steam_deck(),
        game_mode=_game_mode(),
        decky=_decky_installed(),
        on_battery=on_battery,
        battery_percent=_battery_percent(),
        vaapi=_vaapi(),
        vulkan=_vulkan(),
        steam_install=_steam_install(),
        steam_libraries=_steam_libraries(),
        desktop=os.environ.get("XDG_CURRENT_DESKTOP", ""),
        distribution=release.get("ID", ""),
        binaries=_plasma_binaries(),
    )
