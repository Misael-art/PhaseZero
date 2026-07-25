# Native UI Foundation — Design Spec

**Data:** 2026-07-10
**Superfície:** `linux/ui_native/` (PySide6/Qt6)
**Objetivo:** Consolidar a UI nativa como superfície única do PhaseZero, com fundação de design system robusta e caminho de portabilidade para Windows via Qt6.

## Contexto e decisão

O PhaseZero possui 3 superfícies Linux-only: Web UI (`linux/ui/`, legada), Native UI (`linux/ui_native/`, PySide6, principal) e TUI (`linux/ui/tui.sh`, fallback).

Decisões do brainstorming:
- **Escopo:** consolidar Nativa PySide6 como base; Web UI congelada/deprecated.
- **Prioridade:** fundação primeiro (design tokens, light mode correto, skeletons, a11y AA); depois portabilidade Windows.
- **Abordagem:** Tokens como Python dataclass + QSS gerado por interpolação (abordagem A).

## Problemas atuais endereçados

1. `theme.qss` tem cores hex hardcoded — sem design tokens de spacing/tipografia/raio.
2. Light mode implementado por regex-rewrite de hex codes em `app.py` (~40 linhas) — frágil, propenso a re-mapping acidental.
3. Páginas usam spinner textual (`#emptyState` "Carregando…") — percepção de espera alta.
4. Diálogos (`PreviewDialog`, `ResultDialog`) têm hierarquia plana, sem ícones de estado, sem ações secundárias (copiar, abrir pasta), sem suporte a operações longas.
5. Sem breadcrumb — usuário não sabe onde está na hierarquia.
6. Feedback de operação só no painel (transient); sem status bar global persistente.
7. Sidebar tem 13 botões flat — sem agrupamento visual por seção.
8. Primitivas Unix espalhadas (`os.killpg`, `os.setsid`, `XDG_STATE_HOME`, `chmod 0600`, bridges `phasezero-admin`/`bigsudo`/`pkexec`) bloqueiam portabilidade Windows.

## Arquitetura

### Fase 1 — Design tokens centralizados

#### `tokens.py` (novo)

Single source of truth. `@dataclass(frozen=True) ThemeTokens` com campos semânticos:

```python
@dataclass(frozen=True)
class ThemeTokens:
    # Cores semânticas — backgrounds
    bg: str                  # appShell, content, dialog (#1e1e2e)
    surface: str             # cards/toast/tooltip (#2a2a3c)
    surface_alt: str         # hover de cards/sidebar buttons (#32324a)
    surface_inset: str       # sidebar/tree — mais escuro que bg (#191926)
    surface_header: str      # headerBar/operationPanel/headerView (#232336)
    surface_input: str       # searchBox bg (#252536)
    surface_hero: str        # hero card bg (#2d2747)
    surface_hero_alt: str    # hero hover (#352c55)
    surface_selected: str    # sidebarButton checked (#2b2444)
    surface_pressed: str     # button pressed (#2f2f40)
    surface_disabled: str    # button/pill/tree-alt disabled (#262636)
    # Cores semânticas — borders
    border: str              # default (#3a3a4c)
    border_subtle: str       # pill/tree/scrollbar/appShell/badge (#33334a)
    border_divider: str      # linhas divisórias header/sidebar/log (#2e2e44)
    border_strong: str       # toast/tooltip/scrollbar hover (#45455c)
    accent_border: str       # hero border tint (#4a3d7a)
    # Texto
    text: str                # primary (#f2f2f7)
    text_strong: str         # titles brightest (#f4f4fa)
    text_dim: str            # secondary (#a0a0b0)
    text_muted: str          # tertiary/disabled (#6a6a82)
    text_log: str            # log/badge body (#cfcfe0)
    # Accent
    accent: str              # #7c4dff
    accent_hover: str        # #8f66ff
    accent_pressed: str      # #6a3ce6
    on_accent: str           # texto sobre accent (#ffffff)
    # Estados (foreground, bg, border para cada)
    success: str; success_bg: str; success_border: str
    warning: str; warning_bg: str; warning_border: str
    error: str;   error_bg: str;   error_border: str
    info: str;    info_bg: str;    info_border: str
    # Danger button variants
    danger: str; danger_hover: str; danger_disabled_bg: str; danger_disabled_border: str
    # Skeleton
    skeleton_base: str; skeleton_shimmer: str
    # Log
    log_bg: str
    # Spacing escala (4px base)
    space_xs: int; space_sm: int; space_md: int; space_lg: int; space_xl: int
    # Tipografia
    font_ui: str; font_mono: str
    text_xs: int; text_sm: int; text_base: int; text_lg: int; text_xl: int; text_2xl: int
    # Raio
    radius_sm: int; radius_md: int; radius_lg: int
    # Shadow
    shadow_alpha: int
    # Transition
    transition: str
```

