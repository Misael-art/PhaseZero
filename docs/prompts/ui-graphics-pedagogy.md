# Implement: pedagogical graphics dropdown + custom option for Windows VM provision

## Objective
The Windows VM provision UI has a graphics selector that fails users in three ways:

1. **Bug**: the catalog parameter `windows.provision.plan → graphics` is declared as `_p("graphics", "Aceleração gráfica", choices=("compat","virtio-gl"))` WITHOUT `kind="choice"`. `ParameterDialog` (widgets.py:596) only renders a `QComboBox` when `kind == "choice"`; without it, the param falls into the `else` branch and renders as a free-text `QLineEdit`, so the `choices` are ignored. Users see a text box with no dropdown.
2. **No pedagogy**: the dedicated combo on the install card (pages/windows_vm.py:77-81) has two items `compat (QXL, software)` and `virtio-gl (OpenGL, requer GPU host compatível)` but ZERO explanation of what each means, the expected outcome, or the host prerequisites. A non-expert cannot make an informed choice and defaults to `compat` — permanent software rendering. This recreates the "silent lie" pattern the backend was hardened against: the UI lets users pick blindly.
3. **No escape hatch for advanced/experimental**: a power user who wants `virtio-venus` (experimental Vulkan, already implemented in the backend) or to pass a custom profile/extra QEMU args has no path. The combo is fixed at two values.

Fix all three: correct the kind bug, make every choice self-explanatory (tooltip + helper text with expected outcome + prerequisites), and add a "Customizado" entry that reveals an advanced field. Keep the change UI-only — do NOT modify the backend (`provision.sh`, `graphics.sh`); the profiles already exist and are validated by `graphics_preflight`.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch: create `codex/ui-graphics-pedagogy` off current `main`. Push when green.
- Source of truth files (NEVER edit `build/` mirrors):
  - `linux/ui_native/catalog.py`:
    - L124 `def _p(name, label, kind="text", ...)` — `kind` defaults to `"text"`. To get a combo in `ParameterDialog`, must pass `kind="choice"`.
    - L254 `_p("graphics", "Aceleração gráfica", choices=("compat", "virtio-gl"), placeholder="compat")` — the bug: missing `kind="choice"`. Compare to L725 `_p("proxy", "Proxy", "choice", choices=(...))` which works.
    - L253-257 the `windows.provision.plan` action argv: `("--iso", "{input}", "--image-index", "{image_index}", "--graphics", "{graphics}", "--json")`.
  - `linux/ui_native/widgets.py:580-628` — `ParameterDialog`. L596 `if parameter.kind == "choice":` gates combo rendering. This is correct; the bug is in the catalog param declaration, not here.
  - `linux/ui_native/pages/windows_vm.py:72-86` — the dedicated install-card form: `_edition_combo` (line 72) and `_graphics_combo` (line 77-81) with two hardcoded items, no tooltips, no helper text, no custom option. `_request_plan` (248) calls `runner.start(plan, values={...})` directly bypassing `ParameterDialog`.
  - `linux/windows-vm/provision.sh` — backend already accepts `--graphics compat|virtio-gl` (and `graphics_preflight` validates the host). The UI must not invent values the backend rejects; for custom/experimental, the backend's `--graphics <profile>` only accepts `compat|virtio-gl` today (unknown → preflight FAIL). Any "custom" UI value must map to a backend-supported path — see FIX 3 design.
  - `tests/test_windows_vm_ui.py` — 15 existing pytest cases; extend.
- Follow `AGENTS.md`: caveman terse prose in chat; normal prose in code/commits. `rtk` if in PATH else run directly + record `rtk missing`. No passwordless sudo, no secret writes, no proprietary downloads.

## Fixes (do ALL)

