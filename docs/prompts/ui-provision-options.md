# Implement: wire provision graphics/image-index + Venus plan into the Windows VM UI

## Objective
The PhaseZero Windows VM backend is complete and tested (66 provision tests, P0 graphics fix, P1 Venus honest plan). The native UI does NOT expose three of these features, so users cannot reach them:

1. **`--graphics` is unreachable in the provision plan UI** — the catalog action `windows.provision.plan` passes only `--iso`. Even after the P0 fix made `--graphics compat|virtio-gl` effective, every install launched from the UI silently uses QXL (the "lie" P0 fixed in the backend is still alive in the UI).
2. **`--image-index` is unreachable, and the existing `_edition_combo` is a ghost widget** — `pages/windows_vm.py` creates a `QComboBox` "Edição:" and enables it after ISO selection, but never populates it. `media-inspect` already returns `images[]` (per-index name + arch) but the UI discards that data. Multi-index ISOs (Win10/11 Home+Pro) always install index 1.
3. **Venus plan is unreachable** — P1 made `graphics.sh plan --profile virtio-venus` print an honest experimental plan, but the UI only has `plan-gl` and `plan-vfio`. There is no `plan-venus` action; users cannot discover Venus or see its prerequisites/status.

Fix all three. This is a UI-only change — do NOT touch the backend scripts (`provision.sh`, `graphics.sh`, `media-inspect.sh`); they are tested and correct. Work happens in `linux/ui_native/catalog.py`, `linux/ui_native/pages/windows_vm.py`, and the python test `tests/test_windows_vm_ui.py`.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch: create `codex/windows-vm-ui-provision-options` off current `codex/windows-vm-graphics-p1` (HEAD `c4c53a8`). Push when green.
- Source of truth files (NEVER edit `build/` mirrors):
  - `linux/ui_native/catalog.py` — action registry. Each entry is built by `_a(id, group, title, description, argv_tuple, icon, ...)`. Existing entries to mirror:
    - `windows.provision.plan` at ~L251: `("windows-vm", "provision", "plan", "--iso", "{input}", "--json")`, `input_kind="file"`.
    - `windows.graphics.plan-gl` at ~L235: `("windows-vm", "graphics", "plan", "--profile", "virtio-gl", "--json")`, badge `"Seguro"`.
    - `windows.graphics.plan-vfio` at ~L237: passes `--pci-devices "{input}"` with `input_label`/`input_kind`.
    - `windows.media.inspect` at ~L250: `("windows-vm", "media", "inspect", "--iso", "{input}")`, badge `"JSON"`. Returns JSON with `.images[] = [{index, name, arch}, ...]`.
  - `linux/ui_native/pages/windows_vm.py` — 209 lines. `WindowsVMPage(BasePage)`:
    - L72-74: `self._edition_combo = QComboBox()` created, label "Edição:", `setEnabled(False)`.
    - L91-96: provision action IDs enumerated (`windows.provision.plan/start/status/watch/resume/cancel/discard`).
    - L110-130: graphics_box with `graphics.doctor/status/plan-gl/test-gl/plan-vfio/compat/runtime-*/guest-guide`.
    - L153: media-inspect action referenced.
    - L185-199: `_select_iso()` opens FileDialog, sets `self._selected_iso`, enables + clears `_edition_combo`, fires `windows.media.inspect` action.
    - L201-205: `_request_plan()` calls `request_action(plan)` — does NOT read `_edition_combo` or any graphics selector.
    - L208-209: `block_while_running`.
  - `tests/test_windows_vm_ui.py` — 3 existing pytest cases (`test_windows_vm_page_covers_graphics_management_and_uses_doctor`, `test_windows_vm_page_has_install_card`, `test_windows_vm_page_covers_provision_actions`). Extend, do not rewrite. The existing pattern (likely `QTest.qapp + instantiate page + introspect`) is the template.
