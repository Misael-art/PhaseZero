#!/usr/bin/env bash
# sony.sh - local-only PS1/PS2 import and emulator integration
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

SYSTEM="${1:-ps1}"
ACTION="${2:-status}"
SOURCE="${3:-}"

PS1_ROMS="$PZ_EMULATION_ROOT/roms/psx"
PS2_ROMS="$PZ_EMULATION_ROOT/roms/ps2"
DUCKSTATION_CONFIG="${XDG_DATA_HOME:-$HOME/.local/share}/duckstation/settings.ini"
PCSX2_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/PCSX2/inis/PCSX2.ini"

ini_set() {
    local file="$1" section="$2" key="$3" value="$4" tmp
    install -d "$(dirname "$file")"
    [ -f "$file" ] || printf '[%s]\n' "$section" > "$file"
    pz_backup_file "$file" user >/dev/null
    tmp="$(mktemp)"
    awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { in_section = 0; done = 0 }
        $0 == "[" section "]" { in_section = 1; print; next }
        /^\[/ {
            if (in_section && !done) {
                print key " = " value
                done = 1
            }
            in_section = 0
            print
            next
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            print key " = " value
            done = 1
            next
        }
        { print }
        END {
            if (!done) {
                if (!in_section) {
                    print "[" section "]"
                }
                print key " = " value
            }
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

count_matching_files() {
    local dir="$1"
    shift
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" -maxdepth 1 -type f \( "$@" \) 2>/dev/null | wc -l | tr -d ' '
}

ensure_ps1_layout() {
    pz_emulation_ensure_layout
    install -d "$PS1_ROMS" "$PZ_EMULATION_ROOT/saves/duckstation/saves" "$PZ_EMULATION_ROOT/saves/duckstation/states"
}

ensure_ps2_layout() {
    pz_emulation_ensure_layout
    install -d "$PS2_ROMS" \
        "$PZ_EMULATION_ROOT/saves/pcsx2/saves" \
        "$PZ_EMULATION_ROOT/saves/pcsx2/states" \
        "$PZ_EMULATION_ROOT/storage/pcsx2/covers" \
        "$PZ_EMULATION_ROOT/storage/pcsx2/snaps" \
        "$PZ_EMULATION_ROOT/storage/pcsx2/cache" \
        "$PZ_EMULATION_ROOT/storage/pcsx2/textures"
}

configure_ps1() {
    ensure_ps1_layout
    ini_set "$DUCKSTATION_CONFIG" "BIOS" "SearchDirectory" "$PZ_EMULATION_ROOT/bios"
    ini_set "$DUCKSTATION_CONFIG" "MemoryCards" "Directory" "$PZ_EMULATION_ROOT/saves/duckstation/saves"
    ini_set "$DUCKSTATION_CONFIG" "Folders" "SaveStates" "$PZ_EMULATION_ROOT/saves/duckstation/states"
    ini_set "$DUCKSTATION_CONFIG" "GameList" "RecursivePaths" "$PS1_ROMS"
    bash "$PZ_ROOT/linux/emulation/hydra.sh" force-classic-config >/dev/null 2>&1 || true
    bash "$PZ_ROOT/linux/emulation/srm.sh" configure --skip-if-configured >/dev/null 2>&1 || true
    pz_info "PS1 DuckStation configured: $DUCKSTATION_CONFIG"
}

configure_ps2() {
    ensure_ps2_layout
    ini_set "$PCSX2_CONFIG" "Folders" "Covers" "$PZ_EMULATION_ROOT/storage/pcsx2/covers"
    ini_set "$PCSX2_CONFIG" "Folders" "Bios" "$PZ_EMULATION_ROOT/bios"
    ini_set "$PCSX2_CONFIG" "Folders" "Snapshots" "$PZ_EMULATION_ROOT/storage/pcsx2/snaps"
    ini_set "$PCSX2_CONFIG" "Folders" "Savestates" "$PZ_EMULATION_ROOT/saves/pcsx2/states"
    ini_set "$PCSX2_CONFIG" "Folders" "MemoryCards" "$PZ_EMULATION_ROOT/saves/pcsx2/saves"
    ini_set "$PCSX2_CONFIG" "Folders" "Cache" "$PZ_EMULATION_ROOT/storage/pcsx2/cache"
    ini_set "$PCSX2_CONFIG" "Folders" "Textures" "$PZ_EMULATION_ROOT/storage/pcsx2/textures"
    ini_set "$PCSX2_CONFIG" "GameList" "RecursivePaths" "$PS2_ROMS"
    bash "$PZ_ROOT/linux/emulation/hydra.sh" force-classic-config >/dev/null 2>&1 || true
    bash "$PZ_ROOT/linux/emulation/srm.sh" configure --skip-if-configured >/dev/null 2>&1 || true
    pz_info "PS2 PCSX2 configured: $PCSX2_CONFIG"
}

import_local_game() {
    local dest
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation $SYSTEM import-game <local-path>"; return 1; }
    pz_emulation_require_local_source "$SOURCE"
    case "$SYSTEM" in
        ps1|psx)
            ensure_ps1_layout
            dest="$PS1_ROMS"
            ;;
        ps2)
            ensure_ps2_layout
            dest="$PS2_ROMS"
            ;;
        *) pz_error "unknown Sony system: $SYSTEM"; return 1 ;;
    esac
    pz_emulation_copy_source "$SOURCE" "$dest"
    configure_system
    pz_info "${SYSTEM^^} local game imported into $dest"
}

