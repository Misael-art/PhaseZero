# Execute: PhaseZero v1.12.0 — implement severity fix + release + install (4 gated phases)

## CRITICAL CONTEXT
This release combines two UI improvements plus the doctor-severity fix that was NOT yet implemented (the prompt at `docs/prompts/ui-doctor-severity-fix.md` exists but no agent executed it). Without the severity fix, doctor runs with any FAIL (e.g. CPU thermal) still show "Operação falhou" red dialog — the exact bug the user reported. The pedagogy fix (dropdown + custom) is already done on `codex/ui-graphics-pedagogy` (validated). The severity fix must be implemented fresh on a new branch, then both merged.

Chain state on main:
- `main` HEAD: `c5a6299` (v1.11.1)
- `codex/ui-graphics-pedagogy`: 1 commit ahead (`78fa890`, validated)
- `codex/ui-doctor-severity-fix`: **does not exist yet** — PHASE 1 creates it
- `codex-bootstrap-secrets-rotation` (57 commits) and `codex/verify-pr1` (4): EXCLUDED, not in this release

Host: Steam Deck Jupiter, BigLinux/Manjaro. Build OUTSIDE `/mnt/sdcard` (exFAT chmod no-op). Use `bigsudo` for root. LFS hook residue → `git -c core.hookspath=/dev/null push`.

## PHASE 1 — implement severity fix (GATED)

Goal: execute the spec in `docs/prompts/ui-doctor-severity-fix.md`. Create branch `codex/ui-doctor-severity-fix` off `main`, implement, test.

### Steps
1. Read `docs/prompts/ui-doctor-severity-fix.md` (the full spec) AND `docs/diagnostics/doctor-fragility-diagnosis.md` for context.
2. `git checkout main && git pull --ff-only origin main`.
3. `git checkout -b codex/ui-doctor-severity-fix`.
4. Implement the 5 fixes from the spec:
   - **FIX 1** `linux/ui_native/result_parser.py`: rewrite `severity_for(value, exit_code, *, mutable=True, has_output=None)` — diagnostic (`mutable=False`) + non-zero exit + valid output → `"warning"`; + no output → `"error"`; mutable + non-zero → `"error"`; exit 0 → `"success"`. Keep status-field checks for exit==0 path.
   - **FIX 2** `linux/ui_native/main_window.py:550`: pass `mutable=bool(action and action.mutable)` from `pending_action` into `severity_for`.
   - **FIX 3** `linux/ui_native/widgets.py:969`: thread `severity` into `ResultDialog`. Map success→"Operação concluída"/"success"; warning→"Concluído com avisos"/"warning"; error→"Operação falhou"/"error". Add "warning" tone to `StatefulDialog` if missing.
   - **FIX 4** `linux/ui_native/main_window.py`: status text L548 ("Concluído"/"Concluído com avisos"/"Falhou"), toast verb L595, status_dot L551 (verify `statusWarning` QSS exists). KEEP L600 action-queue advance gated on `result.ok` (exit code), NOT severity.
   - **FIX 5** (optional) `linux/ui_native/models.py`: add `OperationResult.severity` property; do NOT change `ok`.
5. Tests: add 8 cases per the spec (`tests/test_windows_vm_ui.py` or new `tests/test_result_severity.py`). MUST include case 6 (doctor fixture with `[FAIL]` line + `mutable=False` → `"warning"`).
6. Verify:
   - `python3 -c "import ast; ast.parse(open(f).read())"` on all 4 touched files.
   - `python3 -m pytest tests/test_windows_vm_ui.py -v` — all green (15 existing + 8 new = 23).
   - `bash tests/test_provision.sh`, `bash tests/linux-windows-vm.sh`, `bash tests/audit-doctor.sh` — no regression.
7. Commit on `codex/ui-doctor-severity-fix` with conventional commits:
   - `fix(ui): classify diagnostic non-zero exits as warning, not error`
   - `feat(ui): warning tone in ResultDialog + status text + toast`
   - `test(ui): severity_for coverage for diagnostic vs mutable actions`
8. Push: `git -c core.hookspath=/dev/null push -u origin codex/ui-doctor-severity-fix`.
9. **GATE**: only proceed to PHASE 2 if all tests pass + the doctor-fixture test asserts `"warning"` (not `"error"`). Paste the test output. If fail, STOP.

