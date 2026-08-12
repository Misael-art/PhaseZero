"""Adapters reais de aparência e acessibilidade.

Contrato de adapter:
- `effective(facts, session) -> dict {state, reason, params}`  (state em
  ligado/desligado/pausado-bateria/pausado-jogo/indisponivel/degradado)
- `apply(facts, session, action) -> dict {status, ...}`  (status em
  ligado/desligado/ok; chama notify após escrita)
- `verify(facts, session) -> bool`

Rollback é byte-level via snapshot do engine; nenhum adapter apaga arquivos.

Chaves com `key_verified=False` no catálogo são declaradas conforme
documentação pública do KDE, sem confirmação no código-fonte; a segurança é
garantida por snapshot/restauração byte a byte.
"""

from __future__ import annotations

import shutil

from .kde import process_running
from .catalog import FEATURES
from .models import FeatureSpec

PHASEZERO_THEME_CONF = "phasezero/theme.conf"
PHASEZERO_GROUP = "interface"
PHASEZERO_KEY = "theme"

PHASEZERO_MODES = {
    "system": {"colorscheme": "", "lookandfeel": ""},
    "dark": {"colorscheme": "BreezeDark", "lookandfeel": "org.kde.breezedark.desktop"},
    "light": {"colorscheme": "BreezeLight", "lookandfeel": "org.kde.breeze.desktop"},
    "highcontrast": {"colorscheme": "Breeze High Contrast", "lookandfeel": "org.kde.breezedark.desktop"},
}

ACCENT_PALETTE = {
    "pz.geo-dark": "#4f7cc9",
    "pz.aurora": "#26c9a8",
    "pz.solid-charcoal": "#4f7cc9",
}


class FeatureAdapter:
    def __init__(self, spec: FeatureSpec, **extra) -> None:
        self.spec = spec
        self.extra = extra

    def effective(self, facts, session) -> dict:  # noqa: ARG002 - interface estável
        return {"state": "indisponivel", "reason": "adapter ainda não integrado"}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        return {"status": "failed", "error": "adapter ainda não integrado"}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return False

    def rollback(self, facts, session, action) -> dict:  # noqa: ARG002
        return {"status": "ok"}


def _wanted_state(action: dict) -> str:
    target = action.get("target", {})
    return "ligado" if target.get("state") == "ligado" else "desligado"


def _read(session, config: str, group: str, key: str) -> str:
    return session.read_key(config, group, key).strip()


def _match(session, config: str, group: str, key: str, expected: str) -> bool:
    return _read(session, config, group, key) == expected


# Plasma's stock look-and-feel. Applying it clears the key rather than writing
# the value, because KDE drops entries that match the built-in default.
DEFAULT_LOOKANDFEEL = "org.kde.breeze.desktop"


def _lookandfeel_matches(session, package: str) -> bool:
    """An absent key means the default package is active, not that none is.

    plasma-apply-lookandfeel writes the id for a third-party theme but removes
    the entry entirely when the applied package is the built-in default, so an
    equality test could never confirm a successful switch to Breeze: every
    apply reported "tema global não refletido" and rolled back a change that
    had in fact taken effect.
    """
    current = _read(session, "kdeglobals", "KDE", "LookAndFeelPackage")
    if current:
        return current == package
    return package == DEFAULT_LOOKANDFEEL


class _OnOffConfigAdapter(FeatureAdapter):
    """Adapter genérico: chaves ligado/desligado com valores explícitos."""

    on_values: dict[tuple[str, str, str], str] = {}  # (config, group, key) -> value
    off_values: dict[tuple[str, str, str], str] = {}
    extra_params: tuple[str, ...] = ()

    def _effective_state(self, session) -> tuple[str, str]:
        matched = 0
        conflicts: list[str] = []
        for (config, group, key), value in self.on_values.items():
            current = _read(session, config, group, key)
            if current == value:
                matched += 1
            elif current != "":
                off = self.off_values.get((config, group, key))
                if off is None or current != off:
                    conflicts.append(key)
        if matched == len(self.on_values):
            return "ligado", ""
        if conflicts:
            return "degradado", f"estado misto em {conflicts[0]}"
        return "desligado", ""

    def effective(self, facts, session) -> dict:  # noqa: ARG002
        state, reason = self._effective_state(session)
        return {"state": state, "reason": reason, "params": {}}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        wanted = _wanted_state(action)
        values = self.on_values if wanted == "ligado" else self.off_values
        for (config, group, key), value in values.items():
            session.write_key(config, group, key, value)
        session.notify()
        state, reason = self._effective_state(session)
        if state != wanted:
            return {"status": "failed", "error": reason or f"verificação falhou ({state})"}
        return {"status": wanted}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self._effective_state(session)[0] == "ligado"