- Shared UI helpers: read `linux/ui_native/catalog.py` for the `parameters=(_p(name, label, placeholder=...),)` and `input_label`/`input_kind`/`preview`/`preview_bindings` conventions BEFORE adding new actions, so the new entries match.
- Follow `AGENTS.md`: caveman terse prose in chat; normal prose in code/commits/PRs. `rtk` if in PATH else run directly + record `rtk missing`. No passwordless sudo, no secret writes, no proprietary downloads.

## Fixes (do ALL three)

### FIX 1 — Graphics selector in the provision plan UI
Goal: user picks `compat` or `virtio-gl` when planning an install; the plan command receives `--graphics <choice>`.

Implementation choice (pick whichever matches the catalog/page conventions; prefer the minimal-surprise one):
- Add a `QComboBox` "Aceleração:" to the page form next to "Edição:", with items `compat (QXL, software)` and `virtio-gl (OpenGL)`, default `compat`. Track the selected value in `self._selected_graphics` (default `"compat"`).
- Modify the `windows.provision.plan` catalog entry argv to include `--graphics`, sourced from a parameter or binding. Two acceptable shapes:
  - (preferred) Add `parameters=(_p("graphics", "Aceleração gráfica", placeholder="compat", default="compat"),)` and extend argv to `("--iso", "{input}", "--graphics", "{graphics}", "--json")`. Then the page wires its combo selection into the parameter before `request_action`.
  - OR keep the action static and have the page build the argv at request time (only if the catalog/page framework does not support dynamic params cleanly — confirm by reading how `windows.provision.start` uses `preview_bindings` for `{plan_id}`/`{confirm}`).
- The selected graphics value MUST reach the plan command; verify by running `pz windows-vm provision plan --iso <fake> --graphics virtio-gl --json | jq .graphics` returns `virtio-gl` (the backend already supports it).

UX rule: the combo must NOT silently fall back to `compat` if the user picks `virtio-gl` — the choice is honored as-is. The backend `graphics_preflight` will fail loud at `run_validate` if the host cannot deliver; that is the correct behavior. Do NOT add host-capability gating in the UI combo itself (that would re-create the silent-downgrade anti-pattern). Just label the options honestly: `"compat (QXL, software)"` and `"virtio-gl (OpenGL, requer GPU host compatível)"`.

### FIX 2 — Populate the edition combo from media-inspect + pass `--image-index`
Goal: after ISO selection, the `_edition_combo` is filled with the available Windows image indexes from `media-inspect`, and the chosen index is passed to the plan command.

Steps:
1. Read the `windows.media.inspect` JSON output schema. It returns an `images` array (each item has at minimum `index` and `name`; possibly `arch`). Confirm the exact field names by reading `linux/windows-vm/media-inspect.sh` (read-only) and any existing test fixture in `tests/test_provision.sh` that exercises `parse_wim_images`.
2. In `pages/windows_vm.py`, capture the result of the media-inspect action and populate `_edition_combo`:
   - Add a handler/subscription so when `windows.media.inspect` returns JSON, the page parses `.images[]` and calls `_edition_combo.addItem(f"{index}: {name}", userData=index)` for each. Store the per-item index in `userData` (Qt standard) so retrieval is unambiguous.
   - If `images` is empty or the inspect fails (non-Windows ISO), clear the combo and add a single placeholder item `"1: Padrão"` with userData `1`, then proceed with default index 1.
   - Default selection: index 1 (or the first entry).
3. Track the selected index in `self._selected_image_index` (default `1`). Update it when the combo `currentIndexChanged` fires.
4. Modify the `windows.provision.plan` catalog argv to include `--image-index`. Combined with FIX 1, the final argv becomes roughly `("--iso", "{input}", "--image-index", "{image_index}", "--graphics", "{graphics}", "--json")` (parameter names per the catalog framework conventions you confirmed).
5. `_request_plan()` must read BOTH `self._selected_graphics` and `self._selected_image_index` and pass them into the action invocation. The page wiring pattern is the same as how `windows.provision.start` reads `{plan_id}`/`{confirm}` from preview bindings — mirror it.

