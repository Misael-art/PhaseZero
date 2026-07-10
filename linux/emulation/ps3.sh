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
RPCS3_WRAPPER="$PZ_LOCAL_BIN/phasezero-rpcs3"

detect_rpcs3() {
    if [ -n "${PZ_RPCS3_APP:-}" ]; then
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

write_rpcs3_wrapper() {
    local app
    app="$(detect_rpcs3)"
    [ -n "$app" ] || return 0
    install -d "$PZ_LOCAL_BIN"
    pz_emulation_write_file "$RPCS3_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
app="$app"
performance="$PZ_LOCAL_BIN/phasezero-emulation-launch"
if [ ! -x "\$app" ] && [ -f "\$app" ]; then
    chmod +x "\$app" 2>/dev/null || true
fi
if [ ! -e "\$app" ]; then
    echo "rpcs3 target not found: \$app" >&2
    exit 1
fi
if [ -x "\$performance" ]; then
    exec "\$performance" ps3 -- "\$app" "\$@"
fi
if command -v gamemoderun >/dev/null 2>&1; then
    exec env MANGOHUD=1 gamemoderun "\$app" "\$@"
fi
exec env MANGOHUD=1 "\$app" "\$@"
EOF
}

ps3_esde_system_block() {
    local flatpak="${1:-false}" launcher shell_prefix
    launcher="$RPCS3_WRAPPER"
    if [ "$flatpak" = "true" ]; then
        launcher="flatpak-spawn --host $RPCS3_WRAPPER"
        shell_prefix="flatpak-spawn --host "
    else
        shell_prefix=""
    fi
    cat <<EOF
  <system>
    <name>ps3</name>
    <fullname>Sony PlayStation 3</fullname>
    <path>%ROMPATH%/ps3</path>
    <extension>.desktop .iso .ISO .ps3 .PS3 .ps3dir .PS3DIR .sh .SH</extension>
    <command label="RPCS3 ISO (Standalone)">$launcher --no-gui %ROM%</command>
    <command label="RPCS3 Directory (Standalone)">$launcher --no-gui %ROM%</command>
    <command label="RPCS3 Game Serial (Standalone)">$launcher --no-gui %RPCS3_GAMEID%:%INJECT%=%BASENAME%.ps3</command>
    <command label="RPCS3 Shortcut (Standalone)">${shell_prefix}/bin/bash %ROM%</command>
    <platform>ps3</platform>
    <theme>ps3</theme>
  </system>
EOF
}

write_esde_system_file() {
    local path="$1" flatpak="${2:-false}" tmp
    tmp="$(mktemp)"
    if [ -f "$path" ]; then
        python3 - "$path" "$tmp" "$flatpak" "$RPCS3_WRAPPER" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
tmp = Path(sys.argv[2])
flatpak = sys.argv[3] == "true"
wrapper = sys.argv[4]

try:
    tree = ET.parse(path)
    root = tree.getroot()
except Exception:
    root = ET.Element("systemList")
    tree = ET.ElementTree(root)
if root.tag != "systemList":
    root = ET.Element("systemList")
    tree = ET.ElementTree(root)
for system in list(root.findall("system")):
    if system.findtext("name") == "ps3":
        root.remove(system)
system = ET.Element("system")
values = {
    "name": "ps3",
    "fullname": "Sony PlayStation 3",
    "path": "%ROMPATH%/ps3",
    "extension": ".desktop .iso .ISO .ps3 .PS3 .ps3dir .PS3DIR .sh .SH",
}
for key, value in values.items():
    node = ET.SubElement(system, key)
    node.text = value
launcher = f"flatpak-spawn --host {wrapper}" if flatpak else wrapper
shell = "flatpak-spawn --host /bin/bash %ROM%" if flatpak else "/bin/bash %ROM%"
commands = [
    ("RPCS3 ISO (Standalone)", f"{launcher} --no-gui %ROM%"),
    ("RPCS3 Directory (Standalone)", f"{launcher} --no-gui %ROM%"),
    ("RPCS3 Game Serial (Standalone)", f"{launcher} --no-gui %RPCS3_GAMEID%:%INJECT%=%BASENAME%.ps3"),
    ("RPCS3 Shortcut (Standalone)", shell),
]
for label, text in commands:
    node = ET.SubElement(system, "command")
    node.set("label", label)
    node.text = text
for key, value in {"platform": "ps3", "theme": "ps3"}.items():
    node = ET.SubElement(system, key)
    node.text = value
root.append(system)
ET.indent(tree, space="  ")
tree.write(tmp, encoding="utf-8", xml_declaration=True)
PY
        if ! cmp -s "$path" "$tmp"; then
            cp "$path" "${path}.bak.$(date +%s)" 2>/dev/null || true
            mv "$tmp" "$path"
        else
            rm -f "$tmp"
        fi
    else
        install -d "$(dirname "$path")"
        {
            printf '%s\n' '<?xml version="1.0"?>'
            printf '%s\n' '<systemList>'
            ps3_esde_system_block "$flatpak"
            printf '%s\n' '</systemList>'
        } > "$tmp"
        mv "$tmp" "$path"
    fi
}

configure_esde_ps3() {
    write_rpcs3_wrapper
    write_esde_system_file "$HOME/ES-DE/custom_systems/es_systems.xml" false
    write_esde_system_file "$HOME/.emulationstation/custom_systems/es_systems.xml" false
    write_esde_system_file "$(pz_retrodeck_root)/ES-DE/custom_systems/es_systems.xml" true
    pz_info "ES-DE/RetroDECK PS3 launcher -> $RPCS3_WRAPPER"
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
    bash "$PZ_ROOT/linux/emulation/srm.sh" configure --skip-if-configured >/dev/null 2>&1 || true
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
    bash "$PZ_ROOT/linux/emulation/srm.sh" configure --skip-if-configured >/dev/null 2>&1 || true
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
        --arg wrapper "$RPCS3_WRAPPER" \
        --argjson rpcs3Installed "$([ -n "$app" ] && [ -x "$app" ] && echo true || echo false)" \
        --argjson wrapperInstalled "$([ -x "$RPCS3_WRAPPER" ] && echo true || echo false)" \
        --argjson esdeConfigured "$([ -f "$HOME/ES-DE/custom_systems/es_systems.xml" ] && grep -q 'phasezero-rpcs3' "$HOME/ES-DE/custom_systems/es_systems.xml" && echo true || echo false)" \
        --argjson retrodeckConfigured "$([ -f "$(pz_retrodeck_root)/ES-DE/custom_systems/es_systems.xml" ] && grep -q 'phasezero-rpcs3' "$(pz_retrodeck_root)/ES-DE/custom_systems/es_systems.xml" && echo true || echo false)" \
        --argjson gameEntries "$(ps3_top_count)" \
        --argjson pkgFiles "$(ps3_count "$PS3_PKG" '*.pkg')" \
        --argjson rapFiles "$(ps3_count "$RPCS3_EXDATA" '*.rap')" \
        --argjson firmwareFiles "$(ps3_count "$PS3_FIRMWARE" '*.PUP')" \
        --argjson vfsConfigured "$(vfs_configured_bool)" \
        '{rpcs3: $rpcs3, rpcs3Installed: $rpcs3Installed, wrapper: $wrapper, wrapperInstalled: $wrapperInstalled, esdeConfigured: $esdeConfigured, retrodeckConfigured: $retrodeckConfigured, roms: $roms, pkgStaging: $pkg, firmware: $firmware, devHdd0: $devHdd0, exdata: $exdata, vfs: $vfs, vfsConfigured: $vfsConfigured, gameEntries: $gameEntries, pkgFiles: $pkgFiles, rapFiles: $rapFiles, firmwareFiles: $firmwareFiles, policy: "local-user-owned-import-only"}'
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
    configure|integrate) configure_rpcs3_vfs; bash "$PZ_ROOT/linux/emulation/performance.sh" apply >/dev/null 2>&1 || true; configure_esde_ps3; bash "$PZ_ROOT/linux/emulation/hydra.sh" force-classic-config >/dev/null 2>&1 || true; bash "$PZ_ROOT/linux/emulation/srm.sh" configure >/dev/null 2>&1 || true ;;
    import-game|import) copy_local_game ;;
    import-firmware|firmware) import_firmware ;;
    import-pkg|pkg) import_pkg ;;
    import-rap|rap) import_rap ;;
    *) pz_error "usage: ps3.sh (status|dry-run|configure|import-game <path>|import-firmware <PS3UPDAT.PUP>|import-pkg <path>|import-rap <path>)"; exit 1 ;;
esac
