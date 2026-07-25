#!/usr/bin/env bash
# launch-options.sh - Steam launch option presets for SteamOS-like Linux
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-list}"
PRESET="${2:-balanced}"

option_for_preset() {
    case "$1" in
        minimal)
            echo "gamemoderun %command%"
            ;;
        overlay)
            echo "gamemoderun mangohud %command%"
            ;;
        balanced)
            echo "MANGOHUD=1 gamemoderun %command%"
            ;;
        gamescope-720p)
            echo "gamescope -f -w 1280 -h 720 -W 1280 -H 800 --mangoapp -- gamemoderun %command%"
            ;;
        gamescope-800p)
            echo "gamescope -f -w 1280 -h 800 -W 1280 -H 800 --mangoapp -- gamemoderun %command%"
            ;;
        docked-1080p)
            echo "gamescope -f -w 1920 -h 1080 -W 1920 -H 1080 --mangoapp -- gamemoderun %command%"
            ;;
        debug)
            echo "MANGOHUD=1 MANGOHUD_CONFIG=full gamemoderun %command%"
            ;;
        *)
            return 1
            ;;
    esac
}

list_presets() {
    cat <<'EOF'
minimal        gamemode only
overlay        gamemode + mangohud wrapper
balanced       MANGOHUD=1 + gamemode
gamescope-720p handheld 720p gamescope + MangoApp
gamescope-800p handheld native 800p gamescope + MangoApp
docked-1080p   docked TV 1080p gamescope + MangoApp
debug          verbose MangoHud
EOF
}

json_presets() {
    jq -n \
        --arg minimal "$(option_for_preset minimal)" \
        --arg overlay "$(option_for_preset overlay)" \
        --arg balanced "$(option_for_preset balanced)" \
        --arg gamescope720p "$(option_for_preset gamescope-720p)" \
        --arg gamescope800p "$(option_for_preset gamescope-800p)" \
        --arg docked1080p "$(option_for_preset docked-1080p)" \
        --arg debug "$(option_for_preset debug)" \
        '{
            minimal: $minimal,
            overlay: $overlay,
            balanced: $balanced,
            "gamescope-720p": $gamescope720p,
            "gamescope-800p": $gamescope800p,
            "docked-1080p": $docked1080p,
            debug: $debug
        }'
}

case "$ACTION" in
    list) list_presets ;;
    get)
        if ! option_for_preset "$PRESET"; then
            pz_error "unknown preset: $PRESET"
            exit 1
        fi
        ;;
    json) json_presets ;;
    *) pz_error "usage: launch-options.sh (list|json|get <preset>)"; exit 1 ;;
esac
