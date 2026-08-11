from __future__ import annotations

import json
from pathlib import Path

import pytest

from linux.ui_native.graphics_profiles import (
    DEFAULT_CONTRACT_PATH,
    GraphicsContractError,
    load_graphics_profiles,
    provision_graphics_options,
)


def test_installed_contract_exposes_only_supported_provision_profiles() -> None:
    profiles = load_graphics_profiles()
    by_id = {profile.id: profile for profile in profiles}
    assert set(by_id) == {"compat", "virtio-gl", "virtio-venus"}
    assert by_id["compat"].provision_supported
    assert by_id["virtio-gl"].provision_supported
    assert not by_id["virtio-venus"].provision_supported
    assert by_id["virtio-venus"].plan_supported
    assert [option[0] for option in provision_graphics_options()] == ["compat", "virtio-gl"]


def test_contract_missing_fails_closed(tmp_path: Path) -> None:
    with pytest.raises(GraphicsContractError, match="ausente ou inválido"):
        load_graphics_profiles(tmp_path / "missing.json")


@pytest.mark.parametrize(
    "payload",
    [
        "not-json",
        json.dumps({"schemaVersion": "wrong", "profiles": []}),
        json.dumps({"schemaVersion": "windows-vm-graphics/v1", "profiles": []}),
        json.dumps(
            {
                "schemaVersion": "windows-vm-graphics/v1",
                "profiles": [
                    {
                        "id": "compat",
                        "label": "compat",
                        "helperText": "helper",
                        "provisionSupported": "yes",
                        "applySupported": True,
                        "planSupported": True,
                        "mode": "stable",
                    }
                ],
            }
        ),
    ],
)
def test_contract_malformed_fails_closed(tmp_path: Path, payload: str) -> None:
    contract = tmp_path / "graphics.json"
    contract.write_text(payload, encoding="utf-8")
    with pytest.raises(GraphicsContractError):
        load_graphics_profiles(contract)


def test_default_contract_path_is_runtime_relative() -> None:
    assert DEFAULT_CONTRACT_PATH.name == "graphics-profiles.json"
    assert DEFAULT_CONTRACT_PATH.is_file()
