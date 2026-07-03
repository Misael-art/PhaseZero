#!/usr/bin/env bash
# ps3.sh - local-only PS3 content import and RPCS3 integration
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
SOURCE="${2:-}"
RPCS3_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/rpcs3"
RPCS3_VFS="$RPCS3_CONFIG/vfs.yml"
PS3_ROMS="$PZ_EMULATION_ROOT/roms/ps3"
PS3_PKG="$PS3_ROMS/pkg"
PS3_FIRMWARE="$PZ_EMULATION_ROOT/firmware/ps3"
RPCS3_DEV_HDD0="$PZ_EMULATION_ROOT/storage/rpcs3/dev_hdd0"
RPCS3_EXDATA="$RPCS3_DEV_HDD0/home/00000001/exdata"
PS3_STATE="$PZ_EMULATION_STATE/ps3.json"

detect_rpcs3() {
    if [ "${PZ_RPCS3_APP+x}" ]; then
        echo "$PZ_RPCS3_APP"
        return 0
    fi
    if command -v rpcs3 >/dev/null 2>&1; then
        command -v rpcs3
        return 0
    fi
    if [ -x "$PZ_APPLICATIONS_DIR/rpcs3.AppImage" ]; then
        echo "$PZ_APPLICATIONS_DIR/rpcs3.AppImage"
        return 0
    fi
    if [ -x "$PZ_APPLICATIONS_DIR/RPCS3.AppImage" ]; then
        echo "$PZ_APPLICATIONS_DIR/RPCS3.AppImage"
        return 0
    fi
    return 0
}

ensure_ps3_layout() {
    pz_emulation_ensure_layout
    install -d "$PS3_ROMS" "$PS3_PKG" "$PS3_FIRMWARE" "$RPCS3_DEV_HDD0" "$RPCS3_EXDATA" "$RPCS3_CONFIG"
}

set_vfs_line() {
    local key="$1" value="$2" tmp
    if [ -f "$RPCS3_VFS" ] && grep -Fq "$key" "$RPCS3_VFS"; then
        tmp="$(mktemp)"
        awk -v key="$key" -v value="$value" '
            index($0, key) == 1 { print key " " value; next }
            { print }
        ' "$RPCS3_VFS" > "$tmp"
        mv "$tmp" "$RPCS3_VFS"
    else
        printf '%s %s\n' "$key" "$value" >> "$RPCS3_VFS"
    fi
}

configure_rpcs3_vfs() {
    ensure_ps3_layout
    if [ ! -f "$RPCS3_VFS" ]; then
        cat > "$RPCS3_VFS" <<EOF
\$(EmulatorDir): ""
/dev_hdd0/: $RPCS3_DEV_HDD0/
/dev_hdd1/: \$(EmulatorDir)dev_hdd1/
/dev_flash/: \$(EmulatorDir)dev_flash/
/dev_flash2/: \$(EmulatorDir)dev_flash2/
/dev_flash3/: \$(EmulatorDir)dev_flash3/
/dev_usb000/: \$(EmulatorDir)dev_usb000/
/dev_bdvd/: ""
/app_home/: ""
/games/: $PS3_ROMS/
EOF
    else
        cp "$RPCS3_VFS" "${RPCS3_VFS}.bak.$(date +%s)" 2>/dev/null || true
        set_vfs_line "/dev_hdd0/:" "$RPCS3_DEV_HDD0/"
        set_vfs_line "/games/:" "$PS3_ROMS/"
    fi
    pz_info "RPCS3 VFS configured: $RPCS3_VFS"
}

install_with_rpcs3() {
    local mode="$1" file="$2" app
    app="$(detect_rpcs3)"
    if [ -z "$app" ] || [ ! -x "$app" ]; then
        pz_warn "RPCS3 executable not found; staged only: $file"
        return 0
    fi
    case "$mode" in
        firmware) "$app" --installfw "$file" ;;
        pkg) "$app" --installpkg "$file" ;;
        *) pz_error "unknown RPCS3 install mode: $mode"; return 1 ;;
    esac
}

copy_local_game() {
    local dest
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation ps3 import-game <local-path>"; return 1; }
    pz_emulation_require_local_source "$SOURCE"
    ensure_ps3_layout
    if [ -d "$SOURCE" ] && [ -d "$SOURCE/PS3_GAME" ]; then
        dest="$PS3_ROMS/$(basename "$SOURCE")"
        rm -rf "$dest"
        cp -a "$SOURCE" "$dest"
    else
        pz_emulation_copy_source "$SOURCE" "$PS3_ROMS"
    fi
    configure_rpcs3_vfs
    bash "$PZ_ROOT/linux/emulation/hydra.sh" force-classic-config >/dev/null 2>&1 || true
    bash "$PZ_ROOT/linux/emulation/srm.sh" configure >/dev/null 2>&1 || true
    pz_info "PS3 local game imported into $PS3_ROMS"
}

import_firmware() {
    local file dest
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation ps3 import-firmware <local-PS3UPDAT.PUP>"; return 1; }
    pz_emulation_require_local_source "$SOURCE"
    [ -f "$SOURCE" ] || { pz_error "firmware source must be a file"; return 1; }
    ensure_ps3_layout
    file="$(basename "$SOURCE")"
    dest="$PS3_FIRMWARE/$file"
    cp -f "$SOURCE" "$dest"
    configure_rpcs3_vfs
    install_with_rpcs3 firmware "$dest"
    pz_info "PS3 firmware staged: $dest"
}