class _PhaseZeroThemeAdapter(FeatureAdapter):
    """Tema PhaseZero com persistência em interface/theme."""

    def effective(self, facts, session) -> dict:  # noqa: ARG002
        current = _read(session, PHASEZERO_THEME_CONF, PHASEZERO_GROUP, PHASEZERO_KEY) or "system"
        if current not in PHASEZERO_MODES:
            return {"state": "degradado", "reason": f"modo desconhecido: {current}", "params": {"mode": current}}
        expected = PHASEZERO_MODES[current]
        if expected["colorscheme"] and not _match(session, "kdeglobals", "General", "ColorScheme", expected["colorscheme"]):
            return {
                "state": "degradado",
                "reason": f"esquema esperado {expected['colorscheme']} não corresponde",
                "params": {"mode": current},
            }
        if current == "system":
            return {"state": "ligado", "reason": "", "params": {"mode": "system"}}
        return {"state": "ligado", "reason": "", "params": {"mode": current}}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        params = action.get("params", {})
        mode = str(params.get("mode", "system"))
        if mode not in PHASEZERO_MODES:
            return {"status": "failed", "error": f"modo desconhecido: {mode}"}
        session.write_key(PHASEZERO_THEME_CONF, PHASEZERO_GROUP, PHASEZERO_KEY, mode)
        expected = PHASEZERO_MODES[mode]
        if expected["colorscheme"]:
            session.apply_colorscheme(expected["colorscheme"])
        if expected["lookandfeel"]:
            session.apply_lookandfeel(expected["lookandfeel"])
        session.notify()
        effective = self.effective(facts, session)
        if effective["state"] != "ligado":
            return {"status": "failed", "error": effective.get("reason", "verificação falhou")}
        return {"status": "ligado", "params": {"mode": mode}}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] == "ligado"


class _KdeThemeAdapter(FeatureAdapter):
    # A look-and-feel package id and a Plasma desktop theme name live in
    # different namespaces: applying org.kde.breeze.desktop leaves
    # kdeglobals:[KDE]/LookAndFeelPackage holding that id, while
    # plasmarc:[Theme]/name holds a bare theme name such as "breeze" or "Layan".
    # Reading the latter to confirm the former can never match, so every apply
    # reported "tema global não refletido" and rolled back a change that had in
    # fact succeeded, and effective() always answered "desligado".
    def effective(self, facts, session) -> dict:  # noqa: ARG002
        params = self.spec.default_params
        package = str(params.get("package", "org.kde.breeze.desktop"))
        if _lookandfeel_matches(session, package):
            return {"state": "ligado", "reason": "", "params": {"package": package}}
        return {"state": "desligado", "reason": "", "params": {"package": package}}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        params = action.get("params", {}) or self.spec.default_params
        package = str(params.get("package", "org.kde.breeze.desktop"))
        session.apply_lookandfeel(package)
        session.notify()
        if not _lookandfeel_matches(session, package):
            return {"status": "failed", "error": "tema global não refletido"}
        return {"status": "ligado"}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] == "ligado"


class _NameParamAdapter(FeatureAdapter):
    """Adapter por nome: colorscheme, ícones, cursor."""

    config: str = ""
    group: str = ""
    key: str = ""
    param: str = "name"
    extra_keys: tuple[tuple[str, str, str, str], ...] = ()

    def _expected(self, action) -> dict:
        params = action.get("params", {}) or self.spec.default_params
        return params

    def effective(self, facts, session) -> dict:  # noqa: ARG002
        stored = _read(session, self.config, self.group, self.key).strip()
        if stored == "":
            return {"state": "desligado", "reason": "", "params": {}}
        params = dict(self.spec.default_params)
        params[self.param] = stored
        for config, group, key, value in self.extra_keys:
            if value and not _match(session, config, group, key, value):
                return {"state": "degradado", "reason": f"{key} não corresponde", "params": params}
        return {"state": "ligado", "reason": "", "params": params}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        params = self._expected(action)
        name = str(params.get(self.param, ""))
        if not name:
            return {"status": "failed", "error": "parâmetro obrigatório ausente"}
        self._apply(session, name, params)
        session.notify()
        effective = self.effective(facts, session)
        if effective["state"] != "ligado":
            return {"status": "failed", "error": effective.get("reason", "verificação falhou")}
        return {"status": "ligado", "params": dict(params)}

    def _apply(self, session, name: str, params: dict) -> None:
        session.write_key(self.config, self.group, self.key, name)
        for config, group, key, value in self.extra_keys:
            if value:
                session.write_key(config, group, key, value)

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] == "ligado"