Instâncias:
- `DARK = ThemeTokens(bg="#1e1e2e", surface="#2a2a3c", ..., accent="#7c4dff", ..., space_xs=4, space_sm=8, space_md=12, space_lg=18, space_xl=24, ..., radius_sm=8, radius_md=11, radius_lg=16, ...)`
- `LIGHT = ThemeTokens(bg="#f1f1f6", surface="#ffffff", ..., accent="#7c4dff", ..., space_xs=4, ..., radius_sm=8, ...)`

Accent `#7c4dff` mantido em ambos (identidade de marca). Cores de estado (success/warning/error/info) ajustadas por tema para contraste AA.

#### `render_qss(tokens)` (em `tokens.py`)

Interpolador: lê `theme.qss`, substitui `{{token_name}}` por `getattr(tokens, name)`.

```python
def render_qss(tokens: ThemeTokens) -> str:
    text = (Path(__file__).parent / "theme.qss").read_text()
    def sub(m: re.Match) -> str:
        return str(getattr(tokens, m.group(1)))
    return re.sub(r"\{\{(\w+)\}\}", sub, text)
```

#### `theme.qss` migra para placeholders

Hex codes substituídos por `{{token}}`. Ex.:

```css
#actionCard {
    background: {{surface}};
    border: 1px solid {{border}};
    border-radius: {{radius_lg}}px;
}
```

Toda cor/spacing/raio hardcoded vira placeholder. Mapeamento dark→light documentado nos field names da dataclass.

#### `app.py` simplifica

```python
from .tokens import DARK, LIGHT, render_qss

def apply_theme(app: QApplication, theme: str) -> None:
    tokens = LIGHT if theme == "light" else DARK
    app.setStyle("Fusion")
    app.setStyleSheet(render_qss(tokens))
    palette = QPalette()
    palette.setColor(QPalette.Window, QColor(tokens.bg))
    palette.setColor(QPalette.WindowText, QColor(tokens.text))
    palette.setColor(QPalette.Base, QColor(tokens.bg))
    palette.setColor(QPalette.Text, QColor(tokens.text))
    palette.setColor(QPalette.Button, QColor(tokens.surface))
    palette.setColor(QPalette.ButtonText, QColor(tokens.text))
    palette.setColor(QPalette.Highlight, QColor(tokens.accent))
    palette.setColor(QPalette.HighlightedText, QColor(tokens.on_accent))
    app.setPalette(palette)
```

Regex-rewrite de ~40 linhas removido. Light mode = instanciar `LIGHT`.

#### Migração de hex existente → tokens

Mapeamento dos hex codes atuais para fields da dataclass. Hexes semelhantes consolidados num token único por tema:

