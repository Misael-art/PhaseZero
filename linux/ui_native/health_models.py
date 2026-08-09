from __future__ import annotations

import re
from dataclasses import dataclass


_CHECK_RE = re.compile(
    r"^\[(PASS|WARN|FAIL|ERROR|INFO)]\s+([^:]+):\s*(.*?)(?:\s+—\s+(.*))?$"
)

_GROUPS = (
    (("MEM", "DISK", "FS", "CPU", "GPU"), "Hardware"),
    (("NET",), "Conexão"),
    (("SVC", "DOCKER"), "Serviços"),
    (("SD", "UX", "ST", "BOOT"), "Steam e jogos"),
    (("SEC",), "Segurança"),
    (("AI", "DEV"), "IA e desenvolvimento"),
)

_COPY = {
    "Total RAM >= 4GB": "Memória total suficiente",
    "Available RAM >= 1GB": "Memória disponível suficiente",
    "Swap >= 2GB": "Memória de apoio configurada",
    "root partition usage": "Espaço livre do sistema",
    "Root filesystem type": "Formato do disco do sistema",
    "CPU temperature < 85°C": "Temperatura do processador segura",
    "CPU load (1m) < cores": "Carga do processador equilibrada",
    "AMD GPU detected": "Placa de vídeo AMD detectada",
    "GPU device in sysfs": "Placa de vídeo disponível ao sistema",
    "Internet connectivity": "Conexão com a internet",
    "Tailscale connected": "Acesso remoto Tailscale",
    "Steam Deck hardware": "Hardware Steam Deck reconhecido",
    "Steam client available": "Steam disponível",
    "Gamescope available": "Modo console disponível",
    "MangoHud available": "Monitor de desempenho disponível",
    "GameMode launcher available": "Otimização de jogos disponível",
    "Virtual keyboard available": "Teclado virtual disponível",
    "Docker daemon accessible": "Servidor de aplicativos disponível",
    "Docker Compose": "Gerenciador de serviços disponível",
    "UFW firewall active": "Firewall ativo",
    "SSH server running": "Acesso remoto SSH",
}


@dataclass(frozen=True)
class HealthCheck:
    status: str
    check_id: str
    title: str
    detail: str
    group: str

    @property
    def state(self) -> str:
        return {
            "PASS": "success",
            "WARN": "warning",
            "INFO": "info",
            "FAIL": "error",
            "ERROR": "error",
        }.get(self.status, "info")

    @property
    def needs_attention(self) -> bool:
        return self.status in {"WARN", "FAIL", "ERROR"}


def _group_for(check_id: str) -> str:
    upper = check_id.upper()
    for prefixes, title in _GROUPS:
        if upper.startswith(prefixes):
            return title
    return "Sistema"


def _friendly_title(title: str) -> str:
    if title in _COPY:
        return _COPY[title]
    replacements = (
        (" installed", " instalado"),
        (" available", " disponível"),
        (" running", " em execução"),
        (" active", " ativo"),
        (" connected", " conectado"),
    )
    value = title
    for source, target in replacements:
        value = value.replace(source, target)
    return value[:1].upper() + value[1:]


def parse_health_checks(value: object) -> list[HealthCheck]:
    if not isinstance(value, list):
        return []
    checks: list[HealthCheck] = []
    for item in value:
        match = _CHECK_RE.match(str(item).strip())
        if match is None:
            continue
        status, check_id, title, detail = match.groups()
        checks.append(HealthCheck(
            status=status,
            check_id=check_id.strip(),
            title=_friendly_title(title.strip()),
            detail=(detail or "").strip(),
            group=_group_for(check_id),
        ))
    return checks


def suggested_action_id(check: HealthCheck) -> str:
    if check.check_id == "UX05":
        return "steamdeck.keyboard.repair"
    if check.check_id in {"UX06", "UX07"}:
        return "steamdeck.hotkeys"
    if check.check_id.startswith("NET"):
        return "system.repair-plan"
    if check.check_id.startswith(("MEM", "CPU", "DISK", "FS", "GPU", "SVC", "DOCKER")):
        return "system.repair-plan"
    return "system.repair-plan"
