from __future__ import annotations
import copy
import os
import signal
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from .profile import Profile

ConvertResult = tuple[int, str, str]  # (returncode, stdout, stderr)


def _run(cmd: list[str], *, timeout: int = 300) -> ConvertResult:
    try:
        # Never let a converter prompt for keys, overwrite confirmation, or
        # other interactive input. A batch optimizer must fail closed instead
        # of hanging with a half-written staging file.
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                process.kill()
            process.communicate()
            return 124, "", "timeout"
        return process.returncode, stdout, stderr
    except FileNotFoundError:
        return 127, "", f"binary not found: {cmd[0]}"
    except OSError as exc:
        return 126, "", f"unable to execute {cmd[0]}: {exc}"


def convert_chd(
    source: Path,
    dest: Path,
    profile: Profile,
    *,
    chdman: str = "chdman",
    timeout: int = 600,
) -> ConvertResult:
    # Large optical images are DVDs, not hard disks. `createhd` creates hard
    # drive metadata and yields unsuitable PS2 CHDs; MAME provides `createdvd`
    # specifically for DVD-ROM images.
    input_type = _detect_chd_input(source)
    subcmd = "createdvd" if input_type == "dvd" else "createcd"

    # For createcd: prefer .cue if available
    if subcmd == "createcd":
        cue = source.with_suffix(".cue")
        if cue.exists() and source.suffix.lower() in (".bin", ".img"):
            source = cue

    cmd = [chdman, subcmd, "--force", "-i", str(source), "-o", str(dest)]
    if profile.chd_compression:
        cmd.extend(["-c", profile.chd_compression])
    # Let chdman choose media-correct defaults. A CD hunk must align to a CD
    # frame (2352 bytes), so a generic 16 KiB value is invalid for createcd.
    return _run(cmd, timeout=timeout)


def _detect_chd_input(path: Path) -> str:
    """Return ``cd`` or ``dvd`` for an optical-disc input."""
    try:
        size = path.stat().st_size
        # CD-ROM images top out around 900 MB. PS2 DVD dumps are often much
        # smaller than 3.5 GB after trimming, but still require createdvd.
        if path.suffix.lower() == ".iso" and size > 900_000_000:
            return "dvd"
    except OSError:
        pass
    ext = path.suffix.lower()
    if ext in (".gdi", ".cdi", ".cue"):
        return "cd"
    return "cd"


def _rvz_compression(spec: str) -> tuple[str, int | None]:
    method, sep, level_text = spec.partition(":")
    if method == "none":
        return method, None
    try:
        level = int(level_text) if sep else 5
    except ValueError:
        level = 5
    method = method or "zstd"
    maximum = 22 if method == "zstd" else 9
    return method, max(1, min(level, maximum))


def convert_rvz(
    source: Path,
    dest: Path,
    profile: Profile,
    *,
    tool: str = "dolphin-tool",
    timeout: int = 600,
) -> ConvertResult:
    method, level = _rvz_compression(profile.rvz_compression)
    cmd = [tool, "convert"]
    cmd.extend(["-i", str(source), "-o", str(dest)])
    cmd.extend(["-f", "rvz", "-b", "131072", "-c", method])
    if level is not None:
        cmd.extend(["-l", str(level)])
    if profile.rvz_purge:
        cmd.append("-s")
    return _run(cmd, timeout=timeout)


def convert_cso(
    source: Path,
    dest: Path,
    profile: Profile,
    fmt: str = "cso",
    *,
    timeout: int = 600,
) -> ConvertResult:
    maxcso_format = "cso1" if fmt == "cso" else "zso"
    cmd = [
        "maxcso",
        f"--format={maxcso_format}",
        "--block=2048",
        str(source),
        "-o",
        str(dest),
    ]
    if profile.name == "speed":
        cmd.insert(1, "--fast")
    return _run(cmd, timeout=timeout)


