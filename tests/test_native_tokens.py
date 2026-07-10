from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys_path_prepend = str(ROOT)

import sys

if sys_path_prepend not in sys.path:
    sys.path.insert(0, sys_path_prepend)

from linux.ui_native.tokens import DARK, LIGHT, ThemeTokens, render_qss


def test_dark_and_light_have_same_fields():
    dark_fields = {f.name for f in __import__("dataclasses").fields(DARK)}
    light_fields = {f.name for f in __import__("dataclasses").fields(LIGHT)}
    assert dark_fields == light_fields


def test_render_qss_dark_has_no_placeholders():
    qss = render_qss(DARK)
    assert "{{" not in qss
    assert "}}" not in qss


def test_render_qss_light_has_no_placeholders():
    qss = render_qss(LIGHT)
    assert "{{" not in qss
    assert "}}" not in qss


def test_render_qss_preserves_accent():
    assert DARK.accent == "#7c4dff"
    assert LIGHT.accent == "#7c4dff"
    assert "#7c4dff" in render_qss(DARK)
    assert "#7c4dff" in render_qss(LIGHT)


def test_every_placeholder_resolves():
    """Every {{token}} in theme.qss must map to a ThemeTokens field."""
    qss_raw = (ROOT / "linux" / "ui_native" / "theme.qss").read_text(encoding="utf-8")
    placeholders = set(re.findall(r"\{\{(\w+)\}\}", qss_raw))
    field_names = {f.name for f in __import__("dataclasses").fields(ThemeTokens)}
    missing = placeholders - field_names
    assert not missing, f"Placeholders without token field: {missing}"


def test_app_apply_theme_uses_tokens(monkeypatch):
    """apply_theme should set stylesheet from render_qss, not regex-rewrite."""
    import linux.ui_native.app as app_mod
    # stylesheet() must delegate to render_qss, not contain the old replacements dict
    source = Path(app_mod.__file__).read_text(encoding="utf-8")
    # The old regex-rewrite had a 'replacements = {' block — must be gone.
    assert "replacements = {" not in source
    assert "from .tokens import" in source or "from linux.ui_native.tokens import" in source
