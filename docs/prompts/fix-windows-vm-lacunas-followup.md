# Fix Windows VM implementation bugs — followup to commit c39e53a

## Context
A prior agent implemented the 5 lacunas for the PhaseZero Windows VM in commit `c39e53a` (branch `verify/pr6-head`). The design is sound but a code review found concrete bugs. Your job is to fix ALL of them, run the tests, and report back. Another agent (the validator) will independently re-review and gate the merge.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch to work on: `verify/pr6-head` (or a `codex/windows-vm-bugfix` off it — confirm with validator if unsure; default: stay on `verify/pr6-head`).
- Source of truth files (NEVER edit `build/` mirrors):
  - `linux/windows-vm/windows-vm-boot-prepare.sh`
  - `linux/windows-vm/windows-vm.sh`
  - `linux/windows-vm/container-frontends.sh`
  - `linux/windows-vm/guest/vendor/vendor.json`
  - `tests/linux-windows-vm.sh`
- Follow `AGENTS.md` exactly: caveman terse prose; normal prose only in code/commits/PRs. Use `rtk` if it resolves in PATH or PhaseZero managed bin, else run directly and record `rtk missing`. Use `phasezero-admin`/`bigsudo` for root escalation — NEVER passwordless sudo, NEVER store passwords. No proprietary auto-downloads.

## Bugs to fix (ALL, in priority order)

### BUG 1 — CRITICAL: undefined `$dm` variable in boot-prepare
File: `linux/windows-vm/windows-vm-boot-prepare.sh`, inside the `if grep -qw 'phasezero.windowsvm=1'` block.
The DM detection stores its result in `current_dm`, but the autologin writers are called with `$dm`, which is never assigned:
```bash
gdm|gdm3)
    ensure_autologin_group "$dm"        # BUG: $dm unset -> ""
    remove_gdm_autologin
    write_gdm_autologin
    ;;
lightdm)
    ensure_autologin_group "$dm"        # BUG: same
    remove_lightdm_autologin
    write_lightdm_autologin
    ;;
lxdm)
    ensure_autologin_group "$dm"        # BUG: same
    remove_lightdm_autologin
    write_lightdm_autologin
    ;;
```
**Fix:** replace every `"$dm"` in that case block with `"$current_dm"`. After the fix, on a real GDM/LightDM host `ensure_autologin_group` receives the correct DM name and adds `$TARGET_USER` to the right PAM group (`gdm` or `autologin`).

### BUG 2 — MEDIUM: LXDM writes to the wrong config file
Same file, `lxdm)` arm of the case. It currently calls `remove_lightdm_autologin` + `write_lightdm_autologin`, which target `/etc/lightdm/lightdm.conf.d/...`. LXDM uses `/etc/lxdm/lxdm.conf`.
**Fix:** add dedicated `write_lxdm_autologin` and `remove_lxdm_autologin` functions that manage an idempotent block in `/etc/lxdm/lxdm.conf` (the `[base]` section: `autologin=$TARGET_USER`, `session=/usr/local/lib/phasezero/windows-vm-session`). Mirror the managed-block pattern (`# PhaseZero managed: ...` / strip on remove). Update the `lxdm)` arm to call them and `ensure_autologin_group "$current_dm"` (LXDM uses the `autologin` group on some distros — add `lxdm)` to the group map if appropriate, else keep it a no-op like SDDM).

### BUG 3 — MEDIUM: `cmd_shares_verify` return code semantics inverted and incomplete
File: `linux/windows-vm/windows-vm.sh`, function `cmd_shares_verify`.
Problems:
1. Variable `all_pass` is initialized to `0` and set to `1` on SMB failure. The name says "pass" but `1` means failure — confusing, and `return $all_pass` returns success (`0`) even when shares are degraded.
2. Per-share failures from `verify_share` do not influence the return code — only SMB reachability does.
**Fix:**
- Rename to `fail=0` (or `rc=0`) for clarity; set `fail=1` on any failure.
- Track per-share results: when `verify_share` reports `result != pass` (degraded/fail), set `fail=1`.
- In JSON mode, still emit the array of share objects but also emit a top-level `ok` boolean and `failures` count, e.g. `{"ok":false,"failures":2,"shares":[...]}`.
- Return non-zero iff `fail=1` so callers (and CI) can gate on it.
- Keep text mode output unchanged in spirit but add a final summary line `shares_ok: yes|no` mirroring `ok`.

