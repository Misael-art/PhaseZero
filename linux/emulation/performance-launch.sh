#!/usr/bin/env bash
# Standalone adaptive launcher for PhaseZero emulator performance profiles.
set -euo pipefail

usage() {
    echo "usage: phasezero-emulation-launch <switch|ps3|ps4> -- <emulator> [args...]" >&2
}

platform="${1:-}"
shift || true
[ "${1:-}" = "--" ] && shift

case "$platform" in
    switch|ps3|ps4) ;;
    *) usage; exit 2 ;;
esac

[ "$#" -gt 0 ] || { usage; exit 2; }
app="$1"
shift

if [ ! -x "$app" ] && [ -f "$app" ]; then
    chmod +x "$app" 2>/dev/null || true
fi
[ -e "$app" ] || { echo "$platform emulator not found: $app" >&2; exit 1; }

config="${PZ_EMULATION_PERFORMANCE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/emulation-performance.json}"
game_key=""
for arg in "$@"; do
    case "$arg" in
        -*) continue ;;
    esac
    if [ -e "$arg" ]; then
        game_key="$(basename "$arg")"
        game_key="${game_key%.*}"
        break
    fi
    if [ -z "$game_key" ]; then
        game_key="$arg"
    fi
done

json_value() {
    local filter="$1" fallback="$2"
    if command -v jq >/dev/null 2>&1 && [ -f "$config" ] && jq empty "$config" >/dev/null 2>&1; then
        jq -r "$filter // empty" "$config" 2>/dev/null | head -n 1
    else
        printf '%s\n' "$fallback"
    fi
}

enabled="$(json_value '.enabled' true)"
[ "$enabled" = "false" ] && exec "$app" "$@"
profile_enabled="$(json_value ".profiles.$platform.enabled" true)"
[ "$profile_enabled" = "false" ] && exec "$app" "$@"

if command -v jq >/dev/null 2>&1 && [ -f "$config" ] && jq empty "$config" >/dev/null 2>&1; then
    while IFS=$'\t' read -r name value; do
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [ "$name" = "AMD_VULKAN_ICD" ] &&
            ! grep -qs '^0x1002$' /sys/class/drm/card*/device/vendor 2>/dev/null; then
            continue
        fi
        export "$name=$value"
    done < <(jq -r --arg platform "$platform" '
        (.profiles[$platform].env // {})
        | to_entries[]
        | [.key, (.value | tostring)]
        | @tsv
    ' "$config" 2>/dev/null || true)
fi

mangohud="$(json_value '.mangohud' true)"
gamemode="$(json_value '.gamemode' true)"
[ "$mangohud" = "true" ] && export MANGOHUD="${MANGOHUD:-1}"

lsfg_mode="${PZ_EMULATION_LSFG:-}"
if [ -z "$lsfg_mode" ] && [ -n "$game_key" ] && command -v jq >/dev/null 2>&1 && [ -f "$config" ]; then
    lsfg_mode="$(jq -r --arg platform "$platform" --arg game "$game_key" \
        '.games[$platform][$game].lsfg // .profiles[$platform].lsfg // .lsfg.mode // "auto"' \
        "$config" 2>/dev/null || echo auto)"
fi
[ -n "$lsfg_mode" ] || lsfg_mode="$(json_value ".profiles.$platform.lsfg" auto)"

lsfg_binary="$(json_value '.lsfg.binary' "$HOME/lsfg")"
lsfg_manifest="${XDG_DATA_HOME:-$HOME/.local/share}/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json"
lsfg_library="$HOME/.local/lib/liblsfg-vk.so"
lsfg_config="${XDG_CONFIG_HOME:-$HOME/.config}/lsfg-vk/conf.toml"
lsfg_ready=false
if [ -x "$lsfg_binary" ] && [ -f "$lsfg_manifest" ] && [ -f "$lsfg_library" ] && [ -f "$lsfg_config" ]; then
    lsfg_ready=true
fi

use_lsfg=false
case "$lsfg_mode" in
    on)
        if [ "$lsfg_ready" = "true" ] && [ -n "$game_key" ]; then
            use_lsfg=true
        else
            echo "PhaseZero: LSFG requested but runtime/game missing; launching without frame generation" >&2
            [ "${PZ_EMULATION_LSFG_STRICT:-0}" = "1" ] && exit 3
        fi
        ;;
    auto)
        [ "$lsfg_ready" = "true" ] && [ -n "$game_key" ] && use_lsfg=true
        ;;
    off) ;;
    *)
        echo "PhaseZero: invalid LSFG mode '$lsfg_mode'; using off" >&2
        ;;
esac

command_line=("$app" "$@")
if [ "$use_lsfg" = "true" ]; then
    export DISABLE_VKBASALT="${DISABLE_VKBASALT:-1}"
    command_line=("$lsfg_binary" "${command_line[@]}")
fi

if [ "${PZ_EMULATION_PERFORMANCE_VERBOSE:-0}" = "1" ]; then
    echo "PhaseZero: platform=$platform game=${game_key:-gui} lsfg=$use_lsfg gamemode=$gamemode mangohud=$mangohud" >&2
fi

export PZ_EMULATION_PERFORMANCE_ACTIVE=1
if [ "$gamemode" = "true" ] && command -v gamemoderun >/dev/null 2>&1; then
    exec gamemoderun "${command_line[@]}"
fi
exec "${command_line[@]}"
