# Fix: doctor non-zero exit should not be classified as "Operação falhou"

## Objective
When the user runs `system.doctor` from the UI and the host has any check FAIL (e.g. CPU 95°C thermal — a genuine diagnostic finding, not a crash), `doctor.sh` returns exit code 1 by design (`finish()` at `linux/audit/doctor.sh:36`: `[ "$FAIL" -eq 0 ] && [ "$ERROR" -eq 0 ]`). The UI treats this as an operation failure: `result_parser.py:severity_for` returns `"error"` for ANY non-zero exit code, so `ResultDialog` opens with title "Operação falhou", red icon, and `result.ok == false`. The user sees a scary error popup for what is actually a successful diagnostic that found a problem — the exact opposite of a doctor's purpose.

This is a semantic classification bug in the UI, not in the backend. The doctor did its job: it produced a 150-check report with actionable FAILs. The UI must distinguish "diagnostic command ran and reported findings" from "command crashed or failed to apply a mutation."

Fix the UI classification so:
- Diagnostic/read-only actions (`doctor`, `status`, `inspect`, `discover`, `plan`) with non-zero exit that still produced valid output → classified as `warning` ("Concluído com avisos"), NOT `error`.
- Mutable actions (`install`, `apply`, `provision`, `cancel`, `remove`) with non-zero exit → stays `error` ("Operação falhou") — a real failure to apply.
- Exit code 0 → `success` (unchanged).
- Engine failures (Python exception, timeout, missing binary, empty/no output) → stays `error`.

This is a UI-only change. Do NOT modify `doctor.sh` exit codes — non-zero-on-FAIL is the correct contract for a diagnostic (CI/automation gates on it). The fix lives in `result_parser.py` + how `ResultDialog`/toast render the `warning` severity.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch: create `codex/ui-doctor-severity-fix` off current `main` (HEAD has v1.11.1). Push when green.
- Source of truth files (NEVER edit `build/` mirrors):
  - `linux/ui_native/result_parser.py` — `severity_for(value, exit_code)` at L34. Currently: `if exit_code != 0: return "error"` is the FIRST check, short-circuiting everything. This is the bug.
  - `linux/ui_native/main_window.py` — consumes `severity_for` at L550 to set `status_dot` objectName (`statusSuccess`/`statusWarning`/`statusError`). Already tri-state aware. Also L548 status text ("Concluído" if `result.ok` else "Falhou") — hardcoded to `result.ok`, ignores severity. L595 toast verb ("concluída"/"falhou") — same issue. L600 `if result.ok` action-queue advance — keep gating on exit code (diagnostic non-zero should not auto-advance a queue).
  - `linux/ui_native/widgets.py:969-973` — `ResultDialog.__init__` title/icon: `"Operação concluída" if result.ok else "Operação falhou"`, `"success" if result.ok else "error"`. Ignores severity — always error when exit≠0.
  - `linux/ui_native/models.py` — `OperationResult.ok` is `@property exit_code == 0` (L118). Do NOT change `ok` semantics (automation/CI depend on it); add a NEW `severity` property or compute at call sites.
  - `linux/ui_native/catalog.py` — `ActionSpec` has `badge` (e.g. "JSON", "Seguro"), `mutable` (bool), `risk` fields. Read-only diagnostic actions: `mutable=False`, badge in {"JSON","Seguro"} or no badge. Mutable actions: `mutable=True`. This is the signal to distinguish.
  - `tests/test_windows_vm_ui.py` — existing pytest cases; extend.
- Follow `AGENTS.md`: caveman terse prose in chat; normal prose in code/commits. `rtk` if in PATH else run directly + record `rtk missing`. No passwordless sudo, no secret writes, no proprietary downloads.

## Fixes (do ALL)

### FIX 1 — `severity_for` must consider output validity + action mutability, not just exit code
File: `linux/ui_native/result_parser.py`.
Current L34-49:
```python
def severity_for(value: Any, exit_code: int) -> str:
    if exit_code != 0:
        return "error"
    if not isinstance(value, dict):
        return "success"
    ...
```
The `if exit_code != 0` first-line kills all nuance.

Rewrite `severity_for` to take the action spec (or a boolean `is_diagnostic`) as input and distinguish "non-zero exit with valid output" from "non-zero exit with no/invalid output":

New signature (preferred): `def severity_for(value: Any, exit_code: int, *, mutable: bool = True, has_output: bool | None = None) -> str`
- `mutable=True` (default, preserves existing behavior for install/apply/provision): exit≠0 → `"error"`.
- `mutable=False` (diagnostic/read-only: doctor, status, inspect, discover, plan):
  - exit==0 → `"success"` (unchanged).
  - exit!=0 AND valid structured output present (dict with content, OR a non-empty list of checks/results) → `"warning"` (the diagnostic ran and reported findings).
  - exit!=0 AND no/invalid output (engine crash, timeout, missing binary, JSON parse failure, empty stdout) → `"error"` (the diagnostic itself broke).
- Keep the existing `status` field checks (failed/error/blocked → error; warn/degraded → warning) for the exit==0 path — they remain the source of truth when a command returns 0 but embeds a status field.
- `has_output` lets the caller pass an explicit signal; if `None`, infer from `value` (dict with keys, or non-empty list/string).

