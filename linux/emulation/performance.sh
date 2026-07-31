#!/usr/bin/env bash
# performance.sh - manage adaptive Switch/PS3/PS4 launch profiles.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
shift || true

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero"
CONFIG_FILE="${PZ_EMULATION_PERFORMANCE_CONFIG:-$CONFIG_DIR/emulation-performance.json}"
RUNTIME_SOURCE="$PZ_ROOT/linux/emulation/performance-launch.sh"
RUNTIME_TARGET="$PZ_LOCAL_BIN/phasezero-emulation-launch"
LSFG_PLUGIN="$HOME/homebrew/plugins/decky-lsfg-vk"
LSFG_PACKAGE="$LSFG_PLUGIN/package.json"
LSFG_MANIFEST="${XDG_DATA_HOME:-$HOME/.local/share}/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json"
LSFG_LIBRARY="$HOME/.local/lib/liblsfg-vk.so"
LSFG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/lsfg-vk/conf.toml"
LSFG_BINARY="$HOME/lsfg"
LOSSLESS_DLL="${PZ_LOSSLESS_DLL:-${STEAM_ROOT:-$HOME/.local/share/Steam}/steamapps/common/Lossless Scaling/Lossless.dll}"

default_config() {
    jq -n --arg binary "$LSFG_BINARY" '{
        schemaVersion: 1,
        enabled: true,
        gamemode: true,
        mangohud: true,
        applyTdp: false,
        lsfg: {
            mode: "auto",
            binary: $binary,
            policy: "activate only for game launches when local layer is complete"
        },
        profiles: {
            switch: {
                enabled: true,
                lsfg: "auto",
                baseFps: 30,
                outputHz: 60,
                recommendedTdpWatts: 11,
                env: {
                    AMD_VULKAN_ICD: "RADV",
                    DISABLE_VKBASALT: "1",
                    vblank_mode: "0"
                }
            },
            ps3: {
                enabled: true,
                lsfg: "auto",
                baseFps: 30,
                outputHz: 60,
                recommendedTdpWatts: 12,
                env: {
                    AMD_VULKAN_ICD: "RADV",
                    DISABLE_VKBASALT: "1"
                }
            },
            ps4: {
                enabled: true,
                lsfg: "auto",
                baseFps: 30,
                outputHz: 60,
                recommendedTdpWatts: 15,
                env: {
                    AMD_VULKAN_ICD: "RADV",
                    DISABLE_VKBASALT: "1"
                }
            }
        },
        games: {
            switch: {},
            ps3: {},
            ps4: {}
        }
    }'
}

valid_platform() {
    case "$1" in switch|ps3|ps4) return 0 ;; *) return 1 ;; esac
}

valid_lsfg_mode() {
    case "$1" in auto|on|off) return 0 ;; *) return 1 ;; esac
}

lsfg_ready() {
    [ -x "$LSFG_BINARY" ] &&
        [ -f "$LSFG_LIBRARY" ] &&
        [ -f "$LSFG_MANIFEST" ] &&
        [ -f "$LSFG_CONFIG" ]
}

write_config() {
    local defaults current tmp
    install -d "$CONFIG_DIR" "$PZ_LOCAL_BIN"
    defaults="$(mktemp)"
    current="$(mktemp)"
    tmp="$(mktemp)"
    default_config > "$defaults"
    if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        cp "$CONFIG_FILE" "$current"
        pz_backup_file "$CONFIG_FILE" user >/dev/null
    else
        echo '{}' > "$current"
    fi
    jq -s '.[0] * .[1]' "$defaults" "$current" > "$tmp"
    install -m 0644 "$tmp" "$CONFIG_FILE"
    install -m 0755 "$RUNTIME_SOURCE" "$RUNTIME_TARGET"
    rm -f "$defaults" "$current" "$tmp"
    pz_info "emulation performance profiles installed: $CONFIG_FILE"
    pz_info "adaptive launcher installed: $RUNTIME_TARGET"
}

