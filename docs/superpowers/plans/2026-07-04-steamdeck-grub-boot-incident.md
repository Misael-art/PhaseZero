# Steam Deck GRUB Boot Incident And Hardening Plan

> For agentic workers: treat this as a boot-safety incident record plus implementation plan. Do not apply boot changes by guess. Prove device, mount layout, generated files, EFI prefix, and rollback path before mutation.

## Goal

Recover boot reliability for the BigLinux/Steam Deck NVMe host and harden PhaseZero boot tooling so future SteamOS, Windows VM, Waydroid, GRUB, EFI, and session-switch functions cannot leave the host unbootable.

## Incident Summary

Host context on 2026-07-04:

- Live USB booted from `/dev/sdc`.
- Broken target host on `/dev/nvme0n1`.
- Steam Deck LCD hardware reports DMI product `Jupiter`.
- NVMe layout:
  - `/dev/nvme0n1p1`: EFI System Partition, vfat, UUID `CA66-997B`.
  - `/dev/nvme0n1p2`: Btrfs root, UUID `9ce12162-f2cf-4ce0-aca8-3572fc59e4c8`, root subvolume `@`.
- User-visible error after GRUB menu when selecting NVMe host:
  - `error: net/net.c:grub_net_open_real_:1580:disk 'hd6,gpt2' not found`

## Verified Evidence

`linux/steamdeck/install-steamos-boot.sh` writes a global GRUB drop-in:

- Target path: `/etc/default/grub.d/09-phasezero-handheld.cfg`.
- Code path starts at `grub_handheld_dropin_content`.
- On `Jupiter|Galileo`, it emits:
  - `GRUB_GFXMODE="800x600,640x480,auto"`
  - `GRUB_GFXPAYLOAD_LINUX=keep`
  - `GRUB_TERMINAL_INPUT="console usb_keyboard at_keyboard"`
  - `GRUB_PRELOAD_MODULES="${GRUB_PRELOAD_MODULES:-part_gpt part_msdos} usb usb_keyboard ehci ohci uhci at_keyboard"`

NVMe target had that drop-in installed at:

- `/run/media/biglinux/9ce12162-f2cf-4ce0-aca8-3572fc59e4c8/@/etc/default/grub.d/09-phasezero-handheld.cfg`

Generated NVMe `grub.cfg` contained global mutations:

- `insmod usb`
- `insmod usb_keyboard`
- `insmod ehci`
- `insmod ohci`
- `insmod uhci`
- `insmod at_keyboard`
- `set gfxmode=800x600,640x480,auto`
- `terminal_input console usb_keyboard at_keyboard`

These settings affect every GRUB entry, including normal `BigLinux`, not only `PhaseZero SteamOS Console`.

PhaseZero generated GRUB menu entries were present and mostly valid:

- `PhaseZero SteamOS Console`
- `PhaseZero Windows VM`
- `PhaseZero Waydroid`
- All used root UUID `9ce12162-f2cf-4ce0-aca8-3572fc59e4c8`.
- Kernel existed: `/@/boot/vmlinuz-6.18-x86_64`.
- Initramfs existed: `/@/boot/initramfs-6.18-x86_64.img`.

EFI partition contained:

- `/EFI/BigLinux/grubx64.efi`
- `/EFI/boot/bootx64.efi`

Both EFI binaries contained embedded GRUB prefix:

- `(,gpt2)/@/boot/grub`

That fragile prefix explains the runtime error resolving as `hd6,gpt2`.

## Field Repair Status On 2026-07-04

After an initial external repair attempt, the real host state was checked again from the live USB.

Actual state before final repair:

- `/dev/nvme0n1p2` was mounted as target root with `subvol=@`.
- `/dev/nvme0n1p1` was mounted as target ESP at `/mnt/boot/efi`.
- `/etc/default/grub.d/09-phasezero-handheld.cfg` was already absent.
- `/boot/grub/grub.cfg` no longer contained the unsafe global Steam Deck input/video settings:
  - no `terminal_input console usb_keyboard at_keyboard`;
  - no `insmod at_keyboard`;
  - no `set gfxmode=800x600,640x480,auto`.