### FIX 2 — Pass `mutable` (and the action spec) into `severity_for` at call sites
File: `linux/ui_native/main_window.py` L550.
Current: `severity = severity_for(result.parsed, result.exit_code)`.
Change to pass the pending action's `mutable` flag:
```python
action = self.pending_action
is_diagnostic = action is not None and not action.mutable
severity = severity_for(result.parsed, result.exit_code, mutable=bool(action and action.mutable))
```
The pending action is available at this point in the code (used at L588 `self.pending_action.title`). Use it.

### FIX 3 — `ResultDialog` must render the `warning` severity (yellow), not force error
File: `linux/ui_native/widgets.py:969-973`.
Currently the dialog hardcodes `success`/`error` from `result.ok`. The `ResultDialog` constructor needs the severity. Two acceptable shapes:
- (preferred) Compute severity in `main_window.py` BEFORE constructing `ResultDialog` and pass it as a new parameter: `ResultDialog(result, formatted, severity=severity, parent=self)`. Title/icon map: `success` → "Operação concluída"/"success"; `warning` → "Concluído com avisos"/"warning"; `error` → "Operação falhou"/"error". The `StatefulDialog` base already accepts a `tone`/state — verify by reading its `__init__`; "warning" must be a supported tone (if not, add it to the tone→stylesheet mapping in widgets.py).
- (alternative) Move the severity computation INTO `ResultDialog` from the result + a passed `mutable` flag. Less clean — duplicate logic. Prefer the explicit-pass shape.

Keep the exit-code-based `result.ok` field unchanged (automation contract). Only the visual classification (title, icon, dot, toast) shifts to severity-driven.

### FIX 4 — Toast + status text + dot consistency in main_window.py
- L548 `self.status_text.setText("Concluído" if result.ok else "Falhou")` → drive off severity: `"Concluído"` (success), `"Concluído com avisos"` (warning), `"Falhou"` (error). Keep it short.
- L551 status_dot already uses severity — confirm `statusWarning` objectName has a stylesheet (yellow dot). If missing, add the QSS rule mirroring `statusSuccess`/`statusError`.
- L594-595 toast: `toast_state` already maps severity → state. `verb` currently `"concluída" if result.ok else "falhou"` → `{"success":"concluída", "warning":"concluída com avisos", "error":"falhou"}[severity]`.
- L600 `if result.ok and self._action_queue:` — KEEP gating on `result.ok` (exit code), NOT severity. A diagnostic with warnings must NOT auto-advance a queued mutation. Only exit==0 advances. This is the one place where the raw exit-code contract is the right signal.

### FIX 5 — `OperationResult.severity` convenience (optional but recommended)
File: `linux/ui_native/models.py`.
Add a `severity` property on `OperationResult` that defaults to `success if exit_code==0 else error` (preserving the simple contract). Callers that know the action mutability override via the `severity_for(...)` call. This keeps `ok` (bool, automation-facing) separate from `severity` (tri-state, UI-facing). Do NOT remove `ok`.

## Tests (`tests/test_windows_vm_ui.py` or new `tests/test_result_severity.py`)
Cases:
1. **diagnostic non-zero exit with valid output → warning**: `severity_for({"status":"ok","checks":[...]}, exit_code=1, mutable=False)` → `"warning"`.
2. **diagnostic non-zero exit with NO output → error**: `severity_for(None, exit_code=1, mutable=False)` → `"error"`. Also `severity_for({}, exit_code=1, mutable=False)` → `"error"` (empty dict = no real output).
3. **mutable non-zero exit → error (unchanged)**: `severity_for({"k":1}, exit_code=1, mutable=True)` → `"error"`.
4. **exit 0 → success (unchanged)**: `severity_for({"x":1}, exit_code=0, mutable=False)` → `"success"`; same for `mutable=True`.
5. **status field still respected on exit 0**: `severity_for({"status":"degraded"}, exit_code=0, mutable=True)` → `"warning"`; `{"status":"failed"}` → `"error"` (existing behavior preserved).
6. **doctor real-world fixture**: load the actual result JSON from `/home/misael/.local/state/phasezero/control-center/results/20260727-235657-040957-system.doctor.json` (or a small in-repo fixture capturing the shape: array of check strings with at least one `[FAIL]`), feed its parsed form to `severity_for` with `mutable=False`, assert `"warning"` — NOT `"error"`. This is the regression guard for the reported bug.
7. **ResultDialog renders warning tone**: construct a `ResultDialog` with a result whose severity is `warning`, assert the title is `"Concluído com avisos"` (or the agreed warning title) and the tone/style key is the warning one — NOT "Operação falhou"/error.
8. **mutable install failure stays error**: simulate a `provision start` result with exit_code=1, assert the dialog title is `"Operação falhou"` (no regression for real failures).

If the existing test file cannot easily construct `ResultDialog` without a full Qt session, write a focused unit test on `severity_for` (pure function, no Qt) plus a smoke test that the `widgets.py` tone mapping accepts `"warning"`.

