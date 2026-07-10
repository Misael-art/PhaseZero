#!/usr/bin/env bash
# controllers.sh - safely align emulator profiles with Steam Deck/Steam Input.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
EMUDECK_CFG="${PZ_EMUDECK_CONFIG_ROOT:-$HOME/.config/EmuDeck/backend/configs}"
RYUJINX_REF="$EMUDECK_CFG/Ryujinx/Config.json"
RPCS3_REF="$EMUDECK_CFG/rpcs3/input_configs/global/Default.yml"

backup_file() {
    local path="$1" backup
    [ -f "$path" ] || return 0
    backup="$path.phasezero.bak.$(date +%s%N).$$"
    cp -p -- "$path" "$backup"
}

atomic_jq() {
    local path="$1"
    shift
    local tmp
    tmp="$(mktemp "${path}.phasezero.tmp.XXXXXX")"
    if jq "$@" "$path" > "$tmp"; then
        chmod --reference="$path" "$tmp" 2>/dev/null || true
        mv -f -- "$tmp" "$path"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

ryujinx_active_configs() {
    local path
    for path in \
        "$HOME/.config/Ryujinx/Config.json" \
        "$HOME/.config/ryujinx/Config.json" \
        "$HOME/.var/app/org.ryujinx.Ryujinx/config/Ryujinx/Config.json"; do
        [ -f "$path" ] && printf '%s\n' "$path"
    done | awk '!seen[$0]++'
}

rpcs3_active_dirs() {
    local path
    for path in \
        "$HOME/.config/rpcs3/input_configs" \
        "$HOME/.var/app/net.rpcs3.RPCS3/config/rpcs3/input_configs"; do
        [ -d "$path" ] && printf '%s\n' "$path"
    done | awk '!seen[$0]++'
}

# /proc input is useful for inventory but cannot provide Ryujinx's SDL3 device
# identifier. Never synthesize GUIDs from it: Steam Input exposes a different
# virtual product ID from the physical controller.
enumerate_gamepads() {
    local devices="${PZ_INPUT_DEVICES_FILE:-/proc/bus/input/devices}"
    [ -r "$devices" ] || return 0
    awk '
        function emit() {
            low=tolower(name)
            if (js != "" && low !~ /(motion sensor|imu|accelerometer|gyroscope)/)
                printf "%s\t%s\t%s\t%s\n", js, vendor, product, name
        }
        /^I:/ {
            emit(); name=""; vendor=""; product=""; js=""
        }
        /Vendor=/ {
            value=$0; sub(/.*Vendor=/, "", value); sub(/ .*/, "", value); vendor=tolower(value)
        }
        /Product=/ {
            value=$0; sub(/.*Product=/, "", value); sub(/ .*/, "", value); product=tolower(value)
        }
        /^N: Name=/ {
            name=$0; sub(/^N: Name=/, "", name); gsub(/^"|"$/, "", name)
        }
        /^H: Handlers=/ {
            if (match($0, /js[0-9]+/)) js=substr($0, RSTART+2, RLENGTH-2)
        }
        END { emit() }
    ' "$devices" 2>/dev/null | sort -n -k1,1
}

enumerate_gamepads_json() {
    local idx vendor product name
    local json='[]'
    while IFS=$'\t' read -r idx vendor product name; do
        [ -n "$idx" ] || continue
        json="$(
            jq -nc \
                --argjson current "$json" \
                --arg idx "$idx" \
                --arg vendor "$vendor" \
                --arg product "$product" \
                --arg name "$name" \
                '$current + [{joydevIndex: ($idx|tonumber), vendor: $vendor,
                              product: $product, name: $name,
                              steamDeckPad: ($vendor == "28de")}]'
        )"
    done < <(enumerate_gamepads)
    printf '%s\n' "$json"
}

