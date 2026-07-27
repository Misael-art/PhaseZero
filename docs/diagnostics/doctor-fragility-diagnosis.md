# PhaseZero fragility diagnosis — doctor.sh check engine + host findings

Source: `linux/audit/doctor.sh` run on Steam Deck (Jupiter, BigLinux/Manjaro, kernel 6.18.38).
Output: 150 checks → PASS:62 WARN:52 FAIL:10 ERROR:0 INFO:26.

## Executive summary
Most of the 10 FAILs and several WARNs are **false positives from the check engine itself**, not real host problems. The host is healthy. The engine has 6 fragility classes that erode trust in every future run. Fix the engine first; then the few genuine host items.

## Severity legend for THIS doc
- 🔴 ENGINE BUG — produces wrong output, must fix
- 🟡 POLICY GAP — output technically correct but misleading/inconsistent
- 🟢 HOST ITEM — genuine finding about the Steam Deck itself

---

## 🔴 ENGINE BUG 1 — snap squashfs mounts falsely reported as 100% full (10 of 10 FAILs)
`doctor.sh:59-70`. DISK loop reads `df -h` and flags any mountpoint >90% as FAIL. Skip-list (line 65) excludes `/`, AppImages, runtime user mounts, docker overlay merged dirs — **but NOT snap squashfs loop mounts** (`/var/lib/snapd/snaps/*`). Snap squashfs images are fixed-size read-only; `df` always reports 100%. Every snap (bare, snapd, core24, notepad++, mesa, gnome, gtk-themes, wine-platform) fires FAIL.
**Impact:** 100% of the FAILs in this run are noise. User learns to ignore FAIL.
**Fix:** extend skip-list at line 65:
```bash
/|/tmp/.mount_*|/run/user/*|/var/lib/docker/overlay2/*/merged|/var/lib/snapd/*) continue ;;
```
Additionally: filter by filesystem type — skip `squashfs` and any source matching `loop*`/`udev*` read-only images. More robust than path matching.

## 🔴 ENGINE BUG 2 — MEM01/MEM02 report 0GB on a 16GB Steam Deck
`doctor.sh:48-57`. `free -m` parsed without `LANG=C` (lines 48-50), unlike `df`/`lscpu` elsewhere which DO set `LANG=C`. On localized SteamOS/BigLinux the `Mem:` header regex still matches but column positions can shift; worse, the threshold test `[ "$x" -ge N ] 2>/dev/null` **silently swallows parse errors** and falls to the WARN branch printing `${x}GB` = `0GB`.
**Impact:** RAM diagnostics unusable exactly when you need them (memory pressure).
**Fix:**
1. `LANG=C free -m` on all three calls.
2. Remove `2>/dev/null` from the `[ -ge ]` tests; instead validate `total_mem_mb` is numeric before testing, and emit ERROR (not WARN) if `free` parse yields empty/non-numeric. A parse failure must never look like "low RAM".

## 🔴 ENGINE BUG 3 — DISK check `df -h` parses human sizes as numbers
`doctor.sh:67-69`. `pct_num=${pct%\%}` then `[ "$pct_num" -gt 90 ]`. The `pct` field from `df -h --output=pcent` is fine, but on systems where `df` emits no `%` (some BSD df, or busybox) `pct_num` keeps the `%` and the test silently fails via `2>/dev/null`, skipping the check entirely. Silent skip = check never runs = false PASS-by-omission.
**Fix:** strip both `%` and whitespace; validate numeric; emit ERROR on malformed `df` output rather than silently passing.

## 🔴 ENGINE BUG 4 — stdout omits the check ID
`doctor.sh:20`. `echo "[$status] $desc"` — no `$id`. The human-readable stdout loses the stable identifier (MEM01, DISK_*, WINVM06). IDs only survive in the `RESULTS[]` JSON blob (line 19) and the `Results JSON:` section. So the structured paste and the terminal stdout are different shapes, and you cannot grep stdout by ID. Your pastes came from the JSON path (they have IDs), confirming two divergent renderings.
**Fix:** `echo "[$status] $id: $desc"`. Unify stdout and JSON shape.

## 🟡 POLICY GAP 5 — no severity policy; ad-hoc PASS/WARN/FAIL/INFO per check
No `POLICY.md` in `linux/audit/`. Severity is a hardcoded literal arg to each `check` call. Inconsistencies observed:
- `DEV_git-lfs` missing → WARN (line 583), but `ST07 SteamTinkerLaunch` missing → INFO (476). Both optional dev tools.
- `AI_codex` present → PASS, but its peers `AI_hermes`/`AI_openclaw`/`AI_opencode` missing → WARN, while `AI_omo`/`AI_graphify`/`AI_ponytail` missing → INFO. No rule distinguishes "expected" from "optional" AI tools.
- `WINVM06` direct GRUB boot missing → WARN, but on Steam Deck (GRUB host) this is the *recommended* path and missing it is the expected baseline.
**Fix:** author `linux/audit/SEVERITY.md` with explicit definitions:
- **FAIL** = host-breaking / data-loss risk / core feature cannot run (e.g. disk truly full, KVM missing on a VM feature).
- **ERROR** = check itself failed to run / parse (engine bug). Currently never used despite being in the counter.
- **WARN** = degraded but functional; user action recommended.
- **INFO** = optional capability absent by design.
- **PASS** = present and healthy.
Then audit every `check` call against the policy in one pass.

