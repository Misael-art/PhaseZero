from __future__ import annotations

import hashlib
import posixpath
import stat
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

MAX_ENTRIES = 20_000
MAX_TOTAL_UNCOMPRESSED = 16 * 1024**3
MAX_ENTRY_UNCOMPRESSED = 8 * 1024**3
# Legitimate game data can contain zero-padded regions, so the expansion-ratio
# guard only trips on archives that are both large and implausibly dense.
BOMB_RATIO = 400
BOMB_MIN_UNCOMPRESSED = 256 * 1024**2
_READ_CHUNK = 1024 * 1024


@dataclass
class ZipProbe:
    ok: bool
    reason: str = ""
    names: list[str] = field(default_factory=list)
    total_uncompressed: int = 0
    total_compressed: int = 0


def _entry_name_error(name: str) -> str:
    if not name:
        return "empty entry name"
    if "\\" in name:
        return "backslash in entry name"
    if name.startswith("/"):
        return "absolute entry path"
    if len(name) >= 2 and name[1] == ":":
        return "drive letter in entry path"
    parts = posixpath.normpath(name).split("/")
    if ".." in parts:
        return "path traversal in entry"
    if any("\x00" in part for part in parts):
        return "NUL byte in entry name"
    return ""


def _is_symlink(info: zipfile.ZipInfo) -> bool:
    return stat.S_ISLNK(info.external_attr >> 16)


def probe(path: Path) -> ZipProbe:
    """List and validate a ZIP without extracting anything."""
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
    except (OSError, zipfile.BadZipFile, NotImplementedError) as exc:
        return ZipProbe(False, f"unreadable zip: {exc}")

    if len(infos) > MAX_ENTRIES:
        return ZipProbe(False, f"too many entries ({len(infos)} > {MAX_ENTRIES})")

    names: list[str] = []
    total_unc = 0
    total_cmp = 0
    for info in infos:
        error = _entry_name_error(info.filename)
        if error:
            return ZipProbe(False, f"{error}: {info.filename!r}")
        if _is_symlink(info):
            return ZipProbe(False, f"symlink entry rejected: {info.filename!r}")
        if info.file_size > MAX_ENTRY_UNCOMPRESSED:
            return ZipProbe(False, f"entry too large: {info.filename!r}")
        total_unc += info.file_size
        total_cmp += info.compress_size
        names.append(info.filename)

    if total_unc > MAX_TOTAL_UNCOMPRESSED:
        return ZipProbe(False, f"archive expands past limit ({total_unc} bytes)")
    if (
        total_unc > BOMB_MIN_UNCOMPRESSED
        and total_unc // max(total_cmp, 1) > BOMB_RATIO
    ):
        return ZipProbe(False, "expansion ratio exceeds archive-bomb limit")

    return ZipProbe(True, "", names, total_unc, total_cmp)


def read_member(path: Path, member: str, limit: int = 8 * 1024**2) -> bytes | None:
    """Read one small member fully in memory, honoring a hard size cap."""
    try:
        with zipfile.ZipFile(path) as archive:
            info = archive.getinfo(member)
            if info.file_size > limit:
                return None
            with archive.open(info) as handle:
                data = handle.read(limit + 1)
    except (KeyError, OSError, zipfile.BadZipFile, NotImplementedError):
        return None
    if len(data) > limit:
        return None
    return data


def extract_member(
    archive: zipfile.ZipFile, info: zipfile.ZipInfo, destination: Path
) -> tuple[int, str]:
    """Stream one validated member to ``destination``; returns (bytes, sha256).

    The caller is responsible for having validated names via :func:`probe`.
    Declared sizes are enforced during the read so a lying header cannot fill
    the disk.
    """
    digest = hashlib.sha256()
    written = 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with archive.open(info) as source, open(destination, "wb") as target:
            while True:
                chunk = source.read(_READ_CHUNK)
                if not chunk:
                    break
                written += len(chunk)
                if written > info.file_size:
                    raise ValueError(
                        f"entry {info.filename!r} exceeds its declared size"
                    )
                digest.update(chunk)
                target.write(chunk)
    except zipfile.BadZipFile as exc:
        destination.unlink(missing_ok=True)
        raise ValueError(f"invalid zip member {info.filename!r}: {exc}") from exc
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    return written, digest.hexdigest()
