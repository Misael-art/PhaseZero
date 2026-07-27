# Fix: subsystem manifest default + install path (doctor.sh followup)

## Objective
Commit `7af0aac` made `subsystem_opted()` default to `opted` (conservative — missing config = full WARN visibility). But the shipped template `linux/audit/subsystems.conf` still declares `SUBSYSTEM_*=never` for every subsystem. This creates two contradictory behaviors:
- User copies the template to `$XDG_CONFIG_HOME/phasezero/subsystems.conf` → every optional subsystem silently suppressed to INFO.
- User does NOT copy it → default `opted` → full WARN visibility.

Tests 7 and 9 in `tests/audit-doctor.sh` pass but validate opposite behaviors of the same subsystem (never → suppressed; absent config → WARN). Additionally, there is no install mechanism that places `subsystems.conf` at the XDG path doctor reads — users must copy manually, undocumented.

Resolve both: align the template with the conservative default, and document/install the config path.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch: create `codex/doctor-subsystem-default` off current `codex/doctor-engine-hardening`. Push when green.
- Source of truth files:
  - `linux/audit/doctor.sh` — reads `SUBSYSTEMS_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/subsystems.conf"` (~line 55) and sources it; `subsystem_opted()` (~line 59) defaults to `opted`.
  - `linux/audit/subsystems.conf` — shipped template; currently `SUBSYSTEM_WAYDROID=never` etc.
  - `linux/audit/SEVERITY.md` — severity policy; rule 3 references subsystems.conf.
  - `tests/audit-doctor.sh` — cases 7 (never → INFO), 8 (partial → WARN), 9 (no config → WARN via default opted).
  - `linux/pz` — the PhaseZero dispatcher; check for an existing `pz audit` or `pz doctor` subcommand and an install/copy pattern to mirror.
- Follow `AGENTS.md`: caveman terse prose; normal prose in code/commits. `rtk` if in PATH else run directly + record `rtk missing`. `phasezero-admin`/`bigsudo` for root; no passwordless sudo, no secret writes, no proprietary downloads.

## Fixes (do ALL)

### FIX 1 — Align shipped template default to `opted`
File: `linux/audit/subsystems.conf`. The template ships `SUBSYSTEM_*=never` for all 7 subsystems, contradicting the `opted` runtime default. A user who copies this verbatim gets every optional subsystem silently suppressed — the opposite of the intended conservative behavior.
**Fix:** change every `SUBSYSTEM_*=never` line to `SUBSYSTEM_*=opted` in the shipped template, and update the header comment to explain the semantics clearly:
- `opted` (default, shipped) = user wants visibility; checks run at full severity.
- `partial` = opted-in but known incomplete; still full severity (WARN expected).
- `never` = explicitly opt out; checks for that subsystem become INFO.
Add a comment noting that the runtime default (when this file is absent) is also `opted`, so shipping `opted` keeps template and no-config behavior identical. This removes the contradiction tests 7 and 9 currently paper over.

### FIX 2 — Provide an install path for the config + document it
Currently `subsystems.conf` lives in `linux/audit/` (repo source) but doctor reads from `$XDG_CONFIG_HOME/phasezero/subsystems.conf`. There is no copy/install step and no documentation telling the user where to put it.
**Fix (two parts):**
1. **Install mechanism.** Add a small idempotent installer. Preferred: a `pz audit subsystems (install|status|edit)` subcommand (mirror the existing `pz <area> <verb>` dispatcher style in `linux/pz`; if `pz audit` does not exist, check for `linux/audit/` wiring and add it). The installer must:
   - Be idempotent: if the target already exists, do NOT overwrite (user may have customized it); instead print a diff suggestion and exit 0 with a "already present" message.
   - Copy `linux/audit/subsystems.conf` → `$XDG_CONFIG_HOME/phasezero/subsystems.conf` (create the dir with `install -d`).
   - Honor `PZ_DRY_RUN=1` (print intended action, no write).
   - On conflict, offer `--force` to overwrite (with backup of the old file to `<path>.bak`).
   If adding a `pz` subcommand is too heavy, the minimum acceptable fallback is a standalone `linux/audit/install-subsystems-conf.sh` with the same idempotent/dry-run/backup semantics, invoked the same way the existing audit scripts are. Prefer the `pz` route for consistency.
2. **Documentation.** Update `linux/audit/SEVERITY.md` rule 3 (or add a short "Subsystems configuration" section) to state:
   - Where the file must live (`$XDG_CONFIG_HOME/phasezero/subsystems.conf`).
   - How to install it (`linux/pz audit subsystems install` or the standalone script).
   - The three values (`opted`/`partial`/`never`) and that the default (file absent OR value absent) is `opted`.
   - That `never` suppresses a subsystem's checks to INFO — opt out deliberately, not by accident.
   Also add a one-line pointer in `linux/audit/doctor.sh` header comment near the `SUBSYSTEMS_CONF` read so a reader of the source finds the doc.

