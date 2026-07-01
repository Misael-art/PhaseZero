#!/usr/bin/env bash
# common.sh - shared helpers for Linux emulation setup
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PZ_EMULATION_ROOT="${PZ_EMULATION_ROOT:-$HOME/Emulation}"
PZ_APPLICATIONS_DIR="${PZ_APPLICATIONS_DIR:-$HOME/Applications}"
PZ_LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
PZ_DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
PZ_EMULATION_STATE="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/emulation"

PZ_EDEN_VERSION="${PZ_EDEN_VERSION:-v0.2.1}"
PZ_EDEN_APPIMAGE_NAME="Eden-Linux-${PZ_EDEN_VERSION}-steamdeck-clang-pgo.AppImage"
PZ_EDEN_APPIMAGE_URL="${PZ_EDEN_APPIMAGE_URL:-https://stable.eden-emu.dev/${PZ_EDEN_VERSION}/$PZ_EDEN_APPIMAGE_NAME}"
PZ_EDEN_ZSYNC_URL="${PZ_EDEN_ZSYNC_URL:-https://stable.eden-emu.dev/${PZ_EDEN_VERSION}/Eden-Linux-steamdeck-clang-pgo.AppImage.zsync}"
PZ_CITRON_RELEASE_API="${PZ_CITRON_RELEASE_API:-https://api.github.com/repos/citron-neo/emulator/releases/latest}"
PZ_EMUDECK_RELEASE_API="${PZ_EMUDECK_RELEASE_API:-https://api.github.com/repos/EmuDeck/emudeck-electron/releases/latest}"

pz_emulation_layout_dirs() {
    cat <<EOF
$PZ_EMULATION_ROOT
$PZ_EMULATION_ROOT/bios
$PZ_EMULATION_ROOT/roms
$PZ_EMULATION_ROOT/roms/switch
$PZ_EMULATION_ROOT/roms/psx
$PZ_EMULATION_ROOT/roms/ps2
$PZ_EMULATION_ROOT/roms/ps3
$PZ_EMULATION_ROOT/roms/psp
$PZ_EMULATION_ROOT/roms/gc
$PZ_EMULATION_ROOT/roms/wii
$PZ_EMULATION_ROOT/roms/wiiu
$PZ_EMULATION_ROOT/roms/n64
$PZ_EMULATION_ROOT/roms/snes
$PZ_EMULATION_ROOT/roms/nes
$PZ_EMULATION_ROOT/roms/gba
$PZ_EMULATION_ROOT/roms/gb
$PZ_EMULATION_ROOT/saves
$PZ_EMULATION_ROOT/saves/switch
$PZ_EMULATION_ROOT/state
$PZ_EMULATION_ROOT/state/switch/nand
$PZ_EMULATION_ROOT/cache
$PZ_EMULATION_ROOT/cache/switch
$PZ_EMULATION_ROOT/mods
$PZ_EMULATION_ROOT/mods/switch
$PZ_EMULATION_ROOT/metadata
$PZ_EMULATION_ROOT/metadata/switch
$PZ_EMULATION_ROOT/firmware
$PZ_EMULATION_ROOT/firmware/switch/keys
$PZ_EMULATION_ROOT/firmware/switch/firmware
$PZ_APPLICATIONS_DIR
$PZ_LOCAL_BIN
$PZ_DESKTOP_DIR
$PZ_EMULATION_STATE
EOF
}

pz_emulation_ensure_layout() {
    local dir
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        install -d "$dir"
    done < <(pz_emulation_layout_dirs)
    pz_info "emulation layout ready: $PZ_EMULATION_ROOT"
}

pz_emulation_write_file() {
    local path="$1" mode="${2:-0644}" dir tmp
    dir="$(dirname "$path")"
    install -d "$dir"
    tmp="$(mktemp)"
    cat > "$tmp"
    [ -f "$path" ] && cp "$path" "${path}.bak.$(date +%s)" 2>/dev/null || true
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    pz_info "wrote $path"
}

pz_emulation_download() {
    local url="$1" target="$2" tmp
    tmp="${target}.tmp.$$"
    rm -f "$tmp"
    curl -L --fail --retry 3 --connect-timeout 15 -o "$tmp" "$url"
    chmod +x "$tmp"
    mv "$tmp" "$target"
}

pz_emulation_remote_source() {
    case "$1" in
        http://*|https://*|git://*|ssh://*|git@*) return 0 ;;
        *) return 1 ;;
    esac
}

pz_emulation_blocked_source_reason() {
    case "$1" in
        *github.com/Abdess/retrobios*|*github.com/THZoria/NX_Firmware*|*edenemulators.com/eden-prod-keys*)
            echo "third-party BIOS/firmware/keys downloads are blocked; import only local dumps from hardware you own"
            return 0
            ;;
    esac
    return 1
}

