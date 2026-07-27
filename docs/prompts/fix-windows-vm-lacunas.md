# Fix Windows VM lacunas — critical-area hardening

## Role
You are a senior Linux virtualization engineer. Domain: QEMU/KVM + libvirt + OVMF + Samba + virtiofs + systemd + bootloader integrations. The area is CRITICAL (host mutates GRUB, systemd units, Samba, UFW, NVRAM, boot chain). Every change must be idempotent, reversible, backed-up, and degrade safely — never brick a boot.

## Working context
- Repo: `/mnt/sdcard/Projects/PhaseZero`
- Source of truth: `linux/windows-vm/windows-vm.sh` (2191 lines). NEVER edit the `build/` mirrors — they are generated copies.
- Shared helpers: `linux/lib/common.sh` (`pz_boot_*`, `pz_desktop_write_entry`, sudo/admin helpers, `vm_admin_run`, `phasezero-admin`/`bigsudo`).
- Follow `AGENTS.md` exactly: caveman terse style for prose; normal prose only inside code/commits/PRs. Use `rtk` if it resolves in PATH or PhaseZero managed bin, else run directly and record `rtk missing`. Use `phasezero-admin`/`bigsudo` for root escalation — NEVER configure passwordless sudo or store passwords. Never auto-download ROMs/BIOS/proprietary assets.
- Read `linux/windows-vm/windows-vm.sh` fully before editing. Read `windows-vm-boot-prepare.sh`, `windows-vm-session.sh`, `host-access.sh`, `graphics.sh`, `container-frontends.sh`. Read `profiles/windows-vm-linux.json` and `tests/linux-windows-vm.sh`.
- Follow the existing patterns: managed blocks delimited by `# BEGIN/END PHASEZERO ...`, `vm_admin_run` for root ops, `pz_boot_backup_bundle` before mutations, `pz_boot_validate_*` after, dry-run via `PZ_DRY_RUN=1`, JSON output via `JSON_OUT=1`.

## Lacunas to fix (ALL of them, rigorously)

### Lacuna 1 — Boot is GRUB-only (no EFI stub / systemd-boot / NVRAM loader entry)
The current direct-boot mechanism is purely a GRUB menuentry (`/etc/grub.d/43_phasezero_windows_vm`). On pure-UEFI or systemd-boot hosts it does not apply. `pz_boot_validate_active_efi_safe` only guards against trashing the running EFI — it never creates an NVRAM entry.
**Fix:**
- Detect bootloader in use: GRUB (BIOS or EFI), systemd-boot, rEFInd, direct EFI stub, limine. Add `pz_boot_detect_loader()` to `linux/lib/common.sh` (or extend existing detector) returning one of: `grub-bios`, `grub-efi`, `systemd-boot`, `refind`, `efi-stub`, `unknown`.
- For systemd-boot: generate a one-shot loader entry under `$ESP/loader/entries/phasezero-windows-vm.conf` reusing the same kernel/initrd/cmdline (`phasezero.windowsvm=1`) and the same UUID/subvol resolution. Provide `bootctl set-default` / one-shot via `bootctl set-oneshot` equivalents.
- For rEFInd: generate a stub stanza under `$ESP/refsind.conf` include dir or a `manual` stanza.
- Keep GRUB path as default. Detect-and-route inside `install_boot()` / `remove_boot()` / `status_boot()` / `dry_run_boot()`.
- For EFI stub on systemd-boot systems, prefer `kernel-install` / `bootctl` over hand-rolled `efibootmgr` entries; only fall back to `efibootmgr -c` when `bootctl` is absent and the host is unambiguously EFI.
- Always back up (`pz_boot_backup_bundle`), always validate (`pz_boot_validate_grub_cfg_safe` or new `pz_boot_validate_loader_entry_safe`), always provide rollback notes.
- Add a `--loader <auto|grub|systemd-boot|refind|efi-stub>` override flag to `boot install`.

