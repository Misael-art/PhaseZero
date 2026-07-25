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

sync_eden_keys() { bash "$PZ_ROOT/linux/emulation/eden.sh" configure; }

sync_citron_keys() { bash "$PZ_ROOT/linux/emulation/citron.sh" configure; }

import_switch_keys() {
    local ryujinx
    ryujinx=$(pz_emulation_switch_ryujinx_paths)
    pz_emulation_ensure_layout

    # The central store (firmware/switch/keys) is the single source of truth.
    # Populate it first from any source we can find: an explicit SOURCE arg, or
    # Ryujinx's existing keys. This fixes the bug where "import" succeeded but
    # left the central store empty (so Eden/Citron/NZ could not find keys and
    # re-prompted in Game Mode).
    local central_keydir="$PZ_EMULATION_ROOT/firmware/switch/keys"
    install -d "$central_keydir"

    if [ -n "$SOURCE" ]; then
        pz_emulation_require_local_source "$SOURCE"
        local found=0 file
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
    elif [ "$ryujinx" != "null" ] && jq -e '.hasKeys == true' <<< "$ryujinx" >/dev/null 2>&1; then
        # No explicit source, but Ryujinx already has keys: back-fill the central
        # store from Ryujinx so Eden/Citron/NZ can link to the central path.
        local ryu_keys; ryu_keys="$(jq -r '.keys' <<< "$ryujinx")"
        pz_info "back-filling central key store from Ryujinx: $ryu_keys"
        local kf
        for kf in prod.keys title.keys; do
            [ -f "$ryu_keys/$kf" ] && cp -f "$ryu_keys/$kf" "$central_keydir/$kf"
        done
    else
        pz_error "usage: pz emulation switch import-keys <local-path> (or place prod.keys in Ryujinx first)"
        return 1
    fi

    # Ensure Ryujinx itself reads the central store (link its keys dir in).
    link_ryujinx_to_central

    sync_eden_keys
    sync_citron_keys
    pz_info "Switch keys centralized at $central_keydir"
}

link_ryujinx_to_central() {
    # Point Ryujinx's keys dir at the central store so every emulator shares one
    # copy. Best-effort: skip if the user keeps real keys in Ryujinx only.
    local central_keydir="$PZ_EMULATION_ROOT/firmware/switch/keys"
    local ryu_config="$HOME/.config/Ryujinx/system"
    [ -f "$central_keydir/prod.keys" ] || return 0
    [ -d "$ryu_config" ] || return 0
    local target="$ryu_config/keys"
    # Already linked to the central store?
    [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$central_keydir")" ] && return 0
    # If Ryujinx has its own real key files, keep them but ensure the central has
    # a copy (handled above); do not clobber a working Ryujinx setup.
    if [ -d "$target" ] && [ ! -L "$target" ]; then
        if [ ! -e "$target/prod.keys" ]; then
            rmdir "$target" 2>/dev/null || true
            ln -sfn "$central_keydir" "$target"
        fi
    else
        ln -sfn "$central_keydir" "$target"
    fi
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

sync_eden_firmware() { bash "$PZ_ROOT/linux/emulation/eden.sh" configure; }

sync_citron_firmware() { bash "$PZ_ROOT/linux/emulation/citron.sh" configure; }

import_switch_firmware() {
    local ryujinx
    ryujinx=$(pz_emulation_switch_ryujinx_paths)
    pz_emulation_ensure_layout
    local central_fw="$PZ_EMULATION_ROOT/firmware/switch/firmware"
    install -d "$central_fw"

    if [ -n "$SOURCE" ]; then
        pz_emulation_require_local_source "$SOURCE"
        extract_or_copy_firmware "$SOURCE" "$central_fw"
    elif [ "$ryujinx" != "null" ] && jq -e '.hasFirmware == true' <<< "$ryujinx" >/dev/null 2>&1; then
        local ryu_fw; ryu_fw="$(jq -r '.firmware' <<< "$ryujinx")"
        pz_info "back-filling central firmware store from Ryujinx: $ryu_fw"
        # Firmware is a registered dir tree; sync new files only.
        if [ -d "$ryu_fw" ]; then
            ( cd "$ryu_fw" && tar cf - . 2>/dev/null ) | ( cd "$central_fw" && tar xf - 2>/dev/null || true )
        fi
    else
        pz_error "usage: pz emulation switch import-firmware <local-path> (or install firmware in Ryujinx first)"
        return 1
    fi

    sync_eden_firmware
    sync_citron_firmware
    pz_info "Switch firmware centralized at $central_fw"
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
