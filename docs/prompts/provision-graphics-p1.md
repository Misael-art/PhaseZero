# Implement: P1 graphics — Venus doc + doctor WINVM11 + graphics test coverage

## Objective
The P0 graphics fix landed in commit `2a6255f` (branch `codex/windows-vm-provision-graphics`): `--graphics compat|virtio-gl` is now effective in `provision.sh`, with preflight, honest logging, QGA display-adapter assertion, and profile deps. Three P1 items from the original spec were NOT done and are scoped here:

1. **Graphics test coverage** — `tests/test_provision.sh` still has the original 36 cases; ZERO new cases cover the graphics behavior. This is the most important gap: the P0 fix is untested.
2. **`graphics.sh plan --profile virtio-venus`** — currently errors "plan-only" with no useful output. Make it print an honest experimental plan (prerequisites, what works, what does not, why not wired into provision.sh).
3. **Doctor `WINVM11`** — currently a single WARN for missing graphics runtime. Enrich it to report the resolved profile from a provisioned VM's `operation.json` and the Steam Deck VFIO note.

Deck reality recap (do not relitigate): VanGogh is a single APU, so VFIO passthrough is impossible; Venus (Vulkan via virtio-gpu) is the only accel path and is experimental; virtio-gl (virgl, OpenGL only) is the stable maximum today.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch: create `codex/windows-vm-graphics-p1` off current `codex/windows-vm-provision-graphics` (HEAD `2a6255f`). Push when green.
- Source of truth files:
  - `linux/windows-vm/provision.sh` — now has `graphics_preflight()`, `resolve_graphics_qemu_args()`, `qga_ping`/`qga_exec`/`qga_shutdown`, `run_validate` calls preflight, `run_relaunch` reads `graphics` from plan JSON. `OPERATIONS_DIR` holds `operation.json` per op with `graphicsResolved` field.
  - `linux/windows-vm/graphics.sh` — `graphics plan/doctor/apply/runtime/guest-guide`. Venus currently plan-only.
  - `linux/windows-vm/windows-vm.sh:1602-1672` — `guard_graphics_profile()` documents the v1 contract: compat everywhere, virtio-gl raw-QEMU only, venus/rutabaga/VFIO plan-only.
  - `linux/audit/doctor.sh` — `WINVM11 "Windows graphics integration"` check (~line 290-300). Reads `winvm_status` JSON from `windows-vm.sh status --json`.
  - `tests/test_provision.sh` — 36 existing cases. Extend, do not rewrite.
- Follow `AGENTS.md`: caveman terse prose in chat; normal prose in code/commits. `rtk` if in PATH else run directly + record `rtk missing`. `phasezero-admin`/`bigsudo` for root; no passwordless sudo, no secret writes, no proprietary downloads.

## Fixes (do ALL three)

