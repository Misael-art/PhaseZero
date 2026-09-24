from __future__ import annotations

import os
import pwd
import re
import shutil
import subprocess
from dataclasses import dataclass

from .models import SourceSpec
from .platform import HostFacts


@dataclass(frozen=True)
class CommandPlan:
    program: str
    args: tuple[str, ...]
    elevated: bool
    user_scope: bool = False

    def command(self) -> list[str]:
        return [self.program, *self.args]


class Provider:
    def __init__(self, facts: HostFacts) -> None:
        self.facts = facts

    def supports(self, source: SourceSpec) -> bool:
        if source.kind == "flatpak":
            return self.facts.flatpak and self.facts.flathub
        return source.kind == "package" and self.facts.package_family != "unknown"

    def installed(self, source: SourceSpec) -> bool | None:
        """Return package presence, absence, or unknown on probe failure.

        A failed package-manager query must never be treated as proof that an
        app is absent: that can prompt a duplicate install or misleading CTA.
        """
        command = self._query(source)
        if command is None:
            return None
        try:
            result = subprocess.run(
                command, capture_output=True, text=True,
                timeout=15, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode == 0:
            return True
        detail = f"{result.stdout or ''}\n{result.stderr or ''}".casefold()
        absent_markers = (
            "was not found", "is not installed", "not installed",
            "no packages found", "no package found", "no packages were found",
        )
        if any(marker in detail for marker in absent_markers):
            return False
        return None

    def available(self, source: SourceSpec) -> bool:
        if source.kind == "flatpak":
            return self.facts.flathub
        command = self._available(source)
        if command is None:
            return False
        try:
            return subprocess.run(
                command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=30, check=False,
            ).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False

    def estimate_space(self, source: SourceSpec) -> dict:
        """Best-effort repository size estimate; missing metadata stays unknown."""
        if source.kind != "package":
            return {"downloadBytes": None, "installedBytes": None}
        family = self.facts.package_family
        if family == "arch":
            command = ["pacman", "-Si", source.name]
            download_key, install_key = "Download Size", "Installed Size"
        elif family == "debian":
            command = ["apt-cache", "show", "--no-all-versions", source.name]
            download_key, install_key = "Size", "Installed-Size"
        elif family == "fedora":
            command = ["dnf", "repoquery", "--queryformat", "%{size} %{installsize}", source.name]
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
            except (OSError, subprocess.TimeoutExpired):
                return {"downloadBytes": None, "installedBytes": None}
            match = re.search(r"(?m)^\s*(\d+)\s+(\d+)\s*$", result.stdout or "")
            return {
                "downloadBytes": int(match.group(1)) if match else None,
                "installedBytes": int(match.group(2)) if match else None,
            }
        else:
            return {"downloadBytes": None, "installedBytes": None}
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return {"downloadBytes": None, "installedBytes": None}
        values: dict[str, int | None] = {"downloadBytes": None, "installedBytes": None}
        for line in (result.stdout or "").splitlines():
            key, separator, raw = line.partition(":")
            if not separator:
                continue
            value = raw.strip()
            if key.strip() == download_key:
                values["downloadBytes"] = self._size_bytes(value, default_unit="B" if family == "debian" else "")
            elif key.strip() == install_key:
                values["installedBytes"] = self._size_bytes(value, default_unit="KiB" if family == "debian" else "")
        return values

    @staticmethod
    def _size_bytes(value: str, *, default_unit: str = "") -> int | None:
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)?", value, re.IGNORECASE)
        if not match:
            return None
        number = float(match.group(1))
        unit = (match.group(2) or default_unit or "B").casefold()
        factors = {"b": 1, "kb": 1000, "kib": 1024, "mb": 1000**2, "mib": 1024**2,
                   "gb": 1000**3, "gib": 1024**3, "tb": 1000**4, "tib": 1024**4}
        factor = factors.get(unit)
        return int(number * factor) if factor else None

    def install_plan(self, source: SourceSpec) -> CommandPlan:
        if source.kind == "flatpak":
            return CommandPlan(
                shutil.which("flatpak") or "flatpak",
                ("--user", "install", "-y", source.remote, source.name),
                elevated=False,
                user_scope=True,
            )
        family = self.facts.package_family
        if family == "arch":
            return CommandPlan(self.facts.package_manager, ("-S", "--needed", "--noconfirm", source.name), True)
        if family == "debian":
            return CommandPlan(self.facts.package_manager, ("install", "-y", source.name), True)
        if family == "fedora":
            return CommandPlan(self.facts.package_manager, ("install", "-y", source.name), True)
        if family == "suse":
            return CommandPlan(self.facts.package_manager, ("--non-interactive", "install", source.name), True)
        if family == "rpm-ostree":
            return CommandPlan(self.facts.package_manager, ("install", "--idempotent", source.name), True)
        raise ValueError(f"provider indisponível para {source.name}")

    def remove_plan(self, source: SourceSpec) -> CommandPlan:
        if source.kind == "flatpak":
            return CommandPlan(
                shutil.which("flatpak") or "flatpak",
                ("--user", "uninstall", "-y", source.name),
                elevated=False,
                user_scope=True,
            )
        family = self.facts.package_family
        if family == "arch":
            return CommandPlan(self.facts.package_manager, ("-R", "--noconfirm", source.name), True)
        if family == "debian":
            return CommandPlan(self.facts.package_manager, ("remove", "-y", source.name), True)
        if family == "fedora":
            return CommandPlan(self.facts.package_manager, ("remove", "-y", source.name), True)
        if family == "suse":
            return CommandPlan(self.facts.package_manager, ("--non-interactive", "remove", source.name), True)
        if family == "rpm-ostree":
            return CommandPlan(self.facts.package_manager, ("uninstall", source.name), True)
        raise ValueError(f"provider indisponível para {source.name}")

    def execute(self, plan: CommandPlan) -> tuple[int, str, str]:
        command = plan.command()
        if plan.elevated and os.geteuid() != 0:
            raise PermissionError("ação requer admin bridge")
        if plan.user_scope and os.geteuid() == 0:
            command = self._as_target_user(command)
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=1800, check=False,
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as exc:
            return 124, exc.stdout or "", exc.stderr or "timeout"

    def _query(self, source: SourceSpec) -> list[str] | None:
        if source.kind == "flatpak":
            return [shutil.which("flatpak") or "flatpak", "--user", "info", source.name]
        family = self.facts.package_family
        if family == "arch":
            return ["pacman", "-Q", source.name]
        if family == "debian":
            return ["dpkg-query", "-W", "-f=${Status}", source.name]
        if family in {"fedora", "suse", "rpm-ostree"}:
            return ["rpm", "-q", source.name]
        return None

    def _available(self, source: SourceSpec) -> list[str] | None:
        family = self.facts.package_family
        if family == "arch":
            return ["pacman", "-Si", source.name]
        if family == "debian":
            return ["apt-cache", "show", source.name]
        if family == "fedora":
            return [self.facts.package_manager, "repoquery", source.name]
        if family == "suse":
            return [self.facts.package_manager, "--non-interactive", "search", "--match-exact", source.name]
        if family == "rpm-ostree":
            return ["rpm", "-q", source.name]
        return None

    @staticmethod
    def _as_target_user(command: list[str]) -> list[str]:
        user = os.environ.get("PZ_TARGET_USER") or os.environ.get("SUDO_USER") or ""
        if not user and os.environ.get("PKEXEC_UID", "").isdigit():
            try:
                user = pwd.getpwuid(int(os.environ["PKEXEC_UID"])).pw_name
            except KeyError:
                user = ""
        if not user or user == "root":
            raise PermissionError("usuário alvo ausente para operação Flatpak")
        home = pwd.getpwnam(user).pw_dir
        return [
            "runuser", "-u", user, "--", "env", f"HOME={home}",
            f"XDG_DATA_HOME={home}/.local/share", f"XDG_CONFIG_HOME={home}/.config",
            *command,
        ]
