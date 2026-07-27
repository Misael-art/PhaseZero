# Execute: PhaseZero v1.11.0 — merge ordered, build, install (3 gated phases)

## CRITICAL CONTEXT — read before touching anything
This release merges a 5-branch linear chain into `main`, cuts tag `v1.11.0`, builds native packages, and installs on the host (Steam Deck, Manjaro/BigLinux). The chain is LINEAR — each branch derived from the previous. Merge in the wrong order and the tree breaks. The phases below are GATED: phase N only runs if phase N-1 reports green output. Do NOT skip ahead.

Chain (oldest → newest), each derived from the one above it:
```
codex/doctor-engine-hardening        (3 commits: P0+P1 doctor hardening)
  ← codex/windows-vm-provision        (+1: provision pipeline, total 4)
    ← codex/windows-vm-provision-graphics (+1: P0 graphics, total 5)
      ← codex/windows-vm-graphics-p1  (+1: P1 graphics, total 6)
        ← codex/windows-vm-ui-provision-options (+2: UI options, total 8)  ← tip
```

Branches NOT in this chain (`codex-bootstrap-secrets-rotation`, `codex/host-hygiene-*`, `codex/fix-cli-status-legend`, `codex/foundation-merge`, `codex/verify-pr1`) are EXCLUDED. Do not merge them — their state is unvalidated.

Host facts:
- Steam Deck Jupiter, BigLinux/Manjaro, kernel 6.18.38, pacman native.
- `/mnt/sdcard` is exFAT — `chmod` is a no-op there. Build OUTSIDE `/mnt/sdcard` (use `/tmp` or `$HOME` on ext4).
- `dpkg-deb` exists (workaround: `PZ_DEB_WORK=/tmp/...` so the control dir gets 0755 perms).
- `makepkg` is the native Arch/Manjaro builder — this is the CORRECT install format for this host.
- `flatpak-builder` requires `org.kde.Platform//6.11` SDK (multi-GB download) — SKIP with `PZ_SKIP_FLATPAK=1`.
- Previous install was v1.7.2-era deb forced with `--force-depends`. Must be REMOVED before installing the new arch pkg.

## Repo facts
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Current HEAD: `codex/windows-vm-ui-provision-options` (commit `06913c3` or newer).
- Source of truth: `main` branch (target of merge). `version.json` currently at `1.10.1` (commit `23c87a5`).
- Follow `AGENTS.md`: caveman terse prose in chat; normal prose in code/commits/tags. `rtk` if in PATH else run directly + record `rtk missing`. `phasezero-admin`/`bigsudo` for root; NEVER passwordless sudo, NEVER store passwords. No proprietary downloads.
- LFS hook residue in `.git/hooks/` blocks push; use `git -c core.hookspath=/dev/null push ...` (per-command override, does not persist).

## PHASE 1 — merge chain into main (GATED)

Goal: linearize the 5-branch chain onto `main` preserving order, then verify the result is exactly the tip tree.

Steps:
1. From repo root, `git fetch origin` (use `git -c core.hookspath=/dev/null fetch origin` if the LFS hook complains).
2. `git checkout main` and `git pull --ff-only origin main` (if main has diverged from what you expect, STOP and report — do not force anything).
3. Verify main is an ancestor of the chain tip:
   - `git merge-base --is-ancestor main codex/doctor-engine-hardening && echo OK || echo BROKEN`
   - If the above is OK, also verify the chain is linear:
     - `git merge-base --is-ancestor codex/doctor-engine-hardening codex/windows-vm-provision && echo OK`
     - `git merge-base --is-ancestor codex/windows-vm-provision codex/windows-vm-provision-graphics && echo OK`
     - `git merge-base --is-ancestor codex/windows-vm-provision-graphics codex/windows-vm-graphics-p1 && echo OK`
     - `git merge-base --is-ancestor codex/windows-vm-graphics-p1 codex/windows-vm-ui-provision-options && echo OK`
   - If ANY of these prints BROKEN, STOP — the chain is not linear as assumed. Report and abort.
4. If the chain is linear and main is the base, fast-forward main to the tip:
   - `git merge --ff-only codex/windows-vm-ui-provision-options`
   - This must produce NO merge commit and NO conflicts. If it does, STOP and report — something diverged.