- `grub.cfg` still used the correct root UUID `9ce12162-f2cf-4ce0-aca8-3572fc59e4c8`.
- EFI binaries still contained dangerous prefix `(,gpt2)/@/boot/grub`.

Important finding:

- Running `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BigLinux --recheck` succeeded after mounting `efivarfs`, but still generated an EFI binary containing `(,gpt2)/@/boot/grub`.
- Therefore, a successful `grub-install` exit code is not sufficient proof of a safe bootloader on this host.

Final repair applied:

- Backup bundle created at `/var/lib/phasezero/boot-backups/20260704-075724`.
- `grub-mkconfig -o /boot/grub/grub.cfg` completed with exit code `0`.
- `grub-mkstandalone` generated a standalone EFI binary with embedded UUID bootstrap.
- Updated:
  - `/boot/efi/EFI/BigLinux/grubx64.efi`
  - `/boot/efi/EFI/boot/bootx64.efi`

Embedded bootstrap used:

```grub
insmod part_gpt
insmod btrfs
insmod search
insmod search_fs_uuid
search --no-floppy --fs-uuid --set=root 9ce12162-f2cf-4ce0-aca8-3572fc59e4c8
set prefix=($root)/@/boot/grub
configfile ($root)/@/boot/grub/grub.cfg
```

Final validation:

- No dangerous prefix remained in active EFI binaries:
  - no `(,gpt2)/@/boot/grub`;
  - no `(hdN,gptN)/@/boot/grub`;
  - no `hd6,gpt2`.
- Active NVRAM entry points to `\EFI\BigLinux\grubx64.efi`.
- Target was unmounted after sync.

Validation nuance:

- Standalone GRUB binaries may contain generic documentation/help strings such as `(hd0,gpt1)/boot/grub2/sealed.tpm`.
- Do not fail validation on generic examples.
- Fail only on active dangerous prefix patterns that target `/@/boot/grub` or the observed `hd6,gpt2` failure.

## Root Cause

Primary root cause:

- GRUB EFI binary was installed with a disk-order-dependent embedded prefix, effectively `(,gpt2)/@/boot/grub`.
- At boot, firmware/GRUB disk enumeration resolved this to `hd6,gpt2`.
- That disk did not exist in the boot environment.
- GRUB failed before correctly loading the target config/modules.

Secondary root cause:

- PhaseZero SteamOS boot installer writes global GRUB defaults for handheld input/video.
- These defaults are unsafe on Steam Deck LCD:
  - `at_keyboard` probes legacy PS/2/i8042 paths not reliable on Steam Deck.
  - `usb_keyboard` and USB controller modules are unnecessary under normal UEFI console input.
  - `GRUB_TERMINAL_INPUT` restricts input to a narrow set and can leave GRUB without usable input.
  - `800x600` plus `GRUB_GFXPAYLOAD_LINUX=keep` is risky on 1280x800 eDP.
- Because the drop-in is global, it can break normal host boot too.

Contributing design bugs:

- `root_uuid()` reads `findmnt -no UUID /`, which is unsafe if installer runs from live USB or wrong chroot.
- `latest_kernel_version()` only searches `/boot/vmlinuz-*`; valid distro layouts can differ.
- Boot mutation lacks transaction, backup, dry-run diff, and post-write validation.
- No guard prevents running boot installers outside the intended target root.
- No test asserts that GRUB global settings remain untouched by feature-specific boot entries.

## What Was Not Root Cause In This Observed Host

- Wrong root UUID in PhaseZero entries was not observed. Generated entries used the correct NVMe Btrfs UUID.
- Missing kernel was not observed. Kernel and initramfs files existed.
- Empty `42_phasezero_steamos` was not observed. File existed and generated a menuentry.
- CoreCtrl hook was not final direct cause. It regenerated GRUB on 2026-07-02 before the PhaseZero drop-in. Final `grub.cfg` timestamp was 2026-07-03 23:49, after PhaseZero boot files/drop-in existed.

