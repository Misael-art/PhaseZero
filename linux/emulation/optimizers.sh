#!/usr/bin/env bash
# Apply documented per-game emulator configurations.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"
source "$PZ_ROOT/linux/emulation/optimizers/duckstation.sh"
source "$PZ_ROOT/linux/emulation/optimizers/pcsx2.sh"
source "$PZ_ROOT/linux/emulation/optimizers/dolphin.sh"

ACTION="${1:-status}"
GAME_ID="${2:-}"

optimizer_rows() {
    cat <<'EOF'
jackie-chan|DuckStation|Jackie Chan Stuntmaster|duckstation_apply_jackie_chan
metal-gear-solid|DuckStation|Metal Gear Solid|duckstation_apply_mgs
gta-san-andreas|PCSX2|GTA San Andreas|pcsx2_apply_gta_sa
god-of-war|PCSX2|God of War|pcsx2_apply_gow1
resident-evil-4|PCSX2|Resident Evil 4|pcsx2_apply_re4
god-of-war-2|PCSX2|God of War II|pcsx2_apply_gow2
dbz-budokai-tenkaichi-3|PCSX2|DBZ Budokai Tenkaichi 3|pcsx2_apply_dbzbt3
mk-shaolin-monks|PCSX2|Mortal Kombat Shaolin Monks|pcsx2_apply_mk_shaolin
crash-twinsanity|PCSX2|Crash Twinsanity|pcsx2_apply_crash_twinsanity
onimusha-3|PCSX2|Onimusha 3|pcsx2_apply_onimusha3
super-mario-galaxy|Dolphin|Super Mario Galaxy|dolphin_apply_smg1
super-mario-galaxy-2|Dolphin|Super Mario Galaxy 2|dolphin_apply_smg2
donkey-kong-country-returns|Dolphin|Donkey Kong Country Returns|dolphin_apply_dkc_returns
gta-san-andreas-module-2|PCSX2|GTA San Andreas Module II|pcsx2_apply_gta_sa
EOF
}

apply_one() {
    local id="$1" row function
    row="$(optimizer_rows | awk -F'|' -v id="$id" '$1 == id {print; exit}')"
    [ -n "$row" ] || { pz_error "unknown game optimizer: $id"; return 2; }
    function="${row##*|}"
    "$function"
    pz_info "game optimizer applied: $id"
}

apply_all() {
    local id emulator title function
    while IFS='|' read -r id emulator title function; do "$function"; done < <(optimizer_rows)
    pz_info "all game optimizers applied"
}

status_json() {
    optimizer_rows | jq -R -s '
        split("\n") | map(select(length>0) | split("|") |
        {id:.[0],emulator:.[1],title:.[2],function:.[3]})
    '
}

case "$ACTION" in
    status|list) status_json ;;
    plan|dry-run) optimizer_rows | awk -F'|' '{print "would apply " $1 " (" $2 ": " $3 ")"}' ;;
    apply) [ -n "$GAME_ID" ] || { pz_error "game id required"; exit 2; }; apply_one "$GAME_ID" ;;
    apply-all|install|configure) apply_all ;;
    *) pz_error "usage: optimizers.sh (status|plan|apply <game-id>|apply-all)"; exit 2 ;;
esac
