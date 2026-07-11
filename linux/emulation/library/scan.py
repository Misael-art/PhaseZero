from __future__ import annotations

import os
from pathlib import Path

from ..romopt import detect
from . import SCHEMA, registry, state, vita

_ARCHIVE_FORMATS = {"zip", "7z", "gz"}


def emulation_root() -> Path:
    return Path(os.environ.get("PZ_EMULATION_ROOT") or Path.home() / "Emulation")


def _regular_files(files: list[Path]) -> list[Path]:
    # A symlink can point outside the selected origin; scanning follows it and
    # apply would mutate a foreign tree. Refuse them wholesale.
    return [path for path in files if not path.is_symlink()]


def _collect(scope: str, inputs: list[Path]) -> tuple[list[Path], Path | None, str]:
    if scope == "library":
        root = emulation_root() / "roms"
        if not root.is_dir():
            return [], None, f"biblioteca não encontrada: {root}"
        return _regular_files(detect.find_roms(root)), root, ""
    if scope == "directory":
        if len(inputs) != 1:
            return [], None, "escopo directory exige exatamente um --input"
        root = inputs[0].expanduser()
        if not root.is_dir():
            return [], None, f"pasta não encontrada: {root}"
        root = root.resolve()
        return _regular_files(detect.find_roms(root)), root, ""
    if scope == "files":
        if not inputs:
            return [], None, "escopo files exige ao menos um --input"
        files: list[Path] = []
        for candidate in inputs:
            resolved = candidate.expanduser()
            if not resolved.is_file():
                return [], None, f"arquivo não encontrado: {resolved}"
            if resolved.is_symlink():
                return [], None, f"symlink recusado como origem: {resolved}"
            files.append(resolved.resolve())
        return files, None, ""
    return [], None, f"escopo desconhecido: {scope}"


def _classify(path: Path, roms_root: Path | None) -> dict:
    platform, fmt, method, confidence = detect.detect(path, roms_root)
    # ``detect`` uses the literal sentinel "unknown". Treat it as missing so
    # content probes still receive the real suffix for explicitly selected
    # files outside a canonical ROM directory.
    if not fmt or fmt == detect.FORMAT_UNKNOWN:
        fmt = path.suffix.lower().lstrip(".")
    else:
        fmt = fmt.lstrip(".")
    try:
        size = path.stat().st_size
    except OSError:
        size = 0
    item: dict = {
        "path": str(path),
        "game": path.stem,
        "sizeBytes": size,
        "format": fmt,
        "detection": {"method": method, "confidence": round(confidence, 2)},
    }

    if platform == detect.PLATFORM_UNKNOWN:
        # Directory/extension evidence failed; content probes may still
        # identify an installable package (spec: probes internos de ZIP).
        if fmt in {"zip", "vpk"}:
            classification = vita.classify_zip(path)
            if classification.kind == "installable_zip":
                item["detection"] = {"method": "content", "confidence": 0.95}
                adapter = registry.for_platform(detect.P_VITA)
                item.update(
                    system=adapter.id,
                    systemName=adapter.name,
                    destination=adapter.destinations[0],
                    destinations=list(adapter.destinations),
                )
                _classify_vita(item, path)
                return item
        item.update(
            system=None,
            systemName=None,
            destination=None,
            state=registry.STATE_UNKNOWN,
            transform=None,
            recommendation="evidência insuficiente; origem preservada",
        )
        return item

    adapter = registry.for_platform(platform)
    if adapter is None:
        item.update(
            system=platform,
            systemName=platform,
            destination=None,
            state=registry.STATE_UNKNOWN,
            transform=None,
            recommendation="sistema sem adapter público; origem preservada",
        )
        return item

    item.update(
        system=adapter.id,
        systemName=adapter.name,
        destination=adapter.destinations[0] if adapter.destinations else None,
        destinations=list(adapter.destinations),
    )

    if adapter.id == detect.P_VITA and fmt in {"zip", "vpk"}:
        _classify_vita(item, path)
        return item

    if fmt in _ARCHIVE_FORMATS and adapter.archive_role == "wrapper":
        item.update(
            state=registry.STATE_ACTION,
            transform=registry.TRANSFORM_EXTRACT,
            recommendation=(
                f"arquivo {fmt} embrulha imagem de {adapter.name}; "
                "extração automática ainda não suportada"
            ),
        )
        return item

    if adapter.id == detect.P_VITA and fmt == "pkg":
        item.update(
            state=registry.STATE_BLOCKED,
            transform=None,
            recommendation=(
                "PKG requer licença (zRIF/work.bin) e fluxo manual do Vita3K"
            ),
        )
        return item

    target = adapter.target_format(fmt)
    if target in (None, "rezip"):
        item.update(
            state=registry.STATE_READY,
            transform=registry.TRANSFORM_NONE,
            recommendation="pronto para jogar; nenhuma transformação necessária",
        )
    else:
        item.update(
            state=registry.STATE_ACTION,
            transform=registry.TRANSFORM_CONVERT,
            targetFormat=target,
            recommendation=(
                f"converter {fmt} → {target} para economizar espaço"
            ),
        )
    return item


