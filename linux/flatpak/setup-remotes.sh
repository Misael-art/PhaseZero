#!/usr/bin/env bash
# setup-remotes.sh - Flatpak remote/override management CLI
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/lib/flatpak.sh"

ACTION="${1:-status}"
shift 2>/dev/null || true

usage() {
    cat <<EOF
PhaseZero Flatpak management

Usage:
  pz flatpak status           Show flatpak status JSON
  pz flatpak audit            Check for remote/override/runtime conflicts
  pz flatpak audit --repair   Fix detected conflicts
  pz flatpak remotes          List configured remotes
  pz flatpak remote add <name> <url>  Add a remote
  pz flatpak remote remove <name>     Remove a remote
  pz flatpak overrides apply [--global|--app=<id>] [--steamdeck]  Apply gaming overrides
  pz flatpak overrides remove [--global|--app=<id>]  Remove gaming overrides
  pz flatpak steamdeck-compat Full Steam Deck flatpak compat setup
  pz flatpak rollback         Undo flatpak remote changes
  pz flatpak help             Show this help
EOF
}

cmd_status() {
    pz_flatpak_status
}

cmd_audit() {
    local repair=false
    for arg in "$@"; do
        [ "$arg" = "--repair" ] && repair=true
    done
    if [ "$repair" = true ]; then
        pz_flatpak_audit_repair
    else
        pz_flatpak_audit
    fi
}

cmd_remotes() {
    pz_flatpak_require || return 1
    echo "--- Flatpak Remotes ---"
    flatpak remote-list --columns=name,url,options,priority 2>/dev/null | column -t -s $'\t' 2>/dev/null || \
        flatpak remote-list --columns=name,url,options,priority
}

cmd_remote_add() {
    local name="${1:-}" url="${2:-}"
    [ -z "$name" ] || [ -z "$url" ] && { pz_error "usage: pz flatpak remote add <name> <url>"; return 1; }
    pz_flatpak_ensure_remote "$name" "$url"
}

cmd_remote_remove() {
    local name="${1:-}"
    [ -z "$name" ] && { pz_error "usage: pz flatpak remote remove <name>"; return 1; }
    pz_flatpak_remove_remote "$name"
}

cmd_overrides() {
    local action="${1:-status}"
    shift 2>/dev/null || true
    local app="" scope="user" steamdeck=false

    for arg in "$@"; do
        case "$arg" in
            --global) scope="system" ;;
            --app=*) app="${arg#--app=}" ;;
            --steamdeck) steamdeck=true ;;
        esac
    done

    case "$action" in
        apply)
            if [ "$steamdeck" = true ]; then
                pz_flatpak_override_steamdeck "$app" "$scope"
            else
                pz_flatpak_override_gaming "$app" "$scope"
            fi
            ;;
        remove)
            pz_flatpak_remove_overrides "$app" "$scope"
            ;;
        *)
            pz_error "usage: pz flatpak overrides (apply|remove) [--global] [--app=<id>] [--steamdeck]"
            return 1
            ;;
    esac
}

cmd_steamdeck_compat() {
    pz_flatpak_steamdeck_compat
}

cmd_rollback() {
    pz_flatpak_rollback
}

case "$ACTION" in
    status)           cmd_status "$@" ;;
    audit)            cmd_audit "$@" ;;
    remotes|remote-list|list) cmd_remotes "$@" ;;
    remote-add|remote-add|add)
        cmd_remote_add "${1:-}" "${2:-}"
        ;;
    remote-remove|remote-delete|remove)
        cmd_remote_remove "${1:-}"
        ;;
    overrides|override) cmd_overrides "$@" ;;
    steamdeck|steamdeck-compat|steamdeck_compat) cmd_steamdeck_compat "$@" ;;
    rollback)         cmd_rollback "$@" ;;
    help|--help|-h|"") usage ;;
    *) pz_error "unknown flatpak action: $ACTION"; usage; return 1 ;;
esac
