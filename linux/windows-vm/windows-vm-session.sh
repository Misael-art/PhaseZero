#!/usr/bin/env bash
# windows-vm-session.sh - SDDM session launcher for PhaseZero Windows VM
set -euo pipefail

ENV_FILE="/etc/phasezero/windows-vm.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

PZ_WINDOWS_VM_REPO="${PZ_WINDOWS_VM_REPO:-/mnt/sdcard/Projects/PhaseZero}"
PZ_BIN="$PZ_WINDOWS_VM_REPO/linux/pz"

export PZ_WINDOWS_VM_FULLSCREEN="${PZ_WINDOWS_VM_FULLSCREEN:-1}"
export PZ_WINDOWS_VM_BOOT_SESSION=1
export PZ_WINDOWS_VM_OPTIMIZE="${PZ_WINDOWS_VM_OPTIMIZE:-0}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm"
LOG_FILE="$STATE_DIR/session.log"
install -d "$STATE_DIR"
exec >>"$LOG_FILE" 2>&1
printf '%s starting Windows VM boot session\n' "$(date -Iseconds)"

if [ -x "$PZ_BIN" ]; then
    set +e
    "$PZ_BIN" windows-vm launch --fullscreen
    rc=$?
    set -e
    printf '%s Windows VM launcher exited rc=%s; falling back to desktop\n' "$(date -Iseconds)" "$rc"
fi

if [ -x /usr/bin/startkde-biglinux ]; then
    exec /usr/bin/startkde-biglinux wayland
fi
if command -v startplasma-wayland >/dev/null 2>&1; then
    exec startplasma-wayland
fi
if command -v startplasma-x11 >/dev/null 2>&1; then
    exec startplasma-x11
fi

printf 'PhaseZero Windows VM launcher missing: %s\n' "$PZ_BIN" >&2
sleep 10
exit 1
