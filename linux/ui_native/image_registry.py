"""Versioned registry of Windows ISO images known to the Control Center.

The registry is a small JSON document under the PhaseZero state directory.
It lets the layperson find an installed image, read its basic
characteristics (per WIM image index) and manage it without re-selecting
the file on every launch.

Design contract:
- Source of truth is ``images.json`` under ``state_dir() / "windows-vm"``.
- All access resolves the path lazily through :func:`platform.state_dir` so
  tests can pass an explicit ``state_path`` and never touch the real HOME.
- Writes are atomic (``secure_file`` = ``O_EXCL`` + ``replace``, mode 0600).
- Identity is the ISO ``sha256``: re-adding the same file updates the entry
  in place instead of duplicating it.
- Missing or corrupt files degrade to an empty registry; they never raise.
- Unknown future schema versions fail closed to an empty registry rather
  than risk misinterpreting stored data.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .platform import secure_file, state_dir


SCHEMA_VERSION = 1


def default_path() -> Path:
    """Resolve the registry path lazily from the current platform state dir."""
    return state_dir() / "windows-vm" / "images.json"


def _empty_doc() -> dict[str, Any]:
    return {"schemaVersion": SCHEMA_VERSION, "updatedAt": "", "images": []}


def _resolve(state_path: Path | None) -> Path:
    return state_path if state_path is not None else default_path()


def _migrate(doc: Any) -> dict[str, Any]:
    """Normalize a parsed document; fail closed on unknown/corrupt input."""
    if not isinstance(doc, dict):
        return _empty_doc()
    version = doc.get("schemaVersion")
    if not isinstance(version, int):
        # Missing schema: be conservative and do not adopt free-form JSON.
        return _empty_doc()
    if version > SCHEMA_VERSION:
        # A newer Control Center wrote this; do not guess the layout.
        return _empty_doc()
    images = doc.get("images")
    if not isinstance(images, list):
        images = []
    cleaned = _empty_doc()
    cleaned["updatedAt"] = str(doc.get("updatedAt") or "")
    cleaned["images"] = [img for img in images if isinstance(img, dict)]
    return cleaned


def load(state_path: Path | None = None) -> dict[str, Any]:
    """Read and validate the registry; never raise on missing/corrupt file."""
    path = _resolve(state_path)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, ValueError):
        return _empty_doc()
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return _empty_doc()
    return _migrate(parsed)


def _write(doc: dict[str, Any], state_path: Path | None) -> dict[str, Any]:
    path = _resolve(state_path)
    doc["schemaVersion"] = SCHEMA_VERSION
    doc["updatedAt"] = datetime.now(timezone.utc).isoformat()
    secure_file(path, json.dumps(doc, indent=2, ensure_ascii=False))
    return doc


def list_images(state_path: Path | None = None) -> list[dict[str, Any]]:
    """Return the registered images in insertion order."""
    return list(load(state_path).get("images", []))


def _matches(entry: dict[str, Any], *, sha256: str | None, path: str | None) -> bool:
    if sha256:
        return str(entry.get("sha256") or "") == sha256
    if path:
        return str(entry.get("path") or "") == path
    return False


def add_image(entry: dict[str, Any], state_path: Path | None = None) -> dict[str, Any]:
    """Register one image, idempotent by ``sha256``.

    ``entry`` must carry at least ``path`` and ``sha256``. Re-adding an
    already-registered sha256 updates the stored entry (refresh of
    characteristics) without duplicating it. Returns the updated document.
    """
    if not isinstance(entry, dict):
        raise TypeError("entry must be a dict")
    sha = str(entry.get("sha256") or "")
    if not sha:
        raise ValueError("entry.sha256 is required")
    doc = load(state_path)
    images: list[dict[str, Any]] = list(doc.get("images", []))
    normalized = dict(entry)
    normalized.setdefault("path", "")
    normalized.setdefault("sha256", sha)
    normalized.setdefault("label", "")
    normalized.setdefault("sizeMb", 0)
    normalized.setdefault("arch", "")
    normalized.setdefault("uefiBoot", False)
    normalized.setdefault("valid", False)
    normalized.setdefault("images", [])
    normalized.setdefault("source", "manual")
    normalized.setdefault(
        "addedAt", datetime.now(timezone.utc).isoformat()
    )
    for i, existing in enumerate(images):
        if str(existing.get("sha256") or "") == sha:
            # Preserve original addedAt on refresh.
            normalized["addedAt"] = str(existing.get("addedAt") or normalized["addedAt"])
            images[i] = normalized
            doc["images"] = images
            return _write(doc, state_path)
    images.append(normalized)
    doc["images"] = images
    return _write(doc, state_path)


def remove_image(
    *,
    sha256: str | None = None,
    path: str | None = None,
    state_path: Path | None = None,
) -> dict[str, Any]:
    """Remove a registered image by ``sha256`` (preferred) or ``path``.

    Only the registry entry is removed; the ISO file on disk is untouched.
    Returns the updated document. No-op (and still atomic write-safe) if the
    image is not registered.
    """
    if not sha256 and not path:
        raise ValueError("remove_image requires sha256 or path")
    doc = load(state_path)
    images = [
        img
        for img in doc.get("images", [])
        if isinstance(img, dict) and not _matches(img, sha256=sha256, path=path)
    ]
    doc["images"] = images
    return _write(doc, state_path)
