from __future__ import annotations
import os
import shutil
from pathlib import Path

from .detect import disc_referenced_files


def safe_remove(path: Path, *, dry_run: bool = False) -> bool:
    if not path.exists():
        return False
    if dry_run:
        return True
    try:
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        return True
    except OSError:
        return False


def source_unchanged(source: Path, saved_sig: tuple) -> bool:
    try:
        st = source.stat()
        return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns) == saved_sig
    except OSError:
        return False


def save_source_sig(source: Path) -> tuple:
    st = source.stat()
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)


def clean_after_convert(
    source: Path,
    dest: Path,
    saved_sig: tuple,
    *,
    delete_archive: bool = False,
    archive_to_delete: Path | None = None,
    dry_run: bool = False,
) -> dict[str, bool]:
    result = {"source_removed": False, "archive_removed": False}

    if not source_unchanged(source, saved_sig):
        return result

    if not dest.is_file() or dest.stat().st_size <= 0:
        return result

    if dry_run:
        result["source_removed"] = True
    else:
        try:
            source.unlink()
            result["source_removed"] = True
        except OSError:
            pass

    if delete_archive and archive_to_delete and archive_to_delete.exists():
        if dry_run:
            result["archive_removed"] = True
        else:
            try:
                archive_to_delete.unlink()
                result["archive_removed"] = True
            except OSError:
                pass

    return result


# Extensions of disc-image sidecars that chdman createcd bundles into the .chd.
# After a successful CHD conversion these are redundant and safe to remove.
_CHD_SIDECAR_EXTS = {".cue", ".gdi", ".bin", ".img", ".raw", ".sub", ".ccd"}


def chd_input_files(source: Path) -> set[Path]:
    """Return files chdman is expected to consume for ``source``."""
    inputs = {source}
    descriptor = source
    if source.suffix.lower() not in {".cue", ".gdi", ".ccd"}:
        for extension in (".cue", ".gdi", ".ccd"):
            candidate = source.with_suffix(extension)
            if candidate.is_file():
                descriptor = candidate
                inputs.add(candidate)
                break
    inputs.update(disc_referenced_files(descriptor))
    for extension in _CHD_SIDECAR_EXTS:
        candidate = source.with_suffix(extension)
        if candidate.is_file():
            inputs.add(candidate)
    return inputs


def save_source_sigs(paths: set[Path]) -> dict[Path, tuple]:
    signatures: dict[Path, tuple] = {}
    for path in paths:
        try:
            signatures[path] = save_source_sig(path)
        except OSError:
            continue
    return signatures


def remove_chd_sidecars(
    source: Path,
    *,
    saved_sigs: dict[Path, tuple] | None = None,
    dry_run: bool = False,
) -> list[str]:
    """Delete descriptor sidecars consumed by a verified CHD conversion.
    `chdman createcd` ingests these into a self-contained .chd, so they are no
    longer needed once the .chd is verified. Returns the paths removed.
    Only files captured before conversion are touched. Descriptor-referenced
    tracks may use different stems but cannot escape the descriptor directory."""
    removed: list[str] = []
    candidates = set(saved_sigs) if saved_sigs is not None else chd_input_files(source)
    # Legacy same-stem sidecars not named in a CUE may still be consumed by
    # chdman. Only include files captured before conversion when signatures are
    # supplied; never expand deletion scope after conversion.
    for ext in _CHD_SIDECAR_EXTS:
        candidate = source.parent / f"{source.stem}{ext}"
        if candidate.is_file():
            candidates.add(candidate)
    for candidate in sorted(candidates):
        if candidate == source:
            continue
        if saved_sigs is not None:
            signature = saved_sigs.get(candidate)
            if signature is None or not source_unchanged(candidate, signature):
                continue
        if candidate.is_file():
            if dry_run:
                removed.append(str(candidate))
                continue
            try:
                candidate.unlink()
                removed.append(str(candidate))
            except OSError:
                pass
    return removed