pz_controllers_is_steam_deck_handheld() {
    pz_emulation_is_steam_deck_hardware || return 1
    local root="${PZ_DISPLAY_SYSFS_ROOT:-/sys}" status_path connector status
    for status_path in "$root"/class/drm/card*-*/status; do
        [ -f "$status_path" ] || continue
        connector="$(basename "$(dirname "$status_path")")"
        case "$connector" in *eDP*|*DSI*|*LVDS*) continue ;; esac
        status="$(<"$status_path")"
        [ "$status" = "connected" ] && return 1
    done
    return 0
}

controllers_supported_host() {
    [ "${PZ_CONTROLLERS_FORCE:-0}" = "1" ] || pz_emulation_is_steam_deck_hardware
}

apply_ryujinx() {
    controllers_supported_host || {
        pz_info "Ryujinx: non-Deck host; preserving user controller assignments"
        return 0
    }
    [ -f "$RYUJINX_REF" ] || {
        pz_warn "Ryujinx: EmuDeck reference missing ($RYUJINX_REF); skipped"
        return 0
    }
    jq -e '.input_config | type == "array" and length > 0' "$RYUJINX_REF" >/dev/null 2>&1 || {
        pz_warn "Ryujinx: invalid EmuDeck input reference; skipped"
        return 0
    }

    local ref_slot cfg changed=0 deck_id
    ref_slot="$(jq -c '.input_config[0]' "$RYUJINX_REF")"
    deck_id="${PZ_RYUJINX_DECK_ID:-$(jq -r '.id // empty' <<< "$ref_slot")}"
    [ -n "$deck_id" ] || {
        pz_warn "Ryujinx: reference has no SDL device id; preserving active configs"
        return 0
    }
    if [ -n "${PZ_RYUJINX_DECK_ID:-}" ]; then
        ref_slot="$(jq -nc --argjson slot "$ref_slot" --arg id "$deck_id" '$slot | .id=$id')"
    fi
    ref_slot="$(jq -nc --argjson slot "$ref_slot" '$slot | .player_index="Player1"')"

    while IFS= read -r cfg; do
        [ -n "$cfg" ] || continue
        jq empty "$cfg" >/dev/null 2>&1 || {
            pz_warn "Ryujinx: invalid JSON preserved: $cfg"
            continue
        }
        if jq -e --arg id "$deck_id" '.input_config[0].id? == $id' "$cfg" >/dev/null 2>&1; then
            pz_info "Ryujinx: Steam Deck remains P1 in $cfg"
            continue
        fi
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would set Steam Deck as Ryujinx P1 in $cfg"
            changed=1
            continue
        fi
        backup_file "$cfg"
        # Replace P1 only. Preserve user-configured P2..P8 assignments.
        # shellcheck disable=SC2016  # $slot is a jq variable, not shell expansion.
        atomic_jq "$cfg" --argjson slot "$ref_slot" \
            '.input_config = (if (.input_config | type) == "array" and
                                  (.input_config | length) > 0
                              then [$slot] + .input_config[1:]
                              else [$slot] end)'
        pz_info "Ryujinx: Steam Deck -> P1; existing extra players preserved in $cfg"
        changed=1
    done < <(ryujinx_active_configs)
    [ "$changed" -eq 1 ] || pz_info "Ryujinx: no change needed"
}