### FIX 1 — graphics test coverage in tests/test_provision.sh (MOST IMPORTANT)
The P0 fix is untested. Add cases that exercise the new code paths. Use the existing test file's mocking style (temp dirs, fake plans, `PZ_DRY_RUN=1`, `source` the script, call functions directly). Cases:
1. **plan serializes graphics**: `provision.sh plan --iso <fake> --graphics virtio-gl --json | jq -r .graphics` == `virtio-gl`. Also default (no `--graphics`) == `compat`.
2. **graphics_preflight compat always passes**: call `graphics_preflight test-op compat` → return 0 unconditionally (no host checks for compat).
3. **graphics_preflight virtio-gl fail-loud on missing render node**: in a sandboxed env where `/dev/dri/renderD*` is absent (or wrapped via a `PZ_GFX_RENDER_NODE` override the function honors — add the override if needed for testability), assert `graphics_preflight test-op virtio-gl` returns non-zero AND the operation log contains `fallback: --graphics compat`.
4. **graphics_preflight unknown profile rejected**: `graphics_preflight test-op vfio-looking-glass` → return non-zero with `unknown graphics profile` in log.
5. **resolve_graphics_qemu_args compat**: call with `compat` → `$GRAPHICS_VGA == "-vga qxl"`, `$GRAPHICS_DISPLAY == "-display gtk"`, `$GRAPHICS_ACCEL_LOG` contains `NONE (QXL)`. Also assert `operation.json` now has `.graphicsResolved.profile == "compat"`.
6. **resolve_graphics_qemu_args virtio-gl**: call with `virtio-gl` → `$GRAPHICS_VGA == "-device virtio-vga-gl"`, `$GRAPHICS_DISPLAY == "-display gtk,gl=on"`, `$GRAPHICS_ACCEL_LOG` contains `virgl`. Assert `.graphicsResolved.profile == "virtio-gl"` AND `.graphicsResolved.vgaDevice` and `.graphicsResolved.displayArg` are populated.
7. **run_relaunch qemu_args per profile (dry-run)**: with `PZ_DRY_RUN=1` and a fake completed plan + fake golden-clean snapshot, mock the relaunch path so it prints the qemu_args without exec'ing QEMU. With `graphics=compat` in plan → args contain `-vga qxl -display gtk` and NOT `virtio-vga-gl`. With `graphics=virtio-gl` and mocked-passing preflight → args contain `-device virtio-vga-gl -display gtk,gl=on`.
8. **headless invariant**: assert that for any profile, the setup/drivers/tweaks qemu_args contain `-vga qxl -display none` (parse the static arrays or extract them via a `headless_qemu_args` helper if you need to refactor for testability).
9. **QGA display-adapter check path**: mock `qga_exec` to return a captured `guest-exec-status` JSON containing `out-data` base64 of `"Microsoft Basic Display Adapter"` → assert the drivers phase logs WARN. With `out-data` of `"Red Hat VirtIO GPU"` → assert it logs the adapter name without WARN.

If a case cannot be mocked portably (e.g. real QEMU exec), record under "Skipped / blocked" with the reason — but the function-level cases (1-6, 9) MUST run; they only need `source provision.sh` + temp dirs.

### FIX 2 — `graphics.sh plan --profile virtio-venus` honest experimental plan
File: `linux/windows-vm/graphics.sh`. Today `graphics plan --profile virtio-venus` errors with a "plan-only" message. Replace with a real plan output that:
- Exits 0 (not error).
- Prints `status: experimental` prominently.
- Lists prerequisites: kernel >= 6.7 (Venus virtio-gpu Vulkan support), mesa >= 23 with venus enabled, `crosvm` or a QEMU built with virtio-gpu-vulkan, vulkan-radeon driver on host AMD.
- Lists what works today experimentally: Vulkan 1.x via venus renderer; D3D12 via rutabaga+zink (very experimental).
- Lists what does NOT work: native D3D12, DXGI swapchain without rutabaga, multi-adapter, VFIO on single-APU hosts (Steam Deck).
- States explicitly why it is not wired into `provision.sh` yet: prereqs not pinned, guest driver stability unverified, no automated test coverage.
- Prints the Steam Deck note: VanGogh is a single APU; VFIO passthrough is impossible; Venus is the only acceleration path.
- Keeps `graphics apply --profile virtio-venus` returning an error with the same honest message (do not enable apply).

If `graphics.sh` already has a `venus` branch that errors, modify it. If the plan dispatch is shared, add a `venus` arm to the plan subcommand only.

### FIX 3 — Doctor `WINVM11` enrichment
File: `linux/audit/doctor.sh`, the `WINVM11` block (~line 290-300). Currently emits a single WARN when the graphics runtime is missing. Enrich:
- If a provisioned VM exists, read the most recent `OPERATIONS_DIR/*/operation.json` (look for the `graphicsResolved` field added by P0). If present, surface it in the message: `"VGA: <vgaDevice> (<profile>)"`.
- On a Steam Deck host (`HOST_PROFILE` already computed in doctor.sh), append: `"Host note: VanGogh APU cannot do VFIO passthrough; Venus is the only accel path and is experimental."`.
- Severity policy:
  - `graphicsResolved.profile == "virtio-gl"` AND host supports it → PASS (or INFO if guest driver not yet verified).
  - `graphicsResolved.profile == "compat"` AND host CAN do virtio-gl (preflight would pass) → WARN with actionable `"re-provision with --graphics virtio-gl for OpenGL acceleration"`.
  - `graphicsResolved.profile == "compat"` AND host CANNOT do virtio-gl → INFO (compat is the best this host can do).
  - No provisioned VM → keep current behavior (WARN/MISSING).
