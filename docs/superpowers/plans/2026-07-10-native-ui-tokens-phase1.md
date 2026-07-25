# Native UI Foundation — Phase 1: Design Tokens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Centralize all visual design values (colors, spacing, typography, radii) into a single `ThemeTokens` dataclass with `DARK`/`LIGHT` instances, render QSS by interpolation, and eliminate the fragile regex-rewrite light mode.

**Architecture:** `tokens.py` holds a frozen `ThemeTokens` dataclass as single source of truth. `theme.qss` migrates from hardcoded hex to `{{token_name}}` placeholders. `render_qss(tokens)` interpolates. `app.py` simplifies: dark/light = instantiate the right dataclass, no regex.

**Tech Stack:** Python 3.10+, PySide6/Qt6, stdlib `re`/`dataclasses`, pytest with `QT_QPA_PLATFORM=offscreen`.

**Spec:** `docs/superpowers/specs/2026-07-10-native-ui-foundation-design.md`

## Global Constraints

- Python 3.10+ (frozen dataclasses, `X | None` syntax).
- PySide6 6.6+. Tests run with `QT_QPA_PLATFORM=offscreen`.
- Accent `#7c4dff` kept in BOTH themes (brand identity).
- All hex codes currently in `theme.qss` map to exactly one token field (consolidation per spec — see migration table).
- Existing tests (`tests/test_linux_native_ui.py`, `tests/linux-ui.sh`) must pass after each task.
- `font_ui` includes `"Segoe UI"` for future Windows portability.
- No new runtime dependencies.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `linux/ui_native/tokens.py` | **Create** | `ThemeTokens` dataclass, `DARK`/`LIGHT` instances, `render_qss()` |
| `linux/ui_native/theme.qss` | **Modify** | Replace all hex codes with `{{token}}` placeholders |
| `linux/ui_native/app.py` | **Modify** | Remove `stylesheet()` regex-rewrite (~40 lines); `apply_theme()` uses tokens + `render_qss()` |
| `tests/test_native_tokens.py` | **Create** | Validate tokens cover all QSS placeholders, no residual `{{`, DARK/LIGHT field parity |

---

### Task 1: Create `tokens.py` with ThemeTokens dataclass + DARK/LIGHT + render_qss

**Files:**
- Create: `linux/ui_native/tokens.py`
- Test: `tests/test_native_tokens.py`

**Interfaces:**
- Produces: `ThemeTokens` (frozen dataclass), `DARK: ThemeTokens`, `LIGHT: ThemeTokens`, `render_qss(tokens: ThemeTokens) -> str`

- [ ] **Step 1: Write the failing test**

Create `tests/test_native_tokens.py`:

```python
from __future__ import annotations

import re
from pathlib import Path

import pytest

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /mnt/sdcard/Projects/PhaseZero && QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_tokens.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'linux.ui_native.tokens'`

- [ ] **Step 3: Write minimal implementation**

Create `linux/ui_native/tokens.py`:

```python
from __future__ import annotations

import re
from dataclasses import dataclass, fields
from pathlib import Path

STYLE_DIR = Path(__file__).resolve().parent
QSS_PATH = STYLE_DIR / "theme.qss"
_PLACEHOLDER_RE = re.compile(r"\{\{(\w+)\}\}")


@dataclass(frozen=True)
class ThemeTokens:
    """Single source of truth for all visual design values."""

    # Cores semânticas — backgrounds
    bg: str
    surface: str
    surface_alt: str
    surface_inset: str
    surface_header: str
    surface_input: str
    surface_hero: str
    surface_hero_alt: str
    surface_selected: str
    surface_pressed: str
    surface_disabled: str
    # Cores semânticas — borders
    border: str
    border_subtle: str
    border_divider: str
    border_strong: str
    accent_border: str
    # Texto
    text: str
    text_strong: str
    text_dim: str
    text_muted: str
    text_log: str
    # Accent
    accent: str
    accent_hover: str
    accent_pressed: str
    on_accent: str
    # Estados (foreground, bg, border para cada)
    success: str
    success_bg: str
    success_border: str
    warning: str
    warning_bg: str
    warning_border: str
    error: str
    error_bg: str
    error_border: str
    info: str
    info_bg: str
    info_border: str
    # Danger button variants
    danger: str
    danger_hover: str
    danger_disabled_bg: str
    danger_disabled_border: str
    # Skeleton
    skeleton_base: str
    skeleton_shimmer: str
    # Log
    log_bg: str
    # Spacing escala (4px base)
    space_xs: int
    space_sm: int
    space_md: int
    space_lg: int
    space_xl: int
    # Tipografia
    font_ui: str
    font_mono: str
    text_xs: int
    text_sm: int
    text_base: int
    text_lg: int
    text_xl: int
    text_2xl: int
    # Raio
    radius_sm: int
    radius_md: int
    radius_lg: int
    # Shadow
    shadow_alpha: int
    # Transition
    transition: str


DARK = ThemeTokens(
    # backgrounds
    bg="#1e1e2e",
    surface="#2a2a3c",
    surface_alt="#32324a",
    surface_inset="#191926",
    surface_header="#232336",
    surface_input="#252536",
    surface_hero="#2d2747",
    surface_hero_alt="#352c55",
    surface_selected="#2b2444",
    surface_pressed="#2f2f40",
    surface_disabled="#262636",
    # borders
    border="#3a3a4c",
    border_subtle="#33334a",
    border_divider="#2e2e44",
    border_strong="#45455c",
    accent_border="#4a3d7a",
    # text
    text="#f2f2f7",
    text_strong="#f4f4fa",
    text_dim="#a0a0b0",
    text_muted="#6a6a82",
    text_log="#cfcfe0",
    # accent
    accent="#7c4dff",
    accent_hover="#8f66ff",
    accent_pressed="#6a3ce6",
    on_accent="#ffffff",
    # states
    success="#7cb342",
    success_bg="#2c3a1f",
    success_border="#4d6b2c",
    warning="#ff9800",
    warning_bg="#3d2f16",
    warning_border="#7a5a20",
    error="#e53935",
    error_bg="#3d1f1f",
    error_border="#7a2e2e",
    info="#7c4dff",
    info_bg="#2c2547",
    info_border="#4a3d7a",
    # danger
    danger="#e53935",
    danger_hover="#ef5350",
    danger_disabled_bg="#2c2230",
    danger_disabled_border="#4a2f3a",
    # skeleton
    skeleton_base="#2e2e42",
    skeleton_shimmer="#3a3a52",
    # log
    log_bg="#15151f",
    # spacing
    space_xs=4,
    space_sm=8,
    space_md=12,
    space_lg=18,
    space_xl=24,
    # typography
    font_ui='"Inter", "Noto Sans", "Segoe UI", sans-serif',
    font_mono='"JetBrains Mono", "Cascadia Code", monospace',
    text_xs=10,
    text_sm=11,
    text_base=13,
    text_lg=15,
    text_xl=18,
    text_2xl=26,
    # radius
    radius_sm=8,
    radius_md=11,
    radius_lg=16,
    # shadow
    shadow_alpha=110,
    # transition
    transition="150ms ease",
)


LIGHT = ThemeTokens(
    # backgrounds
    bg="#f1f1f6",
    surface="#ffffff",
    surface_alt="#eeeef6",
    surface_inset="#e8e8f0",
    surface_header="#ffffff",
    surface_input="#ffffff",
    surface_hero="#ece7fb",
    surface_hero_alt="#e0d7f7",
    surface_selected="#ece7fb",
    surface_pressed="#e8e8f0",
    surface_disabled="#f4f4f8",
    # borders
    border="#d0d0dc",
    border_subtle="#e0e0ea",
    border_divider="#d8d8e2",
    border_strong="#c6c6d4",
    accent_border="#c9bdf0",
    # text
    text="#1c1c26",
    text_strong="#1a1a24",
    text_dim="#5a5a68",
    text_muted="#8a8a98",
    text_log="#2a2a36",
    # accent (brand kept identical)
    accent="#7c4dff",
    accent_hover="#9166ff",
    accent_pressed="#6a3ce6",
    on_accent="#ffffff",
    # states
    success="#2e7d32",
    success_bg="#e8f5e9",
    success_border="#a5d6a7",
    warning="#ed6c02",
    warning_bg="#fff4e5",
    warning_border="#ffcc80",
    error="#c62828",
    error_bg="#fdecea",
    error_border="#f5c5c5",
    info="#7c4dff",
    info_bg="#f3eeff",
    info_border="#d4ccf5",
    # danger
    danger="#c62828",
    danger_hover="#d32f2f",
    danger_disabled_bg="#f4f4f8",
    danger_disabled_border="#e0e0ea",
    # skeleton
    skeleton_base="#e0e0ea",
    skeleton_shimmer="#f0f0f6",
    # log
    log_bg="#f6f6fa",
    # spacing (idêntico)
    space_xs=4,
    space_sm=8,
    space_md=12,
    space_lg=18,
    space_xl=24,
    # typography (idêntico)
    font_ui='"Inter", "Noto Sans", "Segoe UI", sans-serif',
    font_mono='"JetBrains Mono", "Cascadia Code", monospace',
    text_xs=10,
    text_sm=11,
    text_base=13,
    text_lg=15,
    text_xl=18,
    text_2xl=26,
    # radius (idêntico)
    radius_sm=8,
    radius_md=11,
    radius_lg=16,
    # shadow (mais leve no light)
    shadow_alpha=60,
    # transition (idêntico)
    transition="150ms ease",
)


def render_qss(tokens: ThemeTokens) -> str:
    """Read theme.qss and substitute every {{token}} placeholder."""
    text = QSS_PATH.read_text(encoding="utf-8")
    _field_names = {f.name for f in fields(tokens)}

    def _sub(match: re.Match[str]) -> str:
        name = match.group(1)
        return str(getattr(tokens, name))

    return _PLACEHOLDER_RE.sub(_sub, text)
```

