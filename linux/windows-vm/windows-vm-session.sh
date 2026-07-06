#!/usr/bin/env bash
# windows-vm-session.sh - SDDM session launcher for PhaseZero Windows VM
set -euo pipefail

ENV_FILE="${PZ_WINDOWS_VM_ENV_FILE:-/etc/phasezero/windows-vm.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

CONFIGURED_REPO="${PZ_WINDOWS_VM_REPO:-}"
PZ_WINDOWS_VM_REPO_FALLBACK="${PZ_WINDOWS_VM_REPO_FALLBACK:-/mnt/sdcard/Projects/PhaseZero}"
RUNTIME_LAUNCHER="${PZ_WINDOWS_VM_RUNTIME_LAUNCHER:-/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/windows-vm.sh}"
RETRY_SECONDS="${PZ_WINDOWS_VM_SESSION_RETRY_SECONDS:-5}"
DESKTOP_FALLBACK="${PZ_WINDOWS_VM_DESKTOP_FALLBACK:-0}"
LAUNCHER_KIND=""
LAUNCHER_ARGS=()

resolve_launcher() {
    local candidate
    if [ -x "$RUNTIME_LAUNCHER" ]; then
        PZ_WINDOWS_VM_REPO=""
        PZ_BIN="$RUNTIME_LAUNCHER"
        LAUNCHER_KIND="runtime"
        LAUNCHER_ARGS=(launch --fullscreen)
        return 0
    fi
    for candidate in \
        "$CONFIGURED_REPO" \
        "$PZ_WINDOWS_VM_REPO_FALLBACK" \
        "$HOME/Projects/PhaseZero" \
        "$HOME/PhaseZero"; do
        [ -n "$candidate" ] || continue
        if [ -x "$candidate/linux/pz" ]; then
            PZ_WINDOWS_VM_REPO="$candidate"
            PZ_BIN="$candidate/linux/pz"
            LAUNCHER_KIND="dispatcher"
            LAUNCHER_ARGS=(windows-vm launch --fullscreen)
            return 0
        fi
    done
    if command -v pz >/dev/null 2>&1; then
        PZ_WINDOWS_VM_REPO=""
        PZ_BIN="$(command -v pz)"
        LAUNCHER_KIND="dispatcher"
        LAUNCHER_ARGS=(windows-vm launch --fullscreen)
        return 0
    fi
    PZ_WINDOWS_VM_REPO="$CONFIGURED_REPO"
    PZ_BIN="${CONFIGURED_REPO:+$CONFIGURED_REPO/linux/pz}"
    return 1
}

PZ_BIN=""
resolve_launcher || true

launcher_command() {
    printf '%q ' "$PZ_BIN" "${LAUNCHER_ARGS[@]}"
}

if [ "${1:-}" = "--validate" ]; then
    [ -n "$PZ_BIN" ] && [ -x "$PZ_BIN" ] && [ -n "$LAUNCHER_KIND" ] || {
        printf 'windows_vm_session_ready=no configured_repo=%s\n' "${CONFIGURED_REPO:-missing}"
        exit 1
    }
    printf 'windows_vm_session_ready=yes repo=%s launcher=%s launcher_kind=%s command=%s\n' \
        "${PZ_WINDOWS_VM_REPO:-runtime}" "$PZ_BIN" "$LAUNCHER_KIND" "$(launcher_command)"
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

# SDDM Wayland sessions start without a compositor; spicy/virt-viewer/QEMU-gtk
# need one or they die with "gtk initialization failed" (black screen).
# PZ_WINDOWS_VM_COMPOSITOR=0 skips the wrap (tests, external compositor).
if [ "${PZ_WINDOWS_VM_COMPOSITOR:-auto}" != "0" ] \
    && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ] \
    && [ "${PZ_WINDOWS_VM_INSIDE_COMPOSITOR:-0}" != "1" ]; then
    if command -v cage >/dev/null 2>&1; then
        printf '%s starting cage compositor for VM viewer\n' "$(date -Iseconds)"
        exec dbus-run-session -- env PZ_WINDOWS_VM_INSIDE_COMPOSITOR=1 cage -- "$0"
    fi
    if command -v kwin_wayland >/dev/null 2>&1; then
        printf '%s starting kwin_wayland compositor for VM viewer\n' "$(date -Iseconds)"
        exec dbus-run-session -- env PZ_WINDOWS_VM_INSIDE_COMPOSITOR=1 \
            kwin_wayland --no-lockscreen --no-global-shortcuts --xwayland --exit-with-session "$0"
    fi
    printf '%s no compositor available (cage/kwin_wayland); viewer may fail\n' "$(date -Iseconds)"
fi

if [ -n "$CONFIGURED_REPO" ] && [ "$CONFIGURED_REPO" != "${PZ_WINDOWS_VM_REPO:-}" ]; then
    printf '%s stale configured repo %s; using %s\n' \
        "$(date -Iseconds)" "$CONFIGURED_REPO" "${PZ_WINDOWS_VM_REPO:-$LAUNCHER_KIND}"
fi

case "$RETRY_SECONDS" in
    ""|*[!0-9]*) RETRY_SECONDS=5 ;;
esac
[ "$RETRY_SECONDS" -ge 1 ] || RETRY_SECONDS=1

fallback_desktop() {
    [ "$DESKTOP_FALLBACK" = "1" ] || return 1
    printf '%s explicit desktop fallback enabled\n' "$(date -Iseconds)"
    if command -v startplasma-wayland >/dev/null 2>&1; then
        exec startplasma-wayland
    fi
    if command -v startplasma-x11 >/dev/null 2>&1; then
        exec startplasma-x11
    fi
    return 1
}

attempt=0
while :; do
    attempt=$((attempt + 1))
    if [ -n "$PZ_BIN" ] && [ -x "$PZ_BIN" ] && [ -n "$LAUNCHER_KIND" ]; then
        printf '%s launching Windows VM attempt=%s kind=%s command=%s\n' \
            "$(date -Iseconds)" "$attempt" "$LAUNCHER_KIND" "$(launcher_command)"
        set +e
        "$PZ_BIN" "${LAUNCHER_ARGS[@]}"
        rc=$?
        set -e
        printf '%s Windows VM launcher exited rc=%s attempt=%s; retrying in %ss\n' \
            "$(date -Iseconds)" "$rc" "$attempt" "$RETRY_SECONDS"
    else
        rc=127
        printf '%s Windows VM launcher missing attempt=%s configured_repo=%s; retrying in %ss\n' \
            "$(date -Iseconds)" "$attempt" "${CONFIGURED_REPO:-missing}" "$RETRY_SECONDS"
    fi
    fallback_desktop || true
    sleep "$RETRY_SECONDS"
done