## PHASE 2 — merge both UI branches into main (GATED)

Goal: linearize `codex/ui-graphics-pedagogy` and `codex/ui-doctor-severity-fix` onto main.

### Steps
1. `git checkout main && git pull --ff-only origin main`.
2. Verify both branches are linear descendants of main:
   - `git merge-base --is-ancestor main codex/ui-graphics-pedagogy && echo OK || echo BROKEN`
   - `git merge-base --is-ancestor main codex/ui-doctor-severity-fix && echo OK || echo BROKEN`
   - If either BROKEN, STOP — report divergence.
3. Check the two feature branches do not conflict with each other (they touch different files mostly: pedagogy = catalog+widgets+page; severity = result_parser+main_window+widgets+models). `widgets.py` is shared — expect possible conflict on `ResultDialog`/`ParameterDialog`. Resolve carefully if it happens; prefer keeping both changes.
4. Merge in order (oldest first):
   - `git merge --ff-only codex/ui-graphics-pedagogy` (must be clean ff).
   - `git merge codex/ui-doctor-severity-fix` (ff-only if possible; if the pedagogy merge advanced main, this may need a real merge — resolve any widgets.py conflict preserving both sets of changes).
5. Verify post-merge tree:
   - `grep -c "WINDOWS_VM_GRAPHICS_OPTIONS" linux/ui_native/catalog.py` >= 1.
   - `grep -c "mutable=" linux/ui_native/result_parser.py` >= 1 (severity fix present).
   - `grep -c "Concluído com avisos" linux/ui_native/widgets.py` >= 1 (warning tone).
6. Run full suite:
   - `python3 -m pytest tests/test_windows_vm_ui.py -v` — all green.
   - `bash tests/test_provision.sh` (66), `bash tests/linux-windows-vm.sh`, `bash tests/audit-doctor.sh` (9).
   - `bash tests/test_provision.sh` etc. — all exit 0.
7. **GATE**: only proceed to PHASE 3 if all tests pass + the 3 greps return expected counts. If any conflict couldn't be resolved cleanly, STOP and report.

## PHASE 3 — bump v1.12.0, tag, build (GATED)

Goal: stamp version, tag, build arch pkg + deb.

### Steps
1. Edit `version.json`:
   - `"version": "1.12.0"`, `"commit": "release-v1.12.0"`, `"builtAt": "<UTC ISO now>"`.
2. `git add version.json && git commit -m "release: v1.12.0"`.
3. `git tag v1.12.0 -m "v1.12.0 — doctor severity fix + graphics pedagogy dropdown + custom escape"`.
4. Push: `git -c core.hookspath=/dev/null push origin main && git -c core.hookspath=/dev/null push origin v1.12.0`.
5. Build arch pkg (PRIMARY, native to this host):
   - `mkdir -p /tmp/pz-dist && bash packaging/linux/arch/build-arch.sh /tmp/pz-dist`.
   - Confirm `/tmp/pz-dist/phasezero-control-center-1.12.0-1-any.pkg.tar*` exists.
   - Extract `usr/lib/phasezero/linux/ui_native/result_parser.py` from the pkg and `grep -c "mutable=" >= 1` (severity fix inside pkg).
   - Extract `usr/lib/phasezero/linux/ui_native/catalog.py` and `grep -c "WINDOWS_VM_GRAPHICS_OPTIONS" >= 1` (pedagogy inside pkg).
6. Build deb (SECONDARY, ext4 workaround):
   - `PZ_DEB_WORK=/tmp/pz-deb-work bash packaging/linux/deb/build-deb.sh /tmp/pz-dist`.
   - Confirm `phasezero-control-center_1.12.0_all.deb` exists.
7. Skip flatpak (`PZ_SKIP_FLATPAK=1` by design — multi-GB SDK out of scope).
8. **GATE**: only proceed to PHASE 4 if arch pkg built AND both internal greps confirmed. If build fails, STOP.

## PHASE 4 — install on host + verify (GATED)

Goal: replace v1.11.1 install with v1.12.0 and verify both fixes are live at the installed path.