### Lacuna 2 — Autologin is SDDM-only (no GDM / LightDM / LXDM / greetd)
`windows-vm-boot-prepare.sh` writes only `/etc/sddm.conf.d/91-phasezero-windows-vm.conf`. On GDM/LightDM/greetd hosts the autologin never happens and the boot chain breaks.
**Fix:**
- Detect active display manager: `systemctl status display-manager.service` + `readlink /etc/systemd/system/display-manager.service`. Return one of: `sddm`, `gdm`, `gdm3`, `lightdm`, `lxdm`, `lxdm-plymouth`, `greetd`, `none`.
- Add per-DM drop-in writers in `windows-vm-boot-prepare.sh` (or a sourced helper `linux/lib/pz-dm.sh`):
  - SDDM: existing `/etc/sddm.conf.d/91-phasezero-windows-vm.conf` `[Autologin]`.
  - GDM: `/etc/gdm3/custom.conf` (or distro path) `[daemon] AutomaticLoginEnable=true AutomaticLogin=$USER` under a `# PhaseZero managed` block; strip on normal boot.
  - LightDM: `/etc/lightdm/lightdm.conf.d/91-phasezero-windows-vm.conf` `[Seat:*] autologin-user=$USER autologin-session=phasezero-windows-vm`.
  - greetd: emit a `tuigreet`/`agreety` config block pointing at the session script.
- PAM autologin group: ensure `$TARGET_USER` is in the right autologin group (`gdm`/`lightdm`/`autologin`) via `groupmems` / `usermod` — wrap in `vm_admin_run`, degrade if unavailable, log explicitly.
- On normal boot (marker absent), strip ALL managed DM blocks, not just SDDM. Idempotent. Keep the existing SteamOS/Waydroid cleanup.
- All drop-in writes must be guarded by `[ -e "$path" ] || return 0`-style checks and never crash if the DM is not installed.

### Lacuna 3 — SLIRP SMB symlink fallback silently serves empty `home/` + `sdcard/`
`ensure_share_links()` (L772) falls back to symlinks when root bind mounts fail. QEMU `smbd` does not follow those into the guest, so `home/` and `sdcard/` look empty there. Currently only a `pz_warn` — user may not notice and lose access silently.
**Fix:**
- When bind mount fails AND virtiofs is also unavailable, make it a HARD failure for `boot install` (return non-zero, abort install) — do not silently degrade in a critical boot path.
- For non-boot `launch` paths, keep the warning but ALSO: (a) attempt `vm_admin_run` retry once if the first mount failed; (b) emit a JSON field `shares_degraded=true shares_degraded_reason=...` so the UI can surface it; (c) verify each bind mount with `mountpoint -q` and re-mount stale ones.
- Add a `shares verify` subcommand to `cmd_shares` that exercises `mountpoint`, `smbclient -N //127.0.0.1/PZHome`, and `smbclient -N //127.0.2.4/qemu` (when QEMU SMB is active) and reports pass/fail per share with machine-readable output.
- Document the failure mode in `docs/windows-container-frontends.md`.

### Lacuna 4 — virtiofs tags exposed but no guest-side mount automation
`start_virtiofs_share()` exposes tags `hosthome`, `exchange`, `sdcard`, `removable`, `media`, `mnt` but there is nothing to mount them inside Windows. Docs treat Samba as primary and virtiofs as fallback, leaving the robust path effectively unusable out of the box.
**Fix:**
- Generate a guest provisioning bundle under `$EXCHANGE_DIR/phasezero-virtiofs-setup/` on `shares install`:
  - A PowerShell bootstrap `Install-VirtioFS.ps1` that: (a) downloads/installs the upstream VirtioFS driver + WinFsp via the existing Windows-native winget/choco profiles (`profiles/windows-vm-linux.json` declares empty arrays — populate them or vendor a pinned installer under `linux/windows-vm/guest/`); (b) creates a scheduled task / service that mounts each tag as a drive letter (e.g. `Z:`=`hosthome`, `Y:`=`exchange`, `X:`=`sdcard`) via `virtiofs.exe` with idempotent mount-points; (c) writes a verbose log to `C:\ProgramData\PhaseZero\virtiofs-setup.log`.
- Add a `pz windows-vm apps install-virtiofs` subcommand (mirror the existing `install-winboat`/`install-winpodx` pattern) that injects the bundle into the running guest via the SPICE WebDAV channel or by copying onto `$EXCHANGE_DIR` and printing the guest-side command to run.
- Honor `AGENTS.md` safety: vendor pinned, signed installers only. NEVER auto-download arbitrary URLs at runtime — pin versions and verify hashes. Provide `--offline` flag that uses a pre-vendored bundle under `linux/windows-vm/guest/`.
- Add tests under `tests/linux-windows-vm.sh` that assert the bundle is generated, the PowerShell is syntactically valid (`pwsh -NoProfile -Command` parse-only when available), and the hash file matches.

