from __future__ import annotations
import struct
import re
import shlex
from pathlib import Path

PLATFORM_UNKNOWN = "unknown"
FORMAT_UNKNOWN = "unknown"

# Platform keys
# Disc systems
P_PS1 = "ps1"
P_PS2 = "ps2"
P_PSP = "psp"
P_DC = "dreamcast"
P_SATURN = "saturn"
P_MEGACD = "megacd"
P_PCE = "pcengine"
P_NGCD = "neogeocd"
P_3DO = "3do"
P_PCFX = "pcfx"
P_FMTOWNS = "fmtowns"
P_JAGCD = "jaguarcd"
P_CD32 = "amigacd32"
P_WII = "wii"
P_GC = "gc"
P_SWITCH = "switch"
# Cartridge systems
P_NES = "nes"
P_SNES = "snes"
P_N64 = "n64"
P_GB = "gb"
P_GBC = "gbc"
P_GBA = "gba"
P_NDS = "nds"
P_3DS = "n3ds"
P_GENESIS = "genesis"
P_MD = "megadrive"
P_SMS = "mastersystem"
P_GG = "gamegear"
P_LYNX = "atarilynx"
P_NGP = "ngp"
P_WS = "ws"
# Systems with no compression
P_PS3 = "ps3"
P_PS4 = "ps4"
P_VITA = "psvita"
P_XBOX = "xbox"
P_XBOX360 = "xbox360"
P_WIIU = "wiiu"

DIR_MAP: dict[str, str] = {
    "ps1": P_PS1, "psx": P_PS1, "playstation": P_PS1,
    "ps2": P_PS2,
    "ps3": P_PS3,
    "ps4": P_PS4,
    "psp": P_PSP,
    "psvita": P_VITA, "vita": P_VITA, "psv": P_VITA,
    "dreamcast": P_DC, "dc": P_DC,
    "saturn": P_SATURN, "ss": P_SATURN,
    "megacd": P_MEGACD, "segacd": P_MEGACD,
    "pcengine": P_PCE, "pce": P_PCE, "pce-cd": P_PCE,
    "tg-cd": P_PCE, "tg16": P_PCE, "turbografx": P_PCE,
    "neogeocd": P_NGCD, "ngcd": P_NGCD,
    "3do": P_3DO,
    "pcfx": P_PCFX,
    "fmtowns": P_FMTOWNS, "towns": P_FMTOWNS,
    "jaguarcd": P_JAGCD, "atarijaguarcd": P_JAGCD,
    "amigacd32": P_CD32, "cd32": P_CD32,
    "gamecube": P_GC, "gc": P_GC, "ngc": P_GC,
    "wii": P_WII,
    "wiiu": P_WIIU,
    "switch": P_SWITCH, "nsw": P_SWITCH,
    "nes": P_NES,
    "snes": P_SNES, "supernes": P_SNES,
    "n64": P_N64, "nintendo64": P_N64,
    "gb": P_GB, "gameboy": P_GB,
    "gbc": P_GBC, "gameboycolor": P_GBC,
    "gba": P_GBA, "gameboyadvance": P_GBA,
    "nds": P_NDS, "ds": P_NDS,
    "3ds": P_3DS,
    "genesis": P_GENESIS, "megadrive": P_MD,
    "mastersystem": P_SMS, "sms": P_SMS,
    "gamegear": P_GG, "gg": P_GG,
    "atarilynx": P_LYNX, "lynx": P_LYNX,
    "ngp": P_NGP,
    "ws": P_WS, "wonderswan": P_WS,
    "xbox": P_XBOX,
    "xbox360": P_XBOX360,
}

