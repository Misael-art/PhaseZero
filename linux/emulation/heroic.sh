#!/usr/bin/env bash
# heroic.sh - tune Heroic defaults and KDE menu hygiene.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
PZ_HEROIC_TOOL="$PZ_ROOT/linux/emulation/heroic.py"

heroic_python() {
    python3 "$PZ_HEROIC_TOOL" "$@"
}

heroic_abort_if_running() {
    [ "${PZ_EMULATION_FORCE_APPLY:-0}" = "1" ] && return 0
    local running
    running="$(ps -eo pid=,comm=,args= 2>/dev/null | awk '
        $2 == "heroic" ||
        $2 == "Heroic" ||
        $2 == "heroic-games-launcher" {
            sub(/^[[:space:]]+/, "")
            print
        }
    ' || true)"
    if [ -n "$running" ]; then
        pz_error "Heroic running; close it before repair or set PZ_EMULATION_FORCE_APPLY=1"
        printf '%s\n' "$running" >&2
        return 2
    fi
}

cmd_repair() {
    heroic_abort_if_running
    pz_emulation_ensure_layout
    heroic_python repair
    pz_info "Heroic optimized and KDE menu organized"
}

case "$ACTION" in
    status) shift || true; heroic_python status "$@" ;;
    plan|dry-run) heroic_python plan ;;
    repair|apply|optimize|configure) cmd_repair ;;
    session) shift || true; heroic_python session "$@" ;;
    *)
        pz_error "usage: heroic.sh (status|plan|repair|session)"
        exit 1
        ;;
esac
