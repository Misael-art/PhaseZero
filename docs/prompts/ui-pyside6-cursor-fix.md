# Fix: PySide6 6.11 QTextCursor API break + clear self-update shadow paths

## Objective
The PhaseZero native UI crashes on launch with:
```
AttributeError: 'PySide6.QtGui.QTextCursor' object has no attribute 'End'
```
at `linux/ui_native/main_window.py:519` (`cursor.movePosition(cursor.End)`). PySide6 6.11+ scopes enums — instance-attribute access (`cursor.End`) is gone; the correct form is `QTextCursor.MoveOperation.End` (enum-class access).

Two compounding problems keep the bug alive even after the v1.11.0 pacman reinstall:
1. The repo source still has the bug (so v1.11.0 carries it too — reinstall alone won't fix).
2. Self-update shadow paths make the pacman install irrelevant on this host:
   - `~/.local/share/applications/io.phasezero.ControlCenter.desktop` (user override) → `Exec=/home/misael/.local/bin/phasezero-control-center`
   - `~/.local/bin/phasezero-control-center` resolves its own `dirname/$SELF/../..` = `~/.local/` FIRST, so it finds `~/.local/share/phasezero/releases/1.10.0/linux/ui/native.sh` before ever reaching `/usr/lib/phasezero`.
   - Result: the menu/icon always launches the stale 1.10.0 self-update copy, never the pacman-installed v1.11.0.

Fix BOTH: the API bug in source (+ audit for similar patterns), and the shadow paths on the host so the pacman install is the one that actually runs.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch: create `codex/ui-pyside6-cursor-fix` off current `main` (HEAD `380bb71`). Push when green.
- Source of truth files (NEVER edit `build/` mirrors):
  - `linux/ui_native/main_window.py:519` — the bug: `cursor.movePosition(cursor.End)`.
  - `linux/ui_native/app.py`, `linux/ui_native/widgets.py`, `linux/ui_native/pages/*.py` — UI files to audit for the same pattern.
  - `tests/test_windows_vm_ui.py` — 11 existing pytest cases; extend.
- Host install paths (this Steam Deck, do NOT edit from the repo commit — handle via a separate install step at the end):
  - Pacman install (correct, v1.11.0): `/usr/lib/phasezero/`.
  - Self-update shadow (WRONG, v1.10.0): `~/.local/share/phasezero/releases/1.10.0/`.
  - User bin shadow: `~/.local/bin/phasezero-control-center`.
  - User desktop override: `~/.local/share/applications/io.phasezero.ControlCenter.desktop`.
  - System desktop (pacman, correct): `/usr/share/applications/io.phasezero.ControlCenter.desktop`.
- Follow `AGENTS.md`: caveman terse prose in chat; normal prose in code/commits. `rtk` if in PATH else run directly + record `rtk missing`. `bigsudo`/`phasezero-admin` for root; NEVER passwordless sudo, NEVER store passwords. No proprietary downloads.
- PySide6 on host: 6.11.1, Qt 6.11.1.

## Fixes (do ALL)

### FIX 1 — correct the QTextCursor enum access (the crash)
File: `linux/ui_native/main_window.py:519`.
- BEFORE: `cursor.movePosition(cursor.End)`
- AFTER: `cursor.movePosition(QTextCursor.MoveOperation.End)` — using the enum class `QTextCursor` (already imported at top of file from `PySide6.QtGui`); `MoveOperation` is the scoped enum, `End` the member.
- If `QTextCursor` is not imported in `main_window.py`, add it to the existing `from PySide6.QtGui import (...)` block (or a new import line). Do NOT introduce a wildcard import.
- Verify the fix smoke-runs under PySide6 6.11: instantiate a `QTextEdit`, get its cursor, call `cursor.movePosition(QTextCursor.MoveOperation.End)` — must not raise. Add this as a pytest case (use `QTest.qapp` fixture pattern from the existing tests).

### FIX 2 — audit all UI files for the same enum-instance pattern
Grep across `linux/ui_native/` for access to PySide6 enum members via an instance variable rather than the class. Patterns to find and fix:
- `<instance>.End`, `<instance>.Start`, `<instance>.KeepAnchor`, `<instance>.MoveAnchor`, `<instance>.Word`, `<instance>.Line`, `<instance>.Block`, `<instance>.Next`, `<instance>.Previous` — on cursor/undo/clipboard objects.
- Also check `Qt.<X>` and `QPalette.<X>` usages: in PySide6 6.11 these are scoped (`Qt.ItemDataRole.DisplayRole`, `Qt.GUI.QPalette.ColorRole.Text`) but class-qualified access like `Qt.TextSelectableByMouse` and `QPalette.Text` still works WITH a deprecation warning in most 6.x releases. They are NOT crashing today, so DO NOT mass-rewrite them — only convert if a smoke test under 6.11 actually errors. Document the audit result in the commit message (audited N usages, M converted, N-M kept as still-valid class access).
- Goal: NO `AttributeError` from any enum access when the app starts and exercises the common paths (doctor, status, plan). Add a smoke test that constructs the `WindowsVMPage` (already covered) AND the `MainWindow` if feasible, and asserts no enum-related exception fires on init + a simulated `append_output` call.

### FIX 3 — add regression tests
File: `tests/test_windows_vm_ui.py` (extend) or `tests/test_ui_pyside6_enums.py` (new, if cleaner).
Cases:
1. **QTextCursor End access compiles and runs**: with `QTest.qapp`, build a `QTextEdit`, `cursor = te.textCursor()`, then `cursor.movePosition(QTextCursor.MoveOperation.End)` — no exception. (Reproduces the original crash; must pass after fix.)
2. **MainWindow init smoke** (if the existing test pattern can construct it cheaply): construct `MainWindow`, assert it does not raise on init. If MainWindow construction needs a full runner/catalog fixture already present in the test file, use it; otherwise skip-with-reason rather than building heavy fixtures.
3. **append_output path**: call `main_window.append_output("hello\n", False)` (or the equivalent method on whichever class owns line 519) and assert it does not raise `AttributeError`. This is the exact path that crashed.
4. **Static audit assertion**: import every module under `linux/ui_native/` and assert no `AttributeError` at import time (catches enum access at module level). Cheap and broad.

If MainWindow is too heavy to construct in tests without a real Qt event loop, write a focused unit test that imports the module, locates the `append_output` function, and exercises the cursor logic on a standalone `QTextEdit` — mirroring the production code path without instantiating the whole window.

### FIX 4 — clear the host shadow paths (install step, separate from the source commit)
After the source fix is committed and tagged, clear the shadow paths on THIS host so the pacman install is the one the menu launches. This is a HOST action, not a repo edit — record it in the handoff report, do NOT commit deletions of files outside the repo.
1. Confirm what's there: `ls -la ~/.local/share/phasezero/releases/ ~/.local/bin/phasezero-control-center ~/.local/share/applications/io.phasezero.ControlCenter.desktop`.
2. Remove the self-update shadow:
   - `rm -rf ~/.local/share/phasezero/releases/1.10.0` (the stale pre-fix release; the dir may hold other versions — only remove `1.10.0`; if the dir becomes empty, remove it too).
   - `rm -f ~/.local/bin/phasezero-control-center` (let `/usr/bin/phasezero-control-center` from pacman take over).
   - `rm -f ~/.local/share/applications/io.phasezero.ControlCenter.desktop` (let `/usr/share/applications/io.phasezero.ControlCenter.desktop` from pacman take over).
3. Verify resolution: `which phasezero-control-center` → must be `/usr/bin/phasezero-control-center`. `gtk-launch io.phasezero.ControlCenter` stderr must NOT contain `AttributeError` and the path in any traceback (if any) must be `/usr/lib/phasezero/...`, not `~/.local/share/phasezero/releases/...`.
4. Reinstall the pacman pkg so the just-fixed code lands at `/usr/lib/phasezero/`:
   - Rebuild the arch pkg from the fixed source (off the new tag, see FIX 5) into `/tmp/pz-dist`.
   - `bigsudo pacman -U --noconfirm /tmp/pz-dist/phasezero-control-center-<new-version>-1-any.pkg.tar`.
5. Final launch smoke: `gtk-launch io.phasezero.ControlCenter` (or `timeout 5 phasezero-control-center`) — must run without the cursor `AttributeError`, and must load from `/usr/lib/phasezero/`.

### FIX 5 — version bump + tag (so the rebuild ships the fix)
Bump `version.json` to `1.11.1` (patch release for the crash fix):
- `"version": "1.11.1"`, `"commit": "release-v1.11.1"`, `"builtAt": "<UTC ISO now>"`.
- Commit `release: v1.11.1` on `main`.
- Tag `v1.11.1`.
- Push main + tag (LFS bypass: `git -c core.hookspath=/dev/null push ...`).

## Robustness contract (MANDATORY)
1. **Minimal source change**: only the enum access pattern + tests. Do NOT refactor unrelated UI code.
2. **Backward compatible**: the new `QTextCursor.MoveOperation.End` form works on PySide6 >= 6.4 (scoped enums landed in 6.x); confirm with the smoke test. Do not introduce a PySide6 version bump requirement.
3. **Audit, don't mass-rewrite**: only convert enum accesses that actually break under 6.11; leave class-access (`Qt.TextSelectableByMouse`) alone unless it errors.
4. **Shadow path cleanup is host-only**: do not commit deletions of `~/.local/...` files (they are not in the repo). Record the cleanup in the handoff report.
5. **Verify at the installed path**: after FIX 4, the smoke test MUST load from `/usr/lib/phasezero/`, not `~/.local/share/phasezero/releases/`.
6. **Honest reporting**: paste the launch stderr before and after. No "works" without proof.
7. **No passwordless sudo**: use `bigsudo`. No secret writes, no proprietary downloads.

## Execution order
1. Read `AGENTS.md`, `linux/ui_native/main_window.py` (around L519 + imports at top), and skim all `linux/ui_native/*.py` + `linux/ui_native/pages/*.py` for enum-instance patterns.
2. FIX 1: change line 519 to `QTextCursor.MoveOperation.End`; ensure the `QTextCursor` import exists.
3. FIX 2: audit findings — list each enum-instance usage found; fix the ones that break under 6.11; document the kept-as-is ones.
4. FIX 3: add the pytest cases (cursor smoke, append_output path, module-import audit). Run and iterate until green.
5. Run `python3 -m pytest tests/test_windows_vm_ui.py -v` — all 11 originals + the new ones must pass.
6. `bash tests/test_provision.sh`, `bash tests/linux-windows-vm.sh`, `bash tests/audit-doctor.sh` — confirm no regression (UI change shouldn't affect them, but run anyway).
7. FIX 5: bump version.json, commit, tag v1.11.1, push.
8. FIX 4: clear host shadow paths, rebuild arch pkg from v1.11.1, `bigsudo pacman -U`, final launch smoke from `/usr/lib/phasezero/`.
9. Commit the source fix on `codex/ui-pyside6-cursor-fix` with conventional commits:
   - `fix(ui): use scoped QTextCursor.MoveOperation.End for PySide6 6.11+`
   - `test(ui): regression coverage for cursor enum access and module-import audit`
   - `release: v1.11.1`
   Push when green.

## Definition of done (assert each in your final report)
- `main_window.py:519` uses `QTextCursor.MoveOperation.End` (or equivalent scoped form); the original `cursor.End` is gone from the repo.
- Audit complete: every enum-instance usage in `linux/ui_native/` either converted or documented as still-valid class access; no `AttributeError` at module import or on `append_output`.
- New pytest cases pass; original 11 still pass; backend suites unaffected.
- `version.json` = `1.11.1`, tag `v1.11.1` pushed.
- Host shadow paths cleared: `which phasezero-control-center` = `/usr/bin/phasezero-control-center`; no `~/.local/share/phasezero/releases/1.10.0/`; no user `.desktop` override.
- Rebuilt arch pkg from v1.11.1 installed via pacman.
- Final launch smoke (gtk-launch or terminal) runs without `AttributeError` AND loads from `/usr/lib/phasezero/` (paste the path proof).
- No passwordless sudo, no secret writes, no proprietary downloads.

## Handoff report format (your final message)
```
## Implementation
- FIX 1 cursor enum: main_window.py:<line> — <one line>
- FIX 2 audit findings: <count converted> converted, <count kept> kept-as-valid, <list any others>
- FIX 3 tests: tests/<file>:<line> — <one line per case>
- FIX 4 host cleanup: <what was removed; which path now wins>
- FIX 5 release: commit <hash>, tag v1.11.1 pushed

## Commits
<git log --oneline of new commits>

## Verification (paste actual output)
- pytest tests/test_windows_vm_ui.py exit + last 25 lines (new cases enumerated)
- bash tests/test_provision.sh / linux-windows-vm.sh / audit-doctor.sh exit codes
- launch stderr BEFORE fix (reproduces AttributeError)
- launch stderr AFTER fix + cleanup (clean run, path = /usr/lib/phasezero/)
- which phasezero-control-center (must be /usr/bin/)
- ls of ~/.local/share/phasezero/releases (must not contain 1.10.0)

## Skipped / blocked
- (none, or list with reason — e.g. MainWindow too heavy to construct in test)

## Notes for validator
- <which enum accesses were left as class-access and why; whether the audit found other crash candidates; whether gtk-launch vs terminal launch behaved differently>
```

If a step is blocked (e.g. cannot rebuild arch pkg because export-source fails on exFAT), record it under "Skipped / blocked", use the `/tmp` ext4 workaround already established, and continue — do not abort.