EXT_MAP: dict[str, str] = {
    ".psx.iso": P_PS1, ".ps1.iso": P_PS1, ".psx.bin": P_PS1,
    ".ps2.iso": P_PS2,
    ".psp.iso": P_PSP, ".psp.cso": P_PSP, ".psp.zso": P_PSP,
    ".dc.iso": P_DC, ".dc.gdi": P_DC,
    ".gc.iso": P_GC, ".gcm": P_GC,
    ".wii.iso": P_WII,
    ".wua": P_WIIU, ".wud": P_WIIU, ".wux": P_WIIU,
    ".nsz": P_SWITCH, ".nsp": P_SWITCH, ".xci": P_SWITCH,
    ".xcz": P_SWITCH,
    ".cso": P_PSP, ".zso": P_PSP,
    ".pbp": P_PSP,
    ".3ds": P_3DS, ".cia": P_3DS,
    ".nds": P_NDS,
    ".vpk": P_VITA, ".pkg": P_VITA,
    ".nes": P_NES, ".smc": P_SNES, ".sfc": P_SNES,
    ".fig": P_SNES,
    ".n64": P_N64, ".z64": P_N64, ".v64": P_N64,
    ".gb": P_GB, ".gbc": P_GBC, ".gba": P_GBA,
    ".nds": P_NDS, ".ds": P_NDS,
    ".3ds": P_3DS, ".cia": P_3DS,
    ".gen": P_GENESIS, ".smd": P_GENESIS, ".md": P_MD,
    ".sms": P_SMS, ".gg": P_GG,
    ".lnx": P_LYNX,
    ".ngp": P_NGP,
    ".ws": P_WS, ".wsc": P_WS,
}

NO_COMPRESSION = {P_PS3, P_PS4, P_VITA, P_XBOX, P_XBOX360, P_WIIU}

CARTRIDGE_SYSTEMS = {
    P_NES, P_SNES, P_N64,
    P_GB, P_GBC, P_GBA,
    P_NDS, P_3DS,
    P_GENESIS, P_MD, P_SMS, P_GG,
    P_LYNX, P_NGP, P_WS,
}

DISC_SYSTEMS = {
    P_PS1, P_PS2, P_PSP,
    P_DC, P_SATURN, P_MEGACD, P_PCE, P_NGCD,
    P_3DO, P_PCFX, P_FMTOWNS, P_JAGCD, P_CD32,
    P_WII, P_GC,
}


def _read_le32(data: bytes, offset: int) -> int:
    if offset + 4 > len(data):
        return 0
    return struct.unpack_from("<I", data, offset)[0]


