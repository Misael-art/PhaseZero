#!/usr/bin/env bash
# PhaseZero managed: Steam/SteamOS session selection hook for gamescope-session-plus.
set -uo pipefail

target="${1:-desktop}"
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phasezero-steamos"
target_file="$runtime_dir/session-target"
freeze_file="$runtime_dir/console-frozen"

install -d "$runtime_dir"

log() {
    printf 'phasezero os-session-select: %s\n' "$*" >&2
}

steamdeck_resume_session() {
    # After a wake, nudge gamescope to repaint so the frozen game returns to
    # the foreground instead of a black screen.
    if command -v gamescope-client >/dev/null 2>&1; then
        gamescope-client -r >/dev/null 2>&1 || true
    fi
}

steamdeck_suspend_host() {
    if command -v systemctl >/dev/null 2>&1 && systemctl can suspend >/dev/null 2>&1; then
        systemctl suspend
        return $?
    fi
    if command -v loginctl >/dev/null 2>&1; then
        loginctl suspend
        return $?
    fi
    return 1
}

steamdeck_toggle_console_sleep() {
    # Steam Deck-like "Desligar" in Game Mode: freeze the session (suspend) and
    # resume on the next power/input wake — not a full host poweroff.
    if [ -f "$freeze_file" ]; then
        rm -f "$freeze_file"
        log "console sleep cleared; resuming session"
        steamdeck_resume_session
        return 0
    fi

    # Install a one-shot resume hook so the freeze marker is cleared and the
    # session is repainted on wake even if this hook is not re-invoked.
    local resume_unit="phasezero-console-resume.service"
    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --user --on-active=3 --unit="$resume_unit" \
            bash -c "rm -f '$freeze_file'; '$0' shutdown >/dev/null 2>&1 || true" \
            >/dev/null 2>&1 || true
    fi

    date -Iseconds > "$freeze_file"
    log "console sleep requested; suspending host (game state preserved)"
    if ! steamdeck_suspend_host; then
        rm -f "$freeze_file"
        systemctl --user reset-failed "$resume_unit" >/dev/null 2>&1 || true
        log "suspend unavailable; refusing host poweroff (set PZ_STEAMOS_ALLOW_POWEROFF=1 to override)"
        return 1
    fi
    # Host woke back up: clear the marker and repaint so the game returns.
    rm -f "$freeze_file"
    steamdeck_resume_session
    return 0
}

steam_shutdown_after=0

case "$target" in
    plasma|desktop)
        printf 'desktop\n' > "$target_file"
        steam_shutdown_after=1
        ;;
    gamepadui|steam)
        printf 'gamepadui\n' > "$target_file"
        steam_shutdown_after=1
        ;;
    reboot)
        printf 'reboot\n' > "$target_file"
        steam_shutdown_after=1
        ;;
    shutdown|poweroff|sleep|suspend|hibernate)
        if [ "${PZ_STEAMOS_ALLOW_POWEROFF:-0}" = "1" ]; then
            printf 'shutdown\n' > "$target_file"
            steam_shutdown_after=1
        else
            steamdeck_toggle_console_sleep
            exit $?
        fi
        ;;
    *)
        printf 'desktop\n' > "$target_file"
        steam_shutdown_after=1
        ;;
esac

if [ "$steam_shutdown_after" -eq 1 ] && [ "${PZ_STEAMOS_SKIP_STEAM_SHUTDOWN:-0}" != "1" ]; then
    steam -shutdown >/dev/null 2>&1 || true
fi

# Steam occasionally acknowledges shutdown but leaves the gamescope unit alive.
if [ "$steam_shutdown_after" -eq 1 ] && [ "${PZ_STEAMOS_SKIP_STEAM_SHUTDOWN:-0}" != "1" ]; then
    nohup bash -c 'sleep 5; systemctl --user stop gamescope-session-plus@steam-plus.service gamescope-session-plus@steam.service >/dev/null 2>&1 || true' \
        >/dev/null 2>&1 &
fi

exit 0
