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
    ledger_record \
        --module "${PZ_MODULE:-systemd}" \
        --action enable-service \
        --service "$scope:$service" \
        --scope "$scope" \
        --reversible true \
        --rollback-cmd "$([ "$scope" = user ] && echo 'systemctl --user' || echo 'systemctl') disable --now $(printf '%q' "$service")"
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
    local target unit_name backup="" existed=0
    pz_systemd_validate_scope "$scope" || return
    [ -f "$unit_file" ] || { pz_error "systemd unit missing: $unit_file"; return 1; }
    unit_name="$(basename "$unit_file")"
    case "$scope" in
        user)
            target="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
            install -d "$target"
            [ -f "$target/$unit_name" ] && existed=1
            backup="$(pz_backup_file "$target/$unit_name" user)"
            install -m 0644 "$unit_file" "$target/$unit_name"
            systemctl --user daemon-reload
            ;;
        system)
            target="/etc/systemd/system"
            pz_admin_run install -d "$target"
            [ -f "$target/$unit_name" ] && existed=1
            backup="$(pz_backup_file "$target/$unit_name" root)"
            pz_admin_run install -m 0644 "$unit_file" "$target/$unit_name"
            pz_admin_run systemctl daemon-reload
            ;;
    esac
    if [ "$existed" = "1" ]; then
        ledger_record --module "${PZ_MODULE:-systemd}" --action install-unit \
            --modified "$target/$unit_name" ${backup:+--backup "$backup"} \
            --service "$scope:$unit_name" --scope "$scope" --reversible true \
            --rollback-cmd "cp -p -- $(printf '%q' "${backup:-}") $(printf '%q' "$target/$unit_name")"
    else
        ledger_record --module "${PZ_MODULE:-systemd}" --action install-unit \
            --created "$target/$unit_name" \
            --service "$scope:$unit_name" --scope "$scope" --reversible true \
            --rollback-cmd "rm -f -- $(printf '%q' "$target/$unit_name")"
    fi
    pz_info "installed systemd unit: $unit_file → $target/$unit_name"
}

pz_systemd_timer_status() {
    local timer="$1"
    systemctl list-timers --all 2>/dev/null | grep "$timer" || echo "no timer: $timer"
}