### BUG 4 — MEDIUM: `bootctl set-oneshot` called with wrong argument form
File: `linux/lib/common.sh`, function `pz_boot_systemd_boot_set_oneshot`.
Current: `bootctl set-oneshot "$entry_id.conf"`.
`bootctl set-oneshot` expects the entry ID (basename without `.conf`) or the full path relative to the entries dir depending on bootctl version. Passing `<id>.conf` is inconsistent.
**Fix:** pass the bare entry ID: `bootctl set-oneshot "$entry_id"`. If a specific distro's bootctl requires the `.conf` form, fall back gracefully:
```bash
bootctl set-oneshot "$entry_id" 2>/dev/null || bootctl set-oneshot "$entry_id.conf" 2>/dev/null || pz_warn "bootctl set-oneshot failed for $entry_id"
```
Document the chosen form in a one-line comment.

### BUG 5 — MEDIUM: undefined `$esp` in rEFInd default-boot message
File: `linux/windows-vm/windows-vm.sh`, function `set_default_boot`, `refind)` arm:
```bash
pz_warn "rEFInd: set default selection in $esp/EFI/refind/refind.conf (default_selection)"
```
`$esp` is not assigned in this function scope.
**Fix:** resolve the ESP via `pz_boot_esp_dir` into a local `esp` variable at the top of the `refind)` arm (or reuse the function inline). Confirm the path exists; if `pz_boot_esp_dir` returns empty, warn and skip.

### BUG 6 — LOW: stray leading space in function name
File: `linux/windows-vm/windows-vm.sh`. The diff introduced ` parse_boot_common_args()` (leading space before the name). It is syntactically tolerated but is noise and breaks `grep -n '^parse_boot_common_args'`.
**Fix:** remove the leading space so it reads `parse_boot_common_args()`.

### BUG 7 — LOW: greetd config not idempotent / clobbers user config
File: `linux/windows-vm/windows-vm-boot-prepare.sh`, `write_greetd_autologin`.
It overwrites `/etc/greetd/config.toml` wholesale (relies on a `.phasezero-backup` restore on remove). If the user already had a custom config and the backup is later removed by an unrelated cleanup, the original is lost.
**Fix:** prefer a drop-in approach where greetd supports it; otherwise keep the full-file overwrite BUT also write a sidecar manifest under `/var/lib/phasezero/windows-vm/greetd-restore.toml` recording both the original path and the backup path with a SHA256 of the original, so `remove_greetd_autologin` can verify the restored file matches the recorded hash before accepting it. If the hash mismatches (user edited meanwhile), warn loudly and refuse to clobber the live config — leave both files in place and instruct the user.

### BUG 8 — LOW: `vendor.json` schema URL is non-resolvable
File: `linux/windows-vm/guest/vendor/vendor.json`.
`"schema": "https://phasezero.local/schemas/vendor-manifest.json"` — `.local` host never resolves.
**Fix:** either drop the `schema` key, or point it at a real in-repo schema path you create at `linux/windows-vm/guest/vendor/vendor-manifest.schema.json` and reference it as `"./vendor-manifest.schema.json"` (relative). If you add a schema, validate the manifest against it in a new test case.

### BUG 9 — LOW: tests do not exercise `cmd_shares_verify` at runtime
File: `tests/linux-windows-vm.sh`.
Currently the test only greps the usage string for "shares verify".
**Fix:** add a runtime test that:
1. Runs `windows-vm.sh shares verify` (non-JSON) and asserts exit code and a `shares_ok:` summary line present.
2. Runs `windows-vm.sh shares verify --json` (set `JSON_OUT=1` via env or however the existing code reads it — verify the actual flag) and pipes through `jq -e '.ok'` to confirm valid JSON with an `ok` boolean.
3. Runs it under `PZ_DRY_RUN=1` and asserts it does not mutate the host.
Cover both the pass and at-least-one-degraded path if feasible (e.g. by pointing `SHARE_BIND_ROOT` at a temp dir with no mounts).

## Robustness contract (must hold for every change)
1. **Idempotent**: every install/remove/write is a no-op if already in desired state. Use the existing `# PhaseZero managed` block delimiters and `cmp -s` guards.
2. **Reversible**: every write path has a matching strip/restore. After BUG 2 (LXDM) and BUG 7 (greetd manifest), confirm install→remove→install is clean.
3. **Backups**: keep using `pz_boot_backup_bundle "<label>"` for host mutations.
4. **Dry-run**: every new/changed path honors `PZ_DRY_RUN=1`.
5. **Validate loud**: after mutation, run the appropriate validator (`testparm`, `bootctl status`, `mountpoint`, `smbclient`). Fail non-zero on mismatch.
6. **Degrade, don't crash**: missing optional tool (`bootctl`, `efibootmgr`, `groupmems`, `pwsh`) → log and continue. Never `set -e`-die on optional capability.
7. **Locale-safe parsing**: keep `LC_ALL=C` for parsed tool output.
8. **Atomic writes**: `mktemp` → write → `fsync` → `mv`.
9. **No passwordless sudo, no secret writes, no proprietary auto-downloads.**