## 🟡 POLICY GAP 6 — host-awareness missing; Steam Deck baseline not modeled
`doctor.sh:121` reads `product_name` (Jupiter) for SD01 but never reuses it. On a Steam Deck:
- Direct GRUB boot (WINVM06, WAYDROID07) is the intended boot path → missing entry is INFO not WARN.
- Tailscale (NET02) absent is normal → should be INFO unless `tailscale0` ever configured.
- Privileged TDP bridge (UX11) is Steam-Deck-specific → WARN appropriate but should explain why.
**Fix:** compute a `HOST_PROFILE` (steamdeck-lcd / steamdeck-oled / generic) once, feed it into the relevant branches.

## 🟡 POLICY GAP 7 — no idempotency / dedup; re-runs are full re-execution
No caching, no dedup, no run-once. Calling doctor twice runs every check twice (slow, and re-emits the snapd spam twice). For a 150-check engine on a handheld this is several seconds of fork/exec.
**Fix (later):** optional `--cache-ttl N` storing results in `$XDG_STATE_HOME/phasezero/doctor-cache.json` keyed by check ID + a host fingerprint. Not urgent but needed once checks grow.

## 🟢 HOST ITEM 8 — `/mnt/sdcard` at 89% (genuine WARN)
Real. 1 TB SD card nearly full. PhaseZero stores ISOs, ROMs, vendor MSIs, qcow2 disks here. At 89% the Windows VM install path (256G qcow2) could fail mid-write.
**Action:** surface as a first-class "actionable" WARN with the PhaseZero-specific consumers listed (VM disks, vendor bundles, emulation ROMs). Consider a `pz storage cleanup` that prunes old qcow2 snapshots, stale ISO downloads, and apt/pacman cache.

## 🟢 HOST ITEM 9 — 52 WARNs mostly "run: linux/pz ... install" (setup drift, not breakage)
52 of 52 WARNs are "X not installed, run install". This is a **fresh/partially-set-up host**, not a broken one. The engine treats "user hasn't enabled feature Y yet" the same as "feature Y is broken". For a tool with ~40 optional subsystems (Waydroid, emulation, 6 AI tools, Decky plugins, WinBoat/WinPodX, etc.) this floods the signal.
**Fix:** introduce a "configured subsystems" manifest. If the user never opted into Waydroid, its 10 missing checks should be INFO (suppressed), not 10 WARNs. Only WARN when a subsystem is *partially* configured (e.g. Waydroid command present but binder not mounted — that's real breakage).

## 🟢 HOST ITEM 10 — capture layer duplicated/truncated the output
Your two pastes are byte-identical except line 1 ("RESULTADO" vs "ESULTADO", missing leading "R"). Neither word appears in `doctor.sh` source (first output is `=== System Info ===`). So a **wrapper** (a Copilot skill / UI capture / translator) is mangling the stream — clipping the first byte on one capture and duplicating the whole blob. This is outside doctor.sh.
**Action:** audit whatever invokes doctor.sh and tees its output (`repair-plan.sh`, `support-bundle.sh`, or a UI page). Likely a `head -c N` / encoding / paste-buffer bug.

---

## Prioritized fix plan

### P0 — engine correctness (unblocks trust in all output)
1. **DISK skip-list + fs-type filter** (BUG 1) — kills 10/10 false FAILs.
2. **`LANG=C free -m` + remove silent `2>/dev/null` on threshold tests + numeric validation** (BUG 2) — fixes MEM 0GB.
3. **DISK pct numeric validation** (BUG 3) — prevents silent skip.
4. **stdout includes `$id`** (BUG 4) — unifies rendering.

### P1 — policy + clarity
5. **Author `linux/audit/SEVERITY.md`** (GAP 5) + audit all `check` calls in one pass against it.
6. **`HOST_PROFILE` derived once, fed into Steam-Deck-aware branches** (GAP 6) — fixes WINVM06/WAYDROID07 severity on Deck.
7. **"Configured subsystems" manifest** (HOST 9) — suppress WARNs for never-opted-in subsystems; WARN only on partial config.

### P2 — resilience / UX
8. **Capture-layer audit** (HOST 10) — find the truncation/dup outside doctor.sh.
9. **`--cache-ttl` dedup** (GAP 7) — only once checks grow or doctor gets called in a loop.
10. **`pz storage cleanup`** (HOST 8) — actionable disk hygiene for the PhaseZero-specific /mnt/sdcard consumers.

## Tests to add (`tests/`-side)
- doctor.sh DISK: mock `df` output containing a snap squashfs line at 100% → assert NOT flagged.
- doctor.sh MEM: mock `free -m` with localized header / empty fields → assert ERROR (not WARN "0GB").
- doctor.sh severity: snapshot test that every `check` call's severity matches `SEVERITY.md` policy for its category.
- HOST_PROFILE: on a Jupiter product_name, WINVM06 not-installed → INFO, not WARN.
