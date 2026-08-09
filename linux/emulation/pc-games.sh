#!/usr/bin/env bash
# pc-games.sh - integrate local PC games from roms/steam with Linux frontends.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
shift 2>/dev/null || shift 1 2>/dev/null || true

PC_TOOL="$PZ_ROOT/linux/emulation/pc-games.py"

pc_games_abort_if_launcher_running() {
    [ "${PZ_EMULATION_FORCE_APPLY:-0}" = "1" ] && return 0
    local running
    running="$(ps -eo pid=,comm=,args= 2>/dev/null | awk '
        $2 == "heroic" ||
        $2 == "Heroic" ||
        $2 == "hydra" ||
        $2 == "Hydra" ||
        $2 == "hydralauncher" ||
        $2 == "Hydra.AppImage" {
            sub(/^[[:space:]]+/, "")
            print
        }
    ' || true)"
    if [ -n "$running" ]; then
        pz_error "PC game frontend running; close Heroic/Hydra before apply/repair or set PZ_EMULATION_FORCE_APPLY=1"
        printf '%s\n' "$running" >&2
        return 2
    fi
}

case "$ACTION" in
    status)
        python3 "$PC_TOOL" status "$@"
        ;;
    plan|dry-run)
        python3 "$PC_TOOL" plan "$@"
        ;;
    apply|integrate|repair)
        pz_emulation_abort_if_frontend_running
        pc_games_abort_if_launcher_running
        pz_emulation_ensure_layout
        python3 "$PC_TOOL" "$ACTION" "$@"
        bash "$PZ_ROOT/linux/emulation/media.sh" index >/dev/null 2>&1 || pz_warn "media index update failed"
        ;;
    launch)
        python3 "$PC_TOOL" launch "$@"
        ;;
    *)
        pz_error "usage: pc-games.sh (status|plan|apply|integrate|repair|launch <slug>) [--json]"
        exit 1
        ;;
esac