def _classify_vita(item: dict, path: Path) -> None:
    classification = vita.classify_zip(path)
    emulator = vita.detect_vita3k()
    item["vita"] = {
        "titleId": classification.title_id or None,
        "title": classification.title or None,
        "workBin": classification.has_workbin,
        "notes": classification.notes,
        "emulatorInstalled": emulator.installed,
        "prefPath": str(emulator.pref_path) if emulator.pref_path else None,
    }
    if classification.kind == "installable_zip":
        item["game"] = classification.title or classification.title_id
        app_dir = vita.installed_app_dir(emulator, classification.title_id)
        if app_dir is not None and app_dir.is_dir():
            item.update(
                state=registry.STATE_READY,
                # Keep an install action in the plan so it can explain the
                # idempotent skip and surface the existing destination.
                transform=registry.TRANSFORM_INSTALL,
                origin="ZIP instalável",
                recommendation=(
                    f"já instalado no Vita3K em ux0/app/{classification.title_id}"
                ),
            )
            return
        missing: list[str] = []
        if not emulator.installed:
            missing.append("vita3k")
        if emulator.pref_path is None:
            missing.append("vita3k pref-path")
        item.update(
            state=registry.STATE_ACTION,
            transform=registry.TRANSFORM_INSTALL,
            origin="ZIP instalável",
            recommendation="Instalar no Vita3K e validar — original será preservado",
            prerequisitesMissing=missing,
        )
        return
    if classification.kind == "blocked":
        item.update(
            state=registry.STATE_BLOCKED,
            transform=None,
            origin="pacote Vita",
            recommendation=classification.reason,
        )
        return
    item.update(
        state=registry.STATE_BLOCKED,
        transform=None,
        origin="arquivo comprimido",
        recommendation=(
            "conteúdo não parece pacote Vita instalável: "
            + classification.reason
        ),
    )


def run(scope: str, inputs: list[Path]) -> dict:
    files, roms_root, error = _collect(scope, inputs)
    if error:
        return {"schema": SCHEMA, "kind": "scan", "status": "fail", "error": error}
    items = [_classify(path, roms_root) for path in files]

    states = [item["state"] for item in items]
    summary = {
        "games": len(items),
        "systems": sorted(
            {item["systemName"] for item in items if item.get("systemName")}
        ),
        "ready": states.count(registry.STATE_READY),
        "actionsRecommended": states.count(registry.STATE_ACTION),
        "blocked": states.count(registry.STATE_BLOCKED),
        "unknown": states.count(registry.STATE_UNKNOWN),
    }
    scan_id = state.new_id("scan")
    payload = {
        "schema": SCHEMA,
        "kind": "scan",
        "status": "ok",
        "scanId": scan_id,
        "scope": scope,
        "inputs": [str(path) for path in inputs],
        "readOnly": True,
        "summary": summary,
        "items": items,
    }
    state.save_record(scan_id, payload)
    return payload