5. Verify the merged tree:
   - All 5 expected features present in the tree: `test -f linux/audit/SEVERITY.md`, `test -f linux/audit/subsystems.conf`, `test -f linux/windows-vm/rescue.sh`, `test -f linux/windows-vm/provision.sh`, `test -f linux/windows-vm/media-inspect.sh`, `test -f linux/windows-vm/autounattend.sh`.
   - `grep -c subsystem_opted linux/audit/doctor.sh` returns >= 2 (hardened).
   - `grep -c graphics_preflight linux/windows-vm/provision.sh` returns >= 1 (P0 graphics present).
   - `grep -c plan-venus linux/ui_native/catalog.py` returns >= 1 (UI Venus present).
6. Run the full test suite from main:
   - `bash tests/test_provision.sh` → must exit 0, 66 PASS.
   - `bash tests/linux-windows-vm.sh` → must exit 0.
   - `bash tests/audit-doctor.sh` → must exit 0, 9 PASS.
   - `python3 -m pytest tests/test_windows_vm_ui.py -q` → must exit 0, 11 PASS.
7. Report PHASE 1 output. **GATE**: only proceed to PHASE 2 if all 4 test suites passed and the 3 greps returned the expected counts. If any failed, STOP.

## PHASE 2 — bump version, tag v1.11.0, build packages (GATED)

Goal: stamp `version.json` at `1.11.0`, tag, push, and build the host-native package(s).

Steps:
1. Edit `version.json`:
   - `"version": "1.11.0"`
   - `"commit": "release-v1.11.0"`
   - `"builtAt": "<current UTC ISO timestamp>"` (use `date -u +%Y-%m-%dT%H:%M:%SZ`)
2. `git add version.json && git commit -m "release: v1.11.0"` on `main`.
3. `git tag v1.11.0 -m "v1.11.0 — doctor hardening + Windows VM provision pipeline + graphics P0/P1 + UI options"`.
4. Push main + tag (LFS bypass): `git -c core.hookspath=/dev/null push origin main` and `git -c core.hookspath=/dev/null push origin v1.11.0`.
5. Build the native Arch package (PRIMARY install format for this host):
   - `bash packaging/linux/arch/build-arch.sh /tmp/pz-dist` (build OUTSIDE /mnt/sdcard).
   - Confirm output exists: `ls -la /tmp/pz-dist/phasezero-control-center-1.11.0-1-any.pkg.tar.zst`.
   - Inspect contents: `tar -tf <pkg> | head` to confirm `usr/lib/phasezero/linux/audit/doctor.sh`, `usr/lib/phasezero/linux/windows-vm/provision.sh`, etc. are present.
   - Confirm hardened doctor inside the pkg: extract `usr/lib/phasezero/linux/audit/doctor.sh` to a tmp path and `grep -c subsystem_opted` → must be >= 2.
6. Build the deb as a SECONDARY artifact (for non-Arch hosts), with the exFAT workaround:
   - `PZ_DEB_WORK=/tmp/pz-deb-work bash packaging/linux/deb/build-deb.sh /tmp/pz-dist`
   - Confirm `phasezero-control-center_1.11.0_all.deb` exists.
7. Skip flatpak: `PZ_SKIP_FLATPAK=1` is the default expectation. Do NOT attempt flatpak (multi-GB SDK; out of scope for this release). If `build-all.sh` is run, set `PZ_SKIP_FLATPAK=1`.
8. Report PHASE 2 output (artifact paths + sizes + the hardened-doctor grep from inside the arch pkg). **GATE**: only proceed to PHASE 3 if the arch pkg built AND the hardened-doctor grep confirmed >= 2. If the arch build failed, STOP.

## PHASE 3 — install on host + verify (GATED)

Goal: replace the stale v1.7.2 install with the new v1.11.0 arch package and verify the running code is hardened.

Steps:
1. Confirm current install version: `cat /usr/lib/phasezero/version.json | grep version`. Record it (should be 1.7.2 or 1.10.1).
2. Remove the old install. If it was a deb: `bigsudo dpkg -r phasezero-control-center`. If arch: `bigsudo pacman -R --noconfirm phasezero-control-center`. If files linger under `/usr/lib/phasezero/` after removal, `bigsudo rm -rf /usr/lib/phasezero` (only if the package manager left them; verify they are PhaseZero-owned first).
3. Install the new arch pkg: `bigsudo pacman -U --noconfirm /tmp/pz-dist/phasezero-control-center-1.11.0-1-any.pkg.tar.zst`.
4. Verify the install:
   - `cat /usr/lib/phasezero/version.json | grep version` → must be 1.11.0.
   - `grep -c subsystem_opted /usr/lib/phasezero/linux/audit/doctor.sh` → must be >= 2.
   - `test -f /usr/lib/phasezero/linux/windows-vm/provision.sh` → must succeed.
   - `test -f /usr/lib/phasezero/linux/windows-vm/rescue.sh` → must succeed.
   - `grep -c plan-venus /usr/lib/phasezero/linux/ui_native/catalog.py` → must be >= 1.
