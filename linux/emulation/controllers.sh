#!/usr/bin/env bash
# controllers.sh - apply the default Steam Deck controller profile to emulators
# that don't ship one wired to the Deck's pad.
#
# On the Deck the built-in controls reach emulators through Steam Input, which
# presents a virtual controller (vendor 28de, "Steam Deck"/Steam Input pad).
# EmuDeck ships reference profiles targeting exactly that pad; PhaseZero had no
# controller-config step, so e.g. Ryujinx stayed bound to whatever random GUID
# was detected first (here 1949:0204) and the Deck controls did nothing. This
# aligns Ryujinx + RPCS3 to EmuDeck's Deck reference (backups on).
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
EMUDECK_CFG="$HOME/.config/EmuDeck/backend/configs"

# --- Ryujinx ----------------------------------------------------------------
RYUJINX_REF="$EMUDECK_CFG/Ryujinx/Config.json"
ryujinx_active_configs() {
    local p
    for p in \
        "$HOME/.config/Ryujinx/Config.json" \
        "$HOME/.config/ryujinx/Config.json" \
        "$HOME/.var/app/org.ryujinx.Ryujinx/config/Ryujinx/Config.json"; do
        if [ -f "$p" ]; then printf '%s\n' "$p"; fi
    done | awk '!seen[$0]++'
}

apply_ryujinx() {
    [ -f "$RYUJINX_REF" ] || { pz_warn "Ryujinx: EmuDeck reference missing ($RYUJINX_REF); skipped"; return 0; }
    jq -e '.input_config | type == "array" and length > 0' "$RYUJINX_REF" >/dev/null 2>&1 || {
        pz_warn "Ryujinx: EmuDeck reference has no usable input_config; skipped"; return 0; }
    local ref_input cfg tmp changed=0
    ref_input="$(jq -c '.input_config' "$RYUJINX_REF")"
    while IFS= read -r cfg; do
        [ -n "$cfg" ] || continue
        jq empty "$cfg" >/dev/null 2>&1 || { pz_warn "Ryujinx: $cfg not valid JSON; skipped"; continue; }
        # Already the Deck (Valve 28de) pad? leave it.
        if jq -e '.input_config[0].id? // "" | test("-28de-")' "$cfg" >/dev/null 2>&1; then
            pz_info "Ryujinx: $cfg already on the Steam Deck pad"
            continue
        fi
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would set Ryujinx input_config -> Steam Deck pad in $cfg"; continue
        fi
        cp "$cfg" "$cfg.phasezero.bak.$(date +%s)"
        tmp="$(mktemp)"
        # Preserve every other key; only swap the controller binding.
        jq --argjson input "$ref_input" '.input_config = $input' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
        pz_info "Ryujinx: input_config -> Steam Deck pad (28de) in $cfg"
        changed=1
    done < <(ryujinx_active_configs)
    [ "$changed" = 1 ] || pz_info "Ryujinx: no change needed"
}

# --- RPCS3 ------------------------------------------------------------------
RPCS3_REF="$EMUDECK_CFG/rpcs3/input_configs/global/Default.yml"
rpcs3_active_dirs() {
    local p
    for p in \
        "$HOME/.config/rpcs3/input_configs" \
        "$HOME/.var/app/net.rpcs3.RPCS3/config/rpcs3/input_configs"; do
        if [ -d "$p" ]; then printf '%s\n' "$p"; fi
    done | awk '!seen[$0]++'
}

apply_rpcs3() {
    [ -f "$RPCS3_REF" ] || { pz_warn "RPCS3: EmuDeck reference missing ($RPCS3_REF); skipped"; return 0; }
    local dir target changed=0
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        target="$dir/global/Default.yml"
        install -d "$dir/global"
        if [ -f "$target" ] && cmp -s "$RPCS3_REF" "$target"; then
            pz_info "RPCS3: $target already matches Deck reference"
        elif [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would copy Deck pad profile -> $target"; changed=1
        else
            [ -f "$target" ] && cp "$target" "$target.phasezero.bak.$(date +%s)"
            cp "$RPCS3_REF" "$target"
            pz_info "RPCS3: Deck pad profile -> $target"
            changed=1
        fi
        # Make sure the global slot actually selects Default.
        if [ "${PZ_DRY_RUN:-0}" != "1" ]; then
            printf 'Active Profiles:\n  global: Default\n' > "$dir/active_profiles.yml"
        fi
    done < <(rpcs3_active_dirs)
    [ "$changed" = 1 ] || pz_info "RPCS3: no change needed"
}

status_json() {
    local ry_ref=false ry_deck=false rp_ref=false rp_match=false cfg
    [ -f "$RYUJINX_REF" ] && ry_ref=true || true
    cfg="$(ryujinx_active_configs)"; cfg="${cfg%%$'\n'*}"
    if [ -n "$cfg" ] && jq -e '.input_config[0].id? // "" | test("-28de-")' "$cfg" >/dev/null 2>&1; then ry_deck=true; fi
    [ -f "$RPCS3_REF" ] && rp_ref=true || true
    if [ -f "$HOME/.config/rpcs3/input_configs/global/Default.yml" ] && cmp -s "$RPCS3_REF" "$HOME/.config/rpcs3/input_configs/global/Default.yml" 2>/dev/null; then rp_match=true; fi
    jq -n --argjson ryRef "$ry_ref" --argjson ryDeck "$ry_deck" --argjson rpRef "$rp_ref" --argjson rpMatch "$rp_match" \
        --arg ryCfg "${cfg:-}" \
        '{tool:"emulator-controllers",
          ryujinx:{referenceAvailable:$ryRef, activeConfig:$ryCfg, onSteamDeckPad:$ryDeck},
          rpcs3:{referenceAvailable:$rpRef, matchesDeckReference:$rpMatch}}'
}

case "$ACTION" in
    apply|configure|repair) apply_ryujinx; apply_rpcs3; pz_info "controller profiles applied (launch emulators via Steam Input for the Deck pad)" ;;
    ryujinx) apply_ryujinx ;;
    rpcs3) apply_rpcs3 ;;
    status) status_json ;;
    dry-run|plan) PZ_DRY_RUN=1 apply_ryujinx; PZ_DRY_RUN=1 apply_rpcs3 ;;
    *) pz_error "usage: controllers.sh (apply|ryujinx|rpcs3|status|dry-run)"; exit 2 ;;
esac
