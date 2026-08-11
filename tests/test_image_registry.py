from __future__ import annotations

import json
import os
import stat
from pathlib import Path

import pytest

from linux.ui_native import image_registry as reg


def _entry(sha: str = "a" * 64, path: str = "/tmp/win.iso", **overrides) -> dict:
    data = {
        "path": path,
        "sha256": sha,
        "label": "Win11",
        "sizeMb": 6234,
        "arch": "x64",
        "uefiBoot": True,
        "valid": True,
        "images": [{"index": 1, "name": "Windows 11 Home", "edition": "Home"}],
        "source": "manual",
    }
    data.update(overrides)
    return data


def test_load_missing_file_returns_empty(tmp_path: Path) -> None:
    doc = reg.load(tmp_path / "images.json")
    assert doc == {"schemaVersion": 1, "updatedAt": "", "images": []}
    assert reg.list_images(tmp_path / "images.json") == []


def test_load_corrupt_json_returns_empty(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    path.write_text("{not json", encoding="utf-8")
    assert reg.load(path) == {"schemaVersion": 1, "updatedAt": "", "images": []}


def test_load_non_dict_json_returns_empty(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    path.write_text("[1, 2, 3]", encoding="utf-8")
    assert reg.load(path)["images"] == []


def test_add_then_list_roundtrip(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    reg.add_image(_entry(), state_path=path)
    images = reg.list_images(path)
    assert len(images) == 1
    assert images[0]["sha256"] == "a" * 64
    assert images[0]["label"] == "Win11"
    doc = json.loads(path.read_text(encoding="utf-8"))
    assert doc["schemaVersion"] == 1
    assert doc["updatedAt"]


def test_add_is_idempotent_by_sha256_and_preserves_addedat(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    reg.add_image(_entry(label="old"), state_path=path)
    first = reg.list_images(path)[0]
    added = first["addedAt"]
    reg.add_image(_entry(label="new"), state_path=path)
    images = reg.list_images(path)
    assert len(images) == 1
    assert images[0]["label"] == "new"
    assert images[0]["addedAt"] == added


def test_add_two_distinct_sha_in_order(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    reg.add_image(_entry(sha="1" * 64, path="/a.iso"), state_path=path)
    reg.add_image(_entry(sha="2" * 64, path="/b.iso"), state_path=path)
    images = reg.list_images(path)
    assert [img["path"] for img in images] == ["/a.iso", "/b.iso"]


def test_remove_by_sha256_keeps_others(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    reg.add_image(_entry(sha="1" * 64, path="/a.iso"), state_path=path)
    reg.add_image(_entry(sha="2" * 64, path="/b.iso"), state_path=path)
    reg.remove_image(sha256="1" * 64, state_path=path)
    images = reg.list_images(path)
    assert len(images) == 1
    assert images[0]["path"] == "/b.iso"


def test_remove_by_path(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    reg.add_image(_entry(sha="1" * 64, path="/a.iso"), state_path=path)
    reg.remove_image(path="/a.iso", state_path=path)
    assert reg.list_images(path) == []


def test_remove_noop_when_absent(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    reg.add_image(_entry(), state_path=path)
    reg.remove_image(sha256="9" * 64, state_path=path)
    assert len(reg.list_images(path)) == 1


def test_remove_requires_identifier(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        reg.remove_image(state_path=tmp_path / "images.json")


def test_add_requires_sha256(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        reg.add_image({"path": "/x.iso"}, state_path=tmp_path / "images.json")


def test_unknown_future_schema_fail_closed(tmp_path: Path) -> None:
    path = tmp_path / "images.json"
    path.write_text(
        json.dumps({"schemaVersion": 99, "images": [{"path": "/x"}]}),
        encoding="utf-8",
    )
    assert reg.load(path)["images"] == []


def test_write_is_atomic_json_mode0600(tmp_path: Path) -> None:
    path = tmp_path / "windows-vm" / "images.json"
    reg.add_image(_entry(), state_path=path)
    # Valid JSON re-readable.
    reg.load(path)
    if os.name == "posix":
        mode = stat.S_IMODE(path.stat().st_mode)
        assert mode == 0o600
    # No stale temp files left behind.
    leftover = list(path.parent.glob("*.tmp"))
    assert leftover == []


def test_default_path_uses_state_dir(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # image_registry binds state_dir at import; patch the name it actually calls.
    monkeypatch.setattr(reg, "state_dir", lambda *a, **k: tmp_path)
    assert reg.default_path() == tmp_path / "windows-vm" / "images.json"