| Hex atual | Token field | Uso no QSS |
|---|---|---|
| `#1e1e2e` | `bg` | appShell, content, dialog |
| `#2a2a3c` | `surface` | actionCard, toast, tooltip |
| `#32324a` | `surface_alt` | actionCard hover, sidebarButton hover |
| `#191926` | `surface_inset` | sidebar, tree bg |
| `#232336` | `surface_header` | headerBar, operationPanel, headerView |
| `#252536` | `surface_input` | searchBox bg |
| `#2d2747` | `surface_hero` | actionCard hero |
| `#352c55` | `surface_hero_alt` | actionCard hero hover |
| `#2b2444` | `surface_selected` | sidebarButton checked |
| `#2f2f40` | `surface_pressed` | button pressed |
| `#262636` | `surface_disabled` | pill/button/tree-alt disabled (`#22222f` consolidado aqui) |
| `#3a3a4c` | `border` | default border |
| `#33334a` | `border_subtle` | pill/tree/scrollbar/appShell/badge (`#34344a` consolidado) |
| `#2e2e44` | `border_divider` | linhas divisórias header/sidebar/log (`#2b2b40` consolidado) |
| `#45455c` | `border_strong` | toast/tooltip/scrollbar hover (`#4a4a60` consolidado) |
| `#4a3d7a` | `accent_border` | hero border tint |
| `#f2f2f7` | `text` | primary text, dialog, windowButton |
| `#f4f4fa` | `text_strong` | windowTitle, pageTitle, cardTitleHero (`#f5f5fa` consolidado) |
| `#a0a0b0` | `text_dim` | subtitle, caption |
| `#6a6a82` | `text_muted` | sectionLabel, sidebarStatus, emptyState, disabled text |
| `#cfcfe0` | `text_log` | log body, badge default text |
| `#7c4dff` | `accent` | brand, primaryButton, scrollbar chunk, searchBox focus |
| `#8f66ff` | `accent_hover` | primaryButton hover |
| `#6a3ce6` | `accent_pressed` | primaryButton pressed |
| `#7cb342` | `success` | status, pill, toast success |
| `#ff9800` | `warning` | status, pill, cardLock |
| `#e53935` | `error` | status, pill, toast error, closeButton hover |
| `#15151f` | `log_bg` | logView bg |

Hexes consolidados marcados entre parênteses. Cores compostas de estado (bg/border de badges e pills) derivam dos 3 fields por estado (`success_bg`, `success_border`, etc.).

**Trade-off:** consolidar hexes visualmente próximos introduz mudança mínima de matiz (ex: `#22222f`→`#262636` no tree-alt). Aceitável — diferenças estavam abaixo do limiar perceptual no tema atual e simplifica o sistema de tokens. Se uma área específica precisar de variação distinta no futuro, adiciona-se um token novo em vez de re-duplicar.

### Fase 2 — Skeleton loaders

#### `SkeletonTile` (em `widgets.py`)

Bloco cinza pulsante que imita um elemento do layout.

```python
class SkeletonTile(QFrame):
    def __init__(self, width: int, height: int, parent=None):
        super().__init__(parent)
        self.setObjectName("skeletonTile")
        self.setFixedSize(width, height)
```

#### `SkeletonCard` (em `widgets.py`)

Imita `ActionCard`: icon_tile placeholder + título placeholder + descrição placeholder + botão placeholder.

Layout espelha `ActionCard.__init__`:
- `SkeletonTile(46, 46)` — icon
- `SkeletonTile(160, 14)` — título
- `SkeletonTile(100, 10)` — sub
- `SkeletonTile(largura-36, 12)` — descrição
- `SkeletonTile(120, 32)` — botão

#### Shimmer

Propriedade `shimmer` no `SkeletonTile` alterna entre `skeleton_base` e `skeleton_shimmer` via `QPropertyAnimation` (mesmo padrão do `Toast` existente). Loop infinito até `hide()`.

#### Tokens skeleton

```python
# DARK
skeleton_base = "#2e2e42"; skeleton_shimmer = "#3a3a52"
# LIGHT
skeleton_base = "#e0e0ea"; skeleton_shimmer = "#f0f0f6"
```

#### Integração — `BasePage` (em `pages/base.py`)

```python
class BasePage(QWidget):
    def show_skeletons(self, count: int = 6, hero: bool = False) -> None:
        """Mostra N skeleton cards enquanto dados carregam."""
        self._clear_content()
        for _ in range(count):
            self._add_card(SkeletonCard(hero=hero))

    def populate(self, cards: list[ActionCard]) -> None:
        """Substitui skeletons por cards reais."""
        self._clear_content()
        for card in cards:
            self._add_card(card)
```

Cada `loadX()` chama `show_skeletons()` antes da promise, `populate()` ao resolver.

#### Threshold

Cargas <200ms: skeleton aparece/some rápido demais = pior que spinner. Gate: só mostra skeleton se estima >200ms (ou após 1 frame se carga já pronta, skip).

#### Onde aparece

| Página | Skeleton imita |
|---|---|
| Dashboard | hero cards + grid ferramentas |
| Overview/SteamDeck/etc | grid de action cards |
| Listas de StatusPill | pills skeleton |
| Resultados | tree skeleton |

