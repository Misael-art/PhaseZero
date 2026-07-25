#!/usr/bin/env bash
# removable-mount-helper.sh - mount a single USB removable block device via
# udisks2, gated on the Windows VM to avoid claiming a device it passes through.
# Instantiated per-device as phasezero-removable-mount@<dev>.service.
set -uo pipefail

DEVNAME="${1:-}"
LOG_DIR="${XDG_STATE_HOME:-/var/log}/phasezero"
LOG_FILE="$LOG_DIR/removable-mount.log"

TARGET_USER="${PZ_TARGET_USER:-${SUDO_USER:-}}"
[ -z "$TARGET_USER" ] && TARGET_USER="${USER:-$(id -un)}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || true)"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"

log() {
    install -d "$LOG_DIR" 2>/dev/null || true
    printf '%s phasezero-removable-mount[%s]: %s\n' "$(date -Iseconds)" "${DEVNAME:-?}" "$*" >>"$LOG_FILE" 2>/dev/null || true
    printf 'phasezero-removable-mount: %s\n' "$*" >&2
}

vm_is_running() {
    if command -v virsh >/dev/null 2>&1; then
        [ "$(LC_ALL=C virsh domstate phasezero-windows 2>/dev/null || true)" = "running" ] && return 0
    fi
    pgrep -af 'qemu.*phasezero-windows' >/dev/null 2>&1
}

vm_session_active() {
    grep -qw 'phasezero.windowsvm=1' /proc/cmdline 2>/dev/null
}

[ -n "$DEVNAME" ] || { log "no device argument"; exit 1; }
# Accept either "sde1" or "/dev/sde1".
case "$DEVNAME" in
    /dev/*) devnode="$DEVNAME"; DEVNAME="${DEVNAME#/dev/}" ;;
    *) devnode="/dev/$DEVNAME" ;;
esac
[[ "$DEVNAME" =~ ^[A-Za-z0-9._+-]+$ ]] || { log "unsafe device name rejected"; exit 1; }
[ -b "$devnode" ] || { log "$devnode is not a block device"; exit 0; }
[ -n "$TARGET_UID" ] && [ "$TARGET_UID" -ne 0 ] && [ -n "$TARGET_HOME" ] || {
    log "invalid non-root target user: $TARGET_USER"
    exit 1
}

# Already mounted? Nothing to do.
if [ -n "$(lsblk -npo MOUNTPOINT "$devnode" 2>/dev/null)" ]; then
    log "$devnode already mounted at $(lsblk -npo MOUNTPOINT "$devnode" 2>/dev/null)"
    exit 0
fi

# Gate: never claim a device the Windows VM may be passing through. The VM's
# default usbredir mode coexists with host mounting, but --usb-mode all|peripherals
# detaches devices via usb-host; standing down while the VM runs is the safe rule.
if vm_is_running; then
    log "$devnode skipped: Windows VM is running (usb-host conflict risk)"
    exit 0
fi
if vm_session_active; then
    log "$devnode skipped: dedicated Windows-VM boot session active"
    exit 0
fi

if ! command -v udisksctl >/dev/null 2>&1; then
    log "$devnode skipped: udisksctl missing"
    exit 0
fi

log "mounting $devnode via udisks2 for $TARGET_USER"
if ! command -v runuser >/dev/null 2>&1; then
    log "$devnode skipped: runuser missing; refusing root-owned udisks mount"
    exit 0
fi
runtime_dir="/run/user/$TARGET_UID"
if runuser -u "$TARGET_USER" -- env \
    HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
    udisksctl mount --block-device "$devnode" --no-user-interaction >>"$LOG_FILE" 2>&1; then
    log "$devnode mounted at $(lsblk -npo MOUNTPOINT "$devnode" 2>/dev/null)"
    exit 0
fi

log "$devnode mount failed"
exit 0