def detect_from_magic(path: Path) -> tuple[str, str, float]:
    data = _safe_read(path, 0x10000)
    if not data:
        return PLATFORM_UNKNOWN, FORMAT_UNKNOWN, 0.0

    # CHD identifies a container, not its source platform. Every current CHD
    # starts with MComprHD; treating that magic as "PS2" misclassifies PS1,
    # Dreamcast, Saturn, and other CHDs. Directory/explicit platform decides.
    if len(data) >= 8 and data[0:8] == b"MComprHD":
        return PLATFORM_UNKNOWN, "chd", 0.80
    if len(data) >= 8 and data[0:6] == b"MCompr":
        return PLATFORM_UNKNOWN, "chd", 0.75

    # RVZ is shared by GameCube and Wii. Container magic alone cannot select
    # the platform; prefer an explicit platform or the ROM directory.
    if len(data) >= 4 and data[0:4] == b"RVZ\x00":
        return PLATFORM_UNKNOWN, "rvz", 0.95

    # WBFS
    if len(data) >= 4 and data[0:4] == b"WBFS":
        return P_WII, "wbfs", 0.95

    # NKIT
    if len(data) >= 6 and data[0:6] == b"NKit2":
        return P_WII, "nkit", 0.90

    # CSO
    if len(data) >= 4 and data[0:4] == b"CISO":
        return P_PSP, "cso", 0.98

    # ZSO
    if len(data) >= 4 and data[0:4] == b"ZISO":
        return P_PSP, "zso", 0.98

    # NSZ keeps the PFS0 container signature used by NSP. The extension is the
    # only cheap way to distinguish an already-compressed NSZ here.
    if len(data) >= 4 and data[0:4] == b"PFS0":
        return P_SWITCH, "nsz" if path.suffix.lower() == ".nsz" else "nsp", 0.95

    # Native GameCube/Wii disc magic values live in the disc header, not at
    # offset zero. "HEAD" belongs to an XCI header and must not imply Wii.
    if len(data) >= 0x20 and data[0x18:0x1c] == b"\x5d\x1c\x9e\xa3":
        return P_WII, "iso", 0.85
    if len(data) >= 0x20 and data[0x1c:0x20] == b"\xc2\x33\x9f\x3d":
        return P_GC, "iso", 0.85

    # GameCube GCM
    if len(data) >= 4 and data[0:4] == b"\x00\x00\x00\x00" and len(data) > 0x400:
        if b"GAMECUBE" in data[0x400:0x500]:
            return P_GC, "iso", 0.90

    # PS-X at sector 16 (0x8000)
    sector16 = data[0x8000:0x9000] if len(data) > 0x8000 else b""
    if b"PS-X" in sector16[:4]:
        return P_PS1, "iso", 0.95
    if b"PLAYSTATION" in sector16:
        return P_PS1, "bin", 0.90

    # PSP boot sector
    if data[0x8000:0x8008] == b"\x00\x00\x00\x00\x00\x00\x00\x00" and len(data) >= 0x10000:
        if b"PSP" in data[0x8000:0x9000]:
            return P_PSP, "iso", 0.85

    # Dreamcast IP.BIN
    if b"SEGA SEGAKATANA" in data[:0x200] or b"SEGA" in data[:0x100]:
        return P_DC, "gdi", 0.85

    # Saturn
    if b"Saturn" in data[0x100:0x200] or b"SEGASATURN" in data[:0x200]:
        return P_SATURN, "iso", 0.85

    # 3DS NCSD
    if len(data) >= 0x100 and data[0x100:0x104] == b"NCSD":
        return P_3DS, "3ds", 0.95

    # CIA (3DS)
    if len(data) >= 4 and data[0:4] == b"\x00\x00\x00\x00" and _read_le32(data, 0x10) > 0:
        if data[0x18:0x20] == b"\x00\x00\x00\x00":
            return P_3DS, "cia", 0.80

    # NRO (Switch homebrew)
    if len(data) >= 0x20 and data[0:4] == b"\x7fELF":
        nro_magic = data[0x10:0x14]
        if nro_magic == b"NRO\x00":
            return P_SWITCH, "nro", 0.90

    return PLATFORM_UNKNOWN, FORMAT_UNKNOWN, 0.0


def _safe_read(path: Path, size: int = 0x10000) -> bytes | None:
    try:
        with open(path, "rb") as f:
            return f.read(size)
    except (OSError, PermissionError):
        return None


def detect_from_ext(path: Path) -> tuple[str, str, float]:
    ext = path.suffix.lower()
    name = path.name.lower()

    multi_ext = _multi_ext(name)
    if multi_ext in EXT_MAP:
        return EXT_MAP[multi_ext], ext, 0.80

    if ext in EXT_MAP:
        return EXT_MAP[ext], ext, 0.75

    if ext == ".rvz":
        return PLATFORM_UNKNOWN, "rvz", 0.80

    # Ambiguous but informative
    raw_disc = {".iso", ".bin", ".img", ".raw", ".mdf", ".nrg", ".ccd", ".sub"}
    if ext in raw_disc:
        return PLATFORM_UNKNOWN, ext, 0.40

    return PLATFORM_UNKNOWN, FORMAT_UNKNOWN, 0.0


def _multi_ext(name: str) -> str:
    parts = name.split(".")
    if len(parts) >= 3:
        return f".{parts[-2].lower()}.{parts[-1].lower()}"
    return ""


def detect_from_dir(path: Path, roms_root: Path | None = None) -> tuple[str, float]:
    names: list[str] = []
    if roms_root:
        try:
            rel = path.parent.relative_to(roms_root)
            names.extend(rel.parts)
            names.append(roms_root.name)
        except ValueError:
            names.append(path.parent.name)
    else:
        names.append(path.parent.name)

    normalized_map = {
        _normalized_dir_name(alias): platform for alias, platform in DIR_MAP.items()
    }
    for name in names:
        platform = normalized_map.get(_normalized_dir_name(name))
        if platform:
            return platform, 0.70
    return PLATFORM_UNKNOWN, 0.0


