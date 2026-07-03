#!/usr/bin/env bash
# waydroid-session.sh - resilient kiosk session launcher for Waydroid
set -euo pipefail

ENV_FILE="/etc/phasezero/waydroid.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

PZ_WAYDROID_REPO="${PZ_WAYDROID_REPO:-/mnt/sdcard/Projects/PhaseZero}"
SESSION_TARGET="/usr/local/lib/phasezero/waydroid-session"
[ -x "$SESSION_TARGET" ] || SESSION_TARGET="$PZ_WAYDROID_REPO/linux/waydroid/waydroid-session.sh"

export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-PhaseZeroWaydroid}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-phasezero-waydroid}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
export GDK_BACKEND="${GDK_BACKEND:-wayland,x11}"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland,x11}"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/waydroid"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/session.log"

log() {
    printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >> "$LOG_FILE"
}

fallback_desktop() {
    log "falling back to desktop"
    if [ -x /usr/bin/startkde-biglinux ]; then
        exec /usr/bin/startkde-biglinux wayland
    fi
    if command -v startplasma-wayland >/dev/null 2>&1; then
        exec startplasma-wayland
    fi
    if command -v startplasma-x11 >/dev/null 2>&1; then
        exec startplasma-x11
    fi
    printf 'PhaseZero Waydroid session failed; see %s\n' "$LOG_FILE" >&2
    sleep 10
    exit 1
}

wait_for_waydroid() {
    local i
    for i in $(seq 1 30); do
        waydroid status >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

start_waydroid_session() {
    if ! command -v waydroid >/dev/null 2>&1; then
        log "waydroid command missing"
        fallback_desktop
    fi
    if [ ! -e /var/lib/waydroid/waydroid_base.prop ]; then
        log "Waydroid image not initialized"
        fallback_desktop
    fi
    waydroid session start >> "$LOG_FILE" 2>&1 &
    wait_for_waydroid || log "waydroid status did not become ready before UI launch"
}

run_waydroid_ui_loop() {
    local max="${PZ_WAYDROID_SESSION_RESTARTS:-3}" attempt=0 rc=0
    start_waydroid_session
    while :; do
        attempt=$((attempt + 1))
        log "starting Waydroid full UI attempt=$attempt"
        set +e
        waydroid show-full-ui >> "$LOG_FILE" 2>&1
        rc=$?
        set -e
        log "Waydroid full UI exited rc=$rc attempt=$attempt"
        [ "$attempt" -ge "$max" ] && break
        sleep 2
    done
    fallback_desktop
}

run_compositor() {
    if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${PZ_WAYDROID_INSIDE_COMPOSITOR:-0}" = "1" ]; then
        run_waydroid_ui_loop
    fi
    if command -v cage >/dev/null 2>&1; then
        log "starting cage compositor"
        exec dbus-run-session -- env PZ_WAYDROID_INSIDE_COMPOSITOR=1 cage -- "$SESSION_TARGET"
    fi
    if command -v kwin_wayland >/dev/null 2>&1; then
        log "starting kwin_wayland compositor"
        exec dbus-run-session -- env PZ_WAYDROID_INSIDE_COMPOSITOR=1 kwin_wayland --no-lockscreen --no-global-shortcuts --xwayland --exit-with-session "$SESSION_TARGET"
    fi
    log "no supported Wayland compositor found"
    fallback_desktop
}

case "${1:-}" in
    --inside-compositor)
        export PZ_WAYDROID_INSIDE_COMPOSITOR=1
        run_waydroid_ui_loop
        ;;
    *)
        run_compositor
        ;;
esac