pz_emulation_require_local_source() {
    local source="$1" reason
    reason="$(pz_emulation_blocked_source_reason "$source" 2>/dev/null || true)"
    if [ -n "$reason" ]; then
        pz_error "blocked source: $source ($reason)"
        return 3
    fi
    if pz_emulation_remote_source "$source"; then
        pz_error "remote BIOS/firmware/key source blocked: $source"
        return 3
    fi
    [ -e "$source" ] || { pz_error "source not found: $source"; return 1; }
}

pz_emulation_copy_source() {
    local source="$1" dest="$2"
    install -d "$dest"
    if [ -d "$source" ]; then
        find "$source" -mindepth 1 -maxdepth 1 -exec cp -a {} "$dest"/ \;
    else
        cp -a "$source" "$dest"/
    fi
}

pz_emulation_count_files() {
    local dir="$1"
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

pz_emulation_sha256_or_empty() {
    local path="$1"
    [ -f "$path" ] || return 0
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
}

pz_emulation_status_json() {
    local emudeck_app="$PZ_APPLICATIONS_DIR/EmuDeck.AppImage"
    local eden_app="$PZ_APPLICATIONS_DIR/$PZ_EDEN_APPIMAGE_NAME"
    local eden_link="$PZ_APPLICATIONS_DIR/Eden.AppImage"
    local hydra_app="$PZ_APPLICATIONS_DIR/Hydra.AppImage"
    local hydra_policy="$PZ_EMULATION_STATE/hydra-policy.json"
    local bios_count switch_key_count switch_fw_count
    bios_count="$(pz_emulation_count_files "$PZ_EMULATION_ROOT/bios")"
    if [ -d "$PZ_EMULATION_ROOT/firmware/switch/keys" ]; then
        switch_key_count="$(find "$PZ_EMULATION_ROOT/firmware/switch/keys" -maxdepth 1 -type f \( -name 'prod.keys' -o -name 'title.keys' \) 2>/dev/null | wc -l | tr -d ' ')"
    else
        switch_key_count=0
    fi
    switch_fw_count="$(pz_emulation_count_files "$PZ_EMULATION_ROOT/firmware/switch/firmware")"
    jq -n \
        --arg root "$PZ_EMULATION_ROOT" \
        --arg appDir "$PZ_APPLICATIONS_DIR" \
        --arg emudeck "$emudeck_app" \
        --arg eden "$eden_app" \
        --arg edenLink "$eden_link" \
        --arg edenSha "$(pz_emulation_sha256_or_empty "$eden_app")" \
        --arg hydra "$hydra_app" \
        --arg hydraPolicy "$hydra_policy" \
        --argjson emudeckInstalled "$([ -x "$emudeck_app" ] && echo true || echo false)" \
        --argjson edenInstalled "$([ -x "$eden_app" ] && echo true || echo false)" \
        --argjson edenLinkInstalled "$([ -x "$eden_link" ] && echo true || echo false)" \
        --argjson hydraInstalled "$([ -x "$hydra_app" ] && echo true || echo false)" \
        --argjson hydraPolicyInstalled "$([ -f "$hydra_policy" ] && echo true || echo false)" \
        --argjson biosCount "$bios_count" \
        --argjson switchKeyCount "$switch_key_count" \
        --argjson switchFirmwareCount "$switch_fw_count" \
        '{
            root: $root,
            applicationsDir: $appDir,
            emudeck: { appImage: $emudeck, installed: $emudeckInstalled },
            eden: { appImage: $eden, link: $edenLink, installed: $edenInstalled, linkInstalled: $edenLinkInstalled, sha256: $edenSha },
            hydra: { appImage: $hydra, installed: $hydraInstalled, policy: $hydraPolicy, policyInstalled: $hydraPolicyInstalled },
            userContent: {
                biosFileCount: $biosCount,
                switchKeyFileCount: $switchKeyCount,
                switchFirmwareFileCount: $switchFirmwareCount,
                policy: "local-user-owned-import-only"
            }
        }'
}

pz_emulation_print_blocked_sources() {
    cat <<'EOF'
Blocked by PhaseZero:
  https://github.com/Abdess/retrobios.git
  https://github.com/THZoria/NX_Firmware.git
  https://edenemulators.com/eden-prod-keys/

Reason:
  BIOS, console firmware, prod.keys/title.keys, ROMs, updates and DLC are user-owned content.
  PhaseZero imports local dumps only. It never downloads or redistributes those files.

Allowed:
  linux/pz emulation bios import /path/to/local/bios-dump
  linux/pz emulation switch import-keys /path/to/local/switch-keys
  linux/pz emulation switch import-firmware /path/to/local/switch-firmware
EOF
}
