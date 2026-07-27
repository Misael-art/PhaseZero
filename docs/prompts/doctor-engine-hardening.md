# Implement: doctor.sh engine hardening (P0 fixes + P1 policy)

## Objective
Kill 6 fragility classes in `linux/audit/doctor.sh` identified by
`docs/diagnostics/doctor-fragility-diagnosis.md` — 4 P0 engine-correction bugs, 3 P1
policy gaps. After these fixes, running `bash linux/audit/doctor.sh` on a healthy
Steam Deck produces 0 false FAILs, 0 silent skips, and consistent severity definitions.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch: create `codex/doctor-engine-hardening` off current `main`. Push when done.
- Source of truth files (NEVER edit `build/` mirrors):
  - `linux/audit/doctor.sh` — main target (772 lines, `check` function at L10, DISK loop L59–70, MEM L48–57)
  - `linux/audit/` — policy directory
  - `linux/lib/common.sh` — shared lib (WARN/ERROR helpers, `pz_boot_*`, `disk_looks_installed` at L332)
- Required reading before any edit: `docs/diagnostics/doctor-fragility-diagnosis.md` in full.

## Follow AGENTS.md exactly
- Caveman terse prose in chat; normal prose only in code/commits/PRs.
- Use `rtk` if it resolves in PATH or PhaseZero managed bin, else run directly.
- Root escalation: `phasezero-admin`/`bigsudo`. NEVER passwordless sudo.
- Critical area: doctor.sh runs on live hosts. Every change must be backward-compat (IDs preserved), default-conservative (probe fail = opted-in, not silent skip), and tested via mock setup in `tests/`.
- Write ai-memory durable pages for each bug workaround discovered during this task.

## P0 — Engine correctness (4)

### 1. DISK skip-list + fs-type filter (BUG 1)
File: `doctor.sh:59–70` DISK loop.

Add **both** protections:
- Extend the `case` skip-list with `/var/lib/snapd/snap/*`
- Filter by filesystem type: skip `squashfs` and any source matching `loop*` (loop devices used by snap, AppImage mounts, ISO loopbacks)

```bash
case "$target" in
    /|/tmp/.mount_*|/run/user/*|/var/lib/docker/overlay2/*/merged|/var/lib/snapd/snap/*) continue ;;
esac
# also skip squashfs / loop / udev read-only filesystems
case "$(LANG=C df --output=fstype "$target" 2>/dev/null | tail -1)" in
    squashfs|iso9660) continue ;;
esac
case "$dev" in
    /dev/loop*) continue ;;
esac
```

Test: mock `df` output containing a snap squashfs line at 100% → assert NOT flagged.

### 2. MEM: LANG=C free + numeric validation + ERROR on parse fail (BUG 2)
File: `doctor.sh:48–57` MEM block.

Replace the three `free -m` calls with `LANG=C free -m`. Remove every `2>/dev/null` from the threshold `[ ... -ge ]` tests. Add explicit numeric validation before comparing. On parse failure (empty/non-numeric `total_mem_mb`), emit **ERROR** (not WARN "0GB").

```bash
total_mem_mb=$(LANG=C free -m | awk '/Mem:/ {print $2 + 0}')
[[ "$total_mem_mb" =~ ^[0-9]+$ ]] && [ "$total_mem_mb" -ge 4096 ] \
    && check MEM01 "Total RAM >= 4GB" PASS "${total_mem_gb}GB" \
    || check MEM01 "Total RAM >= 4GB" ERROR "parse fail or <4GB: ${total_mem_mb}MB"
```

Same pattern for MEM02 (avail) and MEM03 (swap).

Test: mock `free -m` with localized header / empty fields → assert ERROR (not WARN "0GB").

### 3. DISK pct numeric validation + ERROR on malformed (BUG 3)
File: `doctor.sh:67–69` DISK pct parsing.

After stripping `%` and whitespace from `pct`, validate the result is numeric before passing to `-gt` tests. If malformed (e.g. busybox df emits no `%`), emit ERROR.

```bash
pct_num=${pct//[!0-9]/}
if [[ ! "$pct_num" =~ ^[0-9]+$ ]]; then
    check "DISK_$(echo "$target" | tr / _)" "$target usage" ERROR "malformed df: $pct"
    continue
fi
```
Same validation for `root_pct_num`.

Test: mock `df -h --output=pcent` producing malformed pct (e.g. bare number without `%`) → assert ERROR instead of silent skip.

### 4. stdout includes `$id` (BUG 4)
File: `doctor.sh:20` `check` function.

Change line 20:
```bash
echo "[$status] $id: $desc"
```
This unifies the terminal output format with the JSON blob format (which already includes `$id` at L19).

Test: grep the raw stdout for `[PASS] MEM01:` pattern.

## P1 — Policy + clarity (3)

