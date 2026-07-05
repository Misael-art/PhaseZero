#!/usr/bin/env bash
# windows-vm-session.sh - SDDM session launcher for PhaseZero Windows VM
set -euo pipefail

ENV_FILE="${PZ_WINDOWS_VM_ENV_FILE:-/etc/phasezero/windows-vm.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

CONFIGURED_REPO="${PZ_WINDOWS_VM_REPO:-}"
PZ_WINDOWS_VM_REPO_FALLBACK="${PZ_WINDOWS_VM_REPO_FALLBACK:-/mnt/sdcard/Projects/PhaseZero}"

resolve_pz_bin() {
    local candidate
    for candidate in \
        "$CONFIGURED_REPO" \
        "$PZ_WINDOWS_VM_REPO_FALLBACK" \
        "$HOME/Projects/PhaseZero" \
        "$HOME/PhaseZero"; do
        [ -n "$candidate" ] || continue
        if [ -x "$candidate/linux/pz" ]; then
            PZ_WINDOWS_VM_REPO="$candidate"
            PZ_BIN="$candidate/linux/pz"
            return 0
        fi
    done
    if command -v pz >/dev/null 2>&1; then
        PZ_WINDOWS_VM_REPO=""
        PZ_BIN="$(command -v pz)"
        return 0
    fi
    PZ_WINDOWS_VM_REPO="$CONFIGURED_REPO"
    PZ_BIN="${CONFIGURED_REPO:+$CONFIGURED_REPO/linux/pz}"
    return 1
}

PZ_BIN=""
resolve_pz_bin || true

if [ "${1:-}" = "--validate" ]; then
    [ -n "$PZ_BIN" ] && [ -x "$PZ_BIN" ] || {
        printf 'windows_vm_session_ready=no configured_repo=%s\n' "${CONFIGURED_REPO:-missing}"
        exit 1
    }
    printf 'windows_vm_session_ready=yes repo=%s launcher=%s\n' "${PZ_WINDOWS_VM_REPO:-PATH}" "$PZ_BIN"
    exit 0
fi

export PZ_WINDOWS_VM_FULLSCREEN="${PZ_WINDOWS_VM_FULLSCREEN:-1}"
export PZ_WINDOWS_VM_BOOT_SESSION=1
export PZ_WINDOWS_VM_OPTIMIZE="${PZ_WINDOWS_VM_OPTIMIZE:-0}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm"
LOG_FILE="$STATE_DIR/session.log"
install -d "$STATE_DIR"
exec >>"$LOG_FILE" 2>&1
printf '%s starting Windows VM boot session\n' "$(date -Iseconds)"

if [ -n "$CONFIGURED_REPO" ] && [ "$CONFIGURED_REPO" != "${PZ_WINDOWS_VM_REPO:-}" ]; then
    printf '%s stale configured repo %s; using %s\n' "$(date -Iseconds)" "$CONFIGURED_REPO" "${PZ_WINDOWS_VM_REPO:-PATH}"
fi

if [ -n "$PZ_BIN" ] && [ -x "$PZ_BIN" ]; then
    set +e
    "$PZ_BIN" windows-vm launch --fullscreen
    rc=$?
    set -e
    printf '%s Windows VM launcher exited rc=%s; falling back to desktop\n' "$(date -Iseconds)" "$rc"
else
    printf '%s Windows VM launcher missing; configured repo=%s\n' "$(date -Iseconds)" "${CONFIGURED_REPO:-missing}"
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
