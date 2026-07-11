from __future__ import annotations

import os
import posixpath
import re
import shutil
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

from . import safezip, sfo

# Markers of Vitamin/MaiDump packages, which Vita3K does not run. Blocking has
# to name the real cause instead of a generic archive error.
_INCOMPATIBLE_MARKERS = ("eboot_origin.bin", "mai_moe/", "sce_sys/vitamin.txt")


@dataclass
class VitaClassification:
    kind: str  # installable_zip | blocked | not_package
    reason: str = ""
    title_id: str = ""
    title: str = ""
    root: str = ""
    total_uncompressed: int = 0
    has_workbin: bool = False
    notes: list[str] = field(default_factory=list)


def _package_root(names: list[str]) -> str:
    """Find the prefix under which eboot.bin + sce_sys/param.sfo live.

    Accepts content at the archive root or under exactly one top-level folder
    (common when a dump is re-zipped with its title folder).
    """
    # Derive candidates from the two required markers. Looking at every
    # top-level path is incorrect for root packages because ``sce_sys`` and
    # ``sce_module`` are expected siblings, not competing wrapper roots.
    candidates = {""}
    for name in names:
        if name.endswith("eboot.bin"):
            candidates.add(name[: -len("eboot.bin")])
        if name.endswith("sce_sys/param.sfo"):
            candidates.add(name[: -len("sce_sys/param.sfo")])
    for root in sorted(candidates, key=len):
        if root + "eboot.bin" in names and root + "sce_sys/param.sfo" in names:
            return root
    return ""


def classify_zip(path: Path) -> VitaClassification:
    probe = safezip.probe(path)
    if not probe.ok:
        return VitaClassification("blocked", probe.reason)

    names = probe.names
    root = _package_root(names)
    has_root_markers = (
        "eboot.bin" in names and "sce_sys/param.sfo" in names
    )
    if not root and not has_root_markers and not (
        "eboot.bin" in names or any(name.endswith("/param.sfo") for name in names)
    ):
        return VitaClassification(
            "not_package", "no eboot.bin/param.sfo structure found"
        )
    if not root and not has_root_markers:
        return VitaClassification(
            "blocked",
            "estrutura Vita incompleta: eboot.bin e sce_sys/param.sfo "
            "precisam estar na mesma raiz",
        )

    lowered = [name.lower() for name in names]
    for marker in _INCOMPATIBLE_MARKERS:
        if any(name == root.lower() + marker or name.endswith("/" + marker)
               for name in lowered):
            return VitaClassification(
                "blocked",
                f"dump Vitamin/MaiDump detectado ({marker}); Vita3K requer "
                "dump NoNpDrm",
            )

    raw_sfo = safezip.read_member(path, root + "sce_sys/param.sfo")
    if raw_sfo is None:
        return VitaClassification("blocked", "param.sfo ilegível ou grande demais")
    try:
        params = sfo.parse(raw_sfo)
    except ValueError as exc:
        return VitaClassification("blocked", f"param.sfo inválido: {exc}")

    title_id = params.get("TITLE_ID", "")
    if not sfo.is_vita_title_id(title_id):
        return VitaClassification(
            "blocked", f"TITLE_ID inválido no param.sfo: {title_id!r}"
        )

    classification = VitaClassification(
        "installable_zip",
        title_id=str(title_id),
        title=str(params.get("TITLE", "")),
        root=root,
        total_uncompressed=probe.total_uncompressed,
        has_workbin=(root + "sce_sys/package/work.bin") in names,
    )
    stem_match = re.search(r"[A-Z]{4}\d{5}", path.stem.upper())
    if stem_match and stem_match.group(0) != title_id:
        classification.notes.append(
            f"nome do arquivo sugere {stem_match.group(0)}, "
            f"param.sfo declara {title_id}"
        )
    if not classification.has_workbin:
        classification.notes.append(
            "sem sce_sys/package/work.bin; conteúdo licenciado pode exigir "
            "dump NoNpDrm completo"
        )
    return classification


@dataclass
class Vita3K:
    binary: str = ""
    pref_path: Path | None = None

    @property
    def installed(self) -> bool:
        return bool(self.binary)


def _pref_path_from_config() -> Path | None:
    config = (
        Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        / "Vita3K"
        / "config.yml"
    )
    try:
        for line in config.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("pref-path:"):
                value = line.split(":", 1)[1].strip().strip("\"'")
                if value:
                    return Path(value).expanduser()
    except OSError:
        pass
    return None


def detect_vita3k() -> Vita3K:
    binary = os.environ.get("PZ_VITA3K_BINARY", "")
    if not binary:
        applications = Path(
            os.environ.get("PZ_APPLICATIONS_DIR") or Path.home() / "Applications"
        )
        for candidate in (
            applications / "Vita3K" / "Vita3K",
            Path.home() / ".local" / "bin" / "phasezero-vita3k",
        ):
            if candidate.is_file() and os.access(candidate, os.X_OK):
                binary = str(candidate)
                break
        else:
            binary = shutil.which("Vita3K") or shutil.which("vita3k") or ""

    pref_override = os.environ.get("PZ_VITA3K_PREF_PATH", "")
    if pref_override:
        pref_path: Path | None = Path(pref_override).expanduser()
    else:
        pref_path = _pref_path_from_config()
        if pref_path is None:
            default = (
                Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
                / "Vita3K"
                / "Vita3K"
            )
            pref_path = default if default.is_dir() else None
    return Vita3K(binary=binary, pref_path=pref_path)


def installed_app_dir(emulator: Vita3K, title_id: str) -> Path | None:
    if emulator.pref_path is None:
        return None
    return emulator.pref_path / "ux0" / "app" / title_id


def install_zip(
    archive_path: Path, root: str, title_id: str, app_dir: Path
) -> list[dict]:
    """Extract a validated package into ``app_dir`` atomically.

    Staging happens next to the destination (same filesystem) and is promoted
    with one rename; a partial extraction never becomes visible.
    Returns per-file records with sizes and sha256 hashes.
    """
    if app_dir.exists():
        raise FileExistsError(f"destino já existe: {app_dir}")
    app_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = app_dir.parent / f".pz-staging-{title_id}-{uuid.uuid4().hex}"
    files: list[dict] = []
    try:
        staging.mkdir(mode=0o700)
        with zipfile.ZipFile(archive_path) as archive:
            for info in archive.infolist():
                name = info.filename
                if root and not name.startswith(root):
                    continue
                relative = name[len(root):]
                if not relative or relative.endswith("/"):
                    continue
                normalized = posixpath.normpath(relative)
                if normalized.startswith("..") or normalized.startswith("/"):
                    raise ValueError(f"entrada insegura no pacote: {name!r}")
                target = staging / Path(normalized)
                written, digest = safezip.extract_member(archive, info, target)
                files.append(
                    {"path": normalized, "bytes": written, "sha256": digest}
                )
        if not (staging / "eboot.bin").is_file():
            raise ValueError("pacote extraído sem eboot.bin na raiz")
        os.rename(staging, app_dir)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return files
