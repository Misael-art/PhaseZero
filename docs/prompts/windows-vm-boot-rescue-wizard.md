# Implement: Windows VM boot rescue wizard (ISO / disk adopt / escape)

## Objective
Today the PhaseZero Windows VM boot chain (GRUB → `phasezero.windowsvm=1` → SDDM/DM autologin → `windows-vm-session.sh` → compositor → `launch_vm`) dead-loops when the VM disk is missing: `launch_vm` fails at `linux/windows-vm/windows-vm.sh:1701` with `pz_error "VM disk missing: $DISK_PATH ..."`, the session retries every 5s, and the user is stuck on a VT with no UI and no escape.

Add a TUI rescue wizard that intercepts the missing-disk failure, lets the user pick an ISO from the local disk / a pendrive / an official pinned download, install the VM from scratch OR adopt an existing Windows disk, and optionally escape back to the normal host desktop.

## Repo facts (do not re-discover)
- Repo root: `/mnt/sdcard/Projects/PhaseZero`
- Branch: create `codex/windows-vm-boot-rescue` off current `verify/pr6-head`. Push when done.
- Source of truth files (NEVER edit `build/` mirrors):
  - `linux/windows-vm/windows-vm.sh` — `launch_vm` (L1675), disk/iso resolution (`effective_config` L555, `detect_windows_iso` L504, `find_existing_windows_disk` L341, `find_existing_windows_disk_any` L369, `disk_looks_installed` L332, `install_vm` L737, `cmd_adopt` L1763, the disk-missing check at L1701).
  - `linux/windows-vm/windows-vm-session.sh` — session launcher + compositor bootstrap + retry loop (sets `PZ_WINDOWS_VM_BOOT_SESSION=1` at L204, retry loop ~L268, `RETRY_SECONDS` default 5).
  - `linux/windows-vm/windows-vm-boot-prepare.sh` — DM autologin writers/strippers (`remove_sddm_autologin` L109, `remove_gdm_autologin`, `remove_lightdm_autologin`, `remove_lxdm_autologin`, `remove_greetd_autologin`). These are the "escape to desktop" mechanism.
  - `linux/ui/tui.sh` — canonical whiptail wrappers. USE THESE, do not call `whiptail` directly: `pz_tui_menu`, `pz_tui_msgbox`, `pz_tui_yesno`, `pz_tui_infobox`, `pz_tui_show_output`. Backtitle from `version.json`.
  - `linux/lib/common.sh` — shared helpers (`vm_admin_run`, `phasezero-admin`/`bigsudo` for root, `pz_boot_*`, logging).
  - `linux/windows-vm/container-frontends.sh` — `download_atomic` (L116) + `verify_size_hash` (L125) + `file_sha256` (L113). Reuse for the pinned-download path; do NOT re-implement curl/hash logic.
  - `profiles/windows-vm-linux.json` — pacman deps array; `whiptail` is NOT currently listed.
  - `tests/linux-windows-vm.sh` — smoke tests.

## Follow AGENTS.md exactly
- Caveman terse prose in chat; normal prose only in code/commits/PRs.
- Use `rtk` if it resolves in PATH or PhaseZero managed bin, else run directly and record `rtk missing`.
- Root escalation: `phasezero-admin`/`bigsudo`. NEVER passwordless sudo, NEVER store passwords.
- NEVER auto-download ROMs/BIOS/proprietary assets, EXCEPT the pinned official URLs listed below (virtio-win + Microsoft Windows ISO policy). Pin versions and verify SHA256.
- Critical area: boot path + autologin + host mutations. Every change must be idempotent, reversible, backed up, and degrade safely.

## Design

### New file: `linux/windows-vm/rescue.sh`
Sourced by `windows-vm-session.sh` and callable from `launch_vm`. Implements:

```
vm_rescue_run
  ├── vm_rescue_pick_source       (TUI menu: iso-local | iso-net | disk-adopt | escape)
  ├── vm_rescue_scan_isos         (extends detect_windows_iso bases: add /run/media/$USER, /media/$USER, /mnt)
  ├── vm_rescue_scan_disks        (reuse find_existing_windows_disk_any + find_existing_windows_disk; return array of qcow2/img/raw/vmdk ≥5G)
  ├── vm_rescue_download_official (pinned URLs + sha256; reuse download_atomic + verify_size_hash)
  ├── vm_rescue_do_install        (validate ISO via qemu-img info; call install_vm --iso <iso>)
  ├── vm_rescue_do_adopt          (reuse cmd_adopt --disk <path>)
  └── vm_rescue_escape_to_desktop (strip ALL DM drop-ins via the remove_* helpers; systemctl restart display-manager OR isolate graphical.target; else offer reboot)
```

#### `vm_rescue_run` flow
1. If `PZ_WINDOWS_VM_RESCUE=0` env set → skip entirely (escape hatch for automation/tests).
2. `pz_tui_yesno "Disco da VM ausente. Abrir assistente de instalacao?"` — No → go to escape menu.
3. `source="$(vm_rescue_pick_source)"`.
4. Dispatch:
   - `iso-local`  → pick from `vm_rescue_scan_isos` list (TUI menu); if empty, msgbox + back to pick_source.
   - `iso-net`    → `iso="$(vm_rescue_download_official)"`; then install.
   - `disk-adopt` → pick from `vm_rescue_scan_disks` list; `vm_rescue_do_adopt`.
   - `escape`     → `vm_rescue_escape_to_desktop`.
5. Return 0 if a valid disk now exists (`disk_looks_installed "$DISK_PATH"`), else 1.

#### `vm_rescue_scan_isos`
Extend `detect_windows_iso` bases to ALSO scan: `/run/media/$USER`, `/media/$USER`, `/mnt`, `/mnt/sdcard` (already), `$HOME/Downloads`, `$HOME`. Return newline-separated list of `*win*.iso` / `*windows*.iso`. Dedup. Sort.

#### `vm_rescue_scan_disks`
Reuse `find_existing_windows_disk` + `find_existing_windows_disk_any`. ALSO scan the pendrive/external bases above for `*win*.qcow2|.img|.raw|.vmdk`. Return list. Filter `disk_looks_installed` (≥5 GiB actual / ≥32 GiB virtual).

#### `vm_rescue_download_official` — pinned URL policy (MANDATORY)
- **virtio-win ISO**: `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso` — pin the SHA256 in the script (fetch once to compute, or document the known-good hash in a comment; verify via `verify_size_hash`).
- **Windows ISO**: Microsoft's official download requires EULA acceptance and is gated behind `software-download.microsoft.com` with session cookies. DO NOT scrape or bypass. Instead:
  - Show a `pz_tui_msgbox` with the official Microsoft download page URL (`https://www.microsoft.com/software-download/windows11` for Win11, `windows10` for Win10) and instruct the user to download the ISO manually into `/mnt/sdcard` or `$HOME/Downloads`, then return to `iso-local`.
  - This honors "download oficial pinado" without violating Microsoft's ToS or implementing fragile scraping.
- Show progress: run `download_atomic` in background, stream to a temp log, `pz_tui_show_output` the tail.
- Verify SHA256 via `verify_size_hash`; on mismatch, delete + error out.

#### `vm_rescue_do_install`
- Validate ISO: `qemu-img info "$iso"` or `file "$iso"` must report ISO 9660.
- Call `install_vm --iso "$iso"` (reuse existing path: `require_iso_for_install`, `ensure_vm_storage`, `write_config`, `install_user_files`).
- Honor `PZ_DRY_RUN=1`.

#### `vm_rescue_do_adopt`
- Reuse `cmd_adopt --disk "$disk"` (already does `setfacl`/`chmod g+rw`).
- If root unavailable, msgbox "execute: sudo pz windows-vm adopt --disk <path>" + return to menu.

#### `vm_rescue_escape_to_desktop`
1. `pz_tui_yesno "Voltar ao desktop normal? Remove o autologin PhaseZero."`
2. If yes: source the strip helpers (or `source windows-vm-boot-prepare.sh` functions) and call `remove_sddm_autologin; remove_gdm_autologin; remove_lightdm_autologin; remove_lxdm_autologin; remove_greetd_autologin`. Then `systemctl restart display-manager.service 2>/dev/null || systemctl isolate graphical.target`. `exit 0`.
3. If no: `pz_tui_yesno "Reiniciar o host?"` → `systemctl reboot`.
4. Log every step to the state dir with ISO timestamps.

