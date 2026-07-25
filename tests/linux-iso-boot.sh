#!/usr/bin/env bash
# Tests for managed dynamic ISO/USB/grubfm boot backend.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export PZ_ISO_BOOT_CONFIG="$tmp/boot-isos.json"
export PZ_ISO_BOOT_ARTIFACTS="$tmp/artifacts.json"
export PZ_ISO_GRUB_SCRIPT="$tmp/46_phasezero_iso_loopback"
export PZ_USB_GRUB_SCRIPT="$tmp/47_phasezero_removable_efi"
export PZ_GRUBFM_GRUB_SCRIPT="$tmp/48_phasezero_grubfm"

bash -n "$REPO_ROOT/linux/lib/common.sh" "$REPO_ROOT/linux/boot/iso-boot.sh"

printf 'fixture\n' > "$tmp/rescue.iso"
sha="$(sha256sum "$tmp/rescue.iso" | awk '{print $1}')"
cat > "$PZ_ISO_BOOT_CONFIG" <<EOF
{
  "schemaVersion": 1,
  "entries": [
    {
      "id": "arch-rescue",
      "title": "Arch Rescue",
      "kind": "iso",
      "profile": "archiso",
      "hostPath": "$tmp/rescue.iso",
      "fsUuid": "1111-2222",
      "fsType": "btrfs",
      "fsModule": "btrfs",
      "grubPath": "/@/boot/iso/arch rescue.iso",
      "kernelPath": "/arch/boot/x86_64/vmlinuz-linux",
      "initrdPath": "/arch/boot/x86_64/initramfs-linux.img",
      "isoLabel": "ARCH_TEST",
      "sha256": "$sha",
      "enabled": true
    },
    {
      "id": "ventoy-test",
      "title": "Ventoy Test",
      "kind": "removable-efi",
      "fsUuid": "3333-4444",
      "fsType": "vfat",
      "fsModule": "fat",
      "efiPath": "/EFI/BOOT/BOOTX64.EFI",
      "sha256": "deadbeef",
      "enabled": true
    }
  ]
}
EOF

export PZ_ISO_BOOT_LIBRARY_ONLY=1
# shellcheck disable=SC1090
source "$REPO_ROOT/linux/boot/iso-boot.sh"
unset PZ_ISO_BOOT_LIBRARY_ONLY

render_iso_script "$PZ_ISO_BOOT_CONFIG" > "$PZ_ISO_GRUB_SCRIPT"
render_usb_script "$PZ_ISO_BOOT_CONFIG" > "$PZ_USB_GRUB_SCRIPT"

grep -q "phasezero-iso-arch-rescue" "$PZ_ISO_GRUB_SCRIPT"
grep -q 'search --no-floppy --fs-uuid --set=iso_dev 1111-2222' "$PZ_ISO_GRUB_SCRIPT"
grep -q 'img_dev=/dev/disk/by-uuid/1111-2222' "$PZ_ISO_GRUB_SCRIPT"
grep -q 'img_loop=/@/boot/iso/arch rescue.iso' "$PZ_ISO_GRUB_SCRIPT"
grep -q "phasezero-removable-ventoy-test" "$PZ_USB_GRUB_SCRIPT"
grep -q 'search --no-floppy --fs-uuid --set=removable 3333-4444' "$PZ_USB_GRUB_SCRIPT"
grep -q '/EFI/BOOT/BOOTX64.EFI' "$PZ_USB_GRUB_SCRIPT"
! grep -Eq '\(hd[0-9]+,gpt[0-9]+' "$PZ_ISO_GRUB_SCRIPT" "$PZ_USB_GRUB_SCRIPT"

[ "$(pz_boot_grub_dquote 'a $b `c` "d"')" = '"a \$b \`c\` \"d\""' ]
pz_boot_valid_id arch-rescue
! pz_boot_valid_id 'Arch Rescue'
! safe_title "bad'title"

status="$(bash "$REPO_ROOT/linux/boot/iso-boot.sh" iso status --json)"
jq -e '.schemaVersion == 1 and .entries[0].available == true and .entries[0].reason == "ready"' <<< "$status" >/dev/null

before="$(sha256sum "$PZ_ISO_BOOT_CONFIG" | awk '{print $1}')"
bash "$REPO_ROOT/linux/boot/iso-boot.sh" iso remove arch-rescue --dry-run >/dev/null
after="$(sha256sum "$PZ_ISO_BOOT_CONFIG" | awk '{print $1}')"
[ "$before" = "$after" ]

catalog="$(bash "$REPO_ROOT/linux/boot/iso-boot.sh" catalog)"
jq -e '.choices[] | select(.key == "iso:arch-rescue" and .available == true)' <<< "$catalog" >/dev/null

echo "linux-iso-boot ok"