### Fase 3 — Diálogos melhores

#### `StatefulDialog` base (em `widgets.py`)

```python
STATE_ICONS = {
    "success": "✓", "warning": "⚠", "error": "✕",
    "info": "ℹ", "running": "◐",
}

class StatefulDialog(QDialog):
    def __init__(self, title: str, state: str, parent=None):
        super().__init__(parent)
        self.setObjectName("statefulDialog")
        # Header: ícone grande colorido + título
        # Body: QVBoxLayout (subclasses preenchem)
        # Footer: QDialogButtonBox com roles claros

    def add_action(self, label: str, role, variant: str = "", enabled: bool = True) -> QPushButton:
        btn = self.footer.addButton(label, role)
        if variant: btn.setObjectName(variant)
        btn.setEnabled(enabled)
        return btn
```

#### `PreviewDialog` reescrito

Layout:
- Header: ícone `warning` + "Preview concluído"
- Caption: "Nenhuma mutação executada. Revise a saída abaixo."
- **Command bar** (novo): mostra comando exato que será executado, selecionável, mono. Implementado como `QLabel` com `setTextInteractionFlags(Qt.TextSelectableByMouse)` e objectName `commandBar`.
- **Log view**: `QPlainTextEdit` readonly, mono (existente `logView`).
- **Summary chips** (novo): `StatusPill` com contagem de ok/warn/error do parse do log. Contagem derivada de `result.parsed` se disponível, senão omitida.
- Footer: `[Voltar]` (secondary, RejectRole) + `[Confirmar e aplicar]` (danger, AcceptRole, enabled só se `result.ok`).

Comando exato: `result.command` já existe em `OperationResult` (campo `command: list[str]`).

#### `ResultDialog` reescrito

Layout:
- Header: ícone success/error + título ("Operação concluída" / "Operação falhou")
- **Path bar**: `result.json` path selecionável + botão inline "Copiar"
- Log view (existente)
- Footer: `[Copiar saída]` (secondary) + `[Abrir pasta]` (secondary) + `[Fechar]` (primary).

Ações:
- Copiar saída: `QApplication.clipboard().setText(formatted)`
- Abrir pasta: `platform.open_path(result.result_path.parent)` (ver Fase 5)

#### `ProgressDialog` (novo, em `widgets.py`)

Para ações longas que rodam enquanto diálogo aberto.

- State icon `running` animado
- `QProgressBar` (já existe no tema)
- Log view incremental (`CommandRunner` já captura stdout incremental)
- Botão `[Cancelar]` (danger) envia cancel via `runner.cancel()` → SIGTERM (Unix) ou taskkill (Windows)

`MainWindow` decide entre painel de operação (default) ou `ProgressDialog` (fluxos críticos onde usuário não deve interromper). Default continua painel — `ProgressDialog` é opt-in por ação via flag no catálogo (ver Fase 5).

#### Tokens diálogo

```css
#statefulDialog { border-radius: {{radius_lg}}px; }
#dialogStateIcon { font-size: 28px; }
#dialogStateIcon[state="success"] { color: {{success}}; }
#dialogStateIcon[state="warning"] { color: {{warning}}; }
#dialogStateIcon[state="error"]   { color: {{error}}; }
#dialogStateIcon[state="info"]    { color: {{info}}; }
#dialogStateIcon[state="running"] { color: {{accent}}; }
#commandBar {
    background: {{log_bg}};
    border: 1px solid {{border}};
    border-radius: {{radius_sm}}px;
    font-family: {{font_mono}};
    padding: {{space_sm}}px {{space_md}}px;
}
```

### Fase 4 — Navegação + feedback

#### `Breadcrumb` (em `widgets.py`)

```python
class Breadcrumb(QWidget):
    def __init__(self, trail: list[str], parent=None):
        # trail = ["Início", "Emulação"]
        # Labels separados por "›"
        # Ancestrais: text_dim; atual: text + font-weight 600
```

`MainWindow` monta trail ao trocar página. Click em "Início" volta Dashboard.

```css
#breadcrumb { padding: 0 0 {{space_md}}px 0; }
#crumbLink { color: {{text_dim}}; }
#crumbCurrent { color: {{text}}; font-weight: 600; }
#crumbSep { color: {{text_muted}}; padding: 0 {{space_xs}}px; }
```

