from __future__ import annotations

import json
import os
import subprocess
import zipfile
from pathlib import Path

import pytest

from linux.emulation.library import apply as apply_mod
from linux.emulation.library import plan as plan_mod
from linux.emulation.library import registry, safezip, scan, sfo, vita
from linux.emulation.romopt import __main__ as romopt_main


ROOT = Path(__file__).resolve().parents[1]
TITLE_ID = "PCSE01224"


def make_sfo(title_id: str = TITLE_ID, title: str = "Test Game") -> bytes:
    return sfo.build({"TITLE_ID": title_id, "TITLE": title, "APP_VER": "01.00"})


def make_vita_zip(
    path: Path,
    title_id: str = TITLE_ID,
    *,
    root: str = "",
    workbin: bool = True,
    extra: dict[str, bytes] | None = None,
) -> Path:
    entries: dict[str, bytes] = {
        f"{root}eboot.bin": b"\x7fELFfake-eboot",
        f"{root}sce_sys/param.sfo": make_sfo(title_id),
        f"{root}sce_module/libc.suprx": b"module",
    }
    if workbin:
        entries[f"{root}sce_sys/package/work.bin"] = b"license"
    if extra:
        entries.update(extra)
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return path


@pytest.fixture
def env(tmp_path, monkeypatch):
    pref = tmp_path / "vita3k-pref"
    (pref / "ux0" / "app").mkdir(parents=True)
    binary = tmp_path / "Vita3K"
    binary.write_text("#!/bin/sh\n")
    binary.chmod(0o755)
    monkeypatch.setenv("PZ_LIBRARY_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("PZ_VITA3K_PREF_PATH", str(pref))
    monkeypatch.setenv("PZ_VITA3K_BINARY", str(binary))
    monkeypatch.setenv("PZ_EMULATION_ROOT", str(tmp_path / "Emulation"))
    return tmp_path


# --- SFO ---------------------------------------------------------------


def test_sfo_roundtrip():
    parsed = sfo.parse(make_sfo())
    assert parsed["TITLE_ID"] == TITLE_ID
    assert parsed["TITLE"] == "Test Game"


def test_sfo_rejects_garbage():
    with pytest.raises(ValueError):
        sfo.parse(b"not an sfo at all")
    truncated = make_sfo()[:24]
    with pytest.raises(ValueError):
        sfo.parse(truncated)


def test_vita_title_id_pattern():
    assert sfo.is_vita_title_id("PCSE01224")
    assert not sfo.is_vita_title_id("pcse01224")
    assert not sfo.is_vita_title_id("PCSE0122")
    assert not sfo.is_vita_title_id(123)


# --- safe zip probing ---------------------------------------------------


def test_safezip_rejects_path_traversal(tmp_path):
    bad = tmp_path / "evil.zip"
    with zipfile.ZipFile(bad, "w") as archive:
        archive.writestr("../escape.bin", b"x")
    probe = safezip.probe(bad)
    assert not probe.ok
    assert "traversal" in probe.reason


def test_safezip_rejects_absolute_and_backslash(tmp_path):
    for name, marker in (("/abs.bin", "absolute"), ("a\\b.bin", "backslash")):
        bad = tmp_path / f"bad-{marker}.zip"
        with zipfile.ZipFile(bad, "w") as archive:
            archive.writestr(name, b"x")
        probe = safezip.probe(bad)
        assert not probe.ok, name
        assert marker in probe.reason


def test_safezip_rejects_symlink_entry(tmp_path):
    bad = tmp_path / "symlink.zip"
    with zipfile.ZipFile(bad, "w") as archive:
        info = zipfile.ZipInfo("link")
        info.external_attr = 0o120777 << 16
        archive.writestr(info, "/etc/passwd")
    probe = safezip.probe(bad)
    assert not probe.ok
    assert "symlink" in probe.reason


def test_safezip_rejects_lying_declared_size(tmp_path, env):
    archive_path = tmp_path / "liar.zip"
    make_vita_zip(archive_path)
    with zipfile.ZipFile(archive_path) as archive:
        info = archive.getinfo("eboot.bin")
        info.file_size = 1  # header lies: real content is larger
        with pytest.raises(ValueError):
            safezip.extract_member(archive, info, tmp_path / "out.bin")


# --- registry ------------------------------------------------------------


def test_registry_covers_all_public_systems():
    from linux.emulation.romopt import detect

    public = (
        detect.CARTRIDGE_SYSTEMS
        | detect.DISC_SYSTEMS
        | detect.NO_COMPRESSION
        | {detect.P_SWITCH, detect.P_3DS, detect.P_NDS}
    )
    for platform in public:
        assert registry.for_platform(platform) is not None, platform


def test_registry_resolves_aliases():
    assert registry.for_platform("vita").id == "psvita"
    assert registry.for_platform("segacd").id == "megacd"


# --- vita classification --------------------------------------------------


def test_classify_installable_zip(tmp_path):
    archive = make_vita_zip(tmp_path / f"{TITLE_ID}.zip")
    result = vita.classify_zip(archive)
    assert result.kind == "installable_zip"
    assert result.title_id == TITLE_ID
    assert result.has_workbin


def test_classify_installable_zip_nested_root(tmp_path):
    archive = make_vita_zip(tmp_path / "game.zip", root=f"{TITLE_ID}/")
    result = vita.classify_zip(archive)
    assert result.kind == "installable_zip"
    assert result.root == f"{TITLE_ID}/"


def test_classify_blocks_maidump(tmp_path):
    archive = make_vita_zip(
        tmp_path / "mai.zip", extra={"eboot_origin.bin": b"orig"}
    )
    result = vita.classify_zip(archive)
    assert result.kind == "blocked"
    assert "Vitamin/MaiDump" in result.reason


def test_classify_not_a_package(tmp_path):
    archive = tmp_path / "random.zip"
    with zipfile.ZipFile(archive, "w") as handle:
        handle.writestr("readme.txt", "hello")
    result = vita.classify_zip(archive)
    assert result.kind == "not_package"


def test_classify_flags_title_id_mismatch(tmp_path):
    archive = make_vita_zip(tmp_path / "PCSE99999.zip")
    result = vita.classify_zip(archive)
    assert result.kind == "installable_zip"
    assert any("PCSE99999" in note for note in result.notes)


# --- scan -----------------------------------------------------------------


def test_scan_files_classifies_vita_zip_as_installable(tmp_path, env):
    roms = tmp_path / "roms" / "psvita"
    roms.mkdir(parents=True)
    archive = make_vita_zip(roms / f"{TITLE_ID}.zip")
    payload = scan.run("files", [archive])
    assert payload["status"] == "ok"
    assert payload["readOnly"] is True
    (item,) = payload["items"]
    assert item["systemName"] == "PlayStation Vita"
    assert item["origin"] == "ZIP instalável"
    assert item["destination"] == "vita3k"
    assert item["state"] == registry.STATE_ACTION
    assert item["transform"] == registry.TRANSFORM_INSTALL
    assert "original será preservado" in item["recommendation"]


def test_scan_never_reports_recognized_compatible_as_unsupported(tmp_path, env):
    roms = tmp_path / "Emulation" / "roms" / "psvita"
    roms.mkdir(parents=True)
    make_vita_zip(roms / f"{TITLE_ID}.zip")
    payload = scan.run("library", [])
    (item,) = payload["items"]
    assert item["state"] != registry.STATE_BLOCKED
    assert "unsupported" not in json.dumps(payload)


def test_scan_unknown_file_preserved(tmp_path, env):
    mystery = tmp_path / "mystery.bin"
    mystery.write_bytes(b"\x00" * 64)
    payload = scan.run("files", [mystery])
    (item,) = payload["items"]
    assert item["state"] == registry.STATE_UNKNOWN
    assert "preservada" in item["recommendation"]


def test_scan_ready_chd_no_action(tmp_path, env):
    roms = tmp_path / "roms" / "ps2"
    roms.mkdir(parents=True)
    chd = roms / "game.chd"
    chd.write_bytes(b"MComprHD" + b"\x00" * 64)
    payload = scan.run("files", [chd])
    (item,) = payload["items"]
    assert item["state"] == registry.STATE_READY
    assert item["transform"] == registry.TRANSFORM_NONE


def test_scan_recommends_conversion_for_ps2_iso(tmp_path, env):
    roms = tmp_path / "roms" / "ps2"
    roms.mkdir(parents=True)
    iso = roms / "game.iso"
    iso.write_bytes(b"\x00" * 4096)
    payload = scan.run("directory", [roms])
    (item,) = payload["items"]
    assert item["state"] == registry.STATE_ACTION
    assert item["transform"] == registry.TRANSFORM_CONVERT
    assert item["targetFormat"] == "chd"


def test_scan_rejects_missing_input(env):
    payload = scan.run("directory", [Path("/nonexistent/dir")])
    assert payload["status"] == "fail"


def test_scan_directory_skips_symlinked_roms(tmp_path, env):
    outside = tmp_path / "outside"
    outside.mkdir()
    real = make_vita_zip(outside / f"{TITLE_ID}.zip")
    roms = tmp_path / "roms" / "psvita"
    roms.mkdir(parents=True)
    (roms / "linked.zip").symlink_to(real)
    payload = scan.run("directory", [roms])
    assert payload["status"] == "ok"
    assert payload["items"] == []


def test_scan_files_refuses_symlink(tmp_path, env):
    real = make_vita_zip(tmp_path / f"{TITLE_ID}.zip")
    link = tmp_path / "link.zip"
    link.symlink_to(real)
    payload = scan.run("files", [link])
    assert payload["status"] == "fail"
    assert "symlink" in payload["error"]


# --- plan / apply / verify / rollback --------------------------------------


def _scan_plan(archive: Path) -> tuple[dict, dict]:
    scan_payload = scan.run("files", [archive])
    assert scan_payload["status"] == "ok"
    plan_payload = plan_mod.run(scan_payload["scanId"])
    assert plan_payload["status"] == "ok"
    return scan_payload, plan_payload


def test_full_vita_flow_install_verify_rollback(tmp_path, env):
    archive = make_vita_zip(tmp_path / f"{TITLE_ID}.zip")
    _, plan_payload = _scan_plan(archive)
    (action,) = [a for a in plan_payload["actions"] if a["action"] == "install"]
    assert action["executable"], action["blockers"]
    assert action["sourcePreserved"] is True
    install_dir = Path(action["installDir"])
    assert install_dir.name == TITLE_ID
    assert "ux0/app" in str(install_dir)

    # dry-run mutates nothing
    dry = apply_mod.run(plan_payload["planId"], "", dry_run=True)
    assert dry["status"] == "ok"
    assert dry["results"][0]["status"] == "would_install"
    assert not install_dir.exists()

    # wrong token refused
    refused = apply_mod.run(plan_payload["planId"], "wrong", dry_run=False)
    assert refused["status"] == "fail"

    applied = apply_mod.run(
        plan_payload["planId"], plan_payload["confirmToken"], dry_run=False
    )
    assert applied["status"] == "ok", applied
    result = applied["results"][0]
    assert result["status"] == "installed"
    assert (install_dir / "eboot.bin").is_file()
    assert (install_dir / "sce_sys" / "param.sfo").is_file()
    assert archive.is_file()  # original preserved

    # operation manifest is private
    state_dir = Path(env / "state" / "operations")
    manifests = list(state_dir.glob("*.json"))
    assert manifests and (manifests[0].stat().st_mode & 0o777) == 0o600

    verified = apply_mod.verify(applied["operationId"])
    assert verified["status"] == "ok", verified

    rolled = apply_mod.rollback(applied["operationId"])
    assert rolled["status"] == "ok"
    assert not install_dir.exists()
    assert archive.is_file()


def test_apply_skips_already_installed(tmp_path, env):
    archive = make_vita_zip(tmp_path / f"{TITLE_ID}.zip")
    pref = Path(env / "vita3k-pref")
    existing = pref / "ux0" / "app" / TITLE_ID
    existing.mkdir(parents=True)
    _, plan_payload = _scan_plan(archive)
    (action,) = [a for a in plan_payload["actions"] if a["action"] == "install"]
    assert not action["executable"]
    assert any("instalado" in blocker for blocker in action["blockers"])


def test_verify_detects_tampering(tmp_path, env):
    archive = make_vita_zip(tmp_path / f"{TITLE_ID}.zip")
    _, plan_payload = _scan_plan(archive)
    applied = apply_mod.run(
        plan_payload["planId"], plan_payload["confirmToken"], dry_run=False
    )
    install_dir = Path(applied["results"][0]["installDir"])
    (install_dir / "eboot.bin").write_bytes(b"tampered")
    verified = apply_mod.verify(applied["operationId"])
    assert verified["status"] == "fail"


def test_plan_blocks_when_emulator_missing(tmp_path, env, monkeypatch):
    monkeypatch.setenv("PZ_VITA3K_BINARY", "")
    monkeypatch.setenv("PZ_VITA3K_PREF_PATH", "")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "no-config"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "no-data"))
    monkeypatch.setenv("PZ_APPLICATIONS_DIR", str(tmp_path / "no-apps"))
    monkeypatch.setenv("PATH", "/usr/bin-nonexistent")
    archive = make_vita_zip(tmp_path / f"{TITLE_ID}.zip")
    _, plan_payload = _scan_plan(archive)
    (action,) = [a for a in plan_payload["actions"] if a["action"] == "install"]
    assert not action["executable"]
    assert action["blockers"]