- Do NOT execute `graphics_preflight` directly from doctor (it is in provision.sh); instead replicate the cheap host-capability probes (KVM, render node, virglrenderer, AMDGPU) inline or via a shared helper sourced from common.sh if you add one. Keep doctor.sh standalone-runnable.

## Robustness contract (MANDATORY)
1. **Tests must run portably**: function-level cases use `source` + temp dirs; no real QEMU/KVM/ISO required. If a case needs a host probe, use env overrides (`PZ_GFX_RENDER_NODE`, `PZ_GFX_KVM_PATH`) — add them to the preflight if missing.
2. **Honest output**: Venus plan must not promise acceleration that does not exist; doctor must not claim VFIO is possible on a Deck.
3. **Idempotent**: doctor and graphics plan are read-only; no host mutation.
4. **Locale-safe**: `LC_ALL=C` for parsed tool output.
5. **Backward compatible**: existing 36 test cases + 9 audit cases + windows-vm smoke must still pass.
6. **No passwordless sudo, no secret writes, no proprietary downloads.**

## Execution order
1. Read `AGENTS.md`, `tests/test_provision.sh` (existing 36 cases' style), `linux/windows-vm/provision.sh` (graphics_preflight, resolve_graphics_qemu_args, qga_* helpers, run_validate, run_relaunch), `linux/windows-vm/graphics.sh` (venus branch + plan dispatch), `linux/audit/doctor.sh` (WINVM11 + HOST_PROFILE).
2. FIX 1: add the 9 test cases. Run them and iterate until green. If `graphics_preflight` needs env overrides for testability, add them in the same commit.
3. FIX 2: rewrite the venus plan branch in graphics.sh.
4. FIX 3: enrich WINVM11 in doctor.sh.
5. `bash -n` on every touched shell file.
6. `bash tests/test_provision.sh` — report exit + tail.
7. `bash tests/linux-windows-vm.sh` and `bash tests/audit-doctor.sh` — confirm no regression.
8. Commit on `codex/windows-vm-graphics-p1` with conventional commits:
   - `test(windows-vm): graphics preflight, resolution, relaunch, QGA display-adapter coverage`
   - `feat(windows-vm): honest experimental plan for virtio-venus graphics profile`
   - `feat(audit): WINVM11 reports resolved graphics profile + Deck VFIO note`
   Push when green.

## Definition of done (assert each in your final report)
- `tests/test_provision.sh` has the 9 new graphics cases and they pass; total count > 36.
- `graphics_preflight` honors env overrides (`PZ_GFX_RENDER_NODE` etc.) so case 3 can run without a real render node.
- `graphics.sh plan --profile virtio-venus` exits 0 and prints `status: experimental` + prerequisites + Deck VFIO note (no "plan-only" error).
- `graphics.sh apply --profile virtio-venus` still refuses with the honest message.
- `WINVM11` doctor check surfaces `graphicsResolved` when present and appends the Deck VFIO note on Steam Deck hosts; severity follows the policy above.
- `bash -n` clean on all touched files.
- `bash tests/test_provision.sh` exits 0 (with the new cases); paste tail.
- `bash tests/linux-windows-vm.sh` and `bash tests/audit-doctor.sh` exit 0 (no regression).
- No passwordless sudo, no secret writes, no proprietary downloads.

## Handoff report format (your final message)
```
## Implementation
- FIX 1 tests: tests/test_provision.sh:<line> — <one line per case group>
- FIX 1 env overrides: provision.sh:<line> — <one line>
- FIX 2 venus plan: graphics.sh:<line> — <one line>
- FIX 3 WINVM11: doctor.sh:<line> — <one line>

## Commits
<git log --oneline of new commits>

## Verification (paste actual output)
- bash -n results (all touched files)
- tests/test_provision.sh exit code + last 30 lines (with new cases enumerated)
- tests/linux-windows-vm.sh exit code
- tests/audit-doctor.sh exit code
- one before/after: venus plan output (was error, now experimental plan)
- one before/after: WINVM11 output with a mock graphicsResolved

## Skipped / blocked
- (none, or list with reason — especially any case that needed real QEMU)

## Notes for validator
- <which env overrides you added; how the doctor reads operation.json; any shared helper extracted>
```

If a step is blocked, record it under "Skipped / blocked" with the reason and continue — do not abort the whole task.