### 5. Author `linux/audit/SEVERITY.md` (GAP 5)
New file `linux/audit/SEVERITY.md`:

```
# PhaseZero doctor.sh severity policy

| Severity | Meaning | Example |
|----------|---------|---------|
| FAIL     | Host-breaking / data-loss risk / core feature cannot run | Disk truly full, KVM missing on a VM feature |
| ERROR    | Check itself failed to parse or execute | free parse returned empty, df output malformed |
| WARN     | Degraded but functional; user action recommended | AI tool missing, git-lfs not configured |
| INFO     | Optional capability absent by design | Waydroid not opted-in, emulation subsystem not installed |
| PASS     | Present and healthy | git-lfs installed, RAM ≥ 4GB |

## Audit rules (applied in this commit)
1. Every `check` call in doctor.sh matches its category's severity per the table above.
2. ERROR is used ONLY for engine-level parse/execution failures, never for host findings.
3. "Not installed" for a never-opted-in subsystem → INFO, not WARN (see subsystems.conf P1.7).
```

Then audit every single `check` call in `doctor.sh` against this policy. Fix severity literals that violate it (e.g. DEV_git-lfs missing is WARN but ST07 SteamTinkerLaunch missing is INFO — both optional dev tools, should be same severity).

### 6. HOST_PROFILE awareness (GAP 6)
File: `doctor.sh`.

Compute a `HOST_PROFILE` variable once at the top of doctor.sh (after `product_name` read at L40):

```bash
HOST_PROFILE=generic
case "$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)" in
    Jupiter|Jupiter*) HOST_PROFILE=steamdeck-lcd ;;
    Galileo|Galileo*)  HOST_PROFILE=steamdeck-oled ;;
esac
```

Then in the relevant branches:
- WINVM06 (direct GRUB boot missing): on `steamdeck-*` → INFO (expected baseline), else → WARN
- WAYDROID07 (same pattern): on `steamdeck-*` → INFO, else → WARN
- NET02 (Tailscale absent): only WARN if `tailscale0` interface ever existed (check `ip link show tailscale0 2>/dev/null`), else → INFO on Deck

Test: mock product_name = Jupiter → WINVM06 absent → assert INFO, not WARN.

### 7. "Configured subsystems" manifest (GAP 6 / HOST 9)
New file `linux/audit/subsystems.conf` (INI-like, sourced by bash):

```ini
# subsystems.conf — which optional subsystems the user has opted into.
# Format: SUBSYSTEM_<name>=<opted|partial|never>
# Absent entries treated as "never" (checks become INFO).
# "opted"  = user enabled it, all checks run at full severity.
# "partial" = user enabled it but config is incomplete, WARN expected.
# "never"  = not opted in, all relevant checks → INFO (suppressed).

SUBSYSTEM_WAYDROID=never
SUBSYSTEM_EMULATION=never
SUBSYSTEM_AI_TOOLS=never
SUBSYSTEM_WINDOWS_VM=never
SUBSYSTEM_DECKY=never
SUBSYSTEM_WINBOAT=never
SUBSYSTEM_WINPODX=never
```

In `doctor.sh`, source this file early (with fallback if missing = all never):

```bash
SUBSYSTEMS_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/subsystems.conf"
if [ -f "$SUBSYSTEMS_CONF" ]; then
    source "$SUBSYSTEMS_CONF"
fi
```

Create an `_is_subsystem_opted_in` helper:

```bash
# Returns 0 if subsystem is opted-in or partial (i.e. its checks should run fully).
# Returns 1 if subsystem is never (checks downgrade to INFO).
subsystem_opted() {
    local var="SUBSYSTEM_$1"
    case "${!var:-never}" in
        opted|partial) return 0 ;;
        never) return 1 ;;
    esac
}
```

Wrap calls that check subsystem-specific tools: if the subsystem is "never", emit INFO instead of the literal severity.

Default conservative on probe fail: if the conf file parse fails or `!var` is empty → treat as "opted" (do not suppress WARNs).

Test: subsystems.conf with SUBSYSTEM_WAYDROID=never → all WAYDROID* checks → INFO instead of WARN.

## Tests (`tests/audit-doctor.sh`, new file)
9 test cases minimum. Each source `doctor.sh` functions via `bash -c` with mocked PATH and env vars.