import_pkg() {
    local file dest found=0
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation ps3 import-pkg <local-pkg-or-folder>"; return 1; }
    pz_emulation_require_local_source "$SOURCE"
    ensure_ps3_layout
    if [ -d "$SOURCE" ]; then
        while IFS= read -r -d '' file; do
            found=1
            dest="$PS3_PKG/$(basename "$file")"
            cp -f "$file" "$dest"
            install_with_rpcs3 pkg "$dest"
        done < <(find "$SOURCE" -maxdepth 1 -type f -iname '*.pkg' -print0)
    else
        found=1
        dest="$PS3_PKG/$(basename "$SOURCE")"
        cp -f "$SOURCE" "$dest"
        install_with_rpcs3 pkg "$dest"
    fi
    [ "$found" -eq 1 ] || { pz_error "no .pkg files found in $SOURCE"; return 1; }
    configure_rpcs3_vfs
    bash "$PZ_ROOT/linux/emulation/srm.sh" configure >/dev/null 2>&1 || true
    pz_info "PS3 PKG staged in $PS3_PKG"
}

import_rap() {
    local file found=0
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation ps3 import-rap <local-rap-or-folder>"; return 1; }
    pz_emulation_require_local_source "$SOURCE"
    ensure_ps3_layout
    if [ -d "$SOURCE" ]; then
        while IFS= read -r -d '' file; do
            found=1
            cp -f "$file" "$RPCS3_EXDATA/$(basename "$file")"
        done < <(find "$SOURCE" -maxdepth 1 -type f -iname '*.rap' -print0)
    else
        found=1
        cp -f "$SOURCE" "$RPCS3_EXDATA/$(basename "$SOURCE")"
    fi
    [ "$found" -eq 1 ] || { pz_error "no .rap files found in $SOURCE"; return 1; }
    configure_rpcs3_vfs
    pz_info "PS3 RAP files imported into $RPCS3_EXDATA"
}

ps3_count() {
    local dir="$1" pattern="${2:-*}"
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" -maxdepth 1 -type f -iname "$pattern" 2>/dev/null | wc -l | tr -d ' '
}

ps3_top_count() {
    [ -d "$PS3_ROMS" ] || { echo 0; return 0; }
    find "$PS3_ROMS" -mindepth 1 -maxdepth 1 ! -name pkg 2>/dev/null | wc -l | tr -d ' '
}

vfs_configured_bool() {
    [ -f "$RPCS3_VFS" ] || { echo false; return 0; }
    grep -Fq "/dev_hdd0/: $RPCS3_DEV_HDD0/" "$RPCS3_VFS" &&
        grep -Fq "/games/: $PS3_ROMS/" "$RPCS3_VFS" &&
        echo true || echo false
}

status_ps3() {
    local app
    app="$(detect_rpcs3)"
    jq -n \
        --arg rpcs3 "$app" \
        --arg roms "$PS3_ROMS" \
        --arg pkg "$PS3_PKG" \
        --arg firmware "$PS3_FIRMWARE" \
        --arg devHdd0 "$RPCS3_DEV_HDD0" \
        --arg exdata "$RPCS3_EXDATA" \
        --arg vfs "$RPCS3_VFS" \
        --argjson rpcs3Installed "$([ -n "$app" ] && [ -x "$app" ] && echo true || echo false)" \
        --argjson gameEntries "$(ps3_top_count)" \
        --argjson pkgFiles "$(ps3_count "$PS3_PKG" '*.pkg')" \
        --argjson rapFiles "$(ps3_count "$RPCS3_EXDATA" '*.rap')" \
        --argjson firmwareFiles "$(ps3_count "$PS3_FIRMWARE" '*.PUP')" \
        --argjson vfsConfigured "$(vfs_configured_bool)" \
        '{rpcs3: $rpcs3, rpcs3Installed: $rpcs3Installed, roms: $roms, pkgStaging: $pkg, firmware: $firmware, devHdd0: $devHdd0, exdata: $exdata, vfs: $vfs, vfsConfigured: $vfsConfigured, gameEntries: $gameEntries, pkgFiles: $pkgFiles, rapFiles: $rapFiles, firmwareFiles: $firmwareFiles, policy: "local-user-owned-import-only"}'
}

dry_run_ps3() {
    cat <<EOF
PS3 dry-run
  roms:      $PS3_ROMS
  pkg:       $PS3_PKG
  firmware:  $PS3_FIRMWARE
  exdata:    $RPCS3_EXDATA
  vfs:       $RPCS3_VFS
  rpcs3:     $(detect_rpcs3)
  allowed:   local user-owned dumps, PKG, RAP, PS3UPDAT.PUP
  blocked:   remote ROM/PSN/PKG/RAP download sources
EOF
}

case "$ACTION" in
    status) status_ps3 ;;
    dry-run|plan) dry_run_ps3 ;;
    configure|integrate) configure_rpcs3_vfs; bash "$PZ_ROOT/linux/emulation/hydra.sh" force-classic-config >/dev/null 2>&1 || true; bash "$PZ_ROOT/linux/emulation/srm.sh" configure >/dev/null 2>&1 || true ;;
    import-game|import) copy_local_game ;;
    import-firmware|firmware) import_firmware ;;
    import-pkg|pkg) import_pkg ;;
    import-rap|rap) import_rap ;;
    *) pz_error "usage: ps3.sh (status|dry-run|configure|import-game <path>|import-firmware <PS3UPDAT.PUP>|import-pkg <path>|import-rap <path>)"; exit 1 ;;
esac
