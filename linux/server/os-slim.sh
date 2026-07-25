#!/usr/bin/env bash
# os-slim.sh - reversible RAM/footprint reduction for a headless server host.
#
# Stops+disables a curated list of desktop/peripheral services that a home
# server does not need, recording exactly what was changed so `restore` puts the
# host back. This is the "SO enxugado, reversível" from the server profiles. It
# is intentionally conservative: the display manager is only touched with
# --aggressive, and nothing is *masked* (so a normal reboot always recovers).
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

STATE_DIR="${PZ_STATE:-$HOME/.local/state/phasezero}/server"
STATE_FILE="$STATE_DIR/os-slim.json"

# Safe to stop on a headless box; each only acted on if present+enabled.
SLIM_SERVICES=(
    bluetooth.service
    cups.service cups.socket cups.path
    avahi-daemon.service avahi-daemon.socket
    ModemManager.service
    packagekit.service
    power-profiles-daemon.service
    switcheroo-control.service
    geoclue.service
    colord.service
)
# Only with --aggressive (kills the desktop -> biggest RAM win, still reversible).
AGGRESSIVE_SERVICES=(sddm.service gdm.service lightdm.service)

admin_run() {
    if pz_can_sudo_noninteractive; then sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then phasezero-admin "$@"
    else return 127; fi
}

target_services() {
    printf '%s\n' "${SLIM_SERVICES[@]}"
    [ "${1:-}" = "--aggressive" ] && printf '%s\n' "${AGGRESSIVE_SERVICES[@]}"
}

cmd_apply() {
    local aggressive=""; [ "${1:-}" = "--aggressive" ] && aggressive="--aggressive"
    install -d "$STATE_DIR"
    local acted=() svc
    while IFS= read -r svc; do
        systemctl list-unit-files "$svc" >/dev/null 2>&1 || continue
        systemctl is-enabled "$svc" >/dev/null 2>&1 || systemctl is-active "$svc" >/dev/null 2>&1 || continue
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would stop+disable $svc"
            continue
        fi
        if admin_run systemctl disable --now "$svc" >/dev/null 2>&1; then
            acted+=("$svc")
            pz_info "slimmed: $svc (stopped+disabled)"
        else
            pz_warn "could not disable $svc (need root?)"
        fi
    done < <(target_services $aggressive)

    [ "${PZ_DRY_RUN:-0}" = "1" ] && return 0
    printf '%s\n' "${acted[@]:-}" | jq -R . | jq -cs \
        --arg at "$(date -Iseconds)" '{tool:"os-slim", disabledAt:$at, disabled:map(select(length>0))}' \
        > "$STATE_FILE"
    pz_info "recorded ${#acted[@]} slimmed services -> $STATE_FILE (revert: pz server slim restore)"
}

cmd_restore() {
    [ -f "$STATE_FILE" ] || { pz_warn "no os-slim state to restore ($STATE_FILE)"; return 0; }
    local svc
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then pz_info "dry-run: would re-enable $svc"; continue; fi
        admin_run systemctl enable --now "$svc" >/dev/null 2>&1 && pz_info "restored: $svc" || pz_warn "could not restore $svc"
    done < <(jq -r '.disabled[]?' "$STATE_FILE" 2>/dev/null)
    [ "${PZ_DRY_RUN:-0}" = "1" ] || { rm -f "$STATE_FILE"; pz_info "os-slim reverted; state cleared"; }
}

cmd_status() {
    local applied=false
    [ -f "$STATE_FILE" ] && applied=true
    jq -n --argjson applied "$applied" \
        --slurpfile s <(cat "$STATE_FILE" 2>/dev/null || echo '{}') \
        '{tool:"os-slim", applied:$applied, state:($s[0] // {})}'
}

case "${1:-status}" in
    apply|slim) shift 2>/dev/null || true; cmd_apply "${1:-}" ;;
    restore|revert) cmd_restore ;;
    status) cmd_status ;;
    dry-run|plan) shift 2>/dev/null || true; PZ_DRY_RUN=1 cmd_apply "${1:-}" ;;
    *) pz_error "usage: os-slim.sh (apply [--aggressive]|restore|status|dry-run)"; exit 2 ;;
esac