#### `StatusBar` global (em `widgets.py`)

Barra fixa no rodapé da janela.

```python
class StatusBar(QFrame):
    def __init__(self, parent=None):
        self.setObjectName("statusBar")
        # system_state: StatusPill (ok/warn/blocked) — reflecte run_all_status() agregado
        # op_state: QLabel — idle/running/completed/failed
        # reboot_pill: StatusPill — lê /run/reboot-required
        # version: QLabel — do metainfo.xml
```

Conexões:
- `system_state` ← sinal agregado de status (ok se tudo ok, warn se algum warn, error se algum blocked)
- `op_state` ← `CommandRunner.state_changed`
- `reboot_pill` ← check periódico de `/run/reboot-required` (timer 5s)
- `version` ← parse de `packaging/linux/io.phasezero.ControlCenter.metainfo.xml`

#### Sidebar agrupada

Hoje: 13 botões flat. Novo: 3 seções com `#sectionLabel` (já existe no QSS).

```python
# main_window.py
SIDEBAR_SECTIONS = [
    ("INÍCIO",      ["dashboard"]),
    ("SISTEMA",     ["overview", "profiles", "steamdeck", "windows-vm", "waydroid", "boot", "server"]),
    ("FERRAMENTAS", ["emulation", "flatpak", "ai-dev", "tuning", "results"]),
]
```

Renderiza `#sectionLabel` + botões por grupo.

#### Painel de operação enriquecido

Painel atual mostra status textual. Adicionar:
- **Progress bar** — ligada ao `%` regex do `CommandRunner` (já extrai progresso)
- **Log tail** compacto — últimas 3 linhas visíveis no painel
- **Tempo decorrido** — `2.3s` ao lado do status

Slots em `MainWindow`:
```python
def _on_runner_progress(self, pct: int): self.op_progress.setValue(pct)
def _on_runner_log(self, line: str): self.op_log_tail.append_and_trim(line, keep=3)
def _on_runner_elapsed(self, secs: float): self.op_elapsed.setText(f"{secs:.1f}s")
```

#### Layout MainWindow final

```
┌──────────────────────────────────────────────────────────────┐
│ [PZ] PhaseZero  Central de Controle    🇧🇷🇺🇸  🌓  ─ ▢ ✕     │  HeaderBar
├───────────┬──────────────────────────────────────────────────┤
│ INÍCIO    │ Início › Emulação              [🔍 buscar...]    │  Breadcrumb + search
│  Dashboard│ ──────────────────────────────────────────────── │
│ SISTEMA   │  [hero card]  [hero card]                        │
│  Visão    │  [card] [card] [card] [card]                     │  Content
│  ...      │                                                  │
│ FERRAMENTAS├──────────────────────────────────────────────────┤
│  Emulação │ ▶ Instalando BIOS  ████░░ 60%  2.3s              │  Operation panel
│  ...      │ last log line...                                 │
├───────────┴──────────────────────────────────────────────────┤
│ ● pronto  │ operação: running │ reboot: não │ v1.4.1         │  StatusBar
└──────────────────────────────────────────────────────────────┘
```

### Fase 5 — Portabilidade Windows

#### `platform.py` (novo)

Único ponto de variação por OS. Importa-se em todo lugar que precisa de primitiva Unix.

```python
# linux/ui_native/platform.py
import os, sys, shutil, subprocess
from pathlib import Path

IS_WINDOWS = sys.platform == "win32"
IS_LINUX = sys.platform.startswith("linux")

def admin_bridge() -> str | None:
    if IS_LINUX:
        for bin in ("phasezero-admin", "bigsudo", "pkexec"):
            if shutil.which(bin): return bin
    elif IS_WINDOWS:
        return "uac"
    return None

def elevate(argv: list[str]) -> list[str]:
    if IS_WINDOWS:
        exe = argv[0]
        args = " ".join(argv[1:])
        return ["powershell", "-Command",
                f"Start-Process -Verb RunAs -FilePath '{exe}' -ArgumentList '{args}'"]
    bridge = admin_bridge()
    return [bridge] + argv if bridge else argv

def secure_file(path: Path) -> None:
    if IS_WINDOWS:
        subprocess.run(["icacls", str(path), "/inheritance:r",
                        "/grant:r", f"{os.getlogin()}:F"], check=True)
    else:
        path.chmod(0o600)

def kill_process_group(pid: int) -> None:
    if IS_WINDOWS:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
    else:
        import signal
        os.killpg(os.getpgid(pid), signal.SIGKILL)

def state_dir() -> Path:
    if IS_WINDOWS:
        base = os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData/Local"))
        return Path(base) / "phasezero"
    base = os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
    return Path(base) / "phasezero"

def open_path(path: Path) -> None:
    if IS_WINDOWS:
        os.startfile(str(path))  # type: ignore[attr-defined]
    else:
        subprocess.run(["xdg-open", str(path)], check=False)
```

