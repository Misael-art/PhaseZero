from __future__ import annotations
from pathlib import Path
from dataclasses import dataclass, replace

# Platform identifiers (imported from detect)
PLATFORMS: set[str] = {
    "ps1", "ps2", "psp", "dreamcast", "saturn", "megacd",
    "pcengine", "neogeocd", "3do", "pcfx", "fmtowns",
    "jaguarcd", "amigacd32", "wii", "gc", "switch",
    "nes", "snes", "n64", "gb", "gbc", "gba", "nds", "n3ds",
    "genesis", "megadrive", "mastersystem", "gamegear",
    "atarilynx", "ngp", "ws",
    "ps3", "ps4", "psvita", "xbox", "xbox360", "wiiu",
}

PLATFORM_ALIASES: dict[str, str] = {
    "psx": "ps1", "playstation": "ps1",
    "dc": "dreamcast",
    "ss": "saturn",
    "segacd": "megacd",
    "pce": "pcengine", "tg16": "pcengine", "turbografx": "pcengine", "tg-cd": "pcengine",
    "ngcd": "neogeocd",
    "nintendo64": "n64",
    "gameboy": "gb", "gameboycolor": "gbc", "gameboyadvance": "gba",
    "ds": "nds",
    "3ds": "n3ds",
    "supernes": "snes",
    "sms": "mastersystem",
    "gg": "gamegear",
    "atarilynx": "atarilynx",
    "ngp": "ngp",
    "ws": "ws", "wonderswan": "ws",
    "vita": "psvita", "psv": "psvita",
    "nsw": "switch",
    "gamecube": "gc", "ngc": "gc",
    "wiiu": "wiiu",
}


@dataclass
class Profile:
    name: str
    psp_target: str = "cso"
    chd_hunk_size: int = 16384
    chd_compression: str = "zlib"
    rvz_compression: str = "zstd:5"
    rvz_purge: bool = True
    zip_level: int = 9
    zip_method: str = "deflate"
    zip_force: bool = False
    cdda_mode: str = "flac"  # flac (lossless) | ogg (lossy)

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not self.name.strip():
            raise ValueError("profile name must be a non-empty string")
        if self.psp_target not in {"cso", "zso"}:
            raise ValueError("psp_target must be 'cso' or 'zso'")
        if not isinstance(self.chd_hunk_size, int) or self.chd_hunk_size <= 0:
            raise ValueError("chd_hunk_size must be a positive integer")
        if not isinstance(self.chd_compression, str):
            raise ValueError("chd_compression must be a string")
        if not isinstance(self.rvz_compression, str):
            raise ValueError("rvz_compression must be a string")
        rvz_method, separator, rvz_level = self.rvz_compression.partition(":")
        if rvz_method not in {"none", "zstd", "bzip2", "lzma", "lzma2"}:
            raise ValueError("unsupported rvz_compression method")
        if rvz_method != "none":
            if not separator or not rvz_level.isdecimal():
                raise ValueError("rvz_compression must use method:level")
            level = int(rvz_level)
            max_level = 22 if rvz_method == "zstd" else 9
            if not 1 <= level <= max_level:
                raise ValueError(
                    f"rvz_compression level for {rvz_method} must be 1..{max_level}"
                )
        elif separator:
            raise ValueError("rvz_compression 'none' does not accept a level")
        if not isinstance(self.rvz_purge, bool):
            raise ValueError("rvz_purge must be a boolean")
        if not isinstance(self.zip_level, int) or not 0 <= self.zip_level <= 9:
            raise ValueError("zip_level must be an integer from 0 to 9")
        if self.zip_method != "deflate":
            raise ValueError("zip_method currently supports only 'deflate'")
        if not isinstance(self.zip_force, bool):
            raise ValueError("zip_force must be a boolean")
        if self.cdda_mode not in {"flac", "ogg"}:
            raise ValueError("cdda_mode must be 'flac' or 'ogg'")

    def chd_createcd_flags(self) -> list[str]:
        return [
            "--compression", self.chd_compression,
            "--hunksize", str(self.chd_hunk_size),
        ]

    def chd_createhd_flags(self) -> list[str]:
        return [
            "--compression", self.chd_compression,
            "--hunksize", str(self.chd_hunk_size * 4),
        ]

    def rvz_flags(self) -> list[str]:
        return [
            "--format", "rvz",
            "--compression", self.rvz_compression,
        ] + (["--purge"] if self.rvz_purge else [])

    def maxcso_flags(self, fmt: str = "cso") -> list[str]:
        level = {"cso": 6, "zso": 1}.get(fmt, 6)
        return ["--format", fmt, "--level", str(level)]

    @classmethod
    def load(cls, spec: str | Path) -> Profile:
        if isinstance(spec, Path):
            if not spec.is_file():
                raise FileNotFoundError(spec)
            import json
            data = json.loads(spec.read_text("utf-8"))
            if not isinstance(data, dict):
                raise ValueError("profile JSON root must be an object")
            return cls(**data)
        name = str(spec).lower()
        if name in PROFILES:
            return replace(PROFILES[name])
        raise ValueError(f"unknown profile: {spec}")


PROFILES: dict[str, Profile] = {
    "speed": Profile(
        name="speed",
        psp_target="zso",
        chd_hunk_size=65536,
        chd_compression="zlib",
        rvz_compression="zstd:1",
        zip_level=6,
        zip_force=False,
    ),
    "balanced": Profile(
        name="balanced",
        psp_target="cso",
        chd_hunk_size=16384,
        chd_compression="zlib",
        rvz_compression="zstd:5",
        zip_level=9,
        zip_force=False,
    ),
    "archive": Profile(
        name="archive",
        psp_target="cso",
        chd_hunk_size=16384,
        chd_compression="lzma",
        rvz_compression="zstd:7",
        zip_level=9,
        zip_force=True,
        cdda_mode="flac",
    ),
}
