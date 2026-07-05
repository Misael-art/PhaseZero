#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux boot recovery tooling.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$REPO_ROOT/linux/pz" "$REPO_ROOT/linux/lib/common.sh" "$REPO_ROOT/linux/boot/recovery.sh"

"$REPO_ROOT/linux/pz" boot status >/dev/null
menu_output="$(PZ_BOOT_MENU_PRINT_ONLY=1 "$REPO_ROOT/linux/pz" boot menu)"
grep -q 'PhaseZero boot choices' <<< "$menu_output"
grep -q 'linux/pz boot choose <choice>' <<< "$menu_output"
grep -q 's SteamOS, w Windows VM, a Waydroid, e Emergency' <<< "$menu_output"
grep -q 'install-safe-menu' <<< "$menu_output"
target_status="$("$REPO_ROOT/linux/pz" boot status --target-root /)"
grep -q 'target_root: /' <<< "$target_status"
emergency_plan="$("$REPO_ROOT/linux/pz" boot emergency-shell dry-run)"
grep -q 'one-shot via grub-reboot' <<< "$emergency_plan"
safe_menu_plan="$("$REPO_ROOT/linux/pz" boot safe-menu dry-run)"
grep -q 'GRUB_TIMEOUT_STYLE=menu' <<< "$safe_menu_plan"
grep -q 'GRUB_TIMEOUT=10' <<< "$safe_menu_plan"
grep -q 'GRUB_RECORDFAIL_TIMEOUT=10' <<< "$safe_menu_plan"

grep -q 'cmd_boot' "$REPO_ROOT/linux/pz"
grep -q 'install-safe-menu' "$REPO_ROOT/linux/pz"
grep -q '10-phasezero-safe-menu.cfg' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'GRUB_TIMEOUT_STYLE=menu' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'GRUB_RECORDFAIL_TIMEOUT' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'install-efi-fallback' "$REPO_ROOT/linux/pz"
grep -q 'grub-mkstandalone' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q -- '--active' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q "BOOT_ID=\"phasezero-emergency-shell\"" "$REPO_ROOT/linux/boot/recovery.sh"
grep -q -- "--hotkey=e" "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'boot choose' "$REPO_ROOT/linux/pz"
grep -q 'search --no-floppy --fs-uuid --set=root' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'configfile (\\$root)' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'systemd.unit=rescue.target' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'pz_boot_preflight_grub' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'pz_boot_backup_bundle "boot-efi-fallback"' "$REPO_ROOT/linux/boot/recovery.sh"

! grep -q 'init=/bin/bash' "$REPO_ROOT/linux/boot/recovery.sh"
! grep -q 'GRUB_TERMINAL_INPUT=' "$REPO_ROOT/linux/boot/recovery.sh"
! grep -q 'usb_keyboard' "$REPO_ROOT/linux/boot/recovery.sh"
! grep -q 'at_keyboard' "$REPO_ROOT/linux/boot/recovery.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
printf '%s\n' '(,gpt2)/@/boot/grub' > "$tmp_root/dangerous-a.efi"
printf '%s\n' '(hd6,gpt2)/@/boot/grub' > "$tmp_root/dangerous-b.efi"
printf '%s\n' '(hd0,gpt1)/boot/grub2/sealed.tpm' > "$tmp_root/generic-help.efi"
bash -c ". '$REPO_ROOT/linux/lib/common.sh'; pz_boot_efi_has_dangerous_prefix '$tmp_root/dangerous-a.efi'"
bash -c ". '$REPO_ROOT/linux/lib/common.sh'; pz_boot_efi_has_dangerous_prefix '$tmp_root/dangerous-b.efi'"
if bash -c ". '$REPO_ROOT/linux/lib/common.sh'; pz_boot_efi_has_dangerous_prefix '$tmp_root/generic-help.efi'"; then
    echo "generic GRUB help text was treated as dangerous" >&2
    exit 1
fi
if bash -c ". '$REPO_ROOT/linux/lib/common.sh'; export PZ_BOOT_TARGET_ROOT='$tmp_root'; pz_boot_require_current_root_target" >/tmp/phasezero-target-root-test.out 2>&1; then
    echo "expected non-/ target root mutation guard to fail" >&2
    exit 1
fi
grep -q 'target-root mutation must run inside target chroot' /tmp/phasezero-target-root-test.out

if [ "$(findmnt -no FSTYPE / 2>/dev/null || true)" = "overlay" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if sudo -n bash "$REPO_ROOT/linux/boot/recovery.sh" install-card >/tmp/phasezero-boot-recovery-test.out 2>&1; then
        cat /tmp/phasezero-boot-recovery-test.out >&2
        echo "expected install-card to refuse live overlay root" >&2
        exit 1
    fi
    grep -q 'refusing GRUB mutation' /tmp/phasezero-boot-recovery-test.out
fi

echo "linux-boot-recovery smoke ok"
