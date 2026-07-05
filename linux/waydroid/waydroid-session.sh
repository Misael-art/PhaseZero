#!/usr/bin/env bash
# waydroid-session.sh - resilient kiosk session launcher for Waydroid
set -euo pipefail

ENV_FILE="${PZ_WAYDROID_ENV_FILE:-/etc/phasezero/waydroid.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

CONFIGURED_REPO="${PZ_WAYDROID_REPO:-}"
PZ_WAYDROID_REPO_FALLBACK="${PZ_WAYDROID_REPO_FALLBACK:-/mnt/sdcard/Projects/PhaseZero}"
SESSION_TARGET="${PZ_WAYDROID_SESSION_TARGET:-/usr/local/lib/phasezero/waydroid-session}"

resolve_session_target() {
    local candidate
    [ -x "$SESSION_TARGET" ] && return 0
    for candidate in \
        "$CONFIGURED_REPO" \
        "$PZ_WAYDROID_REPO_FALLBACK" \
        "$HOME/Projects/PhaseZero" \
        "$HOME/PhaseZero"; do
        [ -n "$candidate" ] || continue
        if [ -x "$candidate/linux/waydroid/waydroid-session.sh" ]; then
            PZ_WAYDROID_REPO="$candidate"
            SESSION_TARGET="$candidate/linux/waydroid/waydroid-session.sh"
            return 0
        fi
    done
    return 1
}

resolve_session_target || true

if [ "${1:-}" = "--validate" ]; then
    [ -x "$SESSION_TARGET" ] && command -v waydroid >/dev/null 2>&1 || {
        printf 'waydroid_session_ready=no configured_repo=%s target=%s\n' "${CONFIGURED_REPO:-missing}" "$SESSION_TARGET"
        exit 1
    }
    printf 'waydroid_session_ready=yes configured_repo=%s target=%s\n' "${CONFIGURED_REPO:-missing}" "$SESSION_TARGET"
    exit 0
fi

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
    waydroid session stop >> "$LOG_FILE" 2>&1 || true
    log "falling back to desktop"
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

session_is_running() {
    waydroid status 2>/dev/null | grep -Eq '^Session:[[:space:]]*RUNNING$'
}

android_platform_ready() {
    waydroid app list >/dev/null 2>&1
}

wait_for_waydroid() {
    local i
    for i in $(seq 1 120); do
        session_is_running && android_platform_ready && return 0
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
    if session_is_running; then
        log "reusing running Waydroid session"
        return 0
    fi
    waydroid session stop >> "$LOG_FILE" 2>&1 || true
    waydroid session start >> "$LOG_FILE" 2>&1 &
    if ! wait_for_waydroid; then
        log "Waydroid session did not reach RUNNING state"
        return 1
    fi
    log "Waydroid Android platform ready"
}

run_waydroid_ui_loop() {
    local max="${PZ_WAYDROID_SESSION_RESTARTS:-3}" attempt=0 rc=0
    while [ "$attempt" -lt "$max" ]; do
        attempt=$((attempt + 1))
        start_waydroid_session || {
            log "Waydroid startup failed attempt=$attempt"
            sleep 3
            continue
        }
        log "starting Waydroid full UI attempt=$attempt"
        set +e
        waydroid show-full-ui >> "$LOG_FILE" 2>&1
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            log "Waydroid full UI accepted; monitoring Android session"
            while session_is_running; do
                sleep 2
            done
            log "Waydroid session stopped after UI launch"
        else
            log "Waydroid full UI failed rc=$rc attempt=$attempt"
        fi
        waydroid session stop >> "$LOG_FILE" 2>&1 || true
        sleep 3
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