### FIX 3 — Reconcile the tests with the new consistent default
File: `tests/audit-doctor.sh`. Cases 7/8/9 currently encode the contradiction. After FIX 1 the template default is `opted`, matching the no-config default.
**Fix:**
- Case 9 (`test_default_conservative`): keep as-is — no config → `opted` default → WAYDROID WARN. Still valid.
- Case 7 (`test_subsystem_never_waydroid`): keep as-is — explicit `SUBSYSTEM_WAYDROID=never` in a written config → INFO. Still valid and now genuinely distinct from case 9 (no longer a contradiction, since the written file is the only way to get `never`).
- Add a NEW case 10: install the shipped template verbatim (copy `linux/audit/subsystems.conf` to the test XDG path) → assert WAYDROID is WARN (not INFO), proving the shipped template and the no-config default behave identically. This is the regression guard for FIX 1.
- Add a NEW case 11: invoke the installer (or standalone script) into a clean XDG dir → assert the file is copied, re-running is a no-op (idempotent), and `--force` overwrites with a `.bak`. This guards FIX 2.
- Add a NEW case 12: `PZ_DRY_RUN=1` on the installer → assert no file is written and the intended action is printed. Guards the dry-run contract.

## Robustness contract (MANDATORY)
1. **Idempotent**: install is a no-op if target exists (unless `--force`).
2. **Non-destructive**: never overwrite a user config without `--force`; on force, back up to `.bak`.
3. **Dry-run**: `PZ_DRY_RUN=1` honored — print intended action, write nothing.
4. **Atomic write**: copy via `mktemp` → `mv` into place.
5. **Backward compatible**: runtime default stays `opted`; do NOT change `subsystem_opted()` logic. Only the shipped template value and the install/doc story change.
6. **Locale-safe**: `LC_ALL=C` for any parsed command output.
7. **No passwordless sudo, no secret writes, no proprietary downloads.**

## Execution order
1. Read `AGENTS.md`, `linux/audit/doctor.sh` (subsystems section ~lines 54-65), `linux/audit/subsystems.conf`, `linux/audit/SEVERITY.md`, `tests/audit-doctor.sh`, and `linux/pz` (find the audit/doctor dispatch pattern).
2. FIX 1: edit `linux/audit/subsystems.conf` (never → opted, update header comment).
3. FIX 2a: add the installer (`pz audit subsystems install` preferred, else standalone script) with idempotent/dry-run/force/backup.
4. FIX 2b: document in `SEVERITY.md` + pointer comment in doctor.sh.
5. FIX 3: add test cases 10, 11, 12; confirm 7/8/9 still pass.
6. `bash -n` on every touched shell file.
7. `bash tests/audit-doctor.sh` — report exit code + tail.
8. `bash tests/linux-windows-vm.sh` — confirm no regression.
9. Commit on `codex/doctor-subsystem-default` with conventional commits:
   - `fix(audit): ship subsystems.conf with opted default to match runtime default`
   - `feat(audit): pz audit subsystems install (idempotent, dry-run, backup)`
   - `docs(audit): document subsystems.conf location and values`
   - `test(audit): cover shipped-template default, installer idempotency, dry-run`
   Push when green.

## Definition of done (assert each in your final report)
- `linux/audit/subsystems.conf` ships `opted` for all subsystems; header comment explains the three values and that the no-file default is also `opted`.
- Installing the shipped template verbatim produces the SAME behavior as having no config (both WARN) — proven by test case 10.
- There is an idempotent installer (`pz audit subsystems install` or standalone) that copies to `$XDG_CONFIG_HOME/phasezero/subsystems.conf`, no-ops on existing target, backs up on `--force`, and honors `PZ_DRY_RUN=1` — proven by test cases 11 and 12.
- `SEVERITY.md` documents the config path, install command, and the three values; doctor.sh has a pointer comment at the `SUBSYSTEMS_CONF` read.
- `subsystem_opted()` logic unchanged (still defaults to `opted`).
- `bash -n` clean on all touched files.
- `bash tests/audit-doctor.sh` exits 0 (now 12 cases); paste tail.
- `bash tests/linux-windows-vm.sh` exits 0 (no regression).
- No passwordless sudo, no secret writes, no proprietary downloads.

## Handoff report format (your final message)
```
## Implementation
- FIX 1 template default: linux/audit/subsystems.conf — <one line>
- FIX 2a installer: <path> — <one line> (pz subcommand vs standalone)
- FIX 2b docs: SEVERITY.md + doctor.sh:<line> — <one line>
- FIX 3 tests: tests/audit-doctor.sh:<line> — <one line>

## Commits
<git log --oneline of new commits>

## Verification (paste actual output)
- bash -n results (all touched files)
- tests/audit-doctor.sh exit code + last 25 lines (12 cases)
- tests/linux-windows-vm.sh exit code (regression check)
- case 10 output (shipped template == no-config behavior)
- case 11 output (installer idempotent + force backup)
- case 12 output (dry-run writes nothing)

## Skipped / blocked
- (none, or list with reason)

## Notes for validator
- <which install route taken (pz vs standalone) and why; any edge cases in idempotency>
```

If a step is blocked (e.g. `pz audit` dispatch doesn't exist and adding it is too invasive), record it under "Skipped / blocked", fall back to the standalone script, and continue — do not abort the whole task on one blocker.
