from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


SCHEMA_VERSION = "windows-vm-graphics/v1"
DEFAULT_CONTRACT_PATH = Path(__file__).resolve().parents[1] / "windows-vm" / "graphics-profiles.json"


class GraphicsContractError(ValueError):
    """Raised when the installed graphics contract is absent or malformed."""


@dataclass(frozen=True)
class GraphicsProfile:
    id: str
    label: str
    helper_text: str
    provision_supported: bool
    apply_supported: bool
    plan_supported: bool
    mode: str


def load_graphics_profiles(path: Path | None = None) -> tuple[GraphicsProfile, ...]:
    contract_path = path or DEFAULT_CONTRACT_PATH
    try:
        payload = json.loads(contract_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GraphicsContractError(f"contrato gráfico ausente ou inválido: {contract_path}") from exc

    if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
        raise GraphicsContractError(f"schema gráfico incompatível: {contract_path}")
    raw_profiles = payload.get("profiles")
    if not isinstance(raw_profiles, list) or not raw_profiles:
        raise GraphicsContractError(f"lista de perfis gráficos inválida: {contract_path}")

    profiles: list[GraphicsProfile] = []
    seen: set[str] = set()
    for raw in raw_profiles:
        if not isinstance(raw, dict):
            raise GraphicsContractError(f"perfil gráfico inválido: {contract_path}")
        profile_id = raw.get("id")
        label = raw.get("label")
        helper_text = raw.get("helperText")
        mode = raw.get("mode")
        flags = (
            raw.get("provisionSupported"),
            raw.get("applySupported"),
            raw.get("planSupported"),
        )
        if (
            not isinstance(profile_id, str)
            or not profile_id
            or profile_id in seen
            or not isinstance(label, str)
            or not label
            or not isinstance(helper_text, str)
            or not helper_text
            or not isinstance(mode, str)
            or not mode
            or not all(isinstance(flag, bool) for flag in flags)
        ):
            raise GraphicsContractError(f"perfil gráfico inválido: {contract_path}")
        seen.add(profile_id)
        profiles.append(
            GraphicsProfile(
                id=profile_id,
                label=label,
                helper_text=helper_text,
                provision_supported=flags[0],
                apply_supported=flags[1],
                plan_supported=flags[2],
                mode=mode,
            )
        )
    return tuple(profiles)


def provision_graphics_options(path: Path | None = None) -> tuple[tuple[str, str, str], ...]:
    return tuple(
        (profile.id, profile.label, profile.helper_text)
        for profile in load_graphics_profiles(path)
        if profile.provision_supported
    )