#### `command_runner.py` refatorado

Substitui:
- `os.killpg(os.getpgid(pid), signal.SIGKILL)` → `platform.kill_process_group(pid)`
- Paths hardcoded `~/.local/state/...` → `platform.state_dir()`
- `chmod(0o600)` → `platform.secure_file(path)`

`QProcess` já é cross-platform (`CreateNewSession` mapeia para Job Object no Windows). Pontos de chamada Unix diretas ficam apenas em `platform.py`.

#### `models.py` — flag `platforms`

```python
@dataclass(frozen=True)
class ActionSpec:
    # ... campos existentes ...
    platforms: tuple[str, ...] = ("linux",)
```

Default `("linux",)` preserva comportamento atual.

#### `catalog.py` — filtro por OS

```python
from .platform import IS_WINDOWS

def build_catalog(root: Path) -> list[ActionSpec]:
    current = "windows" if IS_WINDOWS else "linux"
    return [a for a in _all_actions(root) if current in a.platforms]
```

Ações marcadas `platforms=("linux",)` desaparecem em Windows. `boot_selector` e similares ficam Linux-only. Ações Windows-only (futuras) usam `platforms=("windows",)`.

#### `app.py` — esconde boot_selector em Windows

```python
if args.boot_selector and not IS_WINDOWS:
    window = BootSelectorWindow(...)
```

#### O que NÃO muda em Windows

| Componente | Status |
|---|---|
| `tokens.py` | idêntico |
| `theme.qss` | idêntico (placeholders) |
| `widgets.py` (cards/pills/toasts/dialogs/skeletons) | idêntico |
| `catalog.py` (lógica) | idêntico (só filtra por OS) |
| `models.py` | idêntico (+ campo `platforms`) |
| `pages/*` | idêntico |
| `main_window.py` | idêntico |
| `boot_selector.py` | Linux-only, escondido em Windows |
| `result_parser.py` | idêntico |

#### Empacotamento Windows (fora deste spec)

PyInstaller → `.exe` standalone; winget/MSI depois. Não incluído neste design — apenas preparado o caminho. Spec futuro para empacotamento.

#### Web UI (fora deste spec)

Web UI (`linux/ui/`) fica congelada/deprecated. Não porta Windows.

## Componentes novos

| Arquivo | Componente | Fase |
|---|---|---|
| `tokens.py` (novo) | `ThemeTokens`, `DARK`, `LIGHT`, `render_qss()` | 1 |
| `widgets.py` | `SkeletonTile`, `SkeletonCard` | 2 |
| `widgets.py` | `StatefulDialog`, `ProgressDialog` | 3 |
| `widgets.py` | `Breadcrumb`, `StatusBar` | 4 |
| `platform.py` (novo) | abstrações OS | 5 |

## Componentes modificados

| Arquivo | Mudança | Fase |
|---|---|---|
| `theme.qss` | hex → placeholders `{{token}}` | 1 |
| `app.py` | `stylesheet()` regex-rewrite removido; `apply_theme()` usa tokens | 1, 5 |
| `pages/base.py` | `show_skeletons()`, `populate()` | 2 |
| `widgets.py` | `PreviewDialog`, `ResultDialog` reescritos sobre `StatefulDialog` | 3 |
| `main_window.py` | Breadcrumb, StatusBar, sidebar seções, op panel rica | 4 |
| `models.py` | campo `platforms` em `ActionSpec` | 5 |
| `catalog.py` | filtro por OS em `build_catalog()` | 5 |
| `command_runner.py` | usa `platform.*` | 5 |

