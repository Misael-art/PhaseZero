"""Evidências da matriz obrigatória: preview, rollback byte a byte, wallpaper
por monitor e Game Mode.

Hermético: nenhum teste toca o HOME real; PZ_THEMES_* redirecionam estado e
configuração; D-Bus é simulado por stub.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.themes.engine import (  # noqa: E402
    PREVIEW_TTL_SECONDS,
    apply_plan,
    catalog_payload,
    create_plan,
    preview_plan,
    rollback_snapshot,
)
from linux.themes.kde import ConfigWrite, KdeSession  # noqa: E402
from linux.themes.platform import detect  # noqa: E402
from linux.themes import state as themes_state  # noqa: E402
from tests.test_themes_contracts import (  # noqa: E402
    FAKE_PLASMA6,
    fake_config,
    fake_plasma,
    fake_state,
)

FAKE_BINARIES = {
    "qdbus": "",
    "plasma-apply-lookandfeel": "",
    "plasma-apply-colorscheme": "",
    "plasma-apply-cursortheme": "",
}


def make_facts(tmp_path: Path, **overrides) -> Path:
    payload = dict(FAKE_PLASMA6)
    payload["binaries"] = dict(FAKE_BINARIES)
    payload.update(overrides)
    path = tmp_path / "facts.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    os.environ["PZ_THEMES_FAKE_JSON"] = str(path)
    return path


WALLPAPER_READ = (
    "if 'desktops().map' in script:\n"
    "    print('[{\"id\":\"1\",\"screen\":0,\"wallpaperPlugin\":\"org.kde.image\","
    "\"wallpaperMode\":\"SingleImage\",\"config\":{\"Image\":\"file:///old.png\","
    "\"FillMode\":\"6\"}}]')\n"
    "else:\n"
    "    print('OK_0')\n"
)


def write_stub(tmp_path: Path, body: str) -> Path:
    stub = tmp_path / "qdbus-stub.py"
    stub.write_text(body, encoding="utf-8")
    os.environ["PZ_THEMES_DBUS_CMD"] = sys.executable + " " + str(stub)
    return stub


def session() -> KdeSession:
    return KdeSession(detect())


@pytest.fixture()
def multi_screen_plasma(tmp_path):
    make_facts(tmp_path)
    write_stub(
        tmp_path,
        "import sys\n"
        "script = sys.argv[-1]\n"
        "if 'desktops().map' in script:\n"
        "    print('[{\"id\":\"1\",\"screen\":0,\"wallpaperPlugin\":\"org.kde.image\","
        "\"wallpaperMode\":\"SingleImage\",\"config\":{\"Image\":\"file:///a.png\"}},"
        "{\"id\":\"2\",\"screen\":1,\"wallpaperPlugin\":\"org.kde.slideshow\","
        "\"wallpaperMode\":\"MultipleImages\",\"config\":{\"ImageSources\":\"[/b1.png,/b2.png]\"}}]')\n"
        "else:\n"
        "    print('OK_' + str(script.count('ds[i].screen ===')))\n",
    )
    yield
    os.environ.pop("PZ_THEMES_FAKE_JSON", None)
    os.environ.pop("PZ_THEMES_DBUS_CMD", None)


# --------------------------------------------------------------------------
# TH-PRV-001 — Preview 15 s com Manter/Reverter/expiração
# --------------------------------------------------------------------------

def test_preview_applies_then_apply_within_ttl_keeps(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    assert plan["ok"] is True

    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True
    assert preview["ttlSeconds"] == PREVIEW_TTL_SECONDS
    assert preview["expiresAt"] > time.time()

    operation = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert operation["status"] == "complete"
    assert operation["restored"] is False
    record = themes_state.load("previews", preview["previewId"])
    assert record["applied"] is True
    assert record.get("expiredRolledBack") is not True


def test_preview_expiry_rolls_back_and_blocks_apply(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)

    record = themes_state.load("previews", preview["previewId"])
    record["expiresAt"] = int(time.time()) - 1
    themes_state.save("previews", preview["previewId"], record)

    with pytest.raises(Exception, match="expirou e foi revertido automaticamente"):
        apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    updated = themes_state.load("previews", preview["previewId"])
    assert updated["applied"] is False
    assert updated["expiredRolledBack"] is True


def test_preview_reject_wrong_token(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    with pytest.raises(Exception, match="token de confirmação inválido"):
        preview_plan(plan["id"], confirmation="errado", facts=facts, session=sess)


def test_preview_rejects_non_wallpaper_plans(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(feature="access.reduce-motion", feature_state_target="on", facts=facts, session=sess)
    with pytest.raises(Exception, match="somente planos de wallpaper"):
        preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)


# --------------------------------------------------------------------------
# TH-RBK-001 — Rollback preserva painéis/widgets (byte a byte)
# --------------------------------------------------------------------------

def test_rollback_restores_config_bytes_exactly(fake_plasma, fake_state, fake_config):
    plasmarc = fake_config / "plasmarc"
    original = "[Theme]\nname=Breeze\nkeepEmpty=true\n\n[Wallpaper]\ncolor=#111111\n"
    plasmarc.write_text(original, encoding="utf-8")

    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(feature="theme.kde", feature_state_target="on", facts=facts, session=sess)
    assert plan["ok"] is True
    snapshot = themes_state.load("snapshots", plan["snapshotId"])
    assert snapshot["files"], "snapshot deve conter cópia de plasmarc"
    assert Path(snapshot["files"][0]["backup"]).read_bytes() == original.encode("utf-8")

    operation = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert operation["status"] == "complete"
    assert plasmarc.read_text(encoding="utf-8") != original

    rollback = rollback_snapshot(plan["snapshotId"], facts=facts, session=sess)
    assert rollback["status"] == "complete"
    assert rollback["restored"] is True
    assert plasmarc.read_bytes() == original.encode("utf-8")


def test_rollback_snapshot_covers_containments_byte_level(fake_plasma, fake_state, fake_config):
    containments = fake_config / "plasma-org.kde.plasma.desktop-appletsrc"
    original = "[Containments][1][General]\nwallpaperPlugin=org.kde.image\n"
    containments.write_text(original, encoding="utf-8")
    writer = ConfigWrite()
    writer.track(containments)
    captured = writer.capture()
    assert captured["files"][0]["sha256"]
    backup = Path(captured["files"][0]["backup"])
    assert backup.read_bytes() == original.encode("utf-8")


def test_rollback_idempotent(fake_plasma, fake_state, fake_config):
    plasmarc = fake_config / "plasmarc"
    plasmarc.write_text("[Theme]\nname=Breeze\n", encoding="utf-8")
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(feature="theme.kde", feature_state_target="on", facts=facts, session=sess)
    apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    first = rollback_snapshot(plan["snapshotId"], facts=facts, session=sess)
    second = rollback_snapshot(plan["snapshotId"], facts=facts, session=sess)
    assert first["status"] == "complete"
    assert second["idempotent"] is True
    assert second["rollbackId"] == first["rollbackId"]


# --------------------------------------------------------------------------
# TH-WAL-001 — Wallpaper por tela via D-Bus, sem reescrever containments
# --------------------------------------------------------------------------

def test_wallpaper_multi_monitor_targets_screen(multi_screen_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="1", facts=facts, session=sess)
    assert plan["ok"] is True
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True


def test_wallpaper_reads_per_screen_state(multi_screen_plasma, fake_state, fake_config):
    screens = session().read_wallpapers()
    assert len(screens) == 2
    assert screens[0]["screen"] == 0
    assert screens[1]["screen"] == 1
    assert screens[1]["wallpaperPlugin"] == "org.kde.slideshow"
    assert screens[0]["config"]["Image"] == "file:///a.png"


def test_wallpaper_plan_writes_no_containments(fake_plasma, fake_state, fake_config):
    containments = fake_config / "plasma-org.kde.plasma.desktop-appletsrc"
    before = "[Containments][1][General]\nwallpaperPlugin=org.kde.image\n"
    containments.write_text(before, encoding="utf-8")
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.aurora", screen="0", facts=facts, session=sess)
    preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert containments.read_text(encoding="utf-8") == before


def test_wallpaper_lock_target_updates_lock_screen(fake_plasma, fake_state, fake_config):
    lock = fake_config / "kscreenlockerrc"
    lock.write_text("[Greeter][Wallpaper][org.kde.image][General]\nImage=/old.png\n", encoding="utf-8")
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", wallpaper_target="lock", facts=facts, session=sess)
    assert plan["ok"] is True
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True
    assert "Image=" in lock.read_text(encoding="utf-8")


def test_wallpaper_video_fails_closed_without_extension(fake_plasma, fake_state, fake_config, tmp_path):
    video = tmp_path / "clip.mp4"
    video.write_bytes(b"not really a video")
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper=str(video), screen="0", facts=facts, session=sess)
    assert plan["ok"] is True
    with pytest.raises(Exception, match="extensão de vídeo"):
        preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)


def test_wallpaper_solid_color_params(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.solid-charcoal", screen="0", facts=facts, session=sess)
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True


# --------------------------------------------------------------------------
# TH-STE-001 — Game Mode: catálogo curado e pause-on-game
# --------------------------------------------------------------------------

def test_game_mode_plugins_curated_with_decky_mapping(fake_plasma, fake_state, fake_config):
    payload = catalog_payload()
    plugins = payload["steamPlugins"]
    assert plugins, "catálogo Steam deve listar plugins do Game Mode"
    assert all(item["deckyPlugin"] for item in plugins)
    assert all(item["sourceUrl"] for item in plugins)
    ids = [item["id"] for item in plugins]
    assert len(ids) == len(set(ids))


def test_game_mode_plan_pauses_on_game(fake_state, fake_config, tmp_path):
    make_facts(tmp_path, gameMode=True, steamOs=True, steamDeck=True)
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(
        feature="power.pause-on-game",
        feature_state_target="on",
        facts=facts,
        session=sess,
    )
    assert plan["ok"] is True
    assert plan["status"] == "ready"
    assert plan["actions"][0]["noop"] is False
    operation = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert operation["status"] == "complete"
