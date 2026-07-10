#!/usr/bin/env bash
# systemd.sh - PhaseZero Linux systemd service helpers
set -euo pipefail

pz_systemd_validate_scope() {
    case "${1:-}" in
        user|system) return 0 ;;
        *) pz_error "invalid systemd scope: ${1:-empty}"; return 2 ;;
    esac
}

pz_systemd_enable() {
    local service="$1" scope="${2:-system}"
    pz_systemd_validate_scope "$scope" || return
    case "$scope" in
        user)
            systemctl --user enable --now "$service"
            ;;
        system)
            pz_admin_run systemctl enable --now "$service"
            ;;
    esac
    pz_info "enabled and started $service ($scope)"
}

pz_systemd_disable() {
    local service="$1" scope="${2:-system}"
    pz_systemd_validate_scope "$scope" || return
    case "$scope" in
        user)
            systemctl --user disable --now "$service" 2>/dev/null || true
            ;;
        system)
            pz_admin_run systemctl disable --now "$service" 2>/dev/null || true
            ;;
    esac
}

pz_systemd_status() {
    local service="$1" scope="${2:-system}"
    pz_systemd_validate_scope "$scope" || return
    case "$scope" in
        user) systemctl --user status "$service" 2>/dev/null || echo "inactive" ;;
        system) systemctl status "$service" 2>/dev/null || echo "inactive" ;;
    esac
}

pz_systemd_is_active() {
    local service="$1" scope="${2:-system}"
    pz_systemd_validate_scope "$scope" || return
    case "$scope" in
        user) systemctl --user is-active "$service" &>/dev/null ;;
        system) systemctl is-active "$service" &>/dev/null ;;
    esac
}

pz_systemd_install_unit() {
    local unit_file="$1" scope="${2:-user}"
    local target unit_name
    pz_systemd_validate_scope "$scope" || return
    [ -f "$unit_file" ] || { pz_error "systemd unit missing: $unit_file"; return 1; }
    unit_name="$(basename "$unit_file")"
    case "$scope" in
        user)
            target="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
            install -d "$target"
            install -m 0644 "$unit_file" "$target/$unit_name"
            systemctl --user daemon-reload
            ;;
        system)
            target="/etc/systemd/system"
            pz_admin_run install -d "$target"
            pz_admin_run install -m 0644 "$unit_file" "$target/$unit_name"
            pz_admin_run systemctl daemon-reload
            ;;
    esac
    pz_info "installed systemd unit: $unit_file → $target/$unit_name"
}

pz_systemd_timer_status() {
    local timer="$1"
    systemctl list-timers --all 2>/dev/null | grep "$timer" || echo "no timer: $timer"
}
