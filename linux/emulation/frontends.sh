#!/usr/bin/env bash
# frontends.sh - switch between BigBox, Steam Big Picture, ES-DE, SRM and Heroic.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
PZ_FRONTENDS_DIR="${PZ_FRONTENDS_DIR:-$PZ_EMULATION_ROOT/tools/launchers/frontends}"
PZ_FRONTENDS_TOOL="$PZ_ROOT/linux/emulation/frontends.py"
PZ_FRONTEND_WRAPPER="$PZ_LOCAL_BIN/phasezero-frontend"
PZ_HEROIC_WRAPPER="$PZ_LOCAL_BIN/phasezero-heroic"
PZ_STEAM_BIGPICTURE_WRAPPER="$PZ_LOCAL_BIN/phasezero-steam-big-picture"

frontend_rows() {
    cat <<EOF
bigbox|Big Box|bigbox.sh|$PZ_LOCAL_BIN/phasezero-bigbox
launchbox|LaunchBox|launchbox.sh|$PZ_LOCAL_BIN/phasezero-launchbox
es-de|ES-DE|es-de.sh|$PZ_LOCAL_BIN/phasezero-es-de
steam-big-picture|Steam Big Picture|steam-big-picture.sh|$PZ_STEAM_BIGPICTURE_WRAPPER
srm|Steam ROM Manager|srm.sh|$PZ_LOCAL_BIN/phasezero-srm
heroic|Heroic Launcher|heroic.sh|$PZ_HEROIC_WRAPPER
return|Return to Gaming Mode|return.sh|$PZ_LOCAL_BIN/phasezero-return
windows-vm|Windows VM|windows-vm.sh|$PZ_LOCAL_BIN/phasezero-windows-vm
waydroid|Waydroid|waydroid.sh|$PZ_LOCAL_BIN/phasezero-waydroid
EOF
}

frontends_python() {
    python3 "$PZ_FRONTENDS_TOOL" "$@"
}

find_heroic_appimage() {
    {
        find "$PZ_APPLICATIONS_DIR" "$PZ_EMULATION_ROOT/tools" "${PZ_APPIMAGE_DIR:-$HOME/Appimage}" \
            -maxdepth 2 -type f \( -iname '*Heroic*.AppImage' -o -iname '*heroic*.AppImage' \) 2>/dev/null || true
    } | sort | head -1
}