## Immediate Recovery Plan

Do not start with package reinstall or blind Timeshift rollback. First repair bootloader deterministically.

From live USB:

```bash
sudo mount -o subvol=@ /dev/nvme0n1p2 /mnt
sudo mount /dev/nvme0n1p1 /mnt/boot/efi

sudo rm -f /mnt/etc/default/grub.d/09-phasezero-handheld.cfg

sudo mount --bind /dev /mnt/dev
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys
sudo mount --bind /run /mnt/run

sudo arch-chroot /mnt
mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BigLinux --recheck
grub-mkconfig -o /boot/grub/grub.cfg
exit

sudo umount -R /mnt
```

Expected validation before reboot:

- `strings /mnt/boot/efi/EFI/BigLinux/grubx64.efi` must not show stale `(hd6,gpt2)` or dangerous disk-number-only prefix targeting `/@/boot/grub`.
- `/mnt/boot/grub/grub.cfg` must not contain:
  - `terminal_input console usb_keyboard at_keyboard`
  - `insmod at_keyboard`
  - forced `set gfxmode=800x600,640x480,auto` from PhaseZero.
- `grub.cfg` must contain search-by-UUID lines for `9ce12162-f2cf-4ce0-aca8-3572fc59e4c8`.

If `grub-install` succeeds but EFI still contains a dangerous prefix, generate a standalone EFI bootstrap instead of accepting the install as fixed:

```bash
cat >/tmp/phasezero-grub-bootstrap.cfg <<'EOF'
insmod part_gpt
insmod btrfs
insmod search
insmod search_fs_uuid
search --no-floppy --fs-uuid --set=root 9ce12162-f2cf-4ce0-aca8-3572fc59e4c8
set prefix=($root)/@/boot/grub
configfile ($root)/@/boot/grub/grub.cfg
EOF

grub-mkstandalone \
  -O x86_64-efi \
  -o /boot/efi/EFI/BigLinux/grubx64.efi \
  --modules="part_gpt btrfs search search_fs_uuid configfile normal" \
  /boot/grub/grub.cfg=/tmp/phasezero-grub-bootstrap.cfg

cp -a /boot/efi/EFI/BigLinux/grubx64.efi /boot/efi/EFI/boot/bootx64.efi
```

## Required Project Hardening

## Implemented Project Controls

Implemented after the incident:

- `linux/pz boot status`
  - prints target boot recovery state.
- `linux/pz boot card`
  - prints host-specific GRUB rescue commands.
- `linux/pz boot install-card`
  - writes `/var/lib/phasezero/boot-recovery/grub-rescue.txt`;
  - writes ESP copy at `/EFI/PhaseZero/grub-rescue.txt` when ESP is mounted;
  - refuses live/root overlay mutation.
- `linux/pz boot install-efi-fallback [--fallback]`
  - generates UUID-based standalone GRUB EFI at `/EFI/PhaseZero/grubx64.efi`;
  - does not overwrite `/EFI/boot/bootx64.efi` unless `--fallback` is explicit;
  - validates dangerous disk-order prefixes after write.
- `linux/pz boot emergency-shell next`
  - creates one-shot `rescue.target` GRUB entry;
  - uses `grub-reboot` instead of permanent default;
  - can be cleared with `linux/pz boot emergency-shell clear`.

Safety controls added:

- shared GRUB preflight in `linux/lib/common.sh`;
- live/root overlay mutation guard;
- boot backup bundles under `/var/lib/phasezero/boot-backups`;
- unsafe global GRUB input/video validation;
- Windows-side fallback GRUB copy blocks EFI binaries containing dangerous prefixes.
- `linux/pz doctor` reports GRUB rescue card, standalone EFI fallback, and temporary emergency shell state.
- `linux/pz repair-plan` suggests `BOOTREC01`, `BOOTREC02`, and `BOOTREC03` actions when recovery controls are missing or still active.

Additional hardening implemented after follow-up review:

- boot helpers are target-aware through `PZ_BOOT_TARGET_ROOT` and `--target-root`;
- mutation commands fail closed when `--target-root` is not `/`, requiring the operator to chroot into the mounted target before writing absolute host paths;
- `linux/pz boot status` distinguishes `missing` from `permission-denied` for ESP files;
- active EFI loader path is detected from `efibootmgr` when possible;
- active EFI prefix state is reported as `safe`, `dangerous`, `permission-denied`, or `unknown`;
- `linux/pz boot install-efi-fallback --active --fallback` can install a UUID-search standalone EFI and copy it to the active loader plus removable fallback path;
- boot install/remove flows for SteamOS, Windows VM, and Waydroid validate active EFI prefix before and after GRUB mutation;
- boot backup bundles use collision-resistant directories;
- GRUB refresh output is persisted under `/var/lib/phasezero/boot-logs` and fails on `error:` lines;
- Doctor reports dangerous active EFI prefixes as `FAIL`;
- RepairPlan suggests active EFI repair only when the prefix scanner reports `dangerous`, and suggests privileged verification when ESP permissions prevent non-root inspection.
- PhaseZero GRUB entries now carry stable IDs and keyboard hotkeys:
  - `phasezero-steamos`, hotkey `s`;
  - `phasezero-windows-vm`, hotkey `w`;
  - `phasezero-waydroid`, hotkey `a`;
  - `phasezero-emergency-shell`, hotkey `e`.
- `grub-reboot`/`grub-set-default` use stable IDs instead of menu titles for PhaseZero entries.
- `linux/pz boot menu` and `linux/pz boot choose <normal|steamos|windows|waydroid|emergency> [--reboot]` provide a Linux-side selector before reboot, avoiding reliance on Steam Deck controls inside GRUB.
- Manual GRUB selection remains secondary; Steam Deck D-pad/analog input in GRUB is firmware-dependent and not treated as reliable automation surface.
- `linux/pz boot install-safe-menu` installs `/etc/default/grub.d/10-phasezero-safe-menu.cfg`, forcing `GRUB_TIMEOUT_STYLE=menu`, `GRUB_TIMEOUT=10`, and `GRUB_RECORDFAIL_TIMEOUT=10` without global input/preload/video overrides.

## Real Host Application Log - 2026-07-04

Applied from live USB to target host `/dev/nvme0n1`.

Target confirmed:

- ESP: `/dev/nvme0n1p1`, vfat, UUID `CA66-997B`.
- Root: `/dev/nvme0n1p2`, btrfs, UUID `9ce12162-f2cf-4ce0-aca8-3572fc59e4c8`.
- Root subvolume: `/@`.
- Boot entry order: `Boot0001 BigLinux` first, pointing to `\EFI\BigLinux\grubx64.efi`.

Applied controls:

- Installed GRUB rescue card:
  - `/var/lib/phasezero/boot-recovery/grub-rescue.txt`;
  - `/boot/efi/EFI/PhaseZero/grub-rescue.txt`.
- Installed UUID-based standalone EFI:
  - `/boot/efi/EFI/PhaseZero/grubx64.efi`;
  - `/boot/efi/EFI/boot/bootx64.efi`.
- Reapplied safe PhaseZero GRUB entries:
  - `PhaseZero SteamOS Console`;
  - `PhaseZero Windows VM`;
  - `PhaseZero Waydroid`.
- Removed/kept absent legacy unsafe drop-in:
  - `/etc/default/grub.d/09-phasezero-handheld.cfg`.

Backups created:

- `/var/lib/phasezero/boot-backups/20260704-082958`
- `/var/lib/phasezero/boot-backups/20260704-083002`
- `/var/lib/phasezero/boot-backups/20260704-083048`
- `/var/lib/phasezero/boot-backups/20260704-083112`
- `/var/lib/phasezero/boot-backups/20260704-083128`

Validation result:

- `grub-script-check /boot/grub/grub.cfg` returned success.
- `/boot/grub/grub.cfg` contains target UUID `9ce12162-f2cf-4ce0-aca8-3572fc59e4c8`.
- `/boot/grub/grub.cfg` contains no unsafe PhaseZero patterns:
  - no `terminal_input console usb_keyboard at_keyboard`;
  - no `insmod at_keyboard`;
  - no forced `set gfxmode=800x600,640x480,auto`.