def convert_nsz_compress(
    source: Path,
    dest: Path,
    profile: Profile | None = None,
    *,
    tool: str = "nsz",
    timeout: int = 600,
) -> ConvertResult:
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=".romopt-nsz-", dir=dest.parent
        ) as output_dir:
            cmd = [tool, "-C", "-o", output_dir, str(source)]
            rc, stdout, stderr = _run(cmd, timeout=timeout)
            if rc != 0:
                return rc, stdout, stderr
            expected_suffix = ".xcz" if source.suffix.lower() == ".xci" else ".nsz"
            outputs = [
                candidate
                for candidate in Path(output_dir).rglob("*")
                if candidate.is_file() and candidate.suffix.lower() == expected_suffix
            ]
            if len(outputs) != 1 or outputs[0].is_symlink() or outputs[0].stat().st_size <= 0:
                return 1, stdout, (
                    f"nsz produced {len(outputs)} valid {expected_suffix} outputs; expected 1"
                )
            os.replace(outputs[0], dest)
            return 0, stdout, stderr
    except OSError as exc:
        return 1, "", f"failed to stage NSZ output: {exc}"


def convert_zip(
    roms: list[Path],
    dest_zip: Path,
    profile: Profile,
    *,
    timeout: int = 600,
) -> ConvertResult:
    try:
        with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=profile.zip_level) as zf:
            for rom in roms:
                zf.write(rom, arcname=rom.name)
        return 0, f"created: {dest_zip}", ""
    except Exception as e:
        return 1, "", str(e)


def rezip_archive(
    source_zip: Path,
    dest_zip: Path,
    profile: Profile,
    *,
    timeout: int = 600,
) -> ConvertResult:
    try:
        with zipfile.ZipFile(source_zip, "r") as zin:
            with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_DEFLATED,
                                 compresslevel=profile.zip_level) as zout:
                for item in zin.infolist():
                    force = profile.zip_force and item.compress_type == zipfile.ZIP_DEFLATED
                    if item.compress_type in (zipfile.ZIP_STORED, 1, 2, 3, 4, 5, 6, 7) or force:
                        target_info = copy.copy(item)
                        target_info.compress_type = zipfile.ZIP_DEFLATED
                        if hasattr(target_info, "compress_level"):
                            target_info.compress_level = profile.zip_level
                        else:
                            # Python <3.13 exposes this only through the
                            # private field consumed by ZipFile.open().
                            target_info._compresslevel = profile.zip_level
                    else:
                        target_info = copy.copy(item)
                    if item.is_dir():
                        zout.writestr(target_info, b"")
                        continue
                    # Stream entries. A multi-gigabyte ROM or hostile ZIP must
                    # not be materialized in process memory.
                    with zin.open(item, "r") as source_handle:
                        with zout.open(target_info, "w", force_zip64=True) as dest_handle:
                            shutil.copyfileobj(source_handle, dest_handle, 1024 * 1024)
        return 0, f"recompressed: {dest_zip}", ""
    except Exception as e:
        return 1, "", str(e)


CONVERTERS = {"chd", "rvz", "cso", "zso", "nsz", "xcz", "zip", "rezip"}


def convert(
    target_format: str,
    source: Path,
    dest: Path,
    profile: Profile,
    *,
    timeout: int = 600,
) -> ConvertResult:
    if target_format == "chd":
        return convert_chd(source, dest, profile, timeout=timeout)
    if target_format == "rvz":
        return convert_rvz(source, dest, profile, timeout=timeout)
    if target_format in ("cso", "zso"):
        return convert_cso(source, dest, profile, fmt=target_format, timeout=timeout)
    if target_format in ("nsz", "xcz"):
        return convert_nsz_compress(source, dest, profile, timeout=timeout)
    if target_format == "zip":
        return convert_zip([source], dest, profile, timeout=timeout)
    if target_format == "rezip":
        return rezip_archive(source, dest, profile, timeout=timeout)
    return 1, "", f"no converter for format: {target_format}"