### Steps
1. Confirm current install: `grep version /usr/lib/phasezero/version.json` (should be 1.11.1).
2. Remove old: `bigsudo pacman -R --noconfirm phasezero-control-center` (or `dpkg -r` if deb). Verify `/usr/lib/phasezero/` is gone or only stale leftovers (clean if needed).
3. Install new arch pkg: `bigsudo pacman -U --noconfirm /tmp/pz-dist/phasezero-control-center-1.12.0-1-any.pkg.tar*`.
4. Verify installed:
   - `grep version /usr/lib/phasezero/version.json` → `1.12.0`.
   - `grep -c "mutable=" /usr/lib/phasezero/linux/ui_native/result_parser.py` >= 1.
   - `grep -c "WINDOWS_VM_GRAPHICS_OPTIONS" /usr/lib/phasezero/linux/ui_native/catalog.py` >= 1.
   - `grep -c "Concluído com avisos" /usr/lib/phasezero/linux/ui_native/widgets.py` >= 1.
5. Clear any re-spawned shadow paths (defensive, should already be clean from v1.11.1 work):
   - `ls ~/.local/share/phasezero/releases/ 2>/dev/null` — empty or absent.
   - `ls ~/.local/bin/phasezero-control-center 2>/dev/null` — absent.
   - `ls ~/.local/share/applications/io.phasezero.ControlCenter.desktop 2>/dev/null` — absent.
   - `which phasezero-control-center` → `/usr/bin/` or `/usr/sbin/`.
6. Clear stale systemd-user transient units (the `app-io.phasezero.ControlCenter@<hash>.service` issue from earlier):
   - `systemctl --user daemon-reload`.
   - `systemctl --user reset-failed`.
7. Smoke-launch via menu: `timeout 8 gtk-launch io.phasezero.ControlCenter 2>/tmp/v12_launch.log`. Assert:
   - No `AttributeError` in stderr.
   - No "Unit ... not found" in stderr.
   - App stays alive until timeout (exit 124 expected).
8. Doctor smoke (the bug we fixed): `/usr/lib/phasezero/linux/pz doctor 2>/dev/null | tail -5` — confirm it runs (FAIL may be present, that's fine — the UI classification is what matters, not the CLI exit).
9. **GATE**: PASSED if installed version is 1.12.0, both greps confirmed, launch is clean.

## Robustness contract (MANDATORY)
1. **`--ff-only` for merges** where possible; if a real merge is needed (PHASE 2 step 4), resolve widgets.py conflicts preserving BOTH feature changes.
2. **Build outside /mnt/sdcard** (exFAT chmod no-op).
3. **Remove old before install new**.
4. **Verify at `/usr/lib/phasezero/`** path, not repo source.
5. **`OperationResult.ok` unchanged** — automation contract.
6. **`doctor.sh` exit codes unchanged** — diagnostic contract.
7. **Action-queue advance stays exit-code-gated** (main_window.py L600).
8. **No passwordless sudo** — use `bigsudo`. No secret writes, no proprietary downloads.

## Handoff report format
```
## PHASE 1 — severity fix implementation
- branch created: codex/ui-doctor-severity-fix
- commits: <hashes>
- tests: pytest <N/N>, severity_for(doctor, exit=1, mutable=False) == "warning" (regression guard)
- GATE: PASSED/FAILED

## PHASE 2 — merge
- pedagogy merge: ff-only, clean
- severity merge: ff-only OR real merge (conflicts resolved: <list>)
- post-merge greps: WINDOWS_VM_GRAPHICS_OPTIONS=<N>, mutable=<N>, "Concluído com avisos"=<N>
- full suite: pytest <N>, provision 66, windows-vm, audit 9
- GATE: PASSED/FAILED

## PHASE 3 — release + build
- version.json: 1.12.0
- commit + tag v1.12.0: pushed
- arch pkg: /tmp/pz-dist/... (size), internal greps confirmed
- deb: built
- GATE: PASSED/FAILED

## PHASE 4 — install
- old version: 1.11.1
- removed + installed 1.12.0
- installed greps: version=1.12.0, mutable=<N>, WINDOWS_VM_GRAPHICS_OPTIONS=<N>, "Concluído com avisos"=<N>
- shadow paths: clean
- systemd-user: daemon-reload + reset-failed done
- launch via gtk-launch: clean (no AttributeError, no Unit-not-found)
- GATE: PASSED/FAILED

## Skipped / blocked
- (none, or list with reason)

## Notes for validator
- <any widgets.py conflict resolution details; whether StatefulDialog warning tone was added; whether systemd-user units cleared>
```

If any GATE fails, STOP — do not attempt later phases.