# --- romopt regression ------------------------------------------------------


def test_romopt_vita_zip_is_install_candidate_not_failure(tmp_path, env):
    roms = tmp_path / "roms" / "psvita"
    roms.mkdir(parents=True)
    make_vita_zip(roms / f"{TITLE_ID}.zip")
    rc = romopt_main.main(
        ["--rom-dir", str(roms), "--platform", "psvita", "--dry-run"]
    )
    assert rc == 0


def test_romopt_other_archive_still_unsupported(tmp_path, env):
    roms = tmp_path / "roms" / "ps2"
    roms.mkdir(parents=True)
    with zipfile.ZipFile(roms / "game.zip", "w") as archive:
        archive.writestr("game.iso", b"\x00" * 128)
    rc = romopt_main.main(
        ["--rom-dir", str(roms), "--platform", "ps2", "--dry-run"]
    )
    assert rc == 1


# --- CLI envelope ------------------------------------------------------------


def test_pz_library_cli_emits_versioned_envelope(tmp_path, env):
    archive = make_vita_zip(tmp_path / f"{TITLE_ID}.zip")
    result = subprocess.run(
        [
            str(ROOT / "linux" / "pz"),
            "emulation",
            "library",
            "scan",
            "--scope", "files",
            "--input", str(archive),
            "--json",
        ],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env={
            **os.environ,
            "PZ_LIBRARY_STATE_DIR": str(tmp_path / "state"),
            "PZ_VITA3K_PREF_PATH": str(env / "vita3k-pref"),
            "PZ_VITA3K_BINARY": str(env / "Vita3K"),
        },
        cwd=tmp_path,
    )
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout.strip().splitlines()[-1])
    assert payload["schema"] == "pz.emulation.library/v1"
    assert payload["items"][0]["state"] == "action"
    assert payload["items"][0]["transform"] == "install"