- EFI binaries validate clean:
  - no `hd6,gpt2`;
  - no `(,gptN)` prefix;
  - no disk-order `(hdN,gptN)/@/boot/grub` prefix.
- EFI binaries contain UUID bootstrap and `configfile ($root)/@/boot/grub/grub.cfg`.
- Kernel and initramfs exist:
  - `/boot/vmlinuz-6.18-x86_64`;
  - `/boot/initramfs-6.18-x86_64.img`.

### Task 1: Remove Unsafe Global GRUB Drop-In

- Stop writing `/etc/default/grub.d/09-phasezero-handheld.cfg` during `linux/pz steamdeck boot install`.
- If a handheld GRUB profile remains needed, make it explicit opt-in:
  - `linux/pz steamdeck boot install --allow-grub-global-handheld-profile`
  - default must be no global GRUB mutation.
- Never set `GRUB_TERMINAL_INPUT` globally for Steam Deck.
- Never preload `at_keyboard`, `ehci`, `ohci`, `uhci`, or `usb_keyboard` globally for Steam Deck.
- Prefer firmware console defaults.

### Task 2: Make Boot Entries Feature-Scoped

- Keep PhaseZero functions as separate `/etc/grub.d/4x_phasezero_*` entries.
- Only add feature marker cmdline:
  - `phasezero.steamos=1`
  - `phasezero.windowsvm=1`
  - `phasezero.waydroid=1`
- Do not change global GRUB input, terminal, video, timeout, theme, or payload.
- Any video/input customization must be per-entry only and proven harmless.

### Task 3: Make Target Detection Chroot-Safe

Replace root detection based on current `/` with target-aware inputs.

Required behavior:

- Installer must know target root path, default `/`.
- In live USB or chroot flow, accept `--target-root /mnt`.
- Resolve root UUID from the target root mount source, not current host `/`.
- Resolve Btrfs subvolume from target root mount options.
- Resolve `/boot` and `/boot/efi` from target root.
- Refuse to continue if target root device is the live USB unless explicitly allowed.

### Task 4: Add EFI Prefix Validation

Before and after `grub-install`, inspect EFI binaries:

- Locate active EFI path from `efibootmgr -v` and mounted ESP.
- Validate `grubx64.efi` exists.
- Run `strings -a` on `grubx64.efi`.
- Fail if embedded prefix contains stale disk-number references like:
  - `(hd[0-9]+,gpt[0-9]+)/@/boot/grub`
  - `(,gpt[0-9]+)/@/boot/grub`
  - `hd6,gpt2`
- Do not fail only because generic help text mentions examples such as `(hd0,gpt1)/boot/grub2/sealed.tpm`.
- Prefer UUID/search-based GRUB config loading where distro supports it.
- If `grub-install` succeeds but prefix validation fails, generate a `grub-mkstandalone` EFI with an embedded UUID bootstrap and validate again.

### Task 4b: Add Standalone EFI Fallback

Implement a controlled fallback for hosts where distro `grub-install` keeps embedding disk-order prefixes.

Required behavior:

- Build a minimal bootstrap config with:
  - `insmod part_gpt`;
  - `insmod btrfs` or target root filesystem module;
  - `insmod search`;
  - `insmod search_fs_uuid`;
  - `search --no-floppy --fs-uuid --set=root <target-root-uuid>`;
  - `set prefix=($root)<boot-grub-path>`;
  - `configfile ($root)<boot-grub-path>/grub.cfg`.
- Generate EFI via `grub-mkstandalone`.
- Write active loader path and fallback loader path:
  - active: ESP path from `efibootmgr -v`, usually `/EFI/BigLinux/grubx64.efi`;
  - fallback: `/EFI/boot/bootx64.efi`.
- Validate dangerous prefix absence after write.
- Store bootstrap config and checksums in boot backup bundle.
- Make fallback explicit in logs: `grub-install-prefix-validation-failed; standalone-efi-fallback-applied`.

