"""Testes herméticos dos adapters de aparência e acessibilidade (M3).

Cobrem: tema PhaseZero, colorscheme, acento, texto, movimento, cursor,
zoom, daltonismo, alerta visual, teclas aderentes, Night Color, auto-dark,
leitor de tela e políticas de energia. Nenhum teste toca o host real:
configuração, estado, D-Bus e binários são redirecionados via PZ_THEMES_*.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "linux"))

from themes.kde import KdeSession  # noqa: E402
from themes.platform import detect  # noqa: E402

SCHEMA = "themes/v1"


def _base_facts(**overrides) -> dict:
    facts = {
        "plasmaMajor": 6,
        "session": "wayland",
        "kwin": True,
        "steamOs": False,
        "steamDeck": False,
        "gameMode": False,
        "decky": False,
        "onBattery": False,
        "batteryPercent": None,
        "vaapi": True,
        "vulkan": True,
        "steamInstall": "",
        "steamLibraries": [],
        "binaries": {"qdbus": ""},
    }
    facts.update(overrides)
    return facts


def _qdbus_stub(path: Path) -> None:
    path.write_text(
        "import sys\n"
        "script = sys.argv[-1]\n"
        "if 'desktops().map' in script:\n"
        "    print('[{\"id\":\"1\",\"screen\":0,\"wallpaperPlugin\":\"org.kde.image\","
        "\"wallpaperMode\":\"SingleImage\",\"config\":{\"Image\":\"file:///old.png\","
        "\"FillMode\":\"6\"}}]')\n"
        "else:\n"
        "    print('OK_0')\n",
        encoding="utf-8",
    )


@pytest.fixture()
def fake_plasma(tmp_path):
    path = tmp_path / "fake.json"
    path.write_text(json.dumps(_base_facts()), encoding="utf-8")
    os.environ["PZ_THEMES_FAKE_JSON"] = str(path)
    stub = tmp_path / "qdbus-stub.py"
    _qdbus_stub(stub)
    os.environ["PZ_THEMES_DBUS_CMD"] = sys.executable + " " + str(stub)
    yield path
    os.environ.pop("PZ_THEMES_FAKE_JSON", None)
    os.environ.pop("PZ_THEMES_DBUS_CMD", None)


@pytest.fixture()
def fake_state(tmp_path):
    os.environ["PZ_THEMES_STATE_DIR"] = str(tmp_path / "state")
    yield tmp_path / "state"
    os.environ.pop("PZ_THEMES_STATE_DIR", None)


@pytest.fixture()
def fake_config(tmp_path):
    directory = tmp_path / "config"
    directory.mkdir()
    os.environ["PZ_THEMES_CONFIG_DIR"] = str(directory)
    yield directory
    os.environ.pop("PZ_THEMES_CONFIG_DIR", None)


def run_cli(*args, env=None):
    environment = dict(os.environ)
    if env:
        environment.update(env)
    return subprocess.run(
        [sys.executable, "-m", "linux.themes", *args],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
        env=environment,
        timeout=60,
    )


def _session(config_dir: Path):
    return KdeSession(detect())


def _apply_feature(feature_id: str, config_dir: Path, state: str = "ligado", params: dict | None = None):
    from themes.catalog import FEATURES
    from themes.features import REGISTRY

    session = _session(config_dir)
    adapter = REGISTRY.get(feature_id)
    assert adapter is not None, feature_id
    action = {
        "kind": "feature",
        "featureId": feature_id,
        "target": {"state": state, "params": params or {}},
        "params": params or {},
    }
    return adapter.apply(detect(), session, action), session


def _read_config(config_dir: Path, name: str, group: str, key: str) -> str:
    from themes.kde import read_ini_key

    return read_ini_key(config_dir / name, group, key).strip()


def _plan_and_apply(*args, **kwargs):
    plan = run_cli("plan", *args, **kwargs)
    assert plan.returncode == 0, plan.stderr
    payload = json.loads(plan.stdout)
    assert payload["ok"] is True, payload.get("blockers")
    apply = run_cli("apply", "--plan-id", payload["id"], "--confirm", payload["confirmToken"])
    assert apply.returncode == 0, apply.stderr
    return json.loads(apply.stdout)


# --- CLI roundtrips ----------------------------------------------------------


def test_profile_essencial_applies_and_verifies(fake_plasma, fake_state, fake_config):
    operation = _plan_and_apply("--profile", "essencial")
    assert operation["status"] == "complete"
    assert operation["restored"] is False
    assert _read_config(fake_config, "kdeglobals", "General", "forceFontDPI") == "106"
    status = json.loads(run_cli("status", "--json").stdout)
    assert status["features"]["access.text-size"]["state"] == "ligado"
    assert status["features"]["theme.phasezero"]["state"] == "ligado"


def test_phasezero_mode_dark_roundtrip(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("theme.phasezero", fake_config, params={"mode": "dark"})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "phasezero/theme.conf", "interface", "theme") == "dark"
    assert _read_config(fake_config, "kdeglobals", "General", "ColorScheme") == "BreezeDark"
    status = json.loads(run_cli("status", "--json").stdout)
    assert status["features"]["theme.phasezero"]["state"] == "ligado"
    assert status["features"]["theme.phasezero"]["params"]["mode"] == "dark"

    result, _ = _apply_feature("theme.phasezero", fake_config, params={"mode": "nonsense"})
    assert result["status"] == "failed"


def test_reduce_motion_on_off_roundtrip(fake_plasma, fake_state, fake_config):
    operation = _plan_and_apply("--feature", "access.reduce-motion", "--state", "on")
    assert operation["status"] == "complete"
    assert _read_config(fake_config, "kwinrc", "KWin", "ReduceMotion") == "true"
    assert _read_config(fake_config, "kdeglobals", "KDE", "AnimationDurationFactor") == "0"

    operation = _plan_and_apply("--feature", "access.reduce-motion", "--state", "off")
    assert operation["status"] == "complete"
    assert _read_config(fake_config, "kwinrc", "KWin", "ReduceMotion") == "false"
    assert _read_config(fake_config, "kdeglobals", "KDE", "AnimationDurationFactor") == "1"


def test_single_key_toggles(fake_plasma, fake_state, fake_config):
    for feature_id, config, group, key in (
        ("access.locate-cursor", "kwinrc", "KWin", "CursorSearchEnabled"),
        ("access.zoom", "kwinrc", "Effect-zoom", "Enabled"),
        ("access.visual-alert", "kaccessrc", "Bell", "VisibleBell"),
        ("access.sticky-keys", "kaccessrc", "Keyboard", "StickyKeys"),
        ("access.slow-keys", "kaccessrc", "Keyboard", "SlowKeys"),
        ("access.bounce-keys", "kaccessrc", "Keyboard", "BounceKeys"),
    ):
        operation = _plan_and_apply("--feature", feature_id, "--state", "on")
        assert operation["status"] == "complete", feature_id
        assert _read_config(fake_config, config, group, key) == "true", feature_id

        operation = _plan_and_apply("--feature", feature_id, "--state", "off")
        assert operation["status"] == "complete", feature_id
        assert _read_config(fake_config, config, group, key) == "false", feature_id


def test_auto_dark_roundtrip(fake_plasma, fake_state, fake_config):
    operation = _plan_and_apply("--feature", "theme.auto-dark", "--state", "on")
    assert operation["status"] == "complete"
    # Plasma reads the active scheme from [General]. This asserted [KDE], the
    # same group the feature wrongly wrote, so the pair agreed with each other
    # while the desktop never changed.
    assert _read_config(fake_config, "kdeglobals", "General", "ColorScheme") == "BreezeDark"
    status = json.loads(run_cli("status", "--json").stdout)
    assert status["features"]["theme.auto-dark"]["state"] == "ligado"


def test_screen_reader_reports_honest_state(fake_plasma, fake_state, fake_config):
    status = json.loads(run_cli("status", "--json").stdout)
    entry = status["features"]["access.screen-reader"]
    assert entry["state"] in ("indisponivel", "desligado", "ligado")
    if entry["state"] == "indisponivel":
        assert entry["reason"]


# --- unit tests com parâmetros ------------------------------------------------


def test_accent_color_param(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("theme.accent", fake_config, params={"mode": "color", "color": "#4f7cc9"})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "phasezero/theme.conf", "accent", "color") == "#4f7cc9"
    assert _read_config(fake_config, "kdeglobals", "General", "AccentColor") == "#4f7cc9"

    result, _ = _apply_feature("theme.accent", fake_config, params={"mode": "color", "color": "not-a-color"})
    assert result["status"] == "failed"


def test_colorblind_custom_type(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("access.colorblind", fake_config, params={"type": "protanopia"})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "kwinrc", "Effect-colorblind", "Type") == "protanopia"

    result, _ = _apply_feature("access.colorblind", fake_config, params={"type": "nonsense"})
    assert result["status"] == "failed"


def test_night_color_temperature(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("theme.night-color", fake_config, params={"temperature": 4000})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "kwinrc", "NightColor", "TemperatureNight") == "4000"
    assert _read_config(fake_config, "kwinrc", "NightColor", "Active") == "true"

    result, _ = _apply_feature("theme.night-color", fake_config, params={"temperature": 9999})
    assert result["status"] == "failed"


def test_text_size_bounds(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("access.text-size", fake_config, params={"percent": 500})
    assert result["status"] == "failed"

    result, _ = _apply_feature("access.text-size", fake_config, params={"percent": 150})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "kdeglobals", "General", "forceFontDPI") == "144"
    status = json.loads(run_cli("status", "--json").stdout)
    assert status["features"]["access.text-size"]["params"]["percent"] == 150


def test_text_size_100_clears_override(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("access.text-size", fake_config, params={"percent": 100})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "kdeglobals", "General", "forceFontDPI") == "0"


def test_icons_and_colorscheme_reflect_stored(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("theme.colorscheme", fake_config, params={"name": "BreezeLight"})
    assert result["status"] == "ligado", result

    result, _ = _apply_feature("theme.icons", fake_config, params={"name": "breeze-dark"})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "kdeglobals", "Icons", "Theme") == "breeze-dark"


def test_cursor_name_and_size(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("theme.cursor", fake_config, params={"name": "breeze_cursors", "size": 32})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "kcminputrc", "Mouse", "cursorTheme") == "breeze_cursors"
    assert _read_config(fake_config, "kcminputrc", "Mouse", "cursorSize") == "32"


# --- políticas de energia -----------------------------------------------------


def test_power_adaptive_pauses_on_battery(fake_plasma, fake_state, fake_config, tmp_path):
    battery_json = tmp_path / "battery.json"
    battery_json.write_text(json.dumps(_base_facts(onBattery=True)), encoding="utf-8")
    os.environ["PZ_THEMES_FAKE_JSON"] = str(battery_json)
    try:
        result, _ = _apply_feature("power.adaptive", fake_config, params={})
        assert result["status"] == "pausado-bateria", result
        assert _read_config(fake_config, "kdeglobals", "KDE", "AnimationDurationFactor") == "0"
        assert _read_config(fake_config, "phasezero/theme.conf", "power", "adaptive") == "true"
    finally:
        os.environ["PZ_THEMES_FAKE_JSON"] = str(fake_plasma)


def test_power_pause_on_game(fake_plasma, fake_state, fake_config, tmp_path):
    game_json = tmp_path / "game.json"
    game_json.write_text(json.dumps(_base_facts(gameMode=True)), encoding="utf-8")
    os.environ["PZ_THEMES_FAKE_JSON"] = str(game_json)
    try:
        result, _ = _apply_feature("power.pause-on-game", fake_config, params={})
        assert result["status"] == "pausado-jogo", result
        assert _read_config(fake_config, "kdeglobals", "KDE", "AnimationDurationFactor") == "0"
    finally:
        os.environ["PZ_THEMES_FAKE_JSON"] = str(fake_plasma)


def test_power_adaptive_running_on_ac(fake_plasma, fake_state, fake_config):
    result, _ = _apply_feature("power.adaptive", fake_config, params={})
    assert result["status"] == "ligado", result
    assert _read_config(fake_config, "kdeglobals", "KDE", "AnimationDurationFactor") == "1"


# --------------------------------------------------------------------------
# Wallpaper Engine — plugin empacotado à parte
# --------------------------------------------------------------------------

def test_wallpaper_engine_absent_plugin_is_unavailable_not_failure(monkeypatch):
    """Um plugin não instalado é um estado normal, não um defeito."""
    from linux.themes import features as feat

    monkeypatch.setattr(feat, "WALLPAPER_ENGINE_DIRS", ("/nao/existe",))
    adapter = feat.REGISTRY.get("video.wallpaper-engine")
    state = adapter.effective(None, None)
    assert state["state"] == "indisponivel"
    # A mensagem tem de nomear o pacote, senão o usuário não sabe o que fazer.
    assert "plasma6-wallpapers-wallpaper-engine-git" in state["reason"]


def test_wallpaper_engine_refuses_incomplete_params(monkeypatch, tmp_path):
    from linux.themes import features as feat

    monkeypatch.setattr(feat, "WALLPAPER_ENGINE_DIRS", (str(tmp_path),))
    adapter = feat.REGISTRY.get("video.wallpaper-engine")
    action = {"target": {"state": "ligado"}, "params": {"steamLibrary": "", "wallpaperId": ""}}
    result = adapter.apply(None, None, action)
    assert result["status"] == "failed"
    assert "obrigatórios" in result["error"]


def test_wallpaper_engine_refuses_missing_steam_library(monkeypatch, tmp_path):
    from linux.themes import features as feat

    monkeypatch.setattr(feat, "WALLPAPER_ENGINE_DIRS", (str(tmp_path),))
    adapter = feat.REGISTRY.get("video.wallpaper-engine")
    action = {
        "target": {"state": "ligado"},
        "params": {"steamLibrary": str(tmp_path / "ausente"), "wallpaperId": "123"},
    }
    result = adapter.apply(None, None, action)
    assert result["status"] == "failed"
    assert "inexistente" in result["error"]
