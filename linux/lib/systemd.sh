#!/usr/bin/env bash
# systemd.sh - PhaseZero Linux systemd service helpers
set -euo pipefail

pz_systemd_enable() {
    local service="$1" scope="${2:-system}"
    case "$scope" in
        user)
            systemctl --user enable --now "$service"
            ;;
        system)
            sudo systemctl enable --now "$service"
            ;;
    esac
    pz_info "enabled and started $service ($scope)"
}

pz_systemd_disable() {
    local service="$1" scope="${2:-system}"
    case "$scope" in
        user)
            systemctl --user disable --now "$service" 2>/dev/null || true
            ;;
        system)
            sudo systemctl disable --now "$service" 2>/dev/null || true
            ;;
    esac
}

pz_systemd_status() {
    local service="$1" scope="${2:-system}"
    case "$scope" in
        user) systemctl --user status "$service" 2>/dev/null || echo "inactive" ;;
        system) systemctl status "$service" 2>/dev/null || echo "inactive" ;;
    esac
}

pz_systemd_is_active() {
    local service="$1" scope="${2:-system}"
    case "$scope" in
        user) systemctl --user is-active "$service" &>/dev/null ;;
        system) systemctl is-active "$service" &>/dev/null ;;
    esac
}

pz_systemd_install_unit() {
    local unit_file="$1" scope="${2:-user}"
    local target
    case "$scope" in
        user) target="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/" ;;
        system) target="/etc/systemd/system/" ;;
    esac
    mkdir -p "$target"
    cp "$unit_file" "$target"
    systemctl --user daemon-reload 2>/dev/null || sudo systemctl daemon-reload
    pz_info "installed systemd unit: $unit_file → $target"
}

pz_systemd_timer_status() {
    local timer="$1"
    systemctl list-timers --all 2>/dev/null | grep "$timer" || echo "no timer: $timer"
}