### FIX 1 — correct the catalog param `kind` (the dropdown bug)
File: `linux/ui_native/catalog.py:254`.
Change:
```python
_p("graphics", "Aceleração gráfica", choices=("compat", "virtio-gl"), placeholder="compat"),
```
to:
```python
_p("graphics", "Aceleração gráfica", "choice", choices=("compat", "virtio-gl", "virtio-venus", "custom"), placeholder="compat"),
```
- Adds `"choice"` as the kind so `ParameterDialog` renders a combo.
- Adds `"virtio-venus"` (experimental, backend has `graphics.sh plan --profile virtio-venus` returning the honest experimental plan) and `"custom"` (escape hatch — see FIX 3).
- The backend `provision.sh plan` accepts whatever string is passed for `--graphics`; `graphics_preflight` later rejects unknown profiles at validate time with a clear message. So the UI can offer `virtio-venus` and `custom`; the backend will fail loud if they are not yet supported in the provision pipeline. That is acceptable — but prefer mapping them safely (see FIX 3 for custom, and consider gating venus).

### FIX 2 — pedagogical dropdown on the install card with tooltips + helper text
File: `linux/ui_native/pages/windows_vm.py:72-86`.
The dedicated `_graphics_combo` must become an informed selector. Requirements:
1. **Items carry userData + rich tooltips**: each item's tooltip explains (a) what it is, (b) the expected outcome, (c) host prerequisites, (d) when to choose it. Use `setItemData(idx, tooltip_str, Qt.ToolTipRole)` per item, or set the combo's `currentIndexChanged` to update a helper `QLabel` below the combo with the selected option's full explanation.
2. **A helper QLabel below the combo** that updates live when the selection changes (preferred over tooltip-only — always visible, no hover required). Each option's helper text (Portuguese, match the app language):
   - **compat (QXL — renderização por software)**: "Padrão. Funciona em qualquer host. Sem aceleração: Windows roda com 'Microsoft Basic Display Adapter'. Indicado se você não precisa de jogos/vídeo ou se sua GPU não suporta virtio-gl. Resultado: interface funcional mas lenta em 3D."
   - **virtio-gl (OpenGL parcial, virgl)**: "Aceleração OpenGL via virgl. Requer: GPU host com mesa/virglrenderer, `/dev/dri/renderD*` acessível, QEMU com virtio-vga-gl. Resultado: aplicativos OpenGL rodam; Vulkan/Direct3D não. Em Steam Deck (APU VanGogh) é o máximo estável. Se o host não atender, o instalador avisa e você volta para compat."
   - **virtio-venus (experimental — Vulkan)**: "EXPERIMENTAL. Vulkan paravirtual via Venus. Pré-requisitos não fixados (kernel 6.7+, mesa 23+, crosvm). No Steam Deck, é o único caminho de aceleração Vulkan, mas ainda instável. O plano experimental pode ser consultado em 'Plano Venus'. Aplicar fica bloqueado na v1."
   - **custom (avançado)**: revela um campo extra (FIX 3).
3. **Edition combo placeholder**: when no ISO is selected, the `_edition_combo` is disabled and empty. Add a placeholder item "Selecione uma ISO primeiro" so the empty state is self-explanatory. Clear it when an ISO is chosen (the existing `_apply_inspect_result` already clears + repopulates).
4. Sync the dedicated combo with the ParameterDialog path: both must offer the same four choices. Since the dedicated combo bypasses ParameterDialog (`_request_plan` calls `runner.start` directly with `values`), keep the four-item list in the page in sync with the catalog param. (A shared constant in `catalog.py` or a small helper would prevent drift — see FIX 4.)

