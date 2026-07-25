from __future__ import annotations
import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def write_manifest(manifest_dir: Path, entry: dict[str, Any]) -> Path:
    manifest_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    name = f"{ts}-{entry.get('platform', 'unknown')}-{uuid.uuid4().hex[:12]}.json"
    path = manifest_dir / name
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(entry, indent=2, default=str), encoding="utf-8")
    os.replace(tmp, path)
    return path


def build_entry(
    status: str,
    platform: str,
    source: str,
    destination: str,
    source_bytes: int,
    output_bytes: int,
    source_sha256: str,
    output_sha256: str = "",
    profile: str = "",
    source_removed: bool = False,
    tool_name: str = "",
    tool_version: str = "",
    **extra: Any,
) -> dict[str, Any]:
    return {
        "schema": "https://phasezero.local/schemas/rom-optimizer.json",
        "status": status,
        "platform": platform,
        "source": source,
        "destination": destination,
        "sourceBytes": source_bytes,
        "outputBytes": output_bytes,
        "sourceSha256": source_sha256,
        "outputSha256": output_sha256 or source_sha256,
        "sourceRemoved": source_removed,
        "profile": profile,
        "tool": {"name": tool_name, "version": tool_version},
        "convertedAt": datetime.now(timezone.utc).isoformat(),
        **extra,
    }


SYNC_MANIFEST_NAME = "sync-manifest.json"


def log_sync_ops(manifest_dir: Path, entries: list[dict[str, Any]]) -> None:
    if not entries:
        return
    manifest_dir.mkdir(parents=True, exist_ok=True)
    path = manifest_dir / SYNC_MANIFEST_NAME
    existing: list[dict[str, Any]] = []
    if path.exists():
        try:
            existing = json.loads(path.read_text("utf-8"))
        except (json.JSONDecodeError, OSError):
            existing = []
    existing.extend(entries)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(existing, indent=2, default=str), encoding="utf-8")
    os.replace(tmp, path)


def load_sync_ops(manifest_dir: Path) -> list[dict[str, Any]]:
    path = manifest_dir / SYNC_MANIFEST_NAME
    if not path.exists():
        return []
    try:
        return json.loads(path.read_text("utf-8"))
    except (json.JSONDecodeError, OSError):
        return []


def log_conversion(manifest_dir: Path, results: list[dict]) -> Path:
    entry = {
        "schema": "https://phasezero.local/schemas/rom-optimizer.json",
        "type": "batch",
        "results": results,
        "total": len(results),
        "convertedAt": datetime.now(timezone.utc).isoformat(),
    }
    return write_manifest(manifest_dir, entry)


def log_conversion_result(manifest_dir: Path, result: dict) -> Path:
    entry = {
        "schema": "https://phasezero.local/schemas/rom-optimizer.json",
        "type": "single",
        **result,
    }
    return write_manifest(manifest_dir, entry)


def undo_sync_batch(manifest_dir: Path, timestamp: str) -> int:
    entries = load_sync_ops(manifest_dir)
    undone = 0
    remaining: list[dict[str, Any]] = []
    for entry in entries:
        if entry.get("ts") == timestamp:
            if entry.get("op", "rename") != "rename":
                # Content rewrites cannot be reversed without a recorded
                # backup. Keep their journal records instead of claiming undo.
                remaining.append(entry)
                continue
            old = Path(entry["old"])
            new = Path(entry["new"])
            if old.exists():
                # Never overwrite a file created since the original rename.
                remaining.append(entry)
            elif new.exists():
                new.rename(old)
                undone += 1
            else:
                remaining.append(entry)
        else:
            remaining.append(entry)
    manifest_dir.mkdir(parents=True, exist_ok=True)
    tmp = (manifest_dir / SYNC_MANIFEST_NAME).with_suffix(".tmp")
    tmp.write_text(json.dumps(remaining, indent=2, default=str), encoding="utf-8")
    os.replace(tmp, manifest_dir / SYNC_MANIFEST_NAME)
    return undone