### Cases
1. **snap-não-FAIL**: mock `df -h` with snap squashfs line at 100% → assert DISK check does NOT emit FAIL
2. **MEM-localized→ERROR**: mock `free -m` with `Mem: total used free shared buff/cache available` (localized header, no parseable numbers) → assert MEM01/MEM02/MEM03 emit ERROR (not WARN "0GB")
3. **MEM-valid→PASS**: mock `free -m` with normal values → assert MEM01/MEM02/MEM03 PASS
4. **pct-malformed→ERROR**: mock `df -h --output=pcent` emitting `100` (no `%`) → assert DISK check emits ERROR (not silent skip)
5. **stdout-id**: capture raw stdout, grep for `[PASS] MEM01:` or `[WARN] MEM01:` pattern
6. **HOST_PROFILE Deck**: mock product_name=Jupiter, WINVM06 check absent → assert INFO, not WARN
7. **subsystem suppression**: mock subsystems.conf with SUBSYSTEM_WAYDROID=never, source it before checks → assert WAYDROID* checks emit INFO
8. **subsystem partial**: mock SUBSYSTEM_WAYDROID=partial → assert WAYDROID* checks keep original severity (WARN/FAIL)
9. **default conservative**: no subsystems.conf file → assert all checks run at stated severity

### Test infrastructure
- `tests/audit-doctor.sh` is a standalone bash script, NOT sourced by pytest.
- Uses `PATH` override to mock `free`, `df`, `qemu-img` — each mock is a tiny script under `tests/.bin/`:
  - `tests/.bin/free` — reads env `MOCK_FREE` or runs real `free` (via absolute path)
  - `tests/.bin/df` — reads env `MOCK_DF` or runs real `df`
  - etc.
- Cleanup: `rm -rf tests/.bin` in EXIT trap.
- Zero external dependencies beyond bash, coreutils, jq.

## Implementation order (13 steps)

### Phase 1 — P0 fixes (steps 1–4)
1. Edit `doctor.sh`: add snap squashfs path skip + fstype filter + loop device skip in DISK loop
2. Edit `doctor.sh`: fix MEM block — `LANG=C free -m`, numeric validation, `2>/dev/null` removal, ERROR on parse failure
3. Edit `doctor.sh`: DISK pct malformed validation — ERROR on unparseable
4. Edit `doctor.sh`: stdout `$id` in `check` function

Commit: `fix(audit): P0 engine hardening — squashfs skip, MEM LANG=C, pct validation, stdout id`

### Phase 2 — P1 policy (steps 5–7)
5. Create `linux/audit/SEVERITY.md`
6. Create `linux/audit/subsystems.conf`
7. Edit `doctor.sh`: source subsystems.conf, add HOST_PROFILE detection, add `subsystem_opted` helper, audit all `check` severity against policy, wrap subsystem checks

Commit: `feat(audit): P1 policy — SEVERITY.md, subsystems.conf, HOST_PROFILE awareness`

### Phase 3 — Tests (steps 8–9)
8. Create `tests/audit-doctor.sh` with all 9 test cases + mock infrastructure
9. Run `bash tests/audit-doctor.sh` — all 9 pass

Commit: `test(audit): doctor engine hardening — 9 mock cases`

### Phase 4 — Verify + push (steps 10–13)
10. Run `bash linux/audit/doctor.sh` — verify 0 false FAILs, all MEM checks show correct values, ERROR for parse failures works
11. `bash -n linux/audit/doctor.sh` syntax check
12. Push branch `codex/doctor-engine-hardening` to origin
13. Write ai-memory durable page documenting any workaround discovered during mock-free/df setup on this filesystem

## Definition of done
Measurable:
- [ ] P0.1: `doctor.sh` DISK loop skips snap squashfs mounts (test case 1 passes)
- [ ] P0.2: MEM emits ERROR on localized/empty free parse (test case 2 passes), PASS on valid values (test case 3 passes)
- [ ] P0.3: DISK emits ERROR on malformed pct (test case 4 passes)
- [ ] P0.4: stdout contains `$id` (test case 5 passes)
- [ ] P1.5: `linux/audit/SEVERITY.md` exists with 5 severity definitions and audit rules
- [ ] P1.6: HOST_PROFILE=steamdeck-lcd makes WINVM06/ WAYDROID07/ NET02 INFO (test case 6 passes)
- [ ] P1.7: `linux/audit/subsystems.conf` exists; never-opted-in subsystems downgrade to INFO (test case 7) but partial keep severity (case 8), default conservative (case 9)
- [ ] All 9 test cases pass in `tests/audit-doctor.sh`
- [ ] `bash linux/audit/doctor.sh` runs without false FAILs on a healthy host
- [ ] Branch `codex/doctor-engine-hardening` pushed to origin
- [ ] ai-memory durable page written with any filesystem-specific workaround

## Handoff format
When closing this task, paste:

```
Implementation: <commit range / branch>
Commits:
  1. <sha> fix(audit): P0 engine hardening
  2. <sha> feat(audit): P1 policy
  3. <sha> test(audit): doctor engine hardening
Verification:
  <paste: bash tests/audit-doctor.sh output>
  <paste: bash linux/audit/doctor.sh | tail -30>
  <paste: bash -n linux/audit/doctor.sh status>
Skipped:
  P2 items from diagnosis (cache-ttl, storage cleanup, capture-layer audit) — not in scope.
Notes:
  Any filesystem quirks, workarounds, or hard-won learnings.
```
