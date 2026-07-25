from __future__ import annotations

import os
import platform as py_platform
import shutil
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class HostFacts:
    platform: str
    architecture: str
    distro: str
    distro_like: tuple[str, ...]
    package_family: str
    immutable: bool
    immutable_kind: str
    container: bool
    init: str
    desktop: str
    session: str
    gpus: tuple[str, ...]
    package_manager: str
    flatpak: bool
    flathub: bool

    def to_dict(self) -> dict:
        payload = asdict(self)
        payload["distro_like"] = list(self.distro_like)
        payload["gpus"] = list(self.gpus)
        return payload


def _os_release(path: Path | None = None) -> dict[str, str]:
    source = path or Path(os.environ.get("PZ_OS_RELEASE") or "/etc/os-release")
    values: dict[str, str] = {}
    try:
        for line in source.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, value = line.split("=", 1)
            values[key] = value.strip().strip("\"'")
    except OSError:
        pass
    return values


def _package_family(distro: str, like: tuple[str, ...], immutable: bool) -> tuple[str, str]:
    if immutable and shutil.which("rpm-ostree"):
        return "rpm-ostree", "rpm-ostree"
    tokens = {distro, *like}
    if tokens & {"arch", "archlinux", "manjaro", "biglinux", "cachyos", "artix"}:
        return "arch", shutil.which("pacman") or "pacman"
    if tokens & {"debian", "ubuntu", "linuxmint", "zorin", "deepin"}:
        return "debian", shutil.which("apt-get") or "apt-get"
    if tokens & {"fedora", "rhel", "centos", "almalinux", "nobara"}:
        return "fedora", shutil.which("dnf") or "dnf"
    if tokens & {"suse", "opensuse", "opensuse-tumbleweed"}:
        return "suse", shutil.which("zypper") or "zypper"
    return "unknown", ""


def _containerized() -> bool:
    if os.environ.get("PZ_CONTAINER") in {"1", "true", "yes"}:
        return True
    if Path("/.dockerenv").exists() or Path("/run/.containerenv").exists():
        return True
    try:
        result = subprocess.run(
            ["systemd-detect-virt", "--container"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3,
            check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _gpus() -> tuple[str, ...]:
    override = os.environ.get("PZ_GPU_TYPES")
    if override is not None:
        return tuple(sorted({item.strip() for item in override.split(",") if item.strip()}))
    try:
        result = subprocess.run(
            ["lspci"], capture_output=True, text=True, timeout=5, check=False,
        )
        text = result.stdout.casefold()
    except (OSError, subprocess.TimeoutExpired):
        text = ""
    values: set[str] = set()
    display_lines = [
        line for line in text.splitlines()
        if any(kind in line for kind in ("vga compatible controller", "3d controller", "display controller"))
    ]
    if any("nvidia" in line for line in display_lines):
        values.add("nvidia")
    if any(
        any(term in line for term in ("amd", "radeon", "advanced micro devices"))
        for line in display_lines
    ):
        values.add("amd")
    if any("intel" in line for line in display_lines):
        values.add("intel")
    return tuple(sorted(values))


def _flathub_available() -> bool:
    if not shutil.which("flatpak"):
        return False
    try:
        result = subprocess.run(
            ["flatpak", "remotes", "--columns=name"], capture_output=True,
            text=True, timeout=8, check=False,
        )
        return any(line.strip() == "flathub" for line in result.stdout.splitlines())
    except (OSError, subprocess.TimeoutExpired):
        return False


def detect() -> HostFacts:
    release = _os_release()
    distro = release.get("ID", "unknown").casefold()
    like = tuple(token.casefold() for token in release.get("ID_LIKE", "").split())
    immutable_kind = ""
    if shutil.which("rpm-ostree"):
        immutable_kind = "rpm-ostree"
    elif Path("/run/ostree-booted").exists():
        immutable_kind = "ostree"
    immutable = bool(immutable_kind)
    family, manager = _package_family(distro, like, immutable)
    desktop = (
        os.environ.get("XDG_CURRENT_DESKTOP")
        or os.environ.get("DESKTOP_SESSION") or "unknown"
    ).split(":", 1)[0].casefold()
    session = os.environ.get("XDG_SESSION_TYPE", "unknown").casefold()
    init = "systemd" if Path("/run/systemd/system").exists() else "other"
    return HostFacts(
        platform=py_platform.system().casefold(),
        architecture=py_platform.machine().casefold(),
        distro=distro,
        distro_like=like,
        package_family=family,
        immutable=immutable,
        immutable_kind=immutable_kind,
        container=_containerized(),
        init=init,
        desktop=desktop,
        session=session,
        gpus=_gpus(),
        package_manager=manager,
        flatpak=bool(shutil.which("flatpak")),
        flathub=_flathub_available(),
    )