### FIX 3 — "custom" escape hatch reveals an advanced field
When the user picks "custom" in either the dedicated combo or the ParameterDialog:
- **Dedicated combo (pages/windows_vm.py)**: reveal a `QLineEdit` (initially hidden) below the combo where the user can type a custom graphics profile name or, if you want to support it, extra QEMU args. Label: "Perfil/args customizados:". The value flows into `_selected_graphics` as-is and reaches `--graphics <value>` in the plan command. If the backend rejects it, the existing `graphics_preflight` FAIL message tells the user the profile is unknown — that is the correct, honest behavior.
- **ParameterDialog (widgets.py)**: this is harder because `ParameterDialog` renders fields statically from the action's `parameters`. Two acceptable approaches:
  - (simpler) When `kind == "choice"` and one of the choices is the literal `"custom"`, render an additional `QLineEdit` that is enabled only when "custom" is selected; its value overrides the combo value for that parameter name. This is a generic improvement to `ParameterDialog` that benefits any choice param with a "custom" entry.
  - (alternative) Do not add "custom" to the ParameterDialog choice list — only to the dedicated install-card combo. Document that the install card is the power-user entry point. This keeps `ParameterDialog` simple but means the two entry points diverge.
  Prefer the simpler-approach (generic `ParameterDialog` "custom" support) so both entry points stay consistent.

### FIX 4 — single source of truth for the graphics options
To prevent the catalog param, the dedicated combo, and the helper texts from drifting, define the graphics option list once. Options:
- Add a module-level constant `WINDOWS_VM_GRAPHICS_OPTIONS` in `catalog.py` (a list of `(value, label, helper_text)` tuples) and import it in `pages/windows_vm.py`. The catalog param uses `[v for v, _, _ in WINDOWS_VM_GRAPHICS_OPTIONS]` for `choices`; the page builds the combo from the same list.
- This also makes the helper text maintainable in one place.

## Robustness contract (MANDATORY)
1. **No silent downgrade**: the dedicated combo must honor the user's choice exactly; backend `graphics_preflight` is the sole gatekeeper (P0 policy preserved).
2. **Backend untouched**: do NOT modify `provision.sh`, `graphics.sh`. Unknown profiles fail loud at validate time — that is correct.
3. **Idempotent**: re-selecting the same option, re-opening the page — no stale state.
4. **Helper text from a single source**: avoid duplicating the explanations across catalog + page; use the FIX 4 constant.
5. **Backward compatible**: existing 15 UI pytest cases + 66 provision + 9 audit + windows-vm smoke must still pass.
6. **Locale-safe**: Portuguese helper text, no parsed command output touched.
7. **Testable**: the new combo items, helper text updates, and custom-field reveal MUST be covered by pytest (mock the page, change combo index, assert helper label text + custom field visibility).
8. **No passwordless sudo, no secret writes, no proprietary downloads.**

## Tests (`tests/test_windows_vm_ui.py`)
Extend with cases:
1. **dedicated combo has 4 items**: assert `_graphics_combo` has items for compat, virtio-gl, virtio-venus, custom (by userData).
2. **helper label updates on selection change**: set combo to virtio-gl → helper label contains "OpenGL" and "virgl"; set to compat → contains "software" / "Microsoft Basic Display"; set to virtio-venus → contains "EXPERIMENTAL" and "Vulkan"; set to custom → contains something about advanced/custom.
3. **custom reveals the advanced line edit**: when combo is at custom, the custom `QLineEdit` is visible; when at any other index, it is hidden.
4. **edition combo placeholder when no ISO**: on fresh page, `_edition_combo` has a single placeholder item "Selecione uma ISO primeiro" and is disabled.
5. **catalog param `kind == "choice"`**: load the `windows.provision.plan` action from the catalog, find the `graphics` parameter, assert `parameter.kind == "choice"` and `parameter.choices` contains the 4 values (regression for the original bug).
6. **ParameterDialog renders combo for graphics**: construct a `ParameterDialog` for the `windows.provision.plan` action, assert the graphics field is a `QComboBox` (not `QLineEdit`).
7. **ParameterDialog custom support**: if you implement the generic "custom" support in ParameterDialog, assert that selecting "custom" enables the extra line edit and its value overrides the combo on submit.
8. **plan argv still includes --graphics <choice>**: with the dedicated combo at virtio-gl, `_request_plan` passes `values={"graphics":"virtio-gl",...}` (existing test — keep passing); with custom + text "my-profile", passes `values={"graphics":"my-profile",...}`.

