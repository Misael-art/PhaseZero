from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import uuid
from pathlib import Path

from .profile import Profile, PLATFORMS, PLATFORM_ALIASES
from . import cartridge
from . import clean
from . import convert
from . import dats
from . import decision
from . import detect
from . import manifest
from . import rename
from . import verify


ARCHIVE_FORMATS = {"7z", "gz"}


def build_argparser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="romopt",
        description="Atomically detect, convert, verify, and optionally clean ROM images.",
    )
    parser.add_argument(
        "--platform",
        choices=sorted(PLATFORMS | set(PLATFORM_ALIASES)),
        help="Force platform for every selected ROM",
    )
    parser.add_argument("--rom-dir", type=Path, help="Directory with ROMs to process")
    parser.add_argument(
        "--dest-dir",
        type=Path,
        help="Output root; relative source subdirectories are preserved (default: in-place)",
    )
    parser.add_argument("--profile", choices=["balanced", "speed", "archive"], default="balanced")
    parser.add_argument("--profile-file", type=Path, help="Custom profile JSON file")
    parser.add_argument("--dry-run", action="store_true", help="Preview without writing any file")
    parser.add_argument("--json", action="store_true", help="Emit a final machine-readable result envelope")

    verification = parser.add_mutually_exclusive_group()
    verification.add_argument(
        "--verify",
        dest="verify",
        action="store_true",
        default=True,
        help="Verify each staged output before commit (default)",
    )
    verification.add_argument(
        "--no-verify",
        dest="verify",
        action="store_false",
        help="Skip format verification; incompatible with --clean",
    )

    cleanup = parser.add_mutually_exclusive_group()
    cleanup.add_argument("--clean", action="store_true", help="Remove verified source inputs")
    cleanup.add_argument(
        "--keep-original", dest="clean", action="store_false", help="Keep source inputs (default)"
    )
    parser.set_defaults(clean=False)

    parser.add_argument("--rename", action="store_true", help="Rename using DAT/serial metadata")
    parser.add_argument("--dat-dir", type=Path, help="User-supplied No-Intro/Redump DAT directory")
    parser.add_argument("--sync", action="store_true", help="Sync saves/states/media with a rename")
    parser.add_argument("--emulation-root", type=Path, help="Root used for rename sync")
    parser.add_argument("--manifest", type=Path, help="Manifest journal directory")
    parser.add_argument("--delete-archives", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--timeout", type=int, default=600, help="Per-tool timeout in seconds")
    parser.add_argument("--jobs", type=int, default=1, help="Parallel jobs (currently must be 1)")
    return parser


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_dat_name(value: str) -> str:
    # DAT names are user-controlled XML. Keep them as one filesystem component.
    cleaned = "".join(" " if ord(char) < 32 or ord(char) == 127 else char for char in value)
    cleaned = cleaned.replace("/", "-").replace("\\", "-").strip(" .")
    cleaned = " ".join(cleaned.split())
    # Leave room for the extension and temporary suffix on common filesystems.
    while len(cleaned.encode("utf-8")) > 180:
        cleaned = cleaned[:-1]
    return cleaned.strip(" .")


def _dat_name(path: Path, platform: str, dat_dir: Path, *, cache: bool) -> str:
    index = dats.load_index(dat_dir, platform, cache=cache)
    if not index:
        return ""
    match = None
    if platform in detect.CARTRIDGE_SYSTEMS:
        match = dats.match_by_crc32(index, rename.compute_crc32(path))
    else:
        serial = rename.extract_serial(path, platform)
        if serial:
            match = dats.match_by_serial(index, serial)
        if not match:
            match = dats.match_by_sha1(index, rename.compute_sha1(path))
    if not match:
        return ""
    return _safe_dat_name(str(match.get("name", "")))


def _rename_target(path: Path, platform: str, dat_dir: Path | None, *, cache: bool) -> Path:
    name = _dat_name(path, platform, dat_dir, cache=cache) if dat_dir else ""
    if not name:
        serial = rename.extract_serial(path, platform)
        game_id = rename.extract_game_id(path, platform)
        region = rename.detect_region(path.name)
        name = rename.build_no_intro_name(
            path, serial=serial, game_id=game_id, region=region
        )
    name = _safe_dat_name(name) or path.stem
    return path.with_name(f"{name}{path.suffix}")


def _destination_parent(rom: Path, rom_dir: Path, dest_root: Path | None) -> Path:
    if dest_root is None:
        return rom.parent
    try:
        relative_parent = rom.parent.relative_to(rom_dir)
    except ValueError:
        relative_parent = Path()
    return dest_root / relative_parent


def _stage_path(destination: Path) -> Path:
    token = uuid.uuid4().hex
    return destination.with_name(
        f".{destination.stem}.{token}.romopt.tmp{destination.suffix}"
    )


def _result_failure(rom: Path, status: str, message: str, **extra: object) -> dict:
    return {"rom": str(rom), "status": status, "error": message, **extra}


def main(argv: list[str] | None = None) -> int:
    parser = build_argparser()
    args = parser.parse_args(argv)

    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    if args.jobs != 1:
        parser.error("--jobs currently supports only 1; parallel commit safety is not implemented")
    if args.clean and not args.verify:
        parser.error("--clean requires verification; remove --no-verify")
    if args.delete_archives:
        parser.error("archive extraction/deletion is not implemented; source archives are preserved")
    if args.sync and not args.rename:
        parser.error("--sync requires --rename")
    if args.profile_file and not args.profile_file.is_file():
        parser.error(f"profile file not found: {args.profile_file}")

    try:
        profile = Profile.load(args.profile_file) if args.profile_file else Profile.load(args.profile)
    except (OSError, ValueError, TypeError) as exc:
        parser.error(f"invalid profile: {exc}")

    rom_dir = (args.rom_dir or Path.cwd()).expanduser()
    if not rom_dir.is_dir():
        print(f"ROM directory not found: {rom_dir}", file=sys.stderr)
        if args.json:
            print(json.dumps({"status": "fail", "error": "ROM directory not found", "results": []}))
        return 2
    rom_dir = rom_dir.resolve()
    dest_root = args.dest_dir.expanduser().resolve() if args.dest_dir else None

    platform = PLATFORM_ALIASES.get(args.platform, args.platform)
    roms = detect.find_roms(rom_dir)
    if dest_root and dest_root != rom_dir:
        # Do not re-ingest pre-existing outputs when destination lives below
        # the selected source tree.
        try:
            dest_root.relative_to(rom_dir)
        except ValueError:
            pass
        else:
            roms = [
                rom for rom in roms
                if dest_root not in (rom.resolve(), *rom.resolve().parents)
            ]
    if not roms:
        print("No ROMs found", file=sys.stderr)
        if args.json:
            print(json.dumps({"status": "warn", "error": "No ROMs found", "results": []}))
        return 1

    manifest_dir = args.manifest or (dest_root or rom_dir) / ".romopt"
    print(f"Found {len(roms)} ROM(s) in {rom_dir}")
    results: list[dict] = []

    for original_rom in roms:
        rom = original_rom
        planned_rename: Path | None = None
        renamed_from: Path | None = None
        print(f"\n{'=' * 60}\n  {rom.name}\n{'=' * 60}")
        detected_platform, current_fmt, method, confidence = detect.detect(rom, rom_dir)
        plat = platform or detected_platform
        fmt_key = current_fmt.lower().lstrip(".")
        if fmt_key == detect.FORMAT_UNKNOWN:
            fmt_key = rom.suffix.lower().lstrip(".")

        if plat == detect.PLATFORM_UNKNOWN:
            message = "unknown platform; use --platform"
            print(f"  ✗ {message}")
            results.append(_result_failure(rom, "unknown_platform", message))
            continue
        if platform:
            method, confidence = "forced", 1.0

        print(f"  Platform: {plat} ({confidence:.2f}, via {method})")
        print(f"  Current format: {fmt_key}")

        if args.rename:
            new_path = _rename_target(rom, plat, args.dat_dir, cache=not args.dry_run)
            if new_path != rom:
                if new_path.exists():
                    message = f"rename target exists: {new_path.name}"
                    print(f"  ✗ {message}")
                    results.append(_result_failure(rom, "rename_conflict", message))
                    continue
                print(f"  Rename: {rom.name} -> {new_path.name}")
                # Defer mutation until format checks/conversion succeed. A
                # missing converter must never leave the source renamed.
                planned_rename = new_path

        if fmt_key in ARCHIVE_FORMATS or (
            fmt_key == "zip" and plat not in detect.CARTRIDGE_SYSTEMS
        ):
            # A ZIP around an installable system is a package, not a
            # compression job. Route it to the library planner instead of
            # failing a recognized, compatible artifact as "unsupported".
            if fmt_key in ("zip", "vpk") and plat == detect.P_VITA:
                message = (
                    "pacote instalável; use 'pz emulation library scan' "
                    "para instalar no Vita3K"
                )
                print(f"  ✓ {message}")
                results.append({
                    "rom": str(rom),
                    "status": "install_candidate",
                    "platform": plat,
                    "format": fmt_key,
                    "hint": message,
                })
                continue
            message = f"archive input {fmt_key} is unsupported; source preserved"
            print(f"  ✗ {message}")
            results.append(_result_failure(rom, "unsupported_archive", message))
            continue

        final_fmt = decision.target_format(plat, fmt_key, profile)
        if not final_fmt:
            if planned_rename:
                if args.dry_run:
                    print("  ✓ Rename planned; no format conversion needed")
                    results.append({
                        "rom": str(rom),
                        "status": "would_rename",
                        "format": fmt_key,
                        "renameDestination": str(planned_rename),
                    })
                else:
                    old_path = rom
                    try:
                        rom.rename(planned_rename)
                        if args.sync:
                            from . import sync as sync_

                            sync_.sync_related_assets(
                                old_path.stem,
                                planned_rename.stem,
                                plat,
                                args.emulation_root or rom_dir.parent,
                                old_path,
                                manifest_dir=manifest_dir,
                            )
                    except OSError as exc:
                        if planned_rename.exists() and not old_path.exists():
                            try:
                                planned_rename.rename(old_path)
                            except OSError:
                                pass
                        message = f"rename/sync failed: {exc}"
                        print(f"  ✗ {message}")
                        results.append(_result_failure(old_path, "rename_fail", message))
                        continue
                    renamed_from = old_path
                    rom = planned_rename
                    print("  ✓ Renamed; no format conversion needed")
                    results.append({
                        "rom": str(rom),
                        "status": "renamed",
                        "format": fmt_key,
                        "renamedFrom": str(renamed_from),
                    })
            elif renamed_from:
                print("  ✓ Renamed; no format conversion needed")
                results.append({
                    "rom": str(rom),
                    "status": "renamed",
                    "format": fmt_key,
                    "renamedFrom": str(renamed_from),
                })
            else:
                print("  ✓ Already optimal or no safe conversion available")
                results.append({"rom": str(rom), "status": "skip", "format": fmt_key})
            continue

        if fmt_key == "zip" and final_fmt == "rezip":
            optimal, details = cartridge.check_zip_optimal(rom)
            if optimal and not profile.zip_force:
                print("  ✓ ZIP already optimally compressed")
                results.append({"rom": str(rom), "status": "skip", "format": "zip"})
                continue
            if details and details[0].startswith("<unreadable:"):
                message = details[0]
                print(f"  ✗ {message}")
                results.append(_result_failure(rom, "invalid_zip", message))
                continue

        out_ext = "zip" if final_fmt in ("zip", "rezip") else final_fmt
        output_name_source = planned_rename or rom
        destination = (
            _destination_parent(rom, rom_dir, dest_root) / f"{output_name_source.stem}.{out_ext}"
        )
        if final_fmt == "rezip" and destination.resolve() == rom.resolve() and not args.clean:
            destination = rom.with_name(f"{rom.stem}.optimized.zip")
        in_place_rezip = final_fmt == "rezip" and destination.resolve() == rom.resolve()
        if destination.exists() and not in_place_rezip:
            print(f"  ✓ Destination already exists; source preserved: {destination}")
            results.append({"rom": str(rom), "status": "exists", "format": final_fmt,
                            "destination": str(destination)})
            continue

        print(f"  Target: {final_fmt} -> {destination}")
        if args.dry_run:
            results.append({"rom": str(rom), "status": "would_convert",
                            "format": final_fmt, "destination": str(destination)})
            continue

        destination.parent.mkdir(parents=True, exist_ok=True)
        source_inputs = clean.chd_input_files(rom) if final_fmt == "chd" else {rom}
        saved_sigs = clean.save_source_sigs(source_inputs)
        source_sig = saved_sigs.get(rom)
        source_crc = rename.compute_crc32(rom) if final_fmt in ("cso", "zso") else ""
        stage = _stage_path(destination)
        try:
            rc, _stdout, stderr = convert.convert(
                final_fmt, rom, stage, profile, timeout=args.timeout
            )
            if rc != 0:
                message = stderr.strip()[-1000:] or f"converter exited {rc}"
                print(f"  ✗ Conversion failed: {message}")
                results.append(_result_failure(rom, "convert_fail", message, rc=rc))
                continue
            if not stage.is_file() or stage.is_symlink() or stage.stat().st_size <= 0:
                message = "converter returned success without a non-empty regular output"
                print(f"  ✗ {message}")
                results.append(_result_failure(rom, "convert_fail", message))
                continue

            verified = False
            verification_message = "verification disabled"
            if args.verify:
                verified, verification_message = verify.verify_format(
                    final_fmt,
                    stage,
                    source_crc,
                    timeout=args.timeout,
                )
                if not verified:
                    print(f"  ✗ Verification failed: {verification_message}")
                    results.append(
                        _result_failure(rom, "verify_fail", verification_message)
                    )
                    continue
                print(f"  ✓ Verification: {verification_message}")

            changed_inputs = [
                path for path, signature in saved_sigs.items()
                if not clean.source_unchanged(path, signature)
            ]
            if changed_inputs:
                message = "source changed during conversion: " + ", ".join(
                    path.name for path in changed_inputs
                )
                print(f"  ✗ {message}")
                results.append(_result_failure(rom, "source_changed", message))
                continue

            os.replace(stage, destination)
            file_record = {
                "rom": str(rom),
                "status": "ok",
                "platform": plat,
                "format": final_fmt,
                "destination": str(destination),
                "sourceBytes": source_sig[2] if source_sig else None,
                "outputBytes": destination.stat().st_size,
                "outputSha256": _sha256(destination),
                "verified": verified,
                "verification": verification_message,
                "sourceRemoved": in_place_rezip,
            }
            rename_source_after_commit = bool(
                planned_rename and planned_rename != destination and not args.clean
            )
            cleanup_after_commit = bool(
                args.clean and source_sig and not in_place_rezip
            )
            if planned_rename and planned_rename == destination and not args.clean:
                file_record["sourceRenameSkipped"] = (
                    "optimized destination occupies rename target; original preserved"
                )

            # Durable checkpoint before destructive cleanup or source rename.
            checkpoint = {
                **file_record,
                "status": "output_committed",
                "cleanupPending": cleanup_after_commit,
                "renamePending": rename_source_after_commit,
            }
            try:
                manifest.log_conversion_result(
                    manifest_dir,
                    checkpoint if cleanup_after_commit or rename_source_after_commit else file_record,
                )
            except OSError as exc:
                message = f"manifest write failed; source preserved: {exc}"
                print(f"  ✗ {message}")
                results.append(_result_failure(rom, "manifest_fail", message,
                                               destination=str(destination)))
                continue

            if cleanup_after_commit:
                clean_result = clean.clean_after_convert(rom, destination, source_sig)
                file_record["sourceRemoved"] = clean_result["source_removed"]
                if clean_result["source_removed"]:
                    print(f"  ✓ Source removed: {rom.name}")
                if final_fmt == "chd":
                    removed = clean.remove_chd_sidecars(rom, saved_sigs=saved_sigs)
                    file_record["removedSidecars"] = removed
                    if removed:
                        print(f"  ✓ Removed {len(removed)} verified CHD sidecar(s)")
                if not file_record["sourceRemoved"]:
                    file_record["status"] = "cleanup_fail"
                    file_record["error"] = "verified output committed but source removal failed"
                    print(f"  ✗ {file_record['error']}")
                elif args.sync and planned_rename:
                    from . import sync as sync_

                    try:
                        sync_.sync_related_assets(
                            rom.stem,
                            planned_rename.stem,
                            plat,
                            args.emulation_root or rom_dir.parent,
                            rom,
                            manifest_dir=manifest_dir,
                        )
                    except OSError as exc:
                        file_record["status"] = "sync_fail"
                        file_record["error"] = f"source removed but related-file sync failed: {exc}"
                        print(f"  ✗ {file_record['error']}")

            if rename_source_after_commit:
                try:
                    rom.rename(planned_rename)
                    renamed_from = rom
                    file_record["sourceRenamedTo"] = str(planned_rename)
                    if args.sync:
                        from . import sync as sync_

                        sync_.sync_related_assets(
                            rom.stem,
                            planned_rename.stem,
                            plat,
                            args.emulation_root or rom_dir.parent,
                            rom,
                            manifest_dir=manifest_dir,
                        )
                except OSError as exc:
                    if planned_rename.exists() and not rom.exists():
                        try:
                            planned_rename.rename(rom)
                        except OSError:
                            pass
                    file_record.pop("sourceRenamedTo", None)
                    file_record["status"] = "rename_fail"
                    file_record["error"] = f"output committed but source rename/sync failed: {exc}"
                    print(f"  ✗ {file_record['error']}")

            if cleanup_after_commit or rename_source_after_commit:
                try:
                    manifest.log_conversion_result(
                        manifest_dir, {"type": "final", **file_record}
                    )
                except OSError as exc:
                    file_record["status"] = "manifest_fail"
                    file_record["error"] = f"final manifest write failed after checkpoint: {exc}"
                    print(f"  ✗ {file_record['error']}")

            results.append(file_record)
            print(f"  ✓ Committed: {destination}")
        finally:
            try:
                if stage.exists() or stage.is_symlink():
                    stage.unlink()
            except OSError:
                pass

    ok_count = sum(result["status"] == "ok" for result in results)
    skip_count = sum(
        result["status"] in ("skip", "exists", "install_candidate")
        for result in results
    )
    preview_count = sum(
        result["status"] in ("would_convert", "would_rename") for result in results
    )
    success_statuses = {
        "ok", "skip", "exists", "would_convert", "would_rename", "renamed",
        "install_candidate",
    }
    fail_count = sum(result["status"] not in success_statuses for result in results)
    print(f"\n{'=' * 60}")
    print(
        f"Done: {ok_count} converted, {skip_count} skipped, "
        f"{preview_count} planned, {fail_count} failed"
    )

    payload = {
        "status": "ok" if fail_count == 0 else "fail",
        "summary": {
            "converted": ok_count,
            "skipped": skip_count,
            "planned": preview_count,
            "failed": fail_count,
        },
        "results": results,
    }

    if not args.dry_run:
        try:
            manifest.log_conversion(manifest_dir, results)
            print(f"Manifest written to: {manifest_dir}/")
        except OSError as exc:
            print(f"Manifest summary failed: {exc}", file=sys.stderr)
            payload["status"] = "fail"
            payload["error"] = f"Manifest summary failed: {exc}"
            if args.json:
                print(json.dumps(payload, ensure_ascii=False))
            return 1
    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
