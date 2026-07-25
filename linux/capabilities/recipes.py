from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass

from .platform import HostFacts
from .providers import CommandPlan


@dataclass(frozen=True)
class ServiceRecipe:
    capability_id: str
    unit: str
    description: str

    def compatible(self, facts: HostFacts) -> tuple[bool, str]:
        if facts.init != "systemd":
            return False, f"ativação requer systemd ({self.unit})"
        if facts.container:
            return False, "ativação de serviço bloqueada em container"
        return True, ""

    def active(self) -> bool:
        systemctl = shutil.which("systemctl") or "systemctl"
        try:
            enabled = subprocess.run(
                [systemctl, "is-enabled", "--quiet", self.unit],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=8, check=False,
            ).returncode == 0
            running = subprocess.run(
                [systemctl, "is-active", "--quiet", self.unit],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=8, check=False,
            ).returncode == 0
            return enabled and running
        except (OSError, subprocess.TimeoutExpired):
            return False

    def apply_plan(self) -> CommandPlan:
        return CommandPlan(
            shutil.which("systemctl") or "systemctl",
            ("enable", "--now", self.unit),
            elevated=True,
        )

    def rollback_plan(self) -> CommandPlan:
        return CommandPlan(
            shutil.which("systemctl") or "systemctl",
            ("disable", "--now", self.unit),
            elevated=True,
        )


# Only deterministic, reversible service activation belongs here. Network
# backend switches, firewall policies and kernel boot parameters remain
# explicit advanced actions; installing a package must never silently change
# connectivity or boot policy.
SERVICE_RECIPES: dict[str, ServiceRecipe] = {
    recipe.capability_id: recipe
    for recipe in (
        ServiceRecipe("health.earlyoom", "earlyoom.service", "Ativa proteção contra OOM."),
        ServiceRecipe("health.ananicy", "ananicy-cpp.service", "Ativa prioridades automáticas."),
        ServiceRecipe("development.docker", "docker.service", "Ativa engine de containers."),
        ServiceRecipe("administration.cockpit", "cockpit.socket", "Ativa console administrativo sob demanda."),
        ServiceRecipe("administration.tailscale", "tailscaled.service", "Ativa daemon Tailscale sem autenticar."),
        ServiceRecipe("administration.zerotier", "zerotier-one.service", "Ativa daemon ZeroTier sem ingressar em rede."),
    )
}


def recipe_for(capability_id: str) -> ServiceRecipe | None:
    return SERVICE_RECIPES.get(capability_id)
