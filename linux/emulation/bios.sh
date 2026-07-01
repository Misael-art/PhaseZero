#!/usr/bin/env bash
# bios.sh - local-only BIOS/firmware/key import helpers
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
SOURCE="${2:-}"
EDEN_SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/eden"
EDEN_KEYS="$EDEN_SHARE/keys"
EDEN_FIRMWARE="$EDEN_SHARE/nand/system/Contents/registered"
CITRON_SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/citron"
CITRON_KEYS="$CITRON_SHARE/keys"
CITRON_FIRMWARE="$CITRON_SHARE/nand/system/Contents/registered"

import_bios() {
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation bios import <local-path>"; return 1; }
    pz_emulation_require_local_source "$SOURCE"
    pz_emulation_ensure_layout
    pz_emulation_copy_source "$SOURCE" "$PZ_EMULATION_ROOT/bios"
    pz_info "BIOS imported into $PZ_EMULATION_ROOT/bios"
}

copy_key_file() {
    local file="$1" name
    name="$(basename "$file")"
    case "$name" in
        prod.keys|title.keys) cp -f "$file" "$PZ_EMULATION_ROOT/firmware/switch/keys/$name" ;;
        *) pz_warn "ignored non-key file: $file" ;;
    esac
}

sync_eden_keys() {
    local key
    install -d "$EDEN_KEYS"
    for key in prod.keys title.keys; do
        [ -f "$PZ_EMULATION_ROOT/firmware/switch/keys/$key" ] && cp -f "$PZ_EMULATION_ROOT/firmware/switch/keys/$key" "$EDEN_KEYS/$key"
    done
    return 0
}

sync_citron_keys() {
    local key
    install -d "$CITRON_KEYS"
    for key in prod.keys title.keys; do
        [ -f "$PZ_EMULATION_ROOT/firmware/switch/keys/$key" ] && cp -f "$PZ_EMULATION_ROOT/firmware/switch/keys/$key" "$CITRON_KEYS/$key"
    done
    return 0
}

import_switch_keys() {
    local found=0 file
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation switch import-keys <local-path>"; return 1; }
    pz_emulation_require_local_source "$SOURCE"
    pz_emulation_ensure_layout
    if [ -d "$SOURCE" ]; then
        while IFS= read -r -d '' file; do
            found=1
            copy_key_file "$file"
        done < <(find "$SOURCE" -maxdepth 1 -type f \( -name 'prod.keys' -o -name 'title.keys' \) -print0)
    else
        found=1
        copy_key_file "$SOURCE"
    fi
    [ "$found" -eq 1 ] || { pz_error "no prod.keys/title.keys found in $SOURCE"; return 1; }
    sync_eden_keys
    sync_citron_keys
    pz_info "Switch keys imported from local source"
}

extract_or_copy_firmware() {
    local source="$1" dest="$2"
    case "$source" in
        *.zip)
            command -v unzip >/dev/null 2>&1 || { pz_error "unzip missing"; return 1; }
            unzip -oq "$source" -d "$dest"
            ;;
        *.7z|*.rar)
            command -v 7z >/dev/null 2>&1 || { pz_error "7z missing"; return 1; }
            7z x -y "-o$dest" "$source" >/dev/null
            ;;
        *)
            pz_emulation_copy_source "$source" "$dest"
            ;;
    esac
}

sync_eden_firmware() {
    install -d "$EDEN_FIRMWARE"
    find "$PZ_EMULATION_ROOT/firmware/switch/firmware" -type f -name '*.nca' -exec cp -n {} "$EDEN_FIRMWARE"/ \; 2>/dev/null || true
}

sync_citron_firmware() {
    install -d "$CITRON_FIRMWARE"
    find "$PZ_EMULATION_ROOT/firmware/switch/firmware" -type f -name '*.nca' -exec cp -n {} "$CITRON_FIRMWARE"/ \; 2>/dev/null || true
}

import_switch_firmware() {
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation switch import-firmware <local-path>"; return 1; }
    pz_emulation_require_local_source "$SOURCE"
    pz_emulation_ensure_layout
    extract_or_copy_firmware "$SOURCE" "$PZ_EMULATION_ROOT/firmware/switch/firmware"
    sync_eden_firmware
    sync_citron_firmware
    pz_info "Switch firmware imported from local source"
}

case "$ACTION" in
    layout) pz_emulation_ensure_layout ;;
    status|switch-status) pz_emulation_status_json ;;
    blocked-sources|policy) pz_emulation_print_blocked_sources ;;
    import) import_bios ;;
    switch-import-keys) import_switch_keys ;;
    switch-import-firmware) import_switch_firmware ;;
    *) pz_error "usage: bios.sh (layout|status|blocked-sources|import <path>|switch-import-keys <path>|switch-import-firmware <path>)"; exit 1 ;;
esac