class _ColorSchemeAdapter(_NameParamAdapter):
    config = "kdeglobals"
    group = "General"
    key = "ColorScheme"

    def _apply(self, session, name: str, params: dict) -> None:  # noqa: ARG002
        session.apply_colorscheme(name)


class _IconsAdapter(_NameParamAdapter):
    config = "kdeglobals"
    group = "Icons"
    key = "Theme"


class _CursorAdapter(_NameParamAdapter):
    config = "kcminputrc"
    group = "Mouse"
    key = "cursorTheme"
    extra_keys = (("kcminputrc", "Mouse", "cursorSize", ""),)

    # Plasma only writes cursorSize once a size is chosen explicitly, so an
    # empty value is the default size and not a broken configuration. Demanding
    # both keys left the feature permanently "degradado" on any desktop that
    # had never touched the size, which is the common case.
    DEFAULT_CURSOR_SIZE = 24

    def effective(self, facts, session) -> dict:  # noqa: ARG002
        name = _read(session, self.config, self.group, self.key).strip()
        size_raw = _read(session, "kcminputrc", "Mouse", "cursorSize").strip()
        if name == "":
            return {"state": "desligado", "reason": "", "params": {}}
        if size_raw == "":
            size = self.DEFAULT_CURSOR_SIZE
        else:
            try:
                size = int(size_raw)
            except ValueError:
                return {"state": "degradado", "reason": "cursorSize ilegível", "params": {}}
        return {"state": "ligado", "reason": "", "params": {"name": name, "size": size}}

    def _apply(self, session, name: str, params: dict) -> None:
        session.apply_cursortheme(name, int(params.get("size", 24)))


class _AccentAdapter(FeatureAdapter):
    def effective(self, facts, session) -> dict:  # noqa: ARG002
        stored = _read(session, PHASEZERO_THEME_CONF, "accent", "color")
        if not stored:
            return {"state": "desligado", "reason": "", "params": {"mode": "auto"}}
        if not _match(session, "kdeglobals", "General", "AccentColor", stored):
            return {"state": "degradado", "reason": "cor de destaque não corresponde", "params": {"mode": "auto"}}
        return {"state": "ligado", "reason": "", "params": {"mode": "auto"}}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        params = action.get("params", {}) or self.spec.default_params
        mode = str(params.get("mode", "auto"))
        color = str(params.get("color", "")).strip()
        if mode == "auto" and not color:
            color = self._from_wallpaper(facts, session)
            if not color:
                return {"status": "failed", "error": "Pillow indisponível para extrair cor do wallpaper local"}
        if mode == "color" and not color:
            return {"status": "failed", "error": "modo color exige --param color"}
        if not color.startswith("#") or len(color) != 7:
            return {"status": "failed", "error": f"cor inválida: {color}"}
        session.write_key("kdeglobals", "General", "AccentColor", color)
        session.write_key(PHASEZERO_THEME_CONF, "accent", "color", color)
        session.notify()
        if not _match(session, "kdeglobals", "General", "AccentColor", color):
            return {"status": "failed", "error": "cor de destaque não refletida"}
        return {"status": "ligado", "params": {"mode": mode, "color": color}}

    def _from_wallpaper(self, facts, session) -> str:  # noqa: ARG002
        try:
            screens = session.read_wallpapers()
        except Exception:
            return ""
        image = ""
        for item in screens:
            config = item.get("config", {}) or {}
            image = str(config.get("Image", ""))
            if image:
                break
        image = image.replace("file://", "")
        if not image:
            return ""
        from pathlib import Path

        path = Path(image)
        if path.name.startswith("pz.") or "phasezero" in str(path):
            return ACCENT_PALETTE.get(path.stem, "")
        try:
            from PIL import Image
        except ImportError:
            return ""
        try:
            with Image.open(path) as handle:
                small = handle.convert("RGB").resize((64, 64))
                pixels = list(small.getdata())
                avg = tuple(round(sum(channel[index] for channel in pixels) / len(pixels)) for index in range(3))
                return "#{:02x}{:02x}{:02x}".format(*avg)
        except Exception:
            return ""

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] == "ligado"