first_existing_frontend_path() {
    local candidate match
    for candidate in "$@"; do
        [ -n "$candidate" ] || continue
        if [[ "$candidate" == *"*"* || "$candidate" == *"?"* || "$candidate" == *"["* ]]; then
            while IFS= read -r match; do
                [ -f "$match" ] || [ -x "$match" ] || continue
                printf '%s\n' "$match"
                return 0
            done < <(compgen -G "$candidate" | sort 2>/dev/null || true)
        elif [ -f "$candidate" ] || [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

write_esde_wrapper() {
    local target
    target="$(first_existing_frontend_path \
        "$PZ_LOCAL_BIN/phasezero-es-de" \
        "$PZ_APPLICATIONS_DIR/ES-DE.AppImage" \
        "${PZ_APPIMAGE_DIR:-$HOME/Appimage}/ES-DE"*.AppImage \
        "$PZ_EMULATION_ROOT/tools/launchers/es-de/es-de.sh" \
        "$PZ_EMULATION_ROOT/tools/launchers/esde/emulationstationde.sh" 2>/dev/null || true)"
    if [ "$target" = "$PZ_LOCAL_BIN/phasezero-es-de" ] && [ -x "$target" ]; then
        return 0
    fi
    pz_emulation_write_file "$PZ_LOCAL_BIN/phasezero-es-de" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
target="$target"
if [ -n "\$target" ] && [ -f "\$target" ]; then
    chmod +x "\$target" 2>/dev/null || true
    exec "\$target" "\$@"
fi
if command -v ES-DE >/dev/null 2>&1; then
    exec ES-DE "\$@"
fi
if command -v es-de >/dev/null 2>&1; then
    exec es-de "\$@"
fi
if command -v emulationstation >/dev/null 2>&1; then
    exec emulationstation "\$@"
fi
echo "ES-DE not found." >&2
exit 1
EOF
}

write_srm_wrapper() {
    local target
    target="$(first_existing_frontend_path \
        "$PZ_LOCAL_BIN/phasezero-srm" \
        "$PZ_EMULATION_ROOT/tools/launchers/srm/steamrommanager.sh" \
        "$HOME/.config/EmuDeck/backend/tools/launchers/srm/steamrommanager.sh" \
        "$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage" \
        "$PZ_EMULATION_ROOT/tools/Steam ROM Manager.AppImage" \
        "$PZ_APPLICATIONS_DIR/Steam-ROM-Manager.AppImage" \
        "${PZ_APPIMAGE_DIR:-$HOME/Appimage}/Steam-ROM-Manager"*.AppImage \
        "${PZ_APPIMAGE_DIR:-$HOME/Appimage}/Steam*ROM*Manager"*.AppImage 2>/dev/null || true)"
    if [ "$target" = "$PZ_LOCAL_BIN/phasezero-srm" ] && [ -x "$target" ]; then
        return 0
    fi
    pz_emulation_write_file "$PZ_LOCAL_BIN/phasezero-srm" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
target="$target"
if [ -n "\$target" ] && [ -f "\$target" ]; then
    chmod +x "\$target" 2>/dev/null || true
    exec "\$target" "\$@"
fi
if command -v steam-rom-manager >/dev/null 2>&1; then
    exec steam-rom-manager "\$@"
fi
echo "Steam ROM Manager not found." >&2
exit 1
EOF
}

write_heroic_wrapper() {
    local appimage
    appimage="$(find_heroic_appimage)"
    pz_emulation_write_file "$PZ_HEROIC_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
PZ_ROOT="$PZ_ROOT"
export PZ_EMULATION_ROOT="$PZ_EMULATION_ROOT"
appimage="$appimage"
python3 "\$PZ_ROOT/linux/emulation/heroic.py" session --mode auto >/dev/null 2>&1 || true
if command -v heroic >/dev/null 2>&1; then
    exec heroic "\$@"
fi
if command -v heroic-games-launcher >/dev/null 2>&1; then
    exec heroic-games-launcher "\$@"
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info com.heroicgameslauncher.hgl >/dev/null 2>&1; then
    exec flatpak run com.heroicgameslauncher.hgl "\$@"
fi
if [ -n "\$appimage" ] && [ -f "\$appimage" ]; then
    chmod +x "\$appimage" 2>/dev/null || true
    exec "\$appimage" "\$@"
fi
echo "Heroic Launcher not found." >&2
exit 1
EOF
}

write_steam_bigpicture_wrapper() {
    pz_emulation_write_file "$PZ_STEAM_BIGPICTURE_WRAPPER" 0755 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v steam >/dev/null 2>&1; then
    echo "steam not found" >&2
    exit 1
fi
steam steam://open/bigpicture >/dev/null 2>&1 && exit 0
exec steam -gamepadui -steamos3 "$@"
EOF
}

write_frontend_router() {
    pz_emulation_write_file "$PZ_FRONTEND_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
PZ_ROOT="$PZ_ROOT"
export PZ_EMULATION_ROOT="$PZ_EMULATION_ROOT"
export PZ_FRONTENDS_DIR="$PZ_FRONTENDS_DIR"
exec "\$PZ_ROOT/linux/emulation/frontends.sh" launch "\$@"
EOF
}

write_frontend_launchers() {
    local id title file target
    install -d "$PZ_FRONTENDS_DIR"
    while IFS='|' read -r id title file target; do
        [ -n "$id" ] || continue
        if [ "$id" = "heroic" ]; then
            pz_emulation_write_file "$PZ_FRONTENDS_DIR/$file" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PZ_HEROIC_CONSOLE_MODE="\${PZ_HEROIC_CONSOLE_MODE:-1}"
exec "$PZ_FRONTEND_WRAPPER" "$id" "\$@"
EOF
            continue
        fi
        pz_emulation_write_file "$PZ_FRONTENDS_DIR/$file" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$PZ_FRONTEND_WRAPPER" "$id" "\$@"
EOF
    done < <(frontend_rows)
}

write_frontend_desktops() {
    pz_emulation_write_file "$PZ_DESKTOP_DIR/phasezero-steam-big-picture.desktop" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=Steam Big Picture
Comment=Steam Big Picture managed by PhaseZero
Exec=$PZ_STEAM_BIGPICTURE_WRAPPER
Terminal=false
Icon=$PZ_EMULATION_ROOT/media/icons/phasezero/steam.svg
Categories=Game;
X-PhaseZero-Managed=true
EOF
    pz_emulation_write_file "$PZ_DESKTOP_DIR/phasezero-heroic.desktop" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=Heroic Launcher
Comment=Heroic Launcher managed by PhaseZero
Exec=$PZ_HEROIC_WRAPPER
Terminal=false
Icon=$PZ_EMULATION_ROOT/media/icons/phasezero/heroic.svg
Categories=Game;
X-PhaseZero-Managed=true
EOF
    pz_emulation_write_file "$PZ_DESKTOP_DIR/phasezero-frontends.desktop" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=PhaseZero Frontends
Comment=Switch emulation frontend experience
Exec=$PZ_FRONTEND_WRAPPER
Terminal=true
Icon=$PZ_EMULATION_ROOT/media/icons/phasezero/frontends.svg
Categories=Game;Emulator;
X-PhaseZero-Managed=true
EOF
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
}

ensure_base_frontends() {
    pz_emulation_ensure_layout
    bash "$PZ_ROOT/linux/steamdeck/convenience-launchers.sh" install >/dev/null
    if [ -f "${PZ_LAUNCHBOX_ROOT:-$PZ_EMULATION_ROOT/tools/launchers/LaunchBox}/LaunchBox.exe" ] &&
        { [ ! -x "$PZ_LOCAL_BIN/phasezero-bigbox" ] || [ ! -x "$PZ_LOCAL_BIN/phasezero-launchbox" ]; }; then
        bash "$PZ_ROOT/linux/emulation/launchbox.sh" repair >/dev/null || pz_warn "LaunchBox repair skipped"
    fi
    write_esde_wrapper
    write_srm_wrapper
}

cmd_repair() {
    pz_emulation_abort_if_frontend_running
    ensure_base_frontends
    write_heroic_wrapper
    write_steam_bigpicture_wrapper
    write_frontend_router
    write_frontend_launchers
    write_frontend_desktops
    frontends_python apply
    pz_info "frontend switcher integrated: $PZ_FRONTENDS_DIR"
}

cmd_plan() {
    frontends_python plan
}

cmd_status() {
    frontends_python status "$@"
}

cmd_launch() {
    local id="${1:-}" target=""
    [ -n "$id" ] || {
        echo "usage: phasezero-frontend <bigbox|launchbox|es-de|steam-big-picture|srm|heroic|return|windows-vm|waydroid>" >&2
        frontend_rows | awk -F'|' '{printf "  %-18s %s\n", $1, $2}' >&2
        return 2
    }
    case "$id" in
        bigbox|big-box) target="$PZ_LOCAL_BIN/phasezero-bigbox" ;;
        launchbox) target="$PZ_LOCAL_BIN/phasezero-launchbox" ;;
        es-de|esde|emulationstation) target="$PZ_LOCAL_BIN/phasezero-es-de" ;;
        steam-big-picture|big-picture|steam) target="$PZ_STEAM_BIGPICTURE_WRAPPER" ;;
        srm|steam-rom-manager) target="$PZ_LOCAL_BIN/phasezero-srm" ;;
        heroic|heroic-launcher) target="$PZ_HEROIC_WRAPPER" ;;
        return|gaming-mode) target="$PZ_LOCAL_BIN/phasezero-return" ;;
        windows-vm|windows) target="$PZ_LOCAL_BIN/phasezero-windows-vm" ;;
        waydroid|android) target="$PZ_LOCAL_BIN/phasezero-waydroid" ;;
        *) pz_error "unknown frontend: $id"; return 2 ;;
    esac
    if [ ! -x "$target" ]; then
        cmd_repair >/dev/null
    fi
    [ -x "$target" ] || { pz_error "frontend target missing: $target"; return 1; }
    exec "$target" "${@:2}"
}

case "$ACTION" in
    status) shift || true; cmd_status "$@" ;;
    plan|dry-run) cmd_plan ;;
    repair|apply|integrate|install) cmd_repair ;;
    launch|open) shift || true; cmd_launch "$@" ;;
    *)
        pz_error "usage: frontends.sh (status|plan|repair|launch <frontend>)"
        exit 1
        ;;
esac