Edge cases:
- ISO with a single image: combo shows `"1: <name>"`, index 1 passed (equivalent to today).
- ISO inspect fails (garbage ISO): combo shows `"1: Padrão"`, index 1 passed, and the plan command itself will fail at validation (correct — the backend `run_validate` already rejects bad ISOs).
- ISO swapped after first selection: re-run media-inspect, repopulate combo, reset index to 1.

### FIX 3 — Add Venus plan action to the UI
Goal: surface `graphics.sh plan --profile virtio-venus` so users can discover Venus, see its experimental status, and read the prerequisites/Deck-VFIO note.

Steps:
1. Add to `linux/ui_native/catalog.py` (next to `windows.graphics.plan-gl` and `windows.graphics.plan-vfio`):
   ```
   _a("windows.graphics.plan-venus", "Windows VM", "Plano Venus (experimental)",
      "Plano experimental Vulkan paravirtual; mostra pré-requisitos e limites no Steam Deck.",
      ("windows-vm", "graphics", "plan", "--profile", "virtio-venus", "--json"),
      "video-display", badge="Seguro")
   ```
   Adjust wording to match the existing entries' style. Badge `"Seguro"` because plan is read-only.
2. In `linux/ui_native/pages/windows_vm.py`, add `"windows.graphics.plan-venus"` to the `graphics_box` action ID tuple (between `plan-gl` and `plan-vfio`, or after `plan-vfio` — match the existing visual order).
3. No special handler needed — the existing `_action_row(action)` loop will render it like the other plan actions. The JSON output (now honest, from P1) shows in whatever output viewer the page uses for `badge="JSON"`/`badge="Seguro"` actions.

## Robustness contract (MANDATORY)
1. **Backend untouched**: do NOT modify `provision.sh`, `graphics.sh`, `media-inspect.sh`, `doctor.sh`. The 66 backend tests are the regression guard.
2. **No silent downgrade**: the graphics combo must honor the user's choice as-is; backend preflight is the sole gatekeeper.
3. **Idempotent**: re-opening the page, re-selecting the same ISO, re-running plan — all safe, no stale state.
4. **Combo populated only from inspect data**: never hardcode editions. Single-image ISO → single combo item.
5. **Locale-safe**: combo items derived from inspect JSON `name` field verbatim (no translation).
6. **Testable**: the new behavior MUST be covered by pytest cases that do not require a real ISO/QEMU — use the existing fixture style (mock catalog JSON, fake inspect output).
7. **Backward compatible**: existing 3 pytest cases + 66 backend shell tests + windows-vm smoke + audit-doctor must still pass.
8. **No passwordless sudo, no secret writes, no proprietary downloads.**

## Tests (`tests/test_windows_vm_ui.py`)
Extend with cases (use the existing fixture/mock pattern in the file):
1. **graphics combo exists with both options**: instantiate the page, assert the graphics combo has items containing `compat` and `virtio-gl`, default selection is `compat`.
2. **plan argv includes --graphics**: with graphics set to `virtio-gl`, the constructed plan argv (or the parameter bound to the action) includes `--graphics virtio-gl`. With default selection, includes `--graphics compat`.
3. **edition combo populates from inspect JSON**: feed a fake inspect result `{"images":[{"index":1,"name":"Windows 11 Pro"},{"index":2,"name":"Windows 11 Home"}]}` through whatever input channel the page subscribes to; assert `_edition_combo` has 2 items with the right names and the userData indices 1 and 2.
4. **plan argv includes --image-index**: with the combo set to the second entry, the constructed plan argv includes `--image-index 2`.
5. **single-image ISO fallback**: feed `{"images":[{"index":1,"name":"Windows 11 Pro"}]}` → combo has 1 item, index 1 passed.
6. **inspect failure fallback**: feed empty/error inspect → combo has placeholder `"1: Padrão"`, index 1 passed.
7. **Venus plan action present**: the page's graphics_box action IDs include `"windows.graphics.plan-venus"`.
8. **Venus plan catalog entry correct**: load `catalog.py` actions and assert `windows.graphics.plan-venus` resolves to argv starting with `windows-vm graphics plan --profile virtio-venus`.

