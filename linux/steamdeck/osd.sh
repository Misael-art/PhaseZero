#!/usr/bin/env bash
# osd.sh - discreet on-screen feedback for PhaseZero hotkeys and actions.
# Uses Plasma's native OSD (the same overlay as volume/brightness), falling
# back to a transient notification, then to a log line.
set -euo pipefail

OSD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSD_PZ_ROOT="$(cd "$OSD_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$OSD_PZ_ROOT/linux/lib/common.sh"

pz_osd_show() {
    local icon="${1:-preferences-desktop-keyboard}" text="${2:-PhaseZero}"

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would show OSD: $text"
        return 0
    fi

    if command -v qdbus6 >/dev/null 2>&1 &&
        qdbus6 org.kde.plasmashell /org/kde/osdService \
            org.kde.osdService.showText "$icon" "$text" >/dev/null 2>&1; then
        return 0
    fi

    if command -v notify-send >/dev/null 2>&1; then
        notify-send --app-name=PhaseZero --icon="$icon" --expire-time=2500 \
            --transient "PhaseZero" "$text" >/dev/null 2>&1 && return 0
    fi

    pz_info "OSD unavailable: $text"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    pz_osd_show "${1:-}" "${2:-}"
fi