## Execution order
1. Read `AGENTS.md`, `linux/ui_native/catalog.py` (the `_p`/`_a` definitions + the `windows.provision.plan` entry + the graphics options), `linux/ui_native/widgets.py` (`ParameterDialog` + how choices render), `linux/ui_native/pages/windows_vm.py` (the install card form + the dedicated combo + `_request_plan`), and `tests/test_windows_vm_ui.py` (existing style).
2. FIX 4 first: define `WINDOWS_VM_GRAPHICS_OPTIONS` constant (value, label, helper_text) in `catalog.py`.
3. FIX 1: fix the catalog param `kind="choice"` and derive `choices` from the constant.
4. FIX 2: rebuild the dedicated combo from the constant; add the live helper `QLabel`; add the edition-combo placeholder.
5. FIX 3: add "custom" to the constant; reveal/hide the advanced `QLineEdit` in the page; add generic "custom" support in `ParameterDialog`.
6. Tests: add the 8 cases.
7. `python3 -c "import ast; ast.parse(open(f).read())"` on every touched `.py` file.
8. `python3 -m pytest tests/test_windows_vm_ui.py -v` — report exit + tail.
9. `bash tests/test_provision.sh`, `bash tests/linux-windows-vm.sh`, `bash tests/audit-doctor.sh` — confirm no regression.
10. Commit on `codex/ui-graphics-pedagogy` with conventional commits:
    - `fix(ui): graphics plan param kind=choice so ParameterDialog renders a combo`
    - `feat(ui): pedagogical graphics dropdown with helper text + edition placeholder`
    - `feat(ui): custom graphics escape hatch (dedicated combo + ParameterDialog)`
    - `refactor(ui): single source of truth for Windows VM graphics options`
    - `test(ui): graphics dropdown pedagogy + custom + placeholder coverage`
    Push when green.

## Definition of done (assert each in your final report)
- The catalog `windows.provision.plan` graphics parameter has `kind="choice"` (regression-fixed); `ParameterDialog` renders it as a `QComboBox`.
- The dedicated install-card combo offers 4 options (compat, virtio-gl, virtio-venus, custom) sourced from a single constant.
- A live helper `QLabel` below the combo explains each option (outcome + prerequisites) and updates on selection change.
- The edition combo shows "Selecione uma ISO primeiro" when no ISO is chosen.
- Selecting "custom" reveals an advanced `QLineEdit` (page) and enables the override field (ParameterDialog); the typed value flows into `--graphics <value>`.
- All 8 new pytest cases pass; originals (15 UI + 66 provision + 9 audit + windows-vm) still pass.
- `ast.parse` clean on all touched files.
- No passwordless sudo, no secret writes, no proprietary downloads.

## Handoff report format (your final message)
```
## Implementation
- FIX 1 kind bug: catalog.py:<line> — <one line>
- FIX 2 pedagogy + placeholder: pages/windows_vm.py:<line> — <one line>
- FIX 3 custom escape: pages/windows_vm.py:<line> + widgets.py:<line> — <one line>
- FIX 4 single source: catalog.py:<line> — <one line>

## Commits
<git log --oneline of new commits>

## Verification (paste actual output)
- ast.parse on all touched files
- pytest tests/test_windows_vm_ui.py exit + last 25 lines (new cases enumerated)
- bash tests/test_provision.sh / linux-windows-vm.sh / audit-doctor.sh exit codes
- one before/after: catalog graphics param kind was "text", now "choice"
- one before/after: helper label text for compat vs virtio-gl vs venus vs custom

## Skipped / blocked
- (none, or list with reason)

## Notes for validator
- <which custom approach in ParameterDialog; whether venus choice is gated by host capability in the UI (prefer: not gated — let backend preflight fail loud); any Qt limitation>
```

If a step is blocked, record it under "Skipped / blocked" with the reason and continue — do not abort.