## Robustness contract (MANDATORY)
1. **Do NOT change `OperationResult.ok`** — automation/CI gate on `exit_code == 0`. Add `severity` alongside, do not replace.
2. **Do NOT change `doctor.sh` exit codes** — non-zero-on-FAIL is the correct diagnostic contract.
3. **Action-queue advance stays exit-code-gated** (L600) — only exit==0 auto-advances queued mutations. A diagnostic warning must never trigger an install.
4. **Mutable actions unchanged**: install/apply/provision/cancel/remove with exit≠0 → still `error`/`Operação falhou`. No regression for real failures.
5. **No silent downgrade**: a non-zero exit that produced NO output is still `error` (engine crash, timeout, missing binary) — do not classify as warning.
6. **Backward compatible**: existing 15 pytest cases + 66 provision + 9 audit + windows-vm smoke must still pass.
7. **Locale-safe**: no parsed command output touched.
8. **No passwordless sudo, no secret writes, no proprietary downloads.**

## Execution order
1. Read `AGENTS.md`, `linux/ui_native/result_parser.py` (full — small file), `linux/ui_native/widgets.py` (the `ResultDialog` + `StatefulDialog` classes + the tone/stylesheet mapping), `linux/ui_native/main_window.py` L540-610, `linux/ui_native/models.py` (`OperationResult` + the badge→state mapping), and the existing `tests/test_windows_vm_ui.py` style.
2. FIX 1: rewrite `severity_for` with the `mutable` kwarg + output-validity logic.
3. FIX 5 (optional): add `OperationResult.severity` property.
4. FIX 2: pass `mutable` from `pending_action` at the `severity_for` call site in main_window.py.
5. FIX 3: thread severity into `ResultDialog`; add "warning" tone if missing.
6. FIX 4: status text, toast verb, dot consistency (verify `statusWarning` QSS exists).
7. FIX tests: add the 8 cases (focus on `severity_for` as pure function + one ResultDialog smoke).
8. `python3 -c "import ast; ast.parse(open('linux/ui_native/result_parser.py').read()); ast.parse(open('linux/ui_native/main_window.py').read()); ast.parse(open('linux/ui_native/widgets.py').read()); ast.parse(open('linux/ui_native/models.py').read())"` — syntax check.
9. `python3 -m pytest tests/test_windows_vm_ui.py -v` — report exit + tail (originals + new cases).
10. `bash tests/test_provision.sh`, `bash tests/linux-windows-vm.sh`, `bash tests/audit-doctor.sh` — confirm no regression.
11. Commit on `codex/ui-doctor-severity-fix` with conventional commits:
    - `fix(ui): classify diagnostic non-zero exits as warning, not error`
    - `feat(ui): warning tone in ResultDialog + status text + toast`
    - `test(ui): severity_for coverage for diagnostic vs mutable actions`
    Push when green.

## Definition of done (assert each in your final report)
- `severity_for` takes `mutable` kwarg; diagnostic (mutable=False) + non-zero exit + valid output → `"warning"`; same + no output → `"error"`; mutable + non-zero → `"error"` (unchanged); exit 0 → `"success"` (unchanged).
- `main_window.py` passes `pending_action.mutable` into `severity_for`.
- `ResultDialog` renders the `warning` tone (title "Concluído com avisos" or agreed wording, yellow icon/dot), driven by the passed severity.
- Status text, toast verb, and status dot are all severity-driven and consistent.
- Action-queue advance (L600) still gates on `result.ok` (exit code), NOT severity.
- `OperationResult.ok` unchanged (still `exit_code == 0`); `severity` added if FIX 5 done.
- All 8 new test cases pass; originals (15 UI + 66 provision + 9 audit + windows-vm) still pass.
- `ast.parse` clean on all 4 touched files.
- No passwordless sudo, no secret writes, no proprietary downloads.

## Handoff report format (your final message)
```
## Implementation
- FIX 1 severity_for: result_parser.py:<line> — <one line>
- FIX 2 call site: main_window.py:<line> — <one line>
- FIX 3 ResultDialog: widgets.py:<line> — <one line> (+ tone mapping if added)
- FIX 4 status/toast/dot: main_window.py:<line> — <one line>
- FIX 5 OperationResult.severity: models.py:<line> — <one line or "skipped">

## Commits
<git log --oneline of new commits>

## Verification (paste actual output)
- ast.parse on 4 files
- pytest tests/test_windows_vm_ui.py exit + last 25 lines (new cases enumerated)
- bash tests/test_provision.sh / linux-windows-vm.sh / audit-doctor.sh exit codes
- one before/after: severity_for(doctor_result, exit=1, mutable=False) was "error", now "warning"
- one before/after: severity_for(install_result, exit=1, mutable=True) stays "error"

## Skipped / blocked
- (none, or list with reason)

## Notes for validator
- <which warning title wording chosen; whether statusWarning QSS already existed; whether FIX 5 was done; any Qt session limitation in tests>
```

If a step is blocked (e.g. `StatefulDialog` tone mapping needs deeper refactor), record it under "Skipped / blocked" with the reason and continue with the rest — do not abort.