configured_ps1_bool() {
    [ -f "$DUCKSTATION_CONFIG" ] || { echo false; return 0; }
    grep -Fq "SearchDirectory = $PZ_EMULATION_ROOT/bios" "$DUCKSTATION_CONFIG" &&
        grep -Fq "RecursivePaths = $PS1_ROMS" "$DUCKSTATION_CONFIG" &&
        echo true || echo false
}

configured_ps2_bool() {
    [ -f "$PCSX2_CONFIG" ] || { echo false; return 0; }
    grep -Fq "Bios = $PZ_EMULATION_ROOT/bios" "$PCSX2_CONFIG" &&
        grep -Fq "RecursivePaths = $PS2_ROMS" "$PCSX2_CONFIG" &&
        echo true || echo false
}

status_ps1() {
    jq -n \
        --arg emulator "$PZ_APPLICATIONS_DIR/DuckStation.AppImage" \
        --arg config "$DUCKSTATION_CONFIG" \
        --arg roms "$PS1_ROMS" \
        --arg bios "$PZ_EMULATION_ROOT/bios" \
        --arg saves "$PZ_EMULATION_ROOT/saves/duckstation/saves" \
        --arg states "$PZ_EMULATION_ROOT/saves/duckstation/states" \
        --argjson installed "$([ -x "$PZ_APPLICATIONS_DIR/DuckStation.AppImage" ] && echo true || echo false)" \
        --argjson configured "$(configured_ps1_bool)" \
        --argjson gameFiles "$(count_matching_files "$PS1_ROMS" -iname '*.chd' -o -iname '*.cue' -o -iname '*.bin' -o -iname '*.img' -o -iname '*.iso' -o -iname '*.pbp' -o -iname '*.m3u')" \
        '{system: "ps1", emulator: "DuckStation", executable: $emulator, installed: $installed, config: $config, configured: $configured, roms: $roms, bios: $bios, saves: $saves, states: $states, gameFiles: $gameFiles, policy: "local-user-owned-import-only"}'
}

status_ps2() {
    jq -n \
        --arg emulator "$PZ_APPLICATIONS_DIR/pcsx2-Qt.AppImage" \
        --arg config "$PCSX2_CONFIG" \
        --arg roms "$PS2_ROMS" \
        --arg bios "$PZ_EMULATION_ROOT/bios" \
        --arg saves "$PZ_EMULATION_ROOT/saves/pcsx2/saves" \
        --arg states "$PZ_EMULATION_ROOT/saves/pcsx2/states" \
        --argjson installed "$([ -x "$PZ_APPLICATIONS_DIR/pcsx2-Qt.AppImage" ] && echo true || echo false)" \
        --argjson configured "$(configured_ps2_bool)" \
        --argjson gameFiles "$(count_matching_files "$PS2_ROMS" -iname '*.chd' -o -iname '*.iso' -o -iname '*.cso' -o -iname '*.gz' -o -iname '*.bin' -o -iname '*.mdf' -o -iname '*.nrg')" \
        '{system: "ps2", emulator: "PCSX2-Qt", executable: $emulator, installed: $installed, config: $config, configured: $configured, roms: $roms, bios: $bios, saves: $saves, states: $states, gameFiles: $gameFiles, policy: "local-user-owned-import-only"}'
}

configure_system() {
    case "$SYSTEM" in
        ps1|psx) configure_ps1 ;;
        ps2) configure_ps2 ;;
        *) pz_error "usage: sony.sh (ps1|ps2) (status|configure|import-game|dry-run) [path]"; return 1 ;;
    esac
}

status_system() {
    case "$SYSTEM" in
        ps1|psx) status_ps1 ;;
        ps2) status_ps2 ;;
        *) pz_error "usage: sony.sh (ps1|ps2) (status|configure|import-game|dry-run) [path]"; return 1 ;;
    esac
}

dry_run_system() {
    case "$SYSTEM" in
        ps1|psx)
            cat <<EOF
PS1 dry-run
  emulator: DuckStation
  roms:     $PS1_ROMS
  config:   $DUCKSTATION_CONFIG
  bios:     $PZ_EMULATION_ROOT/bios
  allowed:  local user-owned disc images/dumps
EOF
            ;;
        ps2)
            cat <<EOF
PS2 dry-run
  emulator: PCSX2-Qt
  roms:     $PS2_ROMS
  config:   $PCSX2_CONFIG
  bios:     $PZ_EMULATION_ROOT/bios
  allowed:  local user-owned disc images/dumps
EOF
            ;;
        *) pz_error "usage: sony.sh (ps1|ps2) (status|configure|import-game|dry-run) [path]"; return 1 ;;
    esac
}

case "$ACTION" in
    status) status_system ;;
    configure|integrate) configure_system ;;
    import-game|import) import_local_game ;;
    dry-run|plan) dry_run_system ;;
    *) pz_error "usage: sony.sh (ps1|ps2) (status|configure|import-game|dry-run) [path]"; exit 1 ;;
esac
