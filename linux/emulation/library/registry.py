from __future__ import annotations

from dataclasses import dataclass, field

from ..romopt import decision, detect

# Artifact/transform vocabulary shared by scan, plan and UI.
TRANSFORM_NONE = "none"
TRANSFORM_CONVERT = "convert"
TRANSFORM_INSTALL = "install"
TRANSFORM_EXTRACT = "extract"

STATE_READY = "ready"
STATE_ACTION = "action"
STATE_BLOCKED = "blocked"
STATE_UNKNOWN = "unknown"


@dataclass(frozen=True)
class SystemAdapter:
    id: str
    name: str
    aliases: tuple[str, ...] = ()
    canonical_rom_dir: str = ""
    destinations: tuple[str, ...] = ()
    # How a ZIP/7z around this system's content must be interpreted.
    #   native   — archive itself is the playable artifact (cartridge sets)
    #   package  — archive can be an installable package (Vita ZIP/VPK)
    #   wrapper  — archive merely wraps a disc image; extraction required
    archive_role: str = "wrapper"
    prerequisites: tuple[str, ...] = ()
    notes: str = ""
    extra_formats: dict[str, str] = field(default_factory=dict)

    def target_format(self, current_format: str) -> str | None:
        override = self.extra_formats.get(current_format)
        if override is not None:
            return override or None
        return decision.target_format(self.id, current_format)


_DESTINATIONS: dict[str, tuple[str, ...]] = {
    detect.P_PS1: ("duckstation",),
    detect.P_PS2: ("pcsx2",),
    detect.P_PS3: ("rpcs3",),
    detect.P_PS4: ("shadps4",),
    detect.P_PSP: ("ppsspp",),
    detect.P_VITA: ("vita3k",),
    detect.P_DC: ("retroarch",),
    detect.P_SATURN: ("retroarch",),
    detect.P_MEGACD: ("retroarch",),
    detect.P_PCE: ("retroarch",),
    detect.P_NGCD: ("retroarch",),
    detect.P_3DO: ("retroarch",),
    detect.P_PCFX: ("retroarch",),
    detect.P_FMTOWNS: ("retroarch",),
    detect.P_JAGCD: ("bigpemu",),
    detect.P_CD32: ("retroarch",),
    detect.P_WII: ("dolphin",),
    detect.P_GC: ("dolphin",),
    detect.P_WIIU: ("cemu",),
    detect.P_SWITCH: ("eden", "citron"),
    detect.P_3DS: ("azahar",),
    detect.P_XBOX: ("xemu",),
    detect.P_XBOX360: ("xenia",),
}

_NAMES: dict[str, str] = {
    detect.P_PS1: "PlayStation",
    detect.P_PS2: "PlayStation 2",
    detect.P_PS3: "PlayStation 3",
    detect.P_PS4: "PlayStation 4",
    detect.P_PSP: "PlayStation Portable",
    detect.P_VITA: "PlayStation Vita",
    detect.P_DC: "Dreamcast",
    detect.P_SATURN: "Sega Saturn",
    detect.P_MEGACD: "Sega CD",
    detect.P_PCE: "PC Engine",
    detect.P_NGCD: "Neo Geo CD",
    detect.P_3DO: "3DO",
    detect.P_PCFX: "PC-FX",
    detect.P_FMTOWNS: "FM Towns",
    detect.P_JAGCD: "Atari Jaguar CD",
    detect.P_CD32: "Amiga CD32",
    detect.P_WII: "Wii",
    detect.P_GC: "GameCube",
    detect.P_WIIU: "Wii U",
    detect.P_SWITCH: "Nintendo Switch",
    detect.P_NES: "NES",
    detect.P_SNES: "Super Nintendo",
    detect.P_N64: "Nintendo 64",
    detect.P_GB: "Game Boy",
    detect.P_GBC: "Game Boy Color",
    detect.P_GBA: "Game Boy Advance",
    detect.P_NDS: "Nintendo DS",
    detect.P_3DS: "Nintendo 3DS",
    detect.P_GENESIS: "Mega Drive / Genesis",
    detect.P_MD: "Mega Drive",
    detect.P_SMS: "Master System",
    detect.P_GG: "Game Gear",
    detect.P_LYNX: "Atari Lynx",
    detect.P_NGP: "Neo Geo Pocket",
    detect.P_WS: "WonderSwan",
    detect.P_XBOX: "Xbox",
    detect.P_XBOX360: "Xbox 360",
}


def _aliases(platform: str) -> tuple[str, ...]:
    return tuple(
        sorted(alias for alias, target in detect.DIR_MAP.items() if target == platform)
    )


def _build() -> dict[str, SystemAdapter]:
    adapters: dict[str, SystemAdapter] = {}
    public = set(_NAMES)
    for platform in sorted(public):
        if platform in detect.CARTRIDGE_SYSTEMS:
            archive_role = "native"
        elif platform == detect.P_VITA:
            archive_role = "package"
        else:
            archive_role = "wrapper"
        prerequisites: tuple[str, ...] = ()
        notes = ""
        extra: dict[str, str] = {}
        if platform == detect.P_VITA:
            prerequisites = ("vita3k",)
            notes = (
                "ZIP/VPK NoNpDrm instala no Vita3K em ux0/app/<TITLE_ID>; "
                "original preservado"
            )
            extra = {"pkg": "", "vpk": ""}
        adapters[platform] = SystemAdapter(
            id=platform,
            name=_NAMES[platform],
            aliases=_aliases(platform),
            canonical_rom_dir=platform,
            destinations=_DESTINATIONS.get(platform, ("retroarch",)),
            archive_role=archive_role,
            prerequisites=prerequisites,
            notes=notes,
            extra_formats=extra,
        )
    return adapters


ADAPTERS: dict[str, SystemAdapter] = _build()


def for_platform(platform: str) -> SystemAdapter | None:
    resolved = decision.resolve_platform_alias(platform)
    adapter = ADAPTERS.get(resolved)
    if adapter is not None:
        return adapter
    return ADAPTERS.get(detect.DIR_MAP.get(platform, ""))


def public_system_ids() -> tuple[str, ...]:
    return tuple(sorted(ADAPTERS))