### Task 5: Transactional Boot Mutation

Every boot mutation must create a recovery bundle before writes:

- `/etc/default/grub`
- `/etc/default/grub.d/*`
- `/etc/grub.d/*phasezero*`
- `/boot/grub/grub.cfg`
- `/boot/grub/grubenv`
- ESP files under `/EFI/BigLinux` and `/EFI/boot`
- `efibootmgr -v` output
- `lsblk -f` output
- `blkid` output
- mount table output

Bundle path example:

- `/var/lib/phasezero/boot-backups/YYYYMMDD-HHMMSS/`

Rollback command must be printed after mutation.

### Task 6: Add Boot Doctor Gates

`linux/pz steamdeck boot install` must run preflight and postflight checks:

- target root mounted and writable;
- ESP mounted at target `/boot/efi`;
- target root UUID matches generated `grub.cfg`;
- kernel path exists;
- initramfs path exists;
- generated menuentries contain no empty `linux` or `initrd`;
- no generated entry uses current live USB UUID;
- no global GRUB terminal/input/video change introduced unless explicit opt-in;
- EFI binary prefix validation passes;
- if EFI prefix validation fails after `grub-install`, standalone EFI fallback either succeeds or install fails closed;
- `grub-mkconfig` output captured and scanned for errors.

Install must fail closed if any gate fails.

### Task 7: Add Tests

Add Linux tests for:

- `install-steamos-boot.sh` does not write global GRUB drop-in by default.
- Generated PhaseZero menuentry uses supplied target UUID, not current `/`.
- Live USB simulation fails when target root is ambiguous.
- Steam Deck `Jupiter` path does not emit `GRUB_TERMINAL_INPUT`.
- Steam Deck `Jupiter` path does not emit `at_keyboard`.
- EFI prefix scanner rejects `(hd6,gpt2)/@/boot/grub`.
- EFI prefix scanner rejects `(,gpt2)/@/boot/grub`.
- EFI prefix scanner does not reject generic help text containing `(hd0,gpt1)/boot/grub2/sealed.tpm`.
- Standalone fallback embeds target UUID search and `configfile ($root)/@/boot/grub/grub.cfg`.
- Standalone fallback updates both active EFI path and fallback `EFI/boot/bootx64.efi`.
- Recovery bundle includes GRUB defaults, scripts, config, ESP files, and command outputs.
- `remove` only removes PhaseZero-owned files and leaves distro GRUB defaults intact.

### Task 8: Update Documentation And CLI Warnings

Update user-facing docs:

- GRUB chooses kernel/cmdline only.
- Session mode switching belongs to systemd/SDDM after boot.
- Steam Deck internal controls are not reliable inside GRUB.
- One-shot boot should use `grub-reboot` from Linux after boot is healthy.
- Boot installers are high-risk and require target validation.

## Acceptance Criteria

- Boot tooling cannot write unsafe global GRUB input/video settings by default.
- Boot tooling can run safely from live USB with explicit `--target-root`.
- Boot tooling refuses ambiguous target or live USB self-target.
- EFI binary prefix check catches stale disk-order references.
- `grub-install` success alone is not accepted unless EFI prefix validation passes.
- Standalone EFI fallback exists for systems where `grub-install` keeps producing disk-order prefixes.
- Post-install `grub.cfg` uses target UUID, existing kernel, existing initramfs.
- A rollback bundle exists before every GRUB/EFI mutation.
- Tests cover Steam Deck `Jupiter` and generic Linux paths.
- Documentation explains recovery and hardening path.

## Notes For Next Agent

- Do not assume current `/` is target root.
- Do not assume `/boot/efi` is mounted.
- Do not assume firmware disk numbering is stable.
- Do not use disk ordinal GRUB prefixes as a source of truth.
- Do not overwrite distro GRUB defaults for feature-specific boot modes.
- Do not reinstall GRUB before capturing current EFI and GRUB state.
- If repairing live host, separate recovery operations from project code hardening commits.