class _TextSizeAdapter(FeatureAdapter):
    def _dpi_for(self, percent: int) -> int:
        return 0 if percent == 100 else max(1, round(96 * percent / 100))

    def effective(self, facts, session) -> dict:  # noqa: ARG002
        stored = _read(session, "kdeglobals", "General", "forceFontDPI").strip()
        if stored == "":
            return {"state": "desligado", "reason": "", "params": {"percent": 100}}
        try:
            dpi = int(stored)
        except ValueError:
            return {"state": "degradado", "reason": "forceFontDPI ilegível", "params": {}}
        if dpi == 0:
            return {"state": "ligado", "reason": "", "params": {"percent": 100}}
        percent = max(50, min(300, round(dpi * 100 / 96)))
        if self._dpi_for(percent) != dpi:
            return {"state": "degradado", "reason": f"DPI {dpi} não mapeado a percentual", "params": {"percent": percent}}
        return {"state": "ligado", "reason": "", "params": {"percent": percent}}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        params = action.get("params", {}) or self.spec.default_params
        try:
            percent = int(params.get("percent", 100))
        except (TypeError, ValueError):
            return {"status": "failed", "error": "percent inválido"}
        if not 50 <= percent <= 300:
            return {"status": "failed", "error": "percent deve estar entre 50 e 300"}
        session.write_key("kdeglobals", "General", "forceFontDPI", str(self._dpi_for(percent)))
        session.notify()
        effective = self.effective(facts, session)
        if effective["state"] != "ligado":
            return {"status": "failed", "error": "escala de texto não refletida"}
        return {"status": "ligado", "params": {"percent": percent}}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] == "ligado"


class _ReduceMotionAdapter(_OnOffConfigAdapter):
    on_values = {
        ("kwinrc", "KWin", "ReduceMotion"): "true",
        ("kdeglobals", "KDE", "AnimationDurationFactor"): "0",
    }
    off_values = {
        ("kwinrc", "KWin", "ReduceMotion"): "false",
        ("kdeglobals", "KDE", "AnimationDurationFactor"): "1",
    }


class _LocateCursorAdapter(_OnOffConfigAdapter):
    on_values = {("kwinrc", "KWin", "CursorSearchEnabled"): "true"}
    off_values = {("kwinrc", "KWin", "CursorSearchEnabled"): "false"}


class _ZoomAdapter(_OnOffConfigAdapter):
    on_values = {("kwinrc", "Effect-zoom", "Enabled"): "true"}
    off_values = {("kwinrc", "Effect-zoom", "Enabled"): "false"}


class _ColorblindAdapter(FeatureAdapter):
    def effective(self, facts, session) -> dict:  # noqa: ARG002
        if not _match(session, "kwinrc", "Effect-colorblind", "Enabled", "true"):
            return {"state": "desligado", "reason": "", "params": {}}
        stored = _read(session, "kwinrc", "Effect-colorblind", "Type").strip()
        if not stored:
            return {"state": "degradado", "reason": "tipo de correção ausente", "params": {}}
        params = dict(self.spec.default_params)
        params["type"] = stored
        return {"state": "ligado", "reason": "", "params": params}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        params = action.get("params", {}) or self.spec.default_params
        correction = str(params.get("type", "deuteranopia"))
        valid = ("protanopia", "deuteranopia", "tritanopia", "achromatopsia")
        if correction not in valid:
            return {"status": "failed", "error": f"tipo inválido: {correction}"}
        session.write_key("kwinrc", "Effect-colorblind", "Enabled", "true")
        session.write_key("kwinrc", "Effect-colorblind", "Type", correction)
        session.notify()
        effective = self.effective(facts, session)
        if effective["state"] != "ligado":
            return {"status": "failed", "error": "filtro não refletido"}
        return {"status": "ligado", "params": dict(params)}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] == "ligado"


class _VisualAlertAdapter(_OnOffConfigAdapter):
    on_values = {("kaccessrc", "Bell", "VisibleBell"): "true"}
    off_values = {("kaccessrc", "Bell", "VisibleBell"): "false"}


class _KeysAccessAdapter(_OnOffConfigAdapter):
    """Teclas aderentes/lentas/repercussão (seção avançada)."""

    def __init__(self, spec: FeatureSpec, key_name: str = "") -> None:
        super().__init__(spec)
        self.key_name = key_name

    @property
    def on_values(self) -> dict:
        return {("kaccessrc", "Keyboard", self.key_name): "true"}

    @property
    def off_values(self) -> dict:
        return {("kaccessrc", "Keyboard", self.key_name): "false"}