## Execution order
1. Read `AGENTS.md`, the four source files, and `tests/linux-windows-vm.sh`.
2. Fix BUG 1 (CRITICAL) first and re-run tests.
3. Fix BUG 2 (LXDM writers).
4. Fix BUG 3 (shares verify return code + JSON shape).
5. Fix BUG 4 (bootctl arg).
6. Fix BUG 5 (`$esp` rEFInd).
7. Fix BUG 6 (leading space).
8. Fix BUG 7 (greetd manifest + hash guard).
9. Fix BUG 8 (vendor schema) — optionally add schema + test.
10. Fix BUG 9 (runtime tests for shares verify).
11. Run full suite: `bash tests/linux-windows-vm.sh` and any related tests. Report exact exit code and tail of output.
12. Syntax-check every touched shell: `bash -n <file>` for all four source files.
13. Commit on the working branch with one conventional commit per logical fix, e.g.:
    - `fix(windows-vm): pass current_dm to autologin group helper`
    - `fix(windows-vm): dedicated LXDM autologin writer`
    - `fix(windows-vm): correct shares verify return code and JSON shape`
    - `fix(windows-vm): bootctl set-oneshot entry id form`
    - `fix(windows-vm): resolve esp for rEFInd default message`
    - `style(windows-vm): drop stray leading space in function name`
    - `fix(windows-vm): greetd restore manifest with hash guard`
    - `chore(windows-vm): resolvable vendor manifest schema`
    - `test(windows-vm): runtime coverage for shares verify`
    Do NOT push unless explicitly asked.

## Definition of done (you must assert each in your final report)
- All 9 bugs fixed; none skipped.
- `bash -n` clean on all four source files.
- `bash tests/linux-windows-vm.sh` exits 0; paste the tail of the output.
- `linux-windows-vm.sh shares verify` returns non-zero when shares are degraded (demonstrate with a constructed degraded state) and 0 when healthy.
- `linux-windows-vm.sh shares verify --json` (or the documented JSON flag) emits `{"ok":..., "failures":..., "shares":[...]}` parseable by `jq -e`.
- On a system with no LXDM, `write_lxdm_autologin`/`remove_lxdm_autologin` are safe no-ops (guard on `[ -d /etc/lxdm ]` or file existence).
- `pz_boot_systemd_boot_set_oneshot <id>` does not pass `<id>.conf` as the primary argument.
- `set_default_boot` rEFInd arm references a resolved `esp` path, not an empty `$esp`.
- greetd restore writes a sidecar manifest with original SHA256; `remove_greetd_autologin` verifies hash before accepting restore and refuses to clobber on mismatch.
- `vendor.json` has no non-resolvable `.local` schema URL (either removed or pointing at a real in-repo file).
- No passwordless sudo, no secret writes, no proprietary auto-downloads introduced.

## Handoff report format (your final message)
When done, post a single report with these exact sections so the validator can verify quickly:

```
## Fixes applied
- BUG 1 (CRITICAL $dm): <file:line> — <one line>
- BUG 2 (LXDM): <file:line> — <one line>
- BUG 3 (shares verify rc+JSON): <file:line> — <one line>
- BUG 4 (bootctl arg): <file:line> — <one line>
- BUG 5 ($esp rEFInd): <file:line> — <one line>
- BUG 6 (leading space): <file:line> — <one line>
- BUG 7 (greetd manifest): <file:line> — <one line>
- BUG 8 (vendor schema): <file:line> — <one line>
- BUG 9 (runtime tests): <file:line> — <one line>

## Commits
<git log --oneline of the new commits, hashes + subjects>

## Verification (paste actual output)
- bash -n results (4 files)
- tests/linux-windows-vm.sh exit code + last 25 lines
- shares verify (healthy) exit + output
- shares verify (degraded) exit + output
- shares verify --json | jq -e '.ok' result
- vendor.json hash recheck (3 MSIs vs manifest)

## Skipped / blocked
- (none, or list with reason)

## Notes for validator
- <anything the validator should double-check, e.g. distro-specific behavior>
```

If a single bug is blocked (e.g. you cannot reproduce a degraded state), record it under "Skipped / blocked" with the reason and continue with the rest — do not abort the whole task on one bug.