status_json() {
    local config_valid=false runtime=false game_mode=false mango=false vulkan=false
    local plugin=false lossless=false ready=false
    [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" >/dev/null 2>&1 && config_valid=true
    [ -x "$RUNTIME_TARGET" ] && runtime=true
    command -v gamemoderun >/dev/null 2>&1 && game_mode=true
    command -v mangohud >/dev/null 2>&1 && mango=true
    command -v vulkaninfo >/dev/null 2>&1 && vulkan=true
    [ -d "$LSFG_PLUGIN" ] && plugin=true
    [ -f "$LOSSLESS_DLL" ] && lossless=true
    lsfg_ready && ready=true

    jq -n \
        --arg config "$CONFIG_FILE" \
        --arg runtime "$RUNTIME_TARGET" \
        --arg lsfgBinary "$LSFG_BINARY" \
        --arg lsfgLibrary "$LSFG_LIBRARY" \
        --arg lsfgManifest "$LSFG_MANIFEST" \
        --arg lsfgConfig "$LSFG_CONFIG" \
        --arg losslessDll "$LOSSLESS_DLL" \
        --argjson configValid "$config_valid" \
        --argjson runtimeInstalled "$runtime" \
        --argjson gamemode "$game_mode" \
        --argjson mangohud "$mango" \
        --argjson vulkan "$vulkan" \
        --argjson deckyPlugin "$plugin" \
        --argjson losslessScaling "$lossless" \
        --argjson lsfgReady "$ready" \
        --slurpfile cfg <([ -f "$CONFIG_FILE" ] && jq '.' "$CONFIG_FILE" 2>/dev/null || echo '{}') \
        '{
            config: $config,
            configValid: $configValid,
            runtime: $runtime,
            runtimeInstalled: $runtimeInstalled,
            tools: {
                gamemode: $gamemode,
                mangohud: $mangohud,
                vulkan: $vulkan
            },
            lsfg: {
                deckyPluginInstalled: $deckyPlugin,
                losslessScalingInstalled: $losslessScaling,
                ready: $lsfgReady,
                binary: $lsfgBinary,
                library: $lsfgLibrary,
                manifest: $lsfgManifest,
                config: $lsfgConfig,
                losslessDll: $losslessDll
            },
            profiles: ($cfg[0].profiles // {})
        }'
}

plan() {
    [ -f "$CONFIG_FILE" ] || echo "create $CONFIG_FILE"
    [ -x "$RUNTIME_TARGET" ] || echo "install $RUNTIME_TARGET"
    command -v gamemoderun >/dev/null 2>&1 || echo "install gamemode"
    command -v mangohud >/dev/null 2>&1 || echo "install mangohud"
    command -v vulkaninfo >/dev/null 2>&1 || echo "install vulkan-tools"
    [ -d "$LSFG_PLUGIN" ] || echo "install Decky LSFG-VK plugin"
    [ -f "$LOSSLESS_DLL" ] || echo "install owned Lossless Scaling Steam app"
    if ! lsfg_ready; then
        echo "prepare LSFG Vulkan layer: linux/pz emulation performance prepare-lsfg"
    fi
    echo "apply adaptive wrappers: linux/pz emulation shortcuts repair"
    echo "refresh SRM parsers: linux/pz emulation srm configure"
}

set_profile() {
    local platform="${1:-}" mode="${2:-}" tmp
    valid_platform "$platform" || { pz_error "platform must be switch, ps3, or ps4"; return 2; }
    valid_lsfg_mode "$mode" || { pz_error "LSFG mode must be auto, on, or off"; return 2; }
    write_config >/dev/null
    tmp="$(mktemp)"
    jq --arg platform "$platform" --arg mode "$mode" '.profiles[$platform].lsfg = $mode' "$CONFIG_FILE" > "$tmp"
    install -m 0644 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    pz_info "$platform LSFG mode set to $mode"
}

set_game() {
    local platform="${1:-}" game="${2:-}" mode="${3:-}" tmp
    valid_platform "$platform" || { pz_error "platform must be switch, ps3, or ps4"; return 2; }
    [ -n "$game" ] || { pz_error "game key required"; return 2; }
    valid_lsfg_mode "$mode" || { pz_error "LSFG mode must be auto, on, or off"; return 2; }
    game="$(basename "$game")"
    game="${game%.*}"
    write_config >/dev/null
    tmp="$(mktemp)"
    jq --arg platform "$platform" --arg game "$game" --arg mode "$mode" \
        '.games[$platform][$game].lsfg = $mode' "$CONFIG_FILE" > "$tmp"
    install -m 0644 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    pz_info "$platform game '$game' LSFG mode set to $mode"
}

prepare_lsfg() {
    local url digest archive tmpdir extracted_lib extracted_json manifest_tmp
    [ -f "$LOSSLESS_DLL" ] || {
        pz_error "Lossless Scaling DLL missing. Install owned Steam app first: $LOSSLESS_DLL"
        return 3
    }
    [ -f "$LSFG_PACKAGE" ] || {
        pz_error "Decky LSFG-VK package metadata missing: $LSFG_PACKAGE"
        return 3
    }
    url="$(jq -r '.remote_binary[]? | select(.name == "lsfg-vk_noui.zip") | .url // empty' "$LSFG_PACKAGE" | head -1)"
    digest="$(jq -r '.remote_binary[]? | select(.name == "lsfg-vk_noui.zip") | .sha256hash // empty' "$LSFG_PACKAGE" | head -1)"
    if [ -n "$url" ] && [ -n "$digest" ]; then
        :
    else
        pz_error "verified lsfg-vk artifact missing from Decky plugin metadata"
        return 3
    fi

    archive="$(mktemp)"
    tmpdir="$(mktemp -d)"
    trap 'rm -f "${archive:-}"; rm -rf "${tmpdir:-}"' RETURN
    curl -L --fail --retry 3 --connect-timeout 15 -o "$archive" "$url"
    printf '%s  %s\n' "$digest" "$archive" | sha256sum -c - >/dev/null
    unzip -q "$archive" -d "$tmpdir"
    extracted_lib="$(find "$tmpdir" -type f -name 'liblsfg-vk.so' -print -quit)"
    extracted_json="$(find "$tmpdir" -type f -name 'VkLayer_LS_frame_generation.json' -print -quit)"
    if [ -n "$extracted_lib" ] && [ -n "$extracted_json" ]; then
        :
    else
        pz_error "verified lsfg-vk archive lacks expected Vulkan layer files"
        return 3
    fi

    install -d "$(dirname "$LSFG_LIBRARY")" "$(dirname "$LSFG_MANIFEST")" "$(dirname "$LSFG_CONFIG")"
    install -m 0755 "$extracted_lib" "$LSFG_LIBRARY"
    manifest_tmp="$(mktemp)"
    jq --arg library "$LSFG_LIBRARY" '.layer.library_path = $library' "$extracted_json" > "$manifest_tmp"
    install -m 0644 "$manifest_tmp" "$LSFG_MANIFEST"
    rm -f "$manifest_tmp"

    if [ ! -f "$LSFG_CONFIG" ]; then
        cat > "$LSFG_CONFIG" <<EOF
version = 1

[global]
current_profile = "phasezero"
dll = "$LOSSLESS_DLL"
no_fp16 = false

[[game]]
exe = "phasezero"
multiplier = 2
flow_scale = 0.5
performance_mode = true
hdr_mode = false
experimental_present_mode = "fifo"
EOF
    elif ! grep -Fq 'exe = "phasezero"' "$LSFG_CONFIG"; then
        pz_backup_file "$LSFG_CONFIG" user >/dev/null
        cat >> "$LSFG_CONFIG" <<'EOF'

[[game]]
exe = "phasezero"
multiplier = 2
flow_scale = 0.5
performance_mode = true
hdr_mode = false
experimental_present_mode = "fifo"
EOF
    fi

    cat > "$LSFG_BINARY" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export LSFG_PROCESS=phasezero
export DISABLE_VKBASALT="${DISABLE_VKBASALT:-1}"
exec "$@"
EOF
    chmod 0755 "$LSFG_BINARY"
    lsfg_ready || { pz_error "LSFG installation incomplete after apply"; return 1; }
    pz_info "LSFG Vulkan layer ready: 2x performance profile"
}

launch() {
    local platform="${1:-}"
    shift || true
    [ -x "$RUNTIME_TARGET" ] || write_config >/dev/null
    exec "$RUNTIME_TARGET" "$platform" "$@"
}

case "$ACTION" in
    status) status_json ;;
    plan|dry-run) plan ;;
    apply|install|repair) write_config ;;
    prepare-lsfg) prepare_lsfg ;;
    set-profile) set_profile "$@" ;;
    set-game) set_game "$@" ;;
    launch) launch "$@" ;;
    *)
        pz_error "usage: performance.sh (status|plan|apply|prepare-lsfg|set-profile <platform> <auto|on|off>|set-game <platform> <game> <auto|on|off>|launch <platform> -- <emulator> [args...])"
        exit 2
        ;;
esac