class _NightColorAdapter(FeatureAdapter):
    def effective(self, facts, session) -> dict:  # noqa: ARG002
        if not _match(session, "kwinrc", "NightColor", "Active", "true"):
            return {"state": "desligado", "reason": "", "params": {}}
        stored = _read(session, "kwinrc", "NightColor", "TemperatureNight").strip()
        if not stored:
            return {"state": "degradado", "reason": "temperatura ausente", "params": {}}
        params = dict(self.spec.default_params)
        params["temperature"] = stored
        return {"state": "ligado", "reason": "", "params": params}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        params = action.get("params", {}) or self.spec.default_params
        try:
            temperature = int(params.get("temperature", 3500))
        except (TypeError, ValueError):
            return {"status": "failed", "error": "temperatura inválida"}
        if not 1000 <= temperature <= 6500:
            return {"status": "failed", "error": "temperatura deve estar entre 1000 e 6500"}
        session.write_key("kwinrc", "NightColor", "Active", "true")
        session.write_key("kwinrc", "NightColor", "Mode", "Times")
        session.write_key("kwinrc", "NightColor", "TemperatureNight", str(temperature))
        session.notify()
        effective = self.effective(facts, session)
        if effective["state"] != "ligado":
            return {"status": "failed", "error": "Night Color não refletido"}
        return {"status": "ligado", "params": dict(params)}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] == "ligado"


class _AutoDarkAdapter(FeatureAdapter):
    # Plasma stores the active colour scheme in kdeglobals:[General]/ColorScheme.
    # This wrote and then re-read [KDE]/ColorScheme, a key nothing else consults,
    # so the change never reached the desktop while the check trivially passed
    # against the value it had just written and reported success.
    def effective(self, facts, session) -> dict:  # noqa: ARG002
        stored = _read(session, "kdeglobals", "General", "ColorScheme").strip()
        if not stored:
            return {"state": "desligado", "reason": "", "params": {}}
        params = dict(self.spec.default_params)
        params["darkScheme"] = stored
        return {"state": "ligado", "reason": "", "params": params}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        params = action.get("params", {}) or self.spec.default_params
        scheme = str(params.get("darkScheme", "BreezeDark"))
        # apply_colorscheme drives plasma-apply-colorscheme, which is what makes
        # a running session repaint; writing the key alone only changes a file.
        session.apply_colorscheme(scheme)
        session.notify()
        if not _match(session, "kdeglobals", "General", "ColorScheme", scheme):
            return {"status": "failed", "error": "alternância automática não refletida"}
        return {"status": "ligado", "params": dict(params)}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] == "ligado"


class _ScreenReaderAdapter(FeatureAdapter):
    def _orca_bin(self) -> str:
        return shutil.which("orca") or ""

    def effective(self, facts, session) -> dict:  # noqa: ARG002
        if not self._orca_bin():
            return {"state": "indisponivel", "reason": "Orca não está instalado"}
        if process_running("orca"):
            return {"state": "ligado", "reason": "", "params": {}}
        return {"state": "desligado", "reason": "", "params": {}}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        binary = self._orca_bin()
        if not binary:
            return {"status": "failed", "error": "Orca não está instalado"}
        wanted = _wanted_state(action)
        if wanted == "ligado":
            result = session.start_process("orca", [binary, "--replace"])
            if result.get("started"):
                return {"status": "ligado", "reason": result.get("reason", "")}
            if not result.get("started"):
                return {"status": "failed", "error": result.get("reason", "falha ao iniciar Orca")}
            return {"status": "ligado", "pid": result.get("pid")}
        result = session.stop_process("orca")
        return {"status": "desligado", **result}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return process_running("orca")

    def rollback(self, facts, session, action) -> dict:  # noqa: ARG002
        session.stop_process("orca")
        return {"status": "ok"}