def _normalized_dir_name(value: str) -> str:
    return re.sub(r"[-_\s]+", "", value.casefold())


SIZE_RANGES: list[tuple[int, int, str, float]] = [
    (500_000_000, 900_000_000, P_PS1, 0.50),
    (500_000_000, 900_000_000, P_DC, 0.45),
    (500_000_000, 900_000_000, P_SATURN, 0.40),
    (1_000_000_000, 2_000_000_000, P_PSP, 0.45),
    (4_000_000_000, 5_000_000_000, P_PS2, 0.55),
    (4_000_000_000, 5_000_000_000, P_WII, 0.50),
    (700_000_000, 3_000_000_000, P_GC, 0.35),
    (6_000_000_000, 9_000_000_000, P_PS3, 0.30),
    (15_000_000_000, 50_000_000_000, P_PS3, 0.40),
]


def detect_size(path: Path) -> tuple[str, float]:
    try:
        size = path.stat().st_size
    except OSError:
        return PLATFORM_UNKNOWN, 0.0
    for lo, hi, platform, conf in SIZE_RANGES:
        if lo <= size <= hi:
            return platform, conf
    return PLATFORM_UNKNOWN, 0.0


DetectResult = tuple[str, str, str, float]
# (platform, format, method, confidence)


def detect(path: Path, roms_root: Path | None = None) -> DetectResult:
    plat_m, fmt_m, conf_m = detect_from_magic(path)
    if plat_m != PLATFORM_UNKNOWN and conf_m >= 0.85:
        return plat_m, fmt_m, "magic", conf_m

    plat_e, fmt_e, conf_e = detect_from_ext(path)
    plat_d, conf_d = detect_from_dir(path, roms_root)

    # If magic and dir agree, high confidence
    if plat_m != PLATFORM_UNKNOWN and plat_m == plat_d and conf_m + conf_d >= 1.0:
        return plat_m, fmt_m or fmt_e, "magic+dir", max(conf_m, conf_d)

    # If magic has medium confidence, use it
    if plat_m != PLATFORM_UNKNOWN and conf_m >= 0.60:
        return plat_m, fmt_m, "magic", conf_m

    # Extension + dir: moderate
    if plat_e != PLATFORM_UNKNOWN and plat_e == plat_d:
        return plat_e, fmt_e, "ext+dir", max(conf_e, conf_d)

    # Extension alone
    if plat_e != PLATFORM_UNKNOWN and conf_e >= 0.50:
        return plat_e, fmt_e, "ext", conf_e

    # Directory alone
    if plat_d != PLATFORM_UNKNOWN:
        fmt = fmt_m if fmt_m != FORMAT_UNKNOWN else path.suffix.lower().lstrip(".")
        method = "magic+dir" if fmt_m != FORMAT_UNKNOWN else "dir"
        return plat_d, fmt, method, max(conf_m, conf_d)

    # Size heuristic as last resort for raw images
    if fmt_e in ("iso", "bin", "img", "raw", "mdf"):
        plat_s, conf_s = detect_size(path)
        if plat_s != PLATFORM_UNKNOWN:
            return plat_s, fmt_e, "size", conf_s

    return PLATFORM_UNKNOWN, FORMAT_UNKNOWN, "none", 0.0


def detect_platform(path: Path, *, force: str | None = None) -> tuple[str, float] | None:
    if force:
        if force in DIR_MAP:
            return DIR_MAP[force], 1.0
        return force, 1.0
    plat, _, _, conf = detect(path)
    if plat != PLATFORM_UNKNOWN:
        return plat, conf
    return None


