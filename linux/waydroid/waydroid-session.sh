#!/usr/bin/env bash
# waydroid-session.sh - resilient kiosk session launcher for Waydroid
set -euo pipefail

ENV_FILE="${PZ_WAYDROID_ENV_FILE:-/etc/phasezero/waydroid.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

CONFIGURED_REPO="${PZ_WAYDROID_REPO:-}"
PZ_WAYDROID_REPO_FALLBACK="${PZ_WAYDROID_REPO_FALLBACK:-/mnt/sdcard/Projects/PhaseZero}"
SESSION_TARGET="${PZ_WAYDROID_SESSION_TARGET:-/usr/local/lib/phasezero/waydroid-session}"
DISPLAY_SESSION_HELPER="${PZ_DISPLAY_SESSION_HELPER:-/usr/local/lib/phasezero/display-session}"
DESKTOP_FALLBACK="${PZ_WAYDROID_DESKTOP_FALLBACK:-0}"

load_display_session_helper() {
    local candidate
    for candidate in \
        "$DISPLAY_SESSION_HELPER" \
        "$CONFIGURED_REPO/linux/steamdeck/display-session.sh" \
        "$PZ_WAYDROID_REPO_FALLBACK/linux/steamdeck/display-session.sh" \
        "$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/steamdeck/display-session.sh"; do
        [ -n "$candidate" ] || continue
        if [ -r "$candidate" ]; then
            # shellcheck disable=SC1090
            . "$candidate"
            return 0
        fi
    done

    pz_display_profile() { printf '%s\n' "generic"; }
    pz_display_external_connectors_csv() { printf '%s\n' ""; }
    pz_display_gamescope_orientation() { printf '%s\n' "${PZ_STEAMDECK_LCD_ORIENTATION:-right}"; }
    pz_display_gamescope_width() { printf '%s\n' "${PZ_STEAMDECK_LCD_LOGICAL_WIDTH:-1280}"; }
    pz_display_gamescope_height() { printf '%s\n' "${PZ_STEAMDECK_LCD_LOGICAL_HEIGHT:-800}"; }
    pz_display_shell_join() {
        local out="" arg
        for arg in "$@"; do
            printf -v arg '%q' "$arg"
            out="${out:+$out }$arg"
        done
        printf '%s\n' "$out"
    }
}

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
load_display_session_helper

display_profile() {
    pz_display_profile
}

external_connectors() {
    pz_display_external_connectors_csv
}

session_has_display() {
    [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ] || [ "${PZ_WAYDROID_INSIDE_COMPOSITOR:-0}" = "1" ]
}

compositor_kind() {
    local requested="${PZ_WAYDROID_COMPOSITOR:-auto}" profile
    session_has_display && { printf '%s\n' "existing-session"; return 0; }
    [ "$requested" = "0" ] && { printf '%s\n' "none"; return 0; }
    profile="$(display_profile)"

    case "$requested" in
        gamescope)
            command -v gamescope >/dev/null 2>&1 && printf '%s\n' "gamescope" || printf '%s\n' "missing-gamescope"
            return 0
            ;;
        kwin|kwin_wayland)
            command -v kwin_wayland >/dev/null 2>&1 && printf '%s\n' "kwin" || printf '%s\n' "missing-kwin"
            return 0
            ;;
        cage)
            command -v cage >/dev/null 2>&1 && printf '%s\n' "cage" || printf '%s\n' "missing-cage"
            return 0
            ;;
    esac

    if [ "$profile" = "steamdeck-lcd-handheld" ]; then
        if command -v gamescope >/dev/null 2>&1; then
            printf '%s\n' "gamescope"
        elif command -v kwin_wayland >/dev/null 2>&1; then
            printf '%s\n' "kwin"
        elif [ "${PZ_STEAMDECK_HANDHELD_ALLOW_CAGE:-0}" = "1" ] && command -v cage >/dev/null 2>&1; then
            printf '%s\n' "cage"
        else
            printf '%s\n' "none"
        fi
        return 0
    fi

    if command -v cage >/dev/null 2>&1; then
        printf '%s\n' "cage"
    elif command -v kwin_wayland >/dev/null 2>&1; then
        printf '%s\n' "kwin"
    else
        printf '%s\n' "none"
    fi
}

compositor_reason() {
    case "$1" in
        existing-session) printf '%s\n' "display-already-present" ;;
        gamescope) printf '%s\n' "steamdeck-lcd-handheld-landscape" ;;
        kwin) printf '%s\n' "fallback-kwin-wayland" ;;
        cage)
            if [ "$(display_profile)" = "steamdeck-lcd-handheld" ]; then
                printf '%s\n' "explicit-handheld-cage-fallback"
            else
                printf '%s\n' "default-kiosk-compositor"
            fi
            ;;
        missing-*) printf '%s\n' "requested-compositor-missing" ;;
        none) printf '%s\n' "no-compositor-wrap" ;;
        *) printf '%s\n' "unknown" ;;
    esac
}