class _PowerAdaptiveAdapter(FeatureAdapter):
    """Política adaptativa: animações pausadas em bateria (e durante jogos)."""

    def __init__(self, spec: FeatureSpec, pause_in_game: bool = False) -> None:
        super().__init__(spec)
        self.pause_in_game = pause_in_game

    def effective(self, facts, session) -> dict:  # noqa: ARG002
        key = "pause-on-game" if self.pause_in_game else "adaptive"
        if not _match(session, PHASEZERO_THEME_CONF, "power", key, "true"):
            return {"state": "desligado", "reason": "", "params": {}}
        paused = facts.game_mode if self.pause_in_game else facts.on_battery
        if paused:
            return {
                "state": "pausado-jogo" if self.pause_in_game else "pausado-bateria",
                "reason": "Steam Gaming Mode ativo" if self.pause_in_game else "host em bateria",
                "params": {},
            }
        return {"state": "ligado", "reason": "", "params": {}}

    def apply(self, facts, session, action) -> dict:  # noqa: ARG002
        key = "pause-on-game" if self.pause_in_game else "adaptive"
        wanted = _wanted_state(action)
        session.write_key(PHASEZERO_THEME_CONF, "power", key, "true" if wanted == "ligado" else "false")
        paused = facts.game_mode if self.pause_in_game else facts.on_battery
        factor = "0" if (wanted == "ligado" and paused) else "1"
        session.write_key("kdeglobals", "KDE", "AnimationDurationFactor", factor)
        session.notify()
        effective = self.effective(facts, session)
        if wanted == "ligado" and effective["state"] not in ("ligado", "pausado-bateria", "pausado-jogo"):
            return {"status": "failed", "error": effective.get("reason", "política não refletida")}
        return {"status": effective["state"] if wanted == "ligado" else "desligado"}

    def verify(self, facts, session) -> bool:  # noqa: ARG002
        return self.effective(facts, session)["state"] in ("ligado", "pausado-bateria", "pausado-jogo")


class _Registry:
    def __init__(self) -> None:
        self._adapters: dict[str, FeatureAdapter] = {}

    def register(self, feature_id: str, adapter: FeatureAdapter) -> None:
        self._adapters[feature_id] = adapter

    def get(self, feature_id: str) -> FeatureAdapter | None:
        return self._adapters.get(feature_id)


REGISTRY = _Registry()

REGISTRY.register("theme.phasezero", _PhaseZeroThemeAdapter(FEATURES["theme.phasezero"]))
REGISTRY.register("theme.kde", _KdeThemeAdapter(FEATURES["theme.kde"]))
REGISTRY.register("theme.colorscheme", _ColorSchemeAdapter(FEATURES["theme.colorscheme"]))
REGISTRY.register("theme.icons", _IconsAdapter(FEATURES["theme.icons"]))
REGISTRY.register("theme.cursor", _CursorAdapter(FEATURES["theme.cursor"]))
REGISTRY.register("theme.accent", _AccentAdapter(FEATURES["theme.accent"]))
REGISTRY.register("theme.auto-dark", _AutoDarkAdapter(FEATURES["theme.auto-dark"]))
REGISTRY.register("theme.night-color", _NightColorAdapter(FEATURES["theme.night-color"]))
REGISTRY.register("access.text-size", _TextSizeAdapter(FEATURES["access.text-size"]))
REGISTRY.register("access.reduce-motion", _ReduceMotionAdapter(FEATURES["access.reduce-motion"]))
REGISTRY.register("access.locate-cursor", _LocateCursorAdapter(FEATURES["access.locate-cursor"]))
REGISTRY.register("access.zoom", _ZoomAdapter(FEATURES["access.zoom"]))
REGISTRY.register("access.colorblind", _ColorblindAdapter(FEATURES["access.colorblind"]))
REGISTRY.register("access.visual-alert", _VisualAlertAdapter(FEATURES["access.visual-alert"]))
REGISTRY.register("access.screen-reader", _ScreenReaderAdapter(FEATURES["access.screen-reader"]))
REGISTRY.register("access.sticky-keys", _KeysAccessAdapter(FEATURES["access.sticky-keys"], key_name="StickyKeys"))
REGISTRY.register("access.slow-keys", _KeysAccessAdapter(FEATURES["access.slow-keys"], key_name="SlowKeys"))
REGISTRY.register("access.bounce-keys", _KeysAccessAdapter(FEATURES["access.bounce-keys"], key_name="BounceKeys"))
REGISTRY.register("power.adaptive", _PowerAdaptiveAdapter(FEATURES["power.adaptive"]))
REGISTRY.register("power.pause-on-game", _PowerAdaptiveAdapter(FEATURES["power.pause-on-game"], pause_in_game=True))


def adapter_for(spec: FeatureSpec) -> FeatureAdapter | None:
    if spec.kind == "internal" and spec.id.startswith("power."):
        return REGISTRY.get(spec.id)
    if spec.kind == "internal":
        return None
    return REGISTRY.get(spec.id)