### Modifications to `windows-vm.sh`
- At L1701 (`[ -f "$DISK_PATH" ] || { pz_error ...; return 1; }`): BEFORE the `return 1`, if `${PZ_WINDOWS_VM_BOOT_SESSION:-0} = 1` and `${PZ_WINDOWS_VM_RESCUE:-1} != 0`, source `rescue.sh` and call `vm_rescue_run`. If it returns 0 (disk now valid), re-run `effective_config` and CONTINUE launch (do not return). If it returns non-zero, fall through to the original `pz_error; return 1`.
- Add CLI flags `--rescue`/`--no-rescue` to `parse_options` mapping to `PZ_WINDOWS_VM_RESCUE=1/0`. Default in boot session = 1; default in normal CLI = 0 (preserve current non-interactive behavior for scripts).

### Modifications to `windows-vm-session.sh`
- Confirm `PZ_WINDOWS_VM_BOOT_SESSION=1` is exported before the launch loop (it is, ~L204).
- Add a consecutive-failure cap: after `PZ_WINDOWS_VM_SESSION_MAX_RETRIES` (default 3) consecutive non-zero exits with no disk present, call `vm_rescue_run` explicitly instead of looping forever. Reset counter on successful launch.
- After a rescue that returns 0, re-resolve config (the launcher already re-execs `pz windows-vm launch --fullscreen` in the loop, so this is naturally handled — just ensure the rescue writes `windows-vm.conf` via `install_vm`/`cmd_adopt` so the next loop iteration picks up the new disk).

### Modifications to `profiles/windows-vm-linux.json`
- Add `whiptail` to the pacman array (provided by `libnewt`, present on virtually all Manjaro/Arch installs; Steam Deck includes it). This makes the TUI dep explicit.

### Ensure `pz_tui_*` is sourceable in boot session
- Verify `linux/ui/tui.sh` sources cleanly without extra deps in a tty (no DBUS/compositor). whiptail works directly on a tty. If `tui.sh` requires something not available in the boot session (e.g. `version.json` path resolution), add a fallback so `pz_tui_*` degrade to plain `read`/`select` when whiptail is absent. Implement the fallback inside rescue.sh as a local `vm_rescue_text_menu` mirroring the `pz_tui_menu` signature, and use it when `command -v whiptail` fails.

## Robustness contract (MANDATORY)
1. **Idempotent**: re-running rescue when a disk already exists is a no-op (skip wizard, continue launch).
2. **Reversible**: `vm_rescue_escape_to_desktop` strips ALL PhaseZero DM drop-ins (existing pattern).
3. **Degrade, don't crash**: whiptail absent → text menu fallback; no network → hide `iso-net`; no root → clear message + escape option. NEVER `set -e`-die on optional capability; wrap in `|| true` and branch.
4. **Backups**: any host mutation via `install_vm`/`cmd_adopt` reuses existing `pz_boot_backup_bundle` / ledger pattern.
5. **Dry-run**: `PZ_DRY_RUN=1` honored in install/adopt/download paths.
6. **Validate loud**: after install/adopt, assert `disk_looks_installed "$DISK_PATH"` is true before claiming success.
7. **Atomic writes**: config writes via existing `write_config` (mktemp → mv).
8. **Logs**: every rescue step logs ISO timestamp + command + rc to `$STATE_DIR/rescue.log`.
9. **No passwordless sudo, no secret writes, no ToS-violating scraping.**
10. **Locale-safe**: keep `LC_ALL=C` for parsed tool output (`qemu-img info`, `file`, `find`).