ROM_EXTENSIONS = {
    ".iso", ".bin", ".cue", ".img", ".raw", ".mdf", ".nrg", ".ccd",
    ".gdi", ".cdi", ".dax",
    ".chd", ".rvz", ".wbfs", ".ciso", ".gcz", ".gcm",
    ".cso", ".zso", ".pbp",
    ".nsp", ".xci", ".nsz", ".xcz", ".nro",
    ".zip", ".7z", ".gz",
    ".nes", ".smc", ".sfc", ".fig", ".n64", ".z64", ".v64",
    ".gb", ".gbc", ".gba", ".nds", ".3ds", ".cia",
    ".gen", ".smd", ".md", ".sms", ".gg",
    ".lnx", ".ngp", ".ngc", ".ws", ".wsc",
    ".wad", ".wua", ".wud",
    ".wux",
    ".pkg", ".vpk",
}


_CUE_FILE_RE = re.compile(r'^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+', re.IGNORECASE)


def cue_referenced_files(cue_path: Path) -> set[Path]:
    """Return existing same-tree files referenced by a CUE sheet.

    Paths escaping the CUE directory are ignored. This prevents an untrusted
    sheet from expanding cleanup scope outside the selected ROM directory.
    """
    referenced: set[Path] = set()
    try:
        parent = cue_path.parent.resolve()
        for line in cue_path.read_text("utf-8-sig", errors="replace").splitlines():
            match = _CUE_FILE_RE.match(line)
            if not match:
                continue
            candidate = (cue_path.parent / (match.group(1) or match.group(2))).resolve()
            try:
                candidate.relative_to(parent)
            except ValueError:
                continue
            if candidate.is_file():
                referenced.add(candidate)
    except OSError:
        return set()
    return referenced


def gdi_referenced_files(gdi_path: Path) -> set[Path]:
    """Return existing same-tree track files referenced by a GDI descriptor."""
    referenced: set[Path] = set()
    try:
        parent = gdi_path.parent.resolve()
        lines = gdi_path.read_text("utf-8-sig", errors="replace").splitlines()
        for line in lines[1:]:
            try:
                fields = shlex.split(line, posix=True)
            except ValueError:
                continue
            if len(fields) < 5:
                continue
            candidate = (gdi_path.parent / fields[4]).resolve()
            try:
                candidate.relative_to(parent)
            except ValueError:
                continue
            if candidate.is_file():
                referenced.add(candidate)
    except OSError:
        return set()
    return referenced


def disc_referenced_files(descriptor: Path) -> set[Path]:
    suffix = descriptor.suffix.lower()
    if suffix == ".cue":
        return cue_referenced_files(descriptor)
    if suffix == ".gdi":
        return gdi_referenced_files(descriptor)
    if suffix == ".ccd":
        return {
            candidate
            for extension in (".img", ".sub")
            if (candidate := descriptor.with_suffix(extension)).is_file()
        }
    return set()


def find_roms(directory: Path, *, recursive: bool = True) -> list[Path]:
    if not directory.is_dir():
        return []
    iterator = directory.rglob("*") if recursive else directory.iterdir()
    found = [
        f for f in iterator
        if f.is_file()
        and f.suffix.lower() in ROM_EXTENSIONS
        and ".romopt" not in f.relative_to(directory).parts
    ]

    # A CUE is the conversion input; its track BIN/IMG files must not be
    # converted independently. Multi-track sets otherwise produce partial or
    # duplicate CHDs and unsafe cleanup decisions.
    sidecar_inputs: set[Path] = set()
    descriptors = [
        file for file in found if file.suffix.lower() in {".cue", ".gdi", ".ccd"}
    ]
    for descriptor in descriptors:
        sidecar_inputs.update(disc_referenced_files(descriptor))
        if descriptor.suffix.lower() == ".cue":
            # CUE is authoritative when competing same-stem descriptors exist.
            sidecar_inputs.update(
                candidate.resolve()
                for extension in (".ccd", ".img", ".sub")
                if (candidate := descriptor.with_suffix(extension)).is_file()
            )
    return sorted(f for f in found if f.resolve() not in sidecar_inputs)