## Fluxo de dados

```
tokens.py (DARK/LIGHT)
    ↓ render_qss(tokens)
theme.qss (placeholders) → QSS string
    ↓ app.setStyleSheet()
QApplication (dark ou light)
    ↓ QSS aplica-se a
widgets.py (ActionCard, SkeletonCard, StatefulDialog, Breadcrumb, StatusBar...)
    ↓ usados por
pages/* (BasePage.show_skeletons → populate)
    ↓ registradas em
main_window.py (sidebar seções + breadcrumb + op panel + statusbar)
    ↓ ações vêm de
catalog.py (filtra por platform.platforms)
    ↓ executadas via
command_runner.py (usa platform.kill_process_group, platform.state_dir)
```

## Tratamento de erros

- `render_qss()`: se placeholder não existe na dataclass, `AttributeError` em runtime. Mitigação: teste que valida todo `{{token}}` no `theme.qss` existe em `ThemeTokens` fields.
- `platform.*` em OS não suportado (ex: macOS): `admin_bridge()` retorna `None`, ações elevadas falham com mensagem clara ("bridge de elevação não disponível"). Não crash.
- Skeleton shimmer: se `QPropertyAnimation` falha (raro), tile mostra `skeleton_base` estático — degrada graciosamente.
- `ProgressDialog` cancelado: `runner.cancel()` já trata SIGTERM/taskkill; se processo já terminou, no-op.

## Estratégia de testes

| Fase | Teste |
|---|---|
| 1 | `test_tokens.py`: todo `{{token}}` no `theme.qss` existe em `ThemeTokens`; `render_qss(DARK)` e `render_qss(LIGHT)` não contêm `{{` residual; `DARK` e `LIGHT` têm mesmos fields. |
| 2 | `test_skeletons.py`: `SkeletonCard` renderiza offscreen sem crash; `BasePage.show_skeletons()` popula grid. |
| 3 | `test_dialogs.py`: `PreviewDialog` habilita confirm só se `result.ok`; `ResultDialog` copia p/ clipboard; `ProgressDialog` cancela via runner. |
| 4 | `test_navigation.py`: `Breadcrumb` monta trail; `StatusBar` reflete estado agregado; sidebar tem 3 seções com botões esperados. |
| 5 | `test_platform.py`: `kill_process_group`/`state_dir`/`secure_file`/`admin_bridge` com `monkeypatch` em `sys.platform`; catálogo filtra por OS. |

Smoke test existente (`tests/test_linux_native_ui.py`, `tests/linux-ui.sh`) deve continuar passando após cada fase.

## Acessibilidade (a11y AA)

- Contraste de texto ≥4.5:1 (text sobre bg) validado nos pares dark/light.
- `:focus-visible` já existe; manter em todos os componentes novos.
- `Breadcrumb`, `StatusBar`: cores de `text_dim`/`text_muted` validadas para contraste AA em ambos temas.
- Diálogos: `role=dialog` equivalente (QDialog já acessível via QAccessible); foco trap dentro do diálogo.
- Skeletons: não bloqueiam navegação por teclado (tab skip sobre tiles).

## Fases de implementação

| Fase | Entrega | Arquivos |
|---|---|---|
| 1 | Design tokens + migração QSS + simplifica app.py | `tokens.py`, `theme.qss`, `app.py` |
| 2 | Skeletons | `widgets.py`, `pages/base.py` |
| 3 | Diálogos | `widgets.py`, `main_window.py` |
| 4 | Navegação + feedback | `widgets.py`, `main_window.py` |
| 5 | Portabilidade Windows | `platform.py`, `models.py`, `catalog.py`, `command_runner.py`, `app.py` |

Cada fase é independente e testável. Pode parar/recomeçar entre fases sem deixar o app quebrado.

## Fora do escopo

- Empacotamento Windows (PyInstaller/MSI/winget) — spec futuro.
- Porta da Web UI para Windows — Web UI deprecated/congelada.
- Novas ações Windows-only — catálogo preparado, mas ações não adicionadas neste spec.
- Redesign visual completo (micro-interações, animações elaboradas) — este spec é fundação estrutural, não redesign estético.
- i18n real (chips PT/EN no header são decorativos; não implementados aqui).