If the page does not currently expose a hook for tests to inject inspect JSON, add a small test-only method (e.g. `_apply_inspect_result(json_dict)`) that the production code path also calls — clean separation, no test-only branches in production logic.

## Execution order
1. Read `AGENTS.md`, `linux/ui_native/catalog.py` (full, focus on `_a`/`_p` definitions and the windows.* entries around L233-L257), `linux/ui_native/pages/windows_vm.py` (full), `tests/test_windows_vm_ui.py` (full), and skim `linux/windows-vm/media-inspect.sh` to confirm the `images[]` field names.
2. FIX 3 (Venus plan action) first — smallest, no state; validates the catalog+page render flow.
3. FIX 1 (graphics combo + plan argv) — adds the combo and the binding.
4. FIX 2 (edition combo populated + `--image-index`) — larger; depends on the inspect-result plumbing.
5. Tests for all three.
6. `python3 -m pytest tests/test_windows_vm_ui.py -v` — report exit + tail.
7. `bash tests/test_provision.sh`, `bash tests/linux-windows-vm.sh`, `bash tests/audit-doctor.sh` — confirm no regression (backend untouched, but run anyway).
8. `python3 -c "import ast; ast.parse(open('linux/ui_native/catalog.py').read()); ast.parse(open('linux/ui_native/pages/windows_vm.py').read())"` — python syntax check on both touched files.
9. Commit on `codex/windows-vm-ui-provision-options` with conventional commits:
   - `feat(ui): surface Venus experimental graphics plan in Windows VM page`
   - `feat(ui): graphics profile selector in provision plan (compat/virtio-gl)`
   - `feat(ui): populate edition combo from media-inspect and pass --image-index`
   - `test(ui): cover provision plan graphics + image-index + venus action`
   Push when green.

## Definition of done (assert each in your final report)
- The provision plan UI has a graphics combo (`compat`/`virtio-gl`) and the choice reaches the plan command as `--graphics <choice>` (proven by test).
- The provision plan UI has the edition combo populated from `media-inspect`'s `images[]`; the chosen index reaches the plan command as `--image-index <n>` (proven by tests for 2-image, 1-image, and inspect-failure cases).
- The graphics box in the UI includes a `plan-venus` action that runs `graphics plan --profile virtio-venus --json`.
- `_edition_combo` is no longer a ghost widget — it reflects real inspect data or a documented fallback.
- All 8 new pytest cases pass; the original 3 still pass (11 total).
- Backend tests unaffected: `tests/test_provision.sh` (66), `tests/linux-windows-vm.sh`, `tests/audit-doctor.sh` all still green.
- `python3 -c ast.parse` clean on both touched UI files.
- No passwordless sudo, no secret writes, no proprietary downloads.

## Handoff report format (your final message)
```
## Implementation
- FIX 1 graphics selector: pages/windows_vm.py:<line> + catalog.py:<line> — <one line>
- FIX 2 edition combo: pages/windows_vm.py:<line> + catalog.py:<line> — <one line>
- FIX 3 Venus action: catalog.py:<line> + pages/windows_vm.py:<line> — <one line>
- inspect-result plumbing: pages/windows_vm.py:<line> — <one line>

## Commits
<git log --oneline of new commits>

## Verification (paste actual output)
- pytest tests/test_windows_vm_ui.py exit code + last 25 lines (8 new + 3 original)
- bash tests/test_provision.sh exit code + tail
- bash tests/linux-windows-vm.sh exit code
- bash tests/audit-doctor.sh exit code
- python3 ast.parse on both UI files
- one screenshot-or-stdout of: graphics combo options, edition combo populated from fake 2-image inspect, plan argv with --graphics virtio-gl --image-index 2

## Skipped / blocked
- (none, or list with reason)

## Notes for validator
- <which catalog binding pattern you used (parameters vs preview_bindings); how inspect JSON reaches the combo; any test-only hook added>
```

If a step is blocked (e.g. the catalog framework cannot express the dynamic argv), record it under "Skipped / blocked" with the reason and continue with the rest — do not abort.