apply_rpcs3() {
    controllers_supported_host || {
        pz_info "RPCS3: non-Deck host; preserving user controller assignments"
        return 0
    }
    [ -f "$RPCS3_REF" ] || {
        pz_warn "RPCS3: EmuDeck reference missing ($RPCS3_REF); skipped"
        return 0
    }
    local dir target active changed=0
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        target="$dir/global/Default.yml"
        active="$dir/active_profiles.yml"
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            if [ ! -f "$target" ] || ! cmp -s "$RPCS3_REF" "$target"; then
                pz_info "dry-run: would install RPCS3 Steam Input reference -> $target"
                changed=1
            fi
            if [ ! -f "$active" ] || ! grep -Fxq '  global: Default' "$active"; then
                pz_info "dry-run: would set RPCS3 global profile to Default while preserving other profiles -> $active"
                changed=1
            fi
            continue
        fi
        install -d -- "$dir/global"
        if [ ! -f "$target" ] || ! cmp -s "$RPCS3_REF" "$target"; then
            backup_file "$target"
            install -m 0644 -- "$RPCS3_REF" "$target"
            changed=1
            pz_info "RPCS3: Steam Input multiplayer reference -> $target"
        fi
        if [ ! -f "$active" ] || ! grep -Fxq '  global: Default' "$active"; then
            local tmp
            backup_file "$active"
            tmp="$(mktemp "${active}.phasezero.tmp.XXXXXX")"
            if [ -f "$active" ]; then
                awk '
                    BEGIN { in_active=0; saw_active=0; wrote=0 }
                    /^Active Profiles:[[:space:]]*$/ {
                        saw_active=1; in_active=1; print; next
                    }
                    in_active && /^[^[:space:]#]/ {
                        if (!wrote) { print "  global: Default"; wrote=1 }
                        in_active=0
                    }
                    in_active && /^[[:space:]]+global:[[:space:]]*/ {
                        if (!wrote) print "  global: Default"
                        wrote=1; next
                    }
                    { print }
                    END {
                        if (in_active && !wrote) print "  global: Default"
                        if (!saw_active) {
                            if (NR > 0) print ""
                            print "Active Profiles:"
                            print "  global: Default"
                        }
                    }
                ' "$active" > "$tmp"
                chmod --reference="$active" "$tmp" 2>/dev/null || true
            else
                printf 'Active Profiles:\n  global: Default\n' > "$tmp"
            fi
            mv -f -- "$tmp" "$active"
            changed=1
        fi
    done < <(rpcs3_active_dirs)
    [ "$changed" -eq 1 ] || pz_info "RPCS3: no change needed"
}

status_json() {
    local ry_ref=false ry_deck=false rp_ref=false rp_match=false handheld=false cfg pads_json
    [ -f "$RYUJINX_REF" ] && ry_ref=true
    cfg="$(ryujinx_active_configs | head -n1 || true)"
    if [ -n "$cfg" ] && jq -e '.input_config[0].id? // "" | test("-28de-")' "$cfg" >/dev/null 2>&1; then
        ry_deck=true
    fi
    [ -f "$RPCS3_REF" ] && rp_ref=true
    if [ -f "$HOME/.config/rpcs3/input_configs/global/Default.yml" ] &&
       cmp -s "$RPCS3_REF" "$HOME/.config/rpcs3/input_configs/global/Default.yml" 2>/dev/null; then
        rp_match=true
    fi
    pz_controllers_is_steam_deck_handheld && handheld=true
    pads_json="$(enumerate_gamepads_json)"
    jq -n \
        --argjson ryRef "$ry_ref" --argjson ryDeck "$ry_deck" \
        --argjson rpRef "$rp_ref" --argjson rpMatch "$rp_match" \
        --argjson handheld "$handheld" --argjson detectedPads "$pads_json" \
        --arg ryCfg "$cfg" \
        '{tool:"emulator-controllers",
          policy:"safe-reference-no-fabricated-guids",
          ryujinx:{referenceAvailable:$ryRef, activeConfig:$ryCfg, onSteamDeckPad:$ryDeck},
          rpcs3:{referenceAvailable:$rpRef, matchesDeckReference:$rpMatch},
          steamDeckHandheld:$handheld,
          detectedPadCount:($detectedPads|length), detectedPads:$detectedPads}'
}

case "$ACTION" in
    apply|configure|repair)
        apply_ryujinx
        apply_rpcs3
        ;;
    ryujinx) apply_ryujinx ;;
    rpcs3) apply_rpcs3 ;;
    status) status_json ;;
    dry-run|plan)
        PZ_DRY_RUN=1 apply_ryujinx
        PZ_DRY_RUN=1 apply_rpcs3
        ;;
    *)
        pz_error "usage: controllers.sh (apply|ryujinx|rpcs3|status|dry-run)"
        exit 2
        ;;
esac