5. Run the installed doctor (via the dispatcher path the UI uses):
   - `/usr/lib/phasezero/linux/pz doctor 2>/dev/null | tail -5` → must show `FAIL: 0` (not 10) and PASS > 60.
   - Confirm MEM lines are `[PASS] MEM01:` / `[PASS] MEM02:` (not WARN 0GB).
   - Confirm 0 snapd FAIL lines: `... | grep -c snapd` → must be 0.
6. Verify any running PhaseZero UI process picks up the new code:
   - `pgrep -af phasezero-control-center` → if a stale instance is running, advise the user to restart it (do NOT kill user sessions without explicit consent).
7. Report PHASE 3 output. Final state: host running v1.11.0, doctor reports FAIL:0, hardened code confirmed at the installed path.

## Robustness contract (MANDATORY)
1. **Never force a merge**: `--ff-only` only. If it fails, STOP and report — do not `--force` or rebase blindly.
2. **Never overwrite uncommitted work**: `git status --porcelain` must be clean (or only untracked `docs/` files) before checkout/merge. If dirty, STOP.
3. **Build outside /mnt/sdcard**: exFAT chmod is a no-op; dpkg-deb and makepkg need real ext4 perms. Use `/tmp` or `$HOME`.
4. **Remove old before install new**: stale v1.7.2 files under `/usr/lib/phasezero/` cause the UI to run old code (the exact bug we fixed in v1.10.1).
5. **Verify at the installed path**: the UI loads from `/usr/lib/phasezero/`, so the grep checks MUST run against that path, not the repo source.
6. **Honest reporting**: if a phase fails, paste the failure output. Do not claim success without the verification greps + test runs.
7. **No passwordless sudo**: use `bigsudo`/`phasezero-admin`. Never store passwords.
8. **No proprietary downloads**: build from the repo source only. Skip flatpak.

## Execution contract
- Execute PHASE 1 fully, paste output, then check the GATE. If green, execute PHASE 2. Paste output, check GATE. If green, execute PHASE 3.
- If any GATE fails, STOP immediately. Do not attempt later phases.
- Do NOT push tags or install until PHASE 1 merge is confirmed linear + tests green.

## Handoff report format (your final message)
```
## PHASE 1 — merge
- chain linearity checks: <OK/BROKEN per branch>
- merge --ff-only result: <commit hash + "no conflicts">
- post-merge greps: SEVERITY.md=<yes/no> subsystem_opted=<N> graphics_preflight=<N> plan-venus=<N>
- test suite results: provision=<66/66 exit> windows-vm=<exit> audit=<9/9 exit> pytest=<11/11 exit>
- GATE: <PASSED/FAILED>

## PHASE 2 — release + build
- version.json bumped: <yes, 1.11.0>
- commit: <hash>
- tag v1.11.0: <created + pushed>
- arch pkg built: <path + size>
- hardened doctor inside arch pkg: subsystem_opted=<N>
- deb built: <path + size> (or skipped with reason)
- flatpak: skipped (PZ_SKIP_FLATPAK=1)
- GATE: <PASSED/FAILED>

## PHASE 3 — install
- old version detected: <1.7.2 / 1.10.1 / other>
- old install removed: <yes, how>
- new arch pkg installed: <yes, pacman -U>
- installed version.json: <1.11.0>
- installed doctor.sh subsystem_opted: <N>
- doctor run via /usr/lib/phasezero/linux/pz: FAIL=<N> snapd=<N> MEM01=<PASS/WARN>
- stale UI process: <none / pid N, advise restart>
- GATE: <PASSED/FAILED>

## Skipped / blocked
- (none, or list with reason — e.g. flatpak skipped by design)

## Notes for validator
- <any host-specific quirk; whether arch pkg signed; whether pacman complained about deps>
```

If PHASE 1 reveals the chain is NOT linear (merge-base checks fail), STOP — report the divergence and do not attempt to force anything. The release cannot proceed until the chain is reconciled.