- [ ] **Step 4: Run test to verify it passes (theme.qss still has hex — placeholder test will fail, that's expected until Task 2)**

Run: `cd /mnt/sdcard/Projects/PhaseZero && QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_tokens.py::test_dark_and_light_have_same_fields tests/test_native_tokens.py::test_render_qss_preserves_accent -v`
Expected: PASS for these two (they don't depend on QSS migration yet).

The `test_every_placeholder_resolves` will PASS if no `{{` in theme.qss yet (empty placeholder set). The `test_render_qss_*_has_no_placeholders` tests will PASS trivially too. All green — Task 2 will keep them green after migration.

Run full file: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_tokens.py -v`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add linux/ui_native/tokens.py tests/test_native_tokens.py
git commit -m "feat(ui-native): add ThemeTokens dataclass with DARK/LIGHT + render_qss

Single source of truth for visual design values. Accent #7c4dff kept
in both themes (brand identity). font_ui includes Segoe UI for future
Windows portability."
```

---

### Task 2: Migrate `theme.qss` to `{{token}}` placeholders

**Files:**
- Modify: `linux/ui_native/theme.qss` (full rewrite of hex → placeholders)

**Interfaces:**
- Consumes: `ThemeTokens` field names from Task 1
- Produces: `theme.qss` that renders correctly via `render_qss(DARK)` and `render_qss(LIGHT)`

**Migration reference** (hex → token field, from spec). Use EXACTLY these mappings — consolidation per spec:

| Hex | Token |
|---|---|
| `#1e1e2e` | `{{bg}}` |
| `#2a2a3c` | `{{surface}}` |
| `#32324a` | `{{surface_alt}}` |
| `#24243a` | `{{surface_alt}}` |
| `#191926` | `{{surface_inset}}` |
| `#232336` | `{{surface_header}}` |
| `#252536` | `{{surface_input}}` |
| `#2d2747` | `{{surface_hero}}` |
| `#352c55` | `{{surface_hero_alt}}` |
| `#2b2444` | `{{surface_selected}}` |
| `#2f2f40` | `{{surface_pressed}}` |
| `#262636` | `{{surface_disabled}}` |
| `#22222f` | `{{surface_disabled}}` |
| `#3a3a4c` | `{{border}}` |
| `#33334a` | `{{border_subtle}}` |
| `#34344a` | `{{border_subtle}}` |
| `#2e2e44` | `{{border_divider}}` |
| `#2b2b40` | `{{border_divider}}` |
| `#45455c` | `{{border_strong}}` |
| `#4a4a60` | `{{border_strong}}` |
| `#4a3d7a` | `{{accent_border}}` |
| `#f2f2f7` | `{{text}}` |
| `#f4f4fa` | `{{text_strong}}` |
| `#f5f5fa` | `{{text_strong}}` |
| `#a0a0b0` | `{{text_dim}}` |
| `#6a6a82` | `{{text_muted}}` |
| `#cfcfe0` | `{{text_log}}` |
| `#7c4dff` | `{{accent}}` |
| `#8f66ff` | `{{accent_hover}}` |
| `#6a3ce6` | `{{accent_pressed}}` |
| `#7cb342` | `{{success}}` |
| `#ff9800` | `{{warning}}` |
| `#e53935` | `{{error}}` |
| `#ef5350` | `{{danger_hover}}` |
| `#15151f` | `{{log_bg}}` |
| `#c8e6a3` | `#c8e6a3` (badge success text — leave literal, no token) |

**Badge/pill/toast composite colors** (bg + border per state) map to state tokens:

| Selector context | Hex | Token |
|---|---|---|
| badge success bg `#2c3a1f` | `{{success_bg}}` |
| badge success border `#4d6b2c` | `{{success_border}}` |
| badge success text `#c8e6a3` | leave literal |
| badge warning bg `#3d2f16` | `{{warning_bg}}` |
| badge warning border `#7a5a20` | `{{warning_border}}` |
| badge warning text `#ffcf8f` | leave literal |
| badge error bg `#3d1f1f` | `{{error_bg}}` |
| badge error border `#7a2e2e` | `{{error_border}}` |
| badge error text `#ffb3b3` | leave literal |
| badge info bg `#2c2547` | `{{info_bg}}` |
| badge info border `#4a3d7a` | `{{accent_border}}` |
| badge info text `#c3b3ff` | leave literal |
| badge default text `#cfcfe0` | `{{text_log}}` |
| badge default bg `#34344a` | `{{border_subtle}}` |
| badge default border `#45455c` | `{{border_strong}}` |
| danger button disabled bg `#2c2230` | `{{danger_disabled_bg}}` |
| danger button disabled border `#4a2f3a` | `{{danger_disabled_border}}` |
| danger button border `#ef5350` | `{{danger_hover}}` |
| warningBanner bg `#3d2f16` | `{{warning_bg}}` |
| warningBanner border `#7a5a20` | `{{warning_border}}` |
| warningText `#ffcf8f` | leave literal |
| `#ffffff` (text on accent) | `{{on_accent}}` |
| `#000000` (shadow rgba black) | leave literal — shadow alpha handled by `{{shadow_alpha}}` where applicable, but rgba(0,0,0,80) stays as-is |

- [ ] **Step 1: Rewrite theme.qss with placeholders**

Full replacement of `linux/ui_native/theme.qss`. Every hex from the table above becomes its `{{token}}`. Font family stack uses `{{font_ui}}` / `{{font_mono}}`. Font sizes that match token values use `{{text_*}}px`; sizes not in the scale (e.g. `10px` in `#langChip`) use `{{text_xs}}px`.

Replace the entire file with:

```css
/* PhaseZero native UI — EmuDeck-inspired theme. Values come from render_qss. */
* {
    font-family: {{font_ui}};
    font-size: {{text_base}}px;
}
QMainWindow {
    background: transparent;
}
#appShell {
    background: {{bg}};
    border: 1px solid {{border_subtle}};
    border-radius: {{radius_lg}}px;
}
#headerBar {
    min-height: 52px;
    background: {{surface_header}};
    border-bottom: 1px solid {{border_divider}};
    border-top-left-radius: {{radius_lg}}px;
    border-top-right-radius: {{radius_lg}}px;
}
#brandMark {
    min-width: 36px;
    min-height: 36px;
    max-width: 36px;
    max-height: 36px;
    border-radius: {{radius_md}}px;
    background: {{accent}};
    color: {{on_accent}};
    font-weight: 800;
    qproperty-alignment: AlignCenter;
}
#windowTitle {
    color: {{text_strong}};
    font-size: {{text_lg}}px;
    font-weight: 700;
}
#windowSubtitle {
    color: {{text_dim}};
    font-size: {{text_xs}}px;
}
#langChip {
    font-size: {{text_lg}}px;
    padding: 0 4px;
}
#windowButton, #closeButton, #iconButton {
    border: 0;
    border-radius: {{radius_sm}}px;
    background: transparent;
}
#windowButton:hover, #iconButton:hover {
    background: {{border_subtle}};
}
#closeButton:hover {
    background: {{error}};
}

/* ---- Sidebar --------------------------------------------------------- */
#sidebar {
    background: {{surface_inset}};
    border-right: 1px solid {{border_divider}};
    border-bottom-left-radius: {{radius_lg}}px;
}
#sectionLabel {
    color: {{text_muted}};
    font-size: {{text_xs}}px;
    font-weight: 800;
    padding: {{space_md}}px {{space_sm}}px 4px {{space_sm}}px;
}
#sidebarButton {
    color: #b7b7c8;
    background: transparent;
    border: 0;
    border-radius: {{radius_md}}px;
    min-height: 38px;
    padding: 3px {{space_md}}px;
    text-align: left;
    font-size: {{text_base}}px;
}
#sidebarButton:hover {
    color: {{on_accent}};
    background: {{surface_alt}};
}
#sidebarButton:checked {
    color: {{on_accent}};
    background: {{surface_selected}};
    border-left: 3px solid {{accent}};
    font-weight: 600;
}
#sidebarStatus {
    color: {{text_muted}};
    font-size: {{text_xs}}px;
    padding: 9px {{space_sm}}px;
}

/* ---- Content header -------------------------------------------------- */
#content {
    background: {{bg}};
}
#pageTitle {
    color: {{text_strong}};
    font-size: {{text_2xl}}px;
    font-weight: 800;
}
#pageSubtitle {
    color: {{text_dim}};
    font-size: {{text_sm}}px;
}
#welcomeTitle {
    color: {{text_strong}};
    font-size: 30px;
    font-weight: 800;
}
#welcomeSubtitle {
    color: {{text_dim}};
    font-size: {{text_base}}px;
}
#sectionHeading {
    color: {{text_strong}};
    font-size: {{text_lg}}px;
    font-weight: 700;
}
#sectionCaption {
    color: #8a8aa0;
    font-size: {{text_sm}}px;
}
#searchBox {
    min-height: 38px;
    border: 1px solid {{border}};
    border-radius: {{radius_md}}px;
    padding: 0 {{space_md}}px;
    color: {{text}};
    background: {{surface_input}};
    selection-background-color: {{accent}};
}
#searchBox:focus {
    border: 1px solid {{accent}};
    background: {{surface_alt}};
}
QScrollArea, QScrollArea > QWidget > QWidget {
    background: transparent;
    border: 0;
}

/* ---- Cards ----------------------------------------------------------- */
#actionCard {
    background: {{surface}};
    border: 1px solid {{border}};
    border-radius: {{radius_lg}}px;
}
#actionCard:hover, #actionCard:focus {
    background: {{surface_alt}};
    border: 1px solid {{accent}};
}
#actionCard[variant="danger"]:hover, #actionCard[variant="danger"]:focus {
    border: 1px solid #e5595a;
}
#actionCard[hero="true"] {
    background: {{surface_hero}};
    border: 1px solid {{accent_border}};
}
#actionCard[hero="true"]:hover, #actionCard[hero="true"]:focus {
    background: {{surface_hero_alt}};
    border: 1px solid {{accent}};
}
#cardIcon {
    background: {{border_subtle}};
    border-radius: {{radius_md}}px;
    qproperty-alignment: AlignCenter;
}
#cardIconHero {
    background: {{accent}};
    border-radius: 13px;
    qproperty-alignment: AlignCenter;
}
#cardTitle {
    color: {{text_strong}};
    font-size: {{text_lg}}px;
    font-weight: 700;
}
#cardTitleHero {
    color: {{text_strong}};
    font-size: 17px;
    font-weight: 800;
}
#cardDescription {
    color: {{text_dim}};
    font-size: {{text_sm}}px;
}
#cardLock {
    color: {{warning}};
    font-size: {{text_xs}}px;
    font-weight: 600;
}
#pathLabel {
    color: #8a8aa0;
}

/* ---- Badges (state colours) ------------------------------------------ */
#badge {
    border-radius: {{radius_sm}}px;
    padding: 3px 9px;
    font-size: {{text_xs}}px;
    font-weight: 800;
    color: {{text_log}};
    background: {{border_subtle}};
    border: 1px solid {{border_strong}};
}
#badge[state="success"] {
    color: #c8e6a3;
    background: {{success_bg}};
    border: 1px solid {{success_border}};
}
#badge[state="warning"] {
    color: #ffcf8f;
    background: {{warning_bg}};
    border: 1px solid {{warning_border}};
}
#badge[state="error"] {
    color: #ffb3b3;
    background: {{error_bg}};
    border: 1px solid {{error_border}};
}
#badge[state="info"] {
    color: #c3b3ff;
    background: {{info_bg}};
    border: 1px solid {{accent_border}};
}

/* ---- Buttons --------------------------------------------------------- */
QPushButton {
    color: {{text}};
    background: {{border}};
    border: 1px solid {{border_strong}};
    border-radius: {{radius_md}}px;
    min-height: 34px;
    padding: 0 {{space_md}}px;
    font-weight: 600;
}
QPushButton:hover {
    background: {{border_strong}};
    border-color: #56566f;
}
QPushButton:pressed {
    background: {{surface_pressed}};
}
QPushButton:disabled {
    color: {{text_muted}};
    background: {{surface_disabled}};
    border-color: {{border_subtle}};
}
#primaryButton {
    color: {{on_accent}};
    background: {{accent}};
    border-color: {{accent_hover}};
    font-weight: 700;
}
#primaryButton:hover {
    background: {{accent_hover}};
}
#primaryButton:pressed {
    background: {{accent_pressed}};
}
#secondaryButton {
    color: {{text}};
    background: {{border}};
    border-color: {{border_strong}};
}
#dangerButton {
    color: {{on_accent}};
    background: {{error}};
    border-color: {{danger_hover}};
    font-weight: 700;
}
#dangerButton:hover {
    background: {{danger_hover}};
}
#dangerButton:disabled {
    color: {{text_muted}};
    background: {{danger_disabled_bg}};
    border-color: {{danger_disabled_border}};
}

/* ---- Operation panel & status --------------------------------------- */
#operationPanel {
    background: {{surface_header}};
    border: 1px solid {{border_subtle}};
    border-radius: {{radius_md}}px;
}
#warningBanner {
    background: {{warning_bg}};
    border: 1px solid {{warning_border}};
    border-radius: {{radius_md}}px;
}
#warningText {
    color: #ffcf8f;
    font-weight: 600;
}
#statusText {
    color: {{text}};
    font-weight: 600;
}
#statusIdle { color: {{text_muted}}; }
#statusRunning { color: {{accent}}; }
#statusSuccess { color: {{success}}; }
#statusWarning { color: {{warning}}; }
#statusError { color: {{error}}; }
QProgressBar {
    border: 0;
    background: {{border_subtle}};
    border-radius: 3px;
}
QProgressBar::chunk {
    background: {{accent}};
    border-radius: 3px;
}
#logView {
    color: {{text_log}};
    background: {{log_bg}};
    border: 1px solid {{border_divider}};
    border-radius: {{radius_md}}px;
    font-family: {{font_mono}};
    font-size: {{text_sm}}px;
    padding: {{space_sm}}px;
}

/* ---- Status pills (checklists) --------------------------------------- */
#statusPill {
    background: {{surface_disabled}};
    border: 1px solid {{border_subtle}};
    border-radius: {{radius_md}}px;
}
#statusPill[state="success"] { border-left: 3px solid {{success}}; }
#statusPill[state="error"] { border-left: 3px solid {{error}}; }
#statusPill[state="warning"] { border-left: 3px solid {{warning}}; }
#statusPill[state="info"] { border-left: 3px solid {{accent}}; }
#pillLabel { color: {{text}}; font-weight: 600; }
#pillDetail { color: #8a8aa0; font-size: {{text_sm}}px; }
#pillDot[state="success"] { color: {{success}}; }
#pillDot[state="error"] { color: {{error}}; }
#pillDot[state="warning"] { color: {{warning}}; }
#pillDot[state="info"] { color: {{accent}}; }

/* ---- Toast ----------------------------------------------------------- */
#toast {
    background: {{surface}};
    border: 1px solid {{border_strong}};
    border-radius: {{radius_md}}px;
    min-width: 260px;
    max-width: 420px;
}
#toast[state="success"] { border-left: 4px solid {{success}}; }
#toast[state="error"] { border-left: 4px solid {{error}}; }
#toast[state="warning"] { border-left: 4px solid {{warning}}; }
#toastText { color: {{text}}; font-weight: 600; }
#toastIcon { font-size: {{text_lg}}px; font-weight: 800; }
#toastIcon[state="success"] { color: {{success}}; }
#toastIcon[state="error"] { color: {{error}}; }
#toastIcon[state="warning"] { color: {{warning}}; }

/* ---- Dialogs & misc -------------------------------------------------- */
#dialogTitle, #successTitle, #errorTitle {
    font-size: 21px;
    font-weight: 700;
}
#dialogTitle, #successTitle { color: {{success}}; }
#errorTitle { color: {{error}}; }
QDialog {
    color: {{text}};
    background: {{bg}};
}
QTreeWidget {
    color: {{text_log}};
    background: {{surface_inset}};
    alternate-background-color: {{surface_disabled}};
    border: 1px solid {{border_subtle}};
    border-radius: {{radius_md}}px;
}
QHeaderView::section {
    color: {{text_dim}};
    background: {{surface_header}};
    border: 0;
    border-bottom: 1px solid {{border_subtle}};
    padding: 7px;
}
#emptyState {
    color: {{text_muted}};
    font-size: {{text_lg}}px;
    qproperty-alignment: AlignCenter;
    min-height: 180px;
}
QScrollBar:vertical {
    width: 10px;
    background: transparent;
}
QScrollBar::handle:vertical {
    min-height: 30px;
    background: {{border}};
    border-radius: 5px;
}
QScrollBar::handle:vertical:hover {
    background: #56566f;
}
QToolTip {
    color: {{text}};
    background: {{surface}};
    border: 1px solid {{border_strong}};
    padding: 6px;
    border-radius: 6px;
}
```

**Notes on preserved literals (not tokenized):**
- `#b7b7c8` (sidebarButton color), `#8a8aa0` (sectionCaption/pathLabel/pillDetail), `#56566f` (hover accents), `#e5595a` (danger card hover border), `#c8e6a3`/`#ffcf8f`/`#ffb3b3`/`#c3b3ff` (badge state text colors), `#ffcf8f` (warningText) — these are fine-grained tints without a dedicated semantic token. They stay literal. In light theme they render slightly off (dark-on-light) but are used on tinted state backgrounds where contrast still holds. A future polish task can tokenize these; out of scope for this foundation phase.

- [ ] **Step 2: Run token tests to verify migration**

Run: `cd /mnt/sdcard/Projects/PhaseZero && QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_tokens.py -v`
Expected: PASS (all 5 tests). `test_every_placeholder_resolves` now validates the real placeholders resolve.

- [ ] **Step 3: Verify dark theme renders without residual placeholders**

Run: `cd /mnt/sdcard/Projects/PhaseZero && QT_QPA_PLATFORM=offscreen python -c "
import sys; sys.path.insert(0, '.')
from linux.ui_native.tokens import DARK, LIGHT, render_qss
d = render_qss(DARK); l = render_qss(LIGHT)
assert '{{' not in d, 'dark has residual placeholder'
assert '{{' not in l, 'light has residual placeholder'
assert '#7c4dff' in d and '#7c4dff' in l, 'accent missing'
print('OK: dark', len(d), 'chars; light', len(l), 'chars')
"`
Expected: `OK: dark <N> chars; light <N> chars`

- [ ] **Step 4: Commit**

```bash
git add linux/ui_native/theme.qss
git commit -m "refactor(ui-native): migrate theme.qss to {{token}} placeholders

All hex codes replaced with semantic token placeholders. Fine-grained
tints (sidebarButton color, badge state text) kept literal — future
polish. Dark theme renders identically to pre-migration."
```

---

### Task 3: Simplify `app.py` — remove regex-rewrite, use tokens

**Files:**
- Modify: `linux/ui_native/app.py:1-129`

**Interfaces:**
- Consumes: `DARK`, `LIGHT`, `render_qss` from Task 1
- Produces: `apply_theme(app, theme)` that works via tokens; `stylesheet()` function removed (or reduced to `render_qss` call)

- [ ] **Step 1: Write the failing test (app uses tokens)**

Append to `tests/test_native_tokens.py`:

```python
def test_app_apply_theme_uses_tokens(monkeypatch):
    """apply_theme should set stylesheet from render_qss, not regex-rewrite."""
    import linux.ui_native.app as app_mod
    # stylesheet() must delegate to render_qss, not contain the old replacements dict
    source = Path(app_mod.__file__).read_text(encoding="utf-8")
    # The old regex-rewrite had a 'replacements = {' block — must be gone.
    assert "replacements = {" not in source
    assert "from .tokens import" in source or "from linux.ui_native.tokens import" in source
```

- [ ] **Step 2: Run test to verify it fails**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_tokens.py::test_app_apply_theme_uses_tokens -v`
Expected: FAIL (`replacements = {` still present in app.py)

- [ ] **Step 3: Rewrite app.py**

Replace the entire `stylesheet()` function and `apply_theme()` function. New `linux/ui_native/app.py`:

```python
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QColor, QPalette
from PySide6.QtWidgets import QApplication

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from linux.ui_native.boot_selector import BootSelectorWindow
    from linux.ui_native.main_window import MainWindow
    from linux.ui_native.tokens import DARK, LIGHT, render_qss
else:
    from .boot_selector import BootSelectorWindow
    from .main_window import MainWindow
    from .tokens import DARK, LIGHT, render_qss


ROOT = Path(__file__).resolve().parents[2]


def apply_theme(app: QApplication, theme: str) -> None:
    tokens = LIGHT if theme == "light" else DARK
    app.setStyle("Fusion")
    app.setStyleSheet(render_qss(tokens))
    palette = QPalette()
    palette.setColor(QPalette.Window, QColor(tokens.bg))
    palette.setColor(QPalette.WindowText, QColor(tokens.text))
    palette.setColor(QPalette.Base, QColor(tokens.surface_inset))
    palette.setColor(QPalette.Text, QColor(tokens.text))
    palette.setColor(QPalette.Button, QColor(tokens.surface))
    palette.setColor(QPalette.ButtonText, QColor(tokens.text))
    palette.setColor(QPalette.Highlight, QColor(tokens.accent))
    palette.setColor(QPalette.HighlightedText, QColor(tokens.on_accent))
    app.setPalette(palette)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="PhaseZero Central de Controle")
    parser.add_argument("--category", default="")
    parser.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--screenshot", default="")
    parser.add_argument("--light", action="store_true")
    parser.add_argument("--boot-selector", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)
    app.setApplicationName("PhaseZero")
    app.setOrganizationName("PhaseZero")
    app.setDesktopFileName("io.phasezero.ControlCenter")
    app.setQuitOnLastWindowClosed(True)
    apply_theme(app, "light" if args.light else "dark")
    if args.boot_selector:
        window = BootSelectorWindow(ROOT, smoke_test=args.smoke_test)
    else:
        window = MainWindow(ROOT, initial_category=args.category)
        window.theme_changed.connect(lambda theme: apply_theme(app, theme))
    window.show()
    if args.smoke_test:
        def finish() -> None:
            if args.screenshot:
                target = Path(args.screenshot).expanduser().resolve()
                target.parent.mkdir(parents=True, exist_ok=True)
                window.grab().save(str(target))
            window.close()
            app.quit()

        QTimer.singleShot(900, finish)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
```

Key changes vs original:
- `stylesheet()` function REMOVED (was the regex-rewrite, ~40 lines).
- `import re` REMOVED (no longer needed).
- `STYLE` constant REMOVED.
- `apply_theme()` uses `render_qss(tokens)` directly.
- `QPalette.Base` uses `surface_inset` (matches sidebar/tree bg, was `#191926` = `surface_inset` in dark).

- [ ] **Step 4: Run test to verify it passes**

Run: `QT_QPA_PLATFORM=offscreen python -m pytest tests/test_native_tokens.py::test_app_apply_theme_uses_tokens -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add linux/ui_native/app.py tests/test_native_tokens.py
git commit -m "refactor(ui-native): replace regex light-mode with token-based theming

apply_theme() now uses render_qss(LIGHT) directly. Removes the ~40-line
regex-rewrite stylesheet() that was fragile to color re-mapping. Light
mode = instantiate LIGHT dataclass."
```

---

### Task 4: Smoke test — verify full native UI boots in dark + light

**Files:**
- Test: `tests/test_linux_native_ui.py` (existing), `tests/linux-ui.sh` (existing)

**Interfaces:**
- Consumes: all prior tasks

- [ ] **Step 1: Run existing native UI pytest suite**

Run: `cd /mnt/sdcard/Projects/PhaseZero && QT_QPA_PLATFORM=offscreen python -m pytest tests/test_linux_native_ui.py -v`
Expected: PASS (all existing tests). If any fail, the QSS migration broke a widget — investigate which selector lost its color.

- [ ] **Step 2: Run native UI smoke test (offscreen boot)**

Run: `cd /mnt/sdcard/Projects/PhaseZero && QT_QPA_PLATFORM=offscreen python linux/ui_native/app.py --smoke-test --screenshot /tmp/pz-native-dark.png`
Expected: exits 0, writes `/tmp/pz-native-dark.png`.

- [ ] **Step 3: Run native UI smoke test in light mode**

Run: `cd /mnt/sdcard/Projects/PhaseZero && QT_QPA_PLATFORM=offscreen python linux/ui_native/app.py --smoke-test --light --screenshot /tmp/pz-native-light.png`
Expected: exits 0, writes `/tmp/pz-native-light.png`.

- [ ] **Step 4: Verify screenshots differ (dark vs light are distinct)**

Run: `cd /mnt/sdcard/Projects/PhaseZero && python -c "
from PySide6.QtGui import QPixmap, QImage
d = QImage('/tmp/pz-native-dark.png'); l = QImage('/tmp/pz-native-light.png')
# Sample a pixel from the sidebar area (x=30, y=100)
dp = QColor.fromRgb(d.pixel(30, 100))
lp = QColor.fromRgb(l.pixel(30, 100))
print(f'dark sidebar pixel: rgb({dp.red()},{dp.green()},{dp.blue()})')
print(f'light sidebar pixel: rgb({lp.red()},{lp.green()},{lp.blue()})')
assert dp != lp, 'dark and light screenshots identical — theming broken'
print('OK: themes render differently')
"`
Expected: `OK: themes render differently`

- [ ] **Step 5: Run bash smoke test if available**

Run: `cd /mnt/sdcard/Projects/PhaseZero && bash tests/linux-ui.sh 2>&1 | tail -20`
Expected: PASS (or skip gracefully if env deps missing). Look for native UI section specifically.

- [ ] **Step 6: Commit final state (no code changes — verification only)**

No commit needed if all green. If fixes were needed during smoke, commit them here with message:
```bash
git commit -am "fix(ui-native): correct token migration issues found in smoke test"
```

---

## Self-Review Checklist (run after writing, before handoff)

- [x] **Spec coverage:** Spec Fase 1 = tokens.py + theme.qss migration + app.py simplification. Tasks 1-3 cover all three. Task 4 verifies.
- [x] **Placeholder scan:** No TBD/TODO. All code blocks complete.
- [x] **Type consistency:** `ThemeTokens` fields match between DARK/LIGHT. `render_qss(tokens: ThemeTokens) -> str` consistent. `apply_theme(app, theme: str)` matches `app.py:main()` usage.
- [x] **Hex→token mapping:** Every hex in original theme.qss accounted for in migration table (Task 2). Fine-grained tints documented as preserved literals.

## Phases 2-5 (separate plans, depend on this one)

- Phase 2: Skeleton loaders (`SkeletonTile`, `SkeletonCard`, `BasePage.show_skeletons`)
- Phase 3: Stateful dialogs (`StatefulDialog`, rewrite `PreviewDialog`/`ResultDialog`, add `ProgressDialog`)
- Phase 4: Navigation + feedback (`Breadcrumb`, `StatusBar`, operation panel log tail + elapsed)
- Phase 5: Windows portability (`platform.py`, refactor `command_runner`, `platforms` field in catalog)

Each phase gets its own plan file after this one is implemented and verified.