### Lacuna 5 — SPICE WebDAV / RDP `\\tsclient` require guest-side services not provisioned
`optimize_libvirt_domain()` attaches the SPICE WebDAV channel and usb-redir devices host-side, but the Windows guest needs `spice-webdavd` (and optionally RDP drive-redirection enabled) which PhaseZero never installs.
**Fix:**
- Extend the same guest provisioning bundle from Lacuna 4 to also install `spice-webdavd` (vendor the signed MSI / zipped binary pinned). Add an `install-spice-webdav` entry-point in the PowerShell bootstrap.
- Generate a `Enable-RdpShares.ps1` that: enables RDP (`fSingleSessionPerUser=0`, `AllowRemoteRPC=1`), sets the RDP drive-redirection GPO/registry keys so host drives appear as `\\tsclient\...`, and restarts `TermService`.
- Document in `docs/windows-container-frontends.md` which share path each protocol provides, prerequisites, and fallback order: Samba (primary, needs root host) → virtiofs (robust, needs WinFsp guest) → SPICE WebDAV (last resort, needs spice-webdavd guest) → RDP `\\tsclient` (needs RDP enabled guest).

## Robustness contract (MANDATORY for every change)
1. **Idempotency:** every install/remove is a no-op if already in desired state. Use managed-block delimiters and `cmp -s` guards before writes.
2. **Reversibility:** every install has a matching remove that strips ALL artifacts (files, drop-ins, GRUB entries, loader entries, Samba blocks, UFW rules, scheduled tasks, systemd units). Test `install` then `remove` then `install` cleanly.
3. **Backups:** call `pz_boot_backup_bundle "<label>"` before EVERY host mutation (boot, Samba, UFW, NVRAM, DM drop-in). Keep the existing centralized backup ledger.
4. **Dry-run:** every new code path honors `PZ_DRY_RUN=1` and prints intended actions without executing.
5. **Validation:** after every host mutation, run the appropriate `pz_boot_validate_*` / `testparm` / `bootctl status` / `smbclient` / `mountpoint` check and FAIL LOUDLY on mismatch. Never claim success without verification.
6. **Degrade, don't crash:** missing optional tool (`bootctl`, `efibootmgr`, `greetd`, `pwsh`) → log `missing`, fall back to next path, continue. NEVER `set -e`-die on optional capability absence — wrap in `|| true` and branch.
7. **Locale-safe parsing:** keep the existing `virsh() { LC_ALL=C command virsh "$@"; }` pattern for ANY parsed tool output (bootctl, efibootmgr, samba, dmidecode).
8. **Atomic writes:** write to `mktemp`, `fsync`, `mv` into place. Never leave a half-written config in a critical boot path.
9. **Logs:** every host mutation logs to the PhaseZero state dir with ISO timestamps and the exact command + rc.
10. **Tests:** extend `tests/linux-windows-vm.sh` with cases for each new loader path, DM, share-verify failure mode, and guest-bundle generation. Run the test file and report pass/fail honestly — if a test is skipped, say so.

## Execution order
1. Read everything listed in Working context.
2. Add `pz_boot_detect_loader()` to `linux/lib/common.sh` + tests.
3. Implement multi-DM support in `windows-vm-boot-prepare.sh` + helper.
4. Harden `ensure_share_links()` and add `shares verify`.
5. Refactor `install_boot()` / `remove_boot()` / `status_boot()` / `dry_run_boot()` to route by detected loader.
6. Build the guest provisioning bundle (`linux/windows-vm/guest/`) for virtiofs + spice-webdav + RDP.
7. Wire `pz windows-vm apps install-virtiofs` + `install-spice-webdav`.
8. Update `docs/windows-container-frontends.md` with the share protocol matrix and fallback order.
9. Run `tests/linux-windows-vm.sh` and any related tests; report results truthfully.
10. Commit per-lacuna on the current branch (`codex/host-hygiene-lacunas` or a new `codex/windows-vm-hardening` if directed). Conventional commits, e.g. `feat(windows-vm): multi-loader boot support (systemd-boot/rEFInd/EFI stub)`. Do NOT push unless asked.

## Definition of done
- All 5 lacunas implemented behind the robustness contract.
- `tests/linux-windows-vm.sh` passes (or skipped-with-reason documented).
- `pz windows-vm boot install` works on GRUB and at least one non-GRUB loader in a VM.
- `pz windows-vm boot remove` restores the host to pre-install state byte-for-byte on the managed blocks.
- `pz windows-vm shares verify` reports per-share status on degraded and healthy paths.
- Guest bundle generated, hashes verified, PowerShell parse-validates.
- No passwordless sudo, no secret writes, no proprietary auto-downloads.

If a step is blocked, record the blocker in the state dir and continue with the next independent step — do not abort the whole task on a single lacuna.