compositor_command() {
    local kind="$1"
    case "$kind" in
        gamescope)
            pz_display_shell_join \
                dbus-run-session -- env PZ_WAYDROID_INSIDE_COMPOSITOR=1 gamescope \
                --backend drm \
                --expose-wayland \
                --force-orientation "$(pz_display_gamescope_orientation)" \
                -W "$(pz_display_gamescope_width)" \
                -H "$(pz_display_gamescope_height)" \
                -w "$(pz_display_gamescope_width)" \
                -h "$(pz_display_gamescope_height)" \
                --force-windows-fullscreen \
                -- "$SESSION_TARGET"
            ;;
        cage)
            pz_display_shell_join dbus-run-session -- env PZ_WAYDROID_INSIDE_COMPOSITOR=1 cage -- "$SESSION_TARGET"
            ;;
        kwin)
            pz_display_shell_join dbus-run-session -- env PZ_WAYDROID_INSIDE_COMPOSITOR=1 \
                kwin_wayland --no-lockscreen --no-global-shortcuts --xwayland --exit-with-session "$SESSION_TARGET"
            ;;
        *) printf '%s\n' "" ;;
    esac
}

if [ "${1:-}" = "--validate" ]; then
    kind="$(compositor_kind)"
    [ -x "$SESSION_TARGET" ] && command -v waydroid >/dev/null 2>&1 || {
        printf 'waydroid_session_ready=no configured_repo=%s target=%s display_profile=%s external_connectors=%s compositor=%s reason=%s\n' \
            "${CONFIGURED_REPO:-missing}" "$SESSION_TARGET" "$(display_profile)" "$(external_connectors)" "$kind" "$(compositor_reason "$kind")"
        exit 1
    }
    printf 'waydroid_session_ready=yes configured_repo=%s target=%s display_profile=%s external_connectors=%s compositor=%s compositor_command=%s reason=%s\n' \
        "${CONFIGURED_REPO:-missing}" "$SESSION_TARGET" "$(display_profile)" "$(external_connectors)" \
        "$kind" "$(compositor_command "$kind")" "$(compositor_reason "$kind")"
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
    if [ "$DESKTOP_FALLBACK" != "1" ]; then
        log "desktop fallback disabled; staying in dedicated Waydroid session"
        sleep 10
        return 1
    fi
    log "explicit desktop fallback enabled"
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
        return 1
    fi
    if [ ! -e /var/lib/waydroid/waydroid_base.prop ]; then
        log "Waydroid image not initialized"
        fallback_desktop
        return 1
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
    local max="${PZ_WAYDROID_SESSION_RESTARTS:-3}" attempt rc=0
    case "$max" in ""|*[!0-9]*) max=3 ;; esac
    [ "$max" -ge 1 ] || max=1
    while :; do
        attempt=0
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
        fallback_desktop || true
    done
}

run_compositor() {
    local kind
    if session_has_display; then
        log "display_profile=$(display_profile) external_connectors=$(external_connectors) compositor=existing-session reason=display-already-present"
        run_waydroid_ui_loop
    fi
    kind="$(compositor_kind)"
    log "display_profile=$(display_profile) external_connectors=$(external_connectors) compositor=$kind reason=$(compositor_reason "$kind") command=$(compositor_command "$kind")"
    case "$kind" in
        gamescope)
            exec dbus-run-session -- env PZ_WAYDROID_INSIDE_COMPOSITOR=1 gamescope \
                --backend drm \
                --expose-wayland \
                --force-orientation "$(pz_display_gamescope_orientation)" \
                -W "$(pz_display_gamescope_width)" \
                -H "$(pz_display_gamescope_height)" \
                -w "$(pz_display_gamescope_width)" \
                -h "$(pz_display_gamescope_height)" \
                --force-windows-fullscreen \
                -- "$SESSION_TARGET"
            ;;
        cage)
            exec dbus-run-session -- env PZ_WAYDROID_INSIDE_COMPOSITOR=1 cage -- "$SESSION_TARGET"
            ;;
        kwin)
            exec dbus-run-session -- env PZ_WAYDROID_INSIDE_COMPOSITOR=1 kwin_wayland --no-lockscreen --no-global-shortcuts --xwayland --exit-with-session "$SESSION_TARGET"
            ;;
        missing-*)
            log "requested compositor unavailable: $kind"
            ;;
    esac
    fallback_desktop || exit 1
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