## Tests (`tests/linux-windows-vm.sh`)
Add cases:
1. **rescue.sh sources cleanly**: `bash -n linux/windows-vm/rescue.sh` and `source` it in a subshell.
2. **ISO scan finds fake ISO**: create `$TMP_ROOT/Downloads/Win11_fake.iso`, point `HOME` at it, assert `vm_rescue_scan_isos` lists it.
3. **Disk scan finds fake qcow2**: create a sparse 6G qcow2 under a fake pendrive dir (`/run/media` mock via env override if the function supports it, else `$HOME`), assert `vm_rescue_scan_disks` lists it and `disk_looks_installed` accepts it.
4. **Missing disk → rescue invoked**: mock `launch_vm` with `PZ_WINDOWS_VM_BOOT_SESSION=1 PZ_WINDOWS_VM_RESCUE=1` and no disk; with `PZ_WINDOWS_VM_RESCUE_AUTO_PICK=<iso>` (test-only env to auto-pick the first scanned ISO without TUI), assert install path runs and disk is created. Do NOT require a real whiptail/TTY in CI — the test-only env bypasses the TUI.
5. **Escape path**: with a fake SDDM drop-in present, call `vm_rescue_escape_to_desktop` in non-destructive test mode (`PZ_WINDOWS_VM_RESCUE_TEST=1` → print intended actions, do not actually restart DM) and assert it would strip the drop-in.
6. **whiptail absent fallback**: `PATH` mock hiding whiptail → assert `vm_rescue_text_menu` is used and still returns a valid choice.

## Execution order
1. Read `AGENTS.md`, all source-of-truth files listed above, `linux/ui/tui.sh`, `linux/boot/recovery.sh` (mirror its entrypoint style), `linux/windows-vm/container-frontends.sh` (`download_atomic`/`verify_size_hash`).
2. Write `linux/windows-vm/rescue.sh`.
3. Hook into `launch_vm` L1701 + add `--rescue`/`--no-rescue` flags.
4. Hook into `windows-vm-session.sh` (max-retries cap + rescue invocation).
5. Add `whiptail` to `profiles/windows-vm-linux.json`.
6. Verify `pz_tui_*` sourceability in boot session; add text fallback if needed.
7. Write tests.
8. `bash -n` on every touched shell file.
9. `bash tests/linux-windows-vm.sh` — report exact exit code + tail.
10. Commit on `codex/windows-vm-boot-rescue` with conventional commits (e.g. `feat(windows-vm): boot rescue wizard on missing disk`, `test(windows-vm): rescue wizard coverage`, `chore(profiles): add whiptail dep`). Push when green.

## Definition of done (assert each in your final report)
- Missing disk in boot session → rescue wizard opens (no silent loop).
- ISO detection covers `/mnt/sdcard`, `$HOME/Downloads`, `$HOME`, `/run/media/$USER`, `/media/$USER`, `/mnt`.
- Pinned official download: virtio-win ISO with SHA256 verify; Windows ISO via Microsoft official page instruction msgbox (no scraping).
- Disk adoption reuses `cmd_adopt`.
- Escape strips ALL DM drop-ins and restarts/isolates the display manager (or offers reboot).
- whiptail absent → text menu fallback works.
- `PZ_WINDOWS_VM_RESCUE=0` disables rescue entirely (automation escape hatch).
- `bash -n` clean on all touched files.
- `bash tests/linux-windows-vm.sh` exits 0; paste tail.
- No passwordless sudo, no secret writes, no ToS-violating scraping.

## Handoff report format (your final message)
```
## Implementation
- rescue.sh: <file:line> — <one line per function>
- launch_vm hook: windows-vm.sh:<line> — <one line>
- session.sh hook: windows-vm-session.sh:<line> — <one line>
- profile dep: profiles/windows-vm-linux.json — whiptail added
- tui fallback: <file:line> — <one line>

## Commits
<git log --oneline of new commits>

## Verification (paste actual output)
- bash -n results (all touched files)
- tests/linux-windows-vm.sh exit code + last 30 lines
- rescue.sh source-in-subshell result
- ISO scan test output
- disk scan test output
- escape-path test output (non-destructive mode)

## Skipped / blocked
- (none, or list with reason)

## Notes for validator
- <distro-specific behavior, Microsoft EULA policy decision, test-only env vars used>
```

If a step is blocked, record it under "Skipped / blocked" and continue with the next independent step — do not abort the whole task on one blocker.
