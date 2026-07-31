#!/usr/bin/env bash
# host-access.sh - let the Linux host browse the Windows VM's internal disk.
#
# Guest->host sharing is handled by the Samba/virtiofs shares (cmd_shares). This
# is the reverse: mount the Windows VM disk image on the host via libguestfs so
# the host can read (default) or write (--rw) the guest's C: drive. Writing while
# the guest is off is safe; mounting a running VM's disk risks corruption, so we
# refuse unless the domain is shut off.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"; shift 2>/dev/null || true
MOUNTPOINT="${PZ_WINDOWS_VM_HOST_MOUNT:-$HOME/VirtualMachines/guest-c}"
RW=0; DISK="${PZ_WINDOWS_VM_DISK:-}"
for a in "$@"; do
    case "$a" in
        --rw) RW=1 ;;
        --disk=*) DISK="${a#*=}" ;;
        --mount=*) MOUNTPOINT="${a#*=}" ;;
    esac
done

resolve_disk() {
    [ -n "$DISK" ] && { printf '%s\n' "$DISK"; return 0; }
    local c
    for c in \
        "$HOME/VirtualMachines/PhaseZero-Windows/phasezero-windows.qcow2" \
        "$HOME/VirtualMachines/Windows/Windows.qcow2" \
        "$HOME/VirtualMachines/Windows11/Windows11.qcow2" \
        /var/lib/libvirt/images/phasezero-windows.qcow2; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    # last resort: newest qcow2 under VirtualMachines
    find "$HOME/VirtualMachines" -maxdepth 3 -name '*.qcow2' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-
}

vm_is_running() {
    if command -v virsh >/dev/null 2>&1; then
        [ "$(LC_ALL=C virsh domstate phasezero-windows 2>/dev/null || true)" = "running" ] && return 0
    fi
    pgrep -af 'qemu.*phasezero-windows' >/dev/null 2>&1
}

cmd_mount() {
    command -v guestmount >/dev/null 2>&1 || { pz_error "libguestfs required: sudo pacman -S libguestfs"; return 1; }
    local disk; disk="$(resolve_disk)"
    if [ -z "$disk" ] || [ ! -f "$disk" ]; then
        pz_error "Windows VM disk not found (pass --disk=PATH)"
        return 1
    fi
    if vm_is_running; then
        pz_error "Windows VM is running; shut it down before mounting its disk on the host (risk of corruption)"
        return 1
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would guestmount $disk -> $MOUNTPOINT ($([ "$RW" = 1 ] && echo rw || echo ro))"
        return 0
    fi
    mkdir -p "$MOUNTPOINT"
    if mountpoint -q "$MOUNTPOINT"; then pz_info "already mounted: $MOUNTPOINT"; return 0; fi
    local mode=(-r); [ "$RW" = 1 ] && mode=(-w)
    if guestmount -a "$disk" -i "${mode[@]}" "$MOUNTPOINT"; then
        pz_info "Windows VM disk mounted at $MOUNTPOINT ($([ "$RW" = 1 ] && echo read-write || echo read-only))"
        pz_info "unmount when done: pz windows-vm host-access unmount"
    else
        pz_error "guestmount failed (multiple partitions? try: guestmount -a $disk -m /dev/sda2 $MOUNTPOINT)"
        return 1
    fi
}

cmd_unmount() {
    mountpoint -q "$MOUNTPOINT" || { pz_info "not mounted: $MOUNTPOINT"; return 0; }
    if command -v guestunmount >/dev/null 2>&1; then guestunmount "$MOUNTPOINT"; else fusermount -u "$MOUNTPOINT" 2>/dev/null || umount "$MOUNTPOINT"; fi
    pz_info "unmounted $MOUNTPOINT"
}

cmd_status() {
    local disk; disk="$(resolve_disk || true)"
    jq -n \
        --arg disk "${disk:-}" --arg mount "$MOUNTPOINT" \
        --argjson guestmount "$(command -v guestmount >/dev/null 2>&1 && echo true || echo false)" \
        --argjson mounted "$(mountpoint -q "$MOUNTPOINT" && echo true || echo false)" \
        --argjson vmRunning "$(vm_is_running && echo true || echo false)" \
        '{tool:"windows-vm-host-access", disk:(if $disk=="" then null else $disk end),
          mountpoint:$mount, mounted:$mounted, libguestfs:$guestmount, vmRunning:$vmRunning}'
}

case "$ACTION" in
    mount|open) cmd_mount ;;
    unmount|umount|close) cmd_unmount ;;
    status) cmd_status ;;
    dry-run|plan) PZ_DRY_RUN=1 cmd_mount ;;
    *) pz_error "usage: host-access.sh (mount [--rw] [--disk=PATH]|unmount|status|dry-run)"; exit 2 ;;
esac
