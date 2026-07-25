from __future__ import annotations
import zipfile
from pathlib import Path

from .profile import Profile


def check_zip_optimal(zip_path: Path) -> tuple[bool, list[str]]:
    """Return (is_optimal, list of entries needing recompression).
    ZIP_DEFLATED (8), BZIP2 (12), LZMA (14), and Zstd (93) are already
    well-compressed. Stored and unknown/legacy methods need recompression.
    Every entry is CRC-tested before an archive can be called optimal."""
    efficient_methods = {
        zipfile.ZIP_DEFLATED,
        zipfile.ZIP_BZIP2,
        zipfile.ZIP_LZMA,
        getattr(zipfile, "ZIP_ZSTANDARD", 93),
    }
    suboptimal: list[str] = []
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            for info in zf.infolist():
                if not info.is_dir() and info.compress_type not in efficient_methods:
                    suboptimal.append(info.filename)
            bad = zf.testzip()
            if bad:
                return False, [f"<unreadable: corrupt entry {bad}>"]
    except Exception as e:
        # A corrupt/unreadable ZIP is NOT optimal — surface it so the caller
        # can quarantine rather than silently treating it as good.
        return False, [f"<unreadable: {e}>"]
    return len(suboptimal) == 0, suboptimal


def group_loose_roms(roms: list[Path]) -> dict[str, list[Path]]:
    groups: dict[str, list[Path]] = {}
    for rom in roms:
        stem = rom.stem
        groups.setdefault(stem, []).append(rom)
    return groups


def needs_optimization(files: list[Path], profile: Profile) -> list[tuple[Path, str | None]]:
    """Check each file: returns (path, action) where action is None=skip, 'zip'=archive, 'rezip'=recompress."""
    result: list[tuple[Path, str | None]] = []
    for f in files:
        if f.suffix.lower() == ".zip":
            optimal, _ = check_zip_optimal(f)
            if not optimal or profile.zip_force:
                result.append((f, "rezip"))
            else:
                result.append((f, None))
        else:
            result.append((f, "zip"))
    return result
