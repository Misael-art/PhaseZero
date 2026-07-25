from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path

from linux.capabilities import state
from . import SCHEMA
from .manager import InstallationError, _target_account

RELEASE_API = "https://api.github.com/repos/Misael-art/PhaseZero/releases/latest"
MAX_SOURCE_BYTES = 64 * 1024 * 1024
MAX_EXTRACT_BYTES = 256 * 1024 * 1024


def _json_url(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "PhaseZero-Updater/1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def _download(url: str, destination: Path, max_bytes: int) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "PhaseZero-Updater/1"})
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            if size > max_bytes:
                raise InstallationError("download excede limite permitido")
            digest.update(chunk)
            output.write(chunk)
    return digest.hexdigest()


def _current_version() -> str:
    root = Path(__file__).resolve().parents[2]
    try:
        return str(json.loads((root / "version.json").read_text(encoding="utf-8"))["version"])
    except (OSError, KeyError, json.JSONDecodeError):
        return "0.0.0"


def _version_tuple(value: str) -> tuple[int, int, int]:
    try:
        parts = value.split("-", 1)[0].split(".")
        return tuple(int(part) for part in parts[:3])  # type: ignore[return-value]
    except (TypeError, ValueError):
        return (0, 0, 0)


def check() -> dict:
    release = _json_url(RELEASE_API)
    latest = str(release.get("tag_name", "")).removeprefix("v")
    current = _current_version()
    assets = {asset["name"]: asset for asset in release.get("assets", ())}
    source_name = f"PhaseZero-{latest}-source.tar.gz"
    return {
        "schema": SCHEMA,
        "currentVersion": current,
        "latestVersion": latest,
        "updateAvailable": _version_tuple(latest) > _version_tuple(current),
        "sourceAvailable": source_name in assets,
        "releaseUrl": release.get("html_url", ""),
    }


def create_update_plan() -> dict:
    release = _json_url(RELEASE_API)
    latest = str(release.get("tag_name", "")).removeprefix("v")
    current = _current_version()
    assets = {asset["name"]: asset for asset in release.get("assets", ())}
    source_name = f"PhaseZero-{latest}-source.tar.gz"
    source = assets.get(source_name)
    sums = assets.get(f"SHA256SUMS-{latest}")
    blockers = []
    if _version_tuple(latest) <= _version_tuple(current):
        blockers.append("versão atual já é igual ou superior à release mais recente")
    if not source or not sums:
        blockers.append("release não possui source bundle e checksums")
    plan_id = state.new_id("update-plan")
    record = {
        "schema": SCHEMA,
        "kind": "self-update-plan",
        "id": plan_id,
        "createdAt": int(time.time()),
        "currentVersion": current,
        "targetVersion": latest,
        "source": source,
        "checksums": sums,
        "blockers": blockers,
        "status": "blocked" if blockers else "ready",
        "confirmToken": state.token(),
    }
    state.save("update-plans", plan_id, record)
    return record


def _safe_extract(archive_path: Path, destination: Path) -> Path:
    total = 0
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            total += max(0, member.size)
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk():
                raise InstallationError("source bundle contém caminho inseguro")
        if total > MAX_EXTRACT_BYTES:
            raise InstallationError("source bundle extraído excede limite")
        archive.extractall(destination, members=members, filter="data")
    roots = [path for path in destination.iterdir() if path.is_dir()]
    if len(roots) != 1:
        raise InstallationError("source bundle deve conter uma raiz única")
    return roots[0]


def apply_update(plan_id: str, confirmation: str) -> dict:
    if os.geteuid() == 0:
        raise InstallationError("self-update user não deve executar como root")
    plan = state.load("update-plans", plan_id)
    if plan.get("schema") != SCHEMA or plan.get("kind") != "self-update-plan":
        raise InstallationError("plano de update incompatível")
    if plan.get("blockers"):
        raise InstallationError("plano de update contém bloqueios")
    if confirmation != plan.get("confirmToken"):
        raise InstallationError("token de confirmação inválido")
    source = plan["source"]
    sums = plan["checksums"]
    with tempfile.TemporaryDirectory(prefix="phasezero-update-") as temporary:
        work = Path(temporary)
        source_path = work / source["name"]
        sums_path = work / sums["name"]
        actual = _download(source["browser_download_url"], source_path, MAX_SOURCE_BYTES)
        expected_api = str(source.get("digest") or "").removeprefix("sha256:")
        if expected_api and actual != expected_api:
            raise InstallationError("digest GitHub do source bundle diverge")
        _download(sums["browser_download_url"], sums_path, 1024 * 1024)
        expected_file = ""
        for line in sums_path.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[-1].lstrip("*") == source["name"]:
                expected_file = parts[0]
                break
        if not expected_file or actual != expected_file:
            raise InstallationError("SHA256SUMS não valida source bundle")
        root = _safe_extract(source_path, work / "extract")
        installer = root / "packaging/linux/install-user.sh"
        if not installer.is_file():
            raise InstallationError("source bundle sem instalador de usuário")
        result = subprocess.run(
            ["bash", str(installer)], cwd=root, capture_output=True, text=True,
            timeout=600, check=False,
        )
        if result.returncode != 0:
            raise InstallationError("instalação do update falhou: " + result.stderr[-2000:])
    return {
        "schema": SCHEMA,
        "status": "complete",
        "fromVersion": plan["currentVersion"],
        "toVersion": plan["targetVersion"],
    }
