#!/usr/bin/env bash
# launchbox.sh - integrate portable LaunchBox with PhaseZero Linux resources
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
PZ_LAUNCHBOX_ROOT="${PZ_LAUNCHBOX_ROOT:-$PZ_EMULATION_ROOT/tools/launchers/LaunchBox}"
PZ_LAUNCHBOX_WINEPREFIX="${PZ_LAUNCHBOX_WINEPREFIX:-$PZ_LAUNCHBOX_ROOT/.phasezero/wineprefix}"
PZ_LAUNCHBOX_COMPAT_ROMS="${PZ_LAUNCHBOX_COMPAT_ROMS:-$PZ_EMULATION_ROOT/tools/launchers/Roms}"
PZ_LAUNCHBOX_SCRIPT="$PZ_ROOT/linux/emulation/launchbox.py"
PZ_LAUNCHBOX_WRAPPER="$PZ_LOCAL_BIN/phasezero-launchbox"
PZ_BIGBOX_WRAPPER="$PZ_LOCAL_BIN/phasezero-bigbox"
PZ_LAUNCHBOX_DESKTOP="$PZ_DESKTOP_DIR/phasezero-launchbox.desktop"
PZ_BIGBOX_DESKTOP="$PZ_DESKTOP_DIR/phasezero-bigbox.desktop"

launchbox_python() {
    python3 "$PZ_LAUNCHBOX_SCRIPT" "$@"
}

launchbox_configure_wine() {
    local prefix_ready=0
    [ -f "$PZ_LAUNCHBOX_WINEPREFIX/system.reg" ] && [ -d "$PZ_LAUNCHBOX_WINEPREFIX/drive_c/windows/system32" ] && prefix_ready=1
    if [ "${PZ_LAUNCHBOX_SKIP_WINEBOOT:-0}" = "1" ]; then
        install -d "$PZ_LAUNCHBOX_WINEPREFIX/dosdevices"
        prefix_ready=1
    fi
    if [ "$prefix_ready" = "0" ] && [ -e "$PZ_LAUNCHBOX_WINEPREFIX" ]; then
        mv "$PZ_LAUNCHBOX_WINEPREFIX" "${PZ_LAUNCHBOX_WINEPREFIX}.broken.$(date +%s)"
    fi
    if [ "$prefix_ready" = "0" ]; then
        install -d "$(dirname "$PZ_LAUNCHBOX_WINEPREFIX")"
    fi
    if [ "$prefix_ready" = "1" ]; then
        :
    elif command -v wineboot >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout "${PZ_LAUNCHBOX_WINEBOOT_TIMEOUT:-120s}" env WINEARCH=win64 WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX" WINEDEBUG=-all wineboot -u >/dev/null 2>&1 || pz_warn "wineboot timed out or failed for $PZ_LAUNCHBOX_WINEPREFIX"
        else
            WINEARCH=win64 WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX" WINEDEBUG=-all wineboot -u >/dev/null 2>&1 || pz_warn "wineboot failed for $PZ_LAUNCHBOX_WINEPREFIX"
        fi
    else
        pz_warn "wineboot missing; LaunchBox wrapper still written"
    fi
    install -d "$PZ_LAUNCHBOX_WINEPREFIX/dosdevices" "$PZ_LAUNCHBOX_ROOT/.phasezero/drives/F" "$PZ_LAUNCHBOX_ROOT/.phasezero/drives/L"
    ln -sfn "$PZ_LAUNCHBOX_ROOT/.phasezero/drives/F" "$PZ_LAUNCHBOX_WINEPREFIX/dosdevices/f:"
    ln -sfn "$PZ_LAUNCHBOX_ROOT/.phasezero/drives/L" "$PZ_LAUNCHBOX_WINEPREFIX/dosdevices/l:"
    [ -e "$PZ_LAUNCHBOX_WINEPREFIX/dosdevices/z:" ] || ln -sfn / "$PZ_LAUNCHBOX_WINEPREFIX/dosdevices/z:"
    if [ "${PZ_LAUNCHBOX_SKIP_WINEBOOT:-0}" = "1" ]; then
        return 0
    fi
}

launchbox_fonts_ready() {
    [ -f "$PZ_LAUNCHBOX_WINEPREFIX/drive_c/windows/Fonts/arial.ttf" ] ||
        [ -f "$PZ_LAUNCHBOX_WINEPREFIX/drive_c/windows/Fonts/Arial.ttf" ]
}

launchbox_install_fonts() {
    launchbox_fonts_ready && return 0
    [ "${PZ_LAUNCHBOX_SKIP_FONTS:-0}" = "1" ] && return 0
    if command -v winetricks >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout "${PZ_LAUNCHBOX_WINETRICKS_TIMEOUT:-240s}" env WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX" WINEDEBUG=-all winetricks -q corefonts >/dev/null 2>&1 || pz_warn "winetricks corefonts failed for $PZ_LAUNCHBOX_WINEPREFIX"
        else
            WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX" WINEDEBUG=-all winetricks -q corefonts >/dev/null 2>&1 || pz_warn "winetricks corefonts failed for $PZ_LAUNCHBOX_WINEPREFIX"
        fi
    fi
    if ! launchbox_fonts_ready; then
        install -d "$PZ_LAUNCHBOX_WINEPREFIX/drive_c/windows/Fonts"
        local font
        for font in \
            /usr/share/fonts/liberation/LiberationSans-Regular.ttf \
            /usr/share/fonts/noto/NotoSans-Regular.ttf; do
            [ -f "$font" ] && cp -f "$font" "$PZ_LAUNCHBOX_WINEPREFIX/drive_c/windows/Fonts/" || true
        done
    fi
}

launchbox_apply_bigbox_safe_settings() {
    [ "${PZ_LAUNCHBOX_BIGBOX_SAFE_SETTINGS:-1}" = "1" ] || return 0
    python3 - "$PZ_LAUNCHBOX_ROOT" <<'PY'
import shutil
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])

def upsert(path: Path, parent_tag: str, values: dict[str, str]) -> None:
    if not path.exists():
        return
    try:
        tree = ET.parse(path)
    except ET.ParseError:
        return
    doc = tree.getroot()
    parent = doc.find(parent_tag)
    if parent is None:
        parent = doc
    changed = False
    for key, value in values.items():
        node = parent.find(key)
        if node is None:
            node = ET.SubElement(parent, key)
            changed = True
        if (node.text or "") != value:
            node.text = value
            changed = True
    if not changed:
        return
    shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))
    ET.indent(tree, space="  ")
    path.write_text('<?xml version="1.0" standalone="yes"?>\n' + ET.tostring(doc, encoding="unicode") + "\n", encoding="utf-8")

upsert(
    root / "Data" / "BigBoxSettings.xml",
    "BigBoxSettings",
    {
        "Theme": "Default",
        "StartupTheme": "Default",
        "PauseTheme": "Default",
        "VideoPlaybackEngine": "VLC",
        "ShowStartupSplashScreen": "false",
        "UseStartupScreen": "false",
        "PlayStartupSound": "false",
        "PlaySelectSound": "false",
        "PlayBackSound": "false",
        "PlayNavigationSound": "false",
        "AutoPlayMusicGamesList": "false",
        "AutoPlayMusicGameDetails": "false",
        "GamesUseBackgroundVideos": "false",
        "PlatformsUseRandomGameVideos": "false",
        "PlatformsUseBackgroundVideos": "false",
        "ShowGameMenuPlayVideo": "false",
        "ShowGameMenuViewVideoFullscreen": "false",
        "ShowGameMenuViewModelFullscreen": "false",
        "BackgroundFade": "0",
        "FrameRate": "60",
        "MarqueeMonitorIndex": "-1",
        "MarqueeScreenCompatibilityMode": "None",
    },
)
upsert(
    root / "Data" / "Settings.xml",
    "Settings",
    {
        "ShowLaunchBoxSplashScreen": "false",
        "UseStartupScreen": "false",
        "VideoPlaybackEngine": "VLC",
        "ShowDetailsVideo": "false",
        "AutoPlayDetailsVideo": "false",
        "ShowPlatformVideo": "false",
        "VideoCheck": "false",
        "DebugLog": "true",
    },
)
PY
}

launchbox_prepare_wine_runtime() {
    export WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX"
    export WINEDEBUG="${WINEDEBUG:--all}"
    export WINEESYNC="${WINEESYNC:-1}"
    if command -v wine >/dev/null 2>&1; then
        timeout 20s wine winecfg -v win10 >/dev/null 2>&1 || true
        timeout 15s wine reg add "HKCU\\Software\\Microsoft\\Avalon.Graphics" \
            /v DisableHWAcceleration /t REG_DWORD /d 1 /f >/dev/null 2>&1 || true
    fi
    if [ "${PZ_LAUNCHBOX_FORCE_X11:-1}" = "1" ]; then
        unset WAYLAND_DISPLAY
        export GDK_BACKEND=x11
        export SDL_VIDEODRIVER=x11
        export QT_QPA_PLATFORM=xcb
    fi
}

launchbox_write_wrappers() {
    pz_emulation_write_file "$PZ_LAUNCHBOX_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PZ_EMULATION_ROOT="$PZ_EMULATION_ROOT"
export PZ_LAUNCHBOX_ROOT="$PZ_LAUNCHBOX_ROOT"
export PZ_LAUNCHBOX_WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX"
exec "$PZ_ROOT/linux/emulation/launchbox.sh" launch "\$@"
EOF
    pz_emulation_write_file "$PZ_BIGBOX_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PZ_EMULATION_ROOT="$PZ_EMULATION_ROOT"
export PZ_LAUNCHBOX_ROOT="$PZ_LAUNCHBOX_ROOT"
export PZ_LAUNCHBOX_WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX"
exec "$PZ_ROOT/linux/emulation/launchbox.sh" bigbox "\$@"
EOF
}

launchbox_write_desktop_entries() {
    pz_emulation_write_file "$PZ_LAUNCHBOX_DESKTOP" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=LaunchBox
Comment=LaunchBox managed by PhaseZero
Exec=$PZ_LAUNCHBOX_WRAPPER
Terminal=false
Icon=$PZ_EMULATION_ROOT/media/icons/phasezero/launchbox.svg
Categories=Game;Emulator;
X-PhaseZero-Managed=true
EOF
    pz_emulation_write_file "$PZ_BIGBOX_DESKTOP" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=Big Box
Comment=Big Box managed by PhaseZero
Exec=$PZ_BIGBOX_WRAPPER
Terminal=false
Icon=$PZ_EMULATION_ROOT/media/icons/phasezero/bigbox.svg
Categories=Game;Emulator;
X-PhaseZero-Managed=true
EOF
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1 || true
}

cmd_integrate() {
    [ -f "$PZ_LAUNCHBOX_ROOT/LaunchBox.exe" ] || { pz_error "LaunchBox.exe not found: $PZ_LAUNCHBOX_ROOT"; return 1; }
    pz_emulation_abort_if_frontend_running
    pz_emulation_ensure_layout
    bash "$PZ_ROOT/linux/emulation/shared-content.sh" repair >/dev/null || pz_warn "shared-content repair reported warnings"
    bash "$PZ_ROOT/linux/emulation/media.sh" repair >/dev/null || pz_warn "media repair reported warnings"
    launchbox_python apply
    launchbox_configure_wine
    launchbox_install_fonts
    launchbox_apply_bigbox_safe_settings
    launchbox_write_wrappers
    launchbox_write_desktop_entries
    pz_info "LaunchBox integrated: $PZ_LAUNCHBOX_ROOT"
}

launchbox_clean_arg() {
    local value="$1"
    value="${value//$'\r'/}"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s\n' "$value"
}

launchbox_core_arg() {
    local value="$1" path base core dir
    path="${value//\\//}"
    case "$path" in
        cores/*_libretro.dll|*_libretro.dll)
            base="${path##*/}"
            core="${base%.dll}.so"
            for dir in \
                "${XDG_CONFIG_HOME:-$HOME/.config}/retroarch/cores" \
                "$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores" \
                "/usr/lib/libretro"; do
                [ -f "$dir/$core" ] && { printf '%s\n' "$dir/$core"; return 0; }
            done
            printf '%s\n' "$core"
            return 0
            ;;
    esac
    return 1
}

launchbox_path_arg() {
    local value="$1" lower rest converted
    value="$(launchbox_clean_arg "$value")"
    [ -z "$value" ] && return 0
    if launchbox_core_arg "$value"; then
        return 0
    fi
    lower="${value,,}"
    case "$lower" in
        steam://*)
            printf '%s\n' "$value"
            return 0
            ;;
        '..\roms\'*)
            rest="${value#..\\Roms\\}"
            rest="${rest#..\\roms\\}"
            printf '%s/%s\n' "$PZ_LAUNCHBOX_COMPAT_ROMS" "${rest//\\//}"
            return 0
            ;;
        [f]:\\@\\deck\\emulation\\*)
            rest="${value:20}"
            printf '%s/%s\n' "$PZ_EMULATION_ROOT" "${rest//\\//}"
            return 0
            ;;
        [l]:\\roms\\*)
            rest="${value:8}"
            printf '%s/%s\n' "$PZ_LAUNCHBOX_COMPAT_ROMS" "${rest//\\//}"
            return 0
            ;;
        [z]:\\*)
            rest="${value:3}"
            printf '/%s\n' "${rest//\\//}"
            return 0
            ;;
        [a-z]:\\*)
            if command -v winepath >/dev/null 2>&1; then
                converted="$(WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX" winepath -u "$value" 2>/dev/null || true)"
                [ -n "$converted" ] && { printf '%s\n' "$converted"; return 0; }
            fi
            ;;
    esac
    printf '%s\n' "$value"
}

launchbox_emulator_script() {
    case "$1" in
        azahar|citra) echo "$PZ_EMULATION_ROOT/tools/launchers/azahar.sh" ;;
        cemu) echo "$PZ_EMULATION_ROOT/tools/launchers/cemu.sh" ;;
        citron) echo "$PZ_EMULATION_ROOT/tools/launchers/citron.sh" ;;
        duckstation|psx) echo "$PZ_EMULATION_ROOT/tools/launchers/duckstation.sh" ;;
        eden|yuzu|switch) echo "$PZ_EMULATION_ROOT/tools/launchers/eden.sh" ;;
        pcsx2|ps2) echo "$PZ_EMULATION_ROOT/tools/launchers/pcsx2-qt.sh" ;;
        retroarch) echo "$PZ_EMULATION_ROOT/tools/launchers/retroarch.sh" ;;
        rpcs3|ps3) echo "$PZ_EMULATION_ROOT/tools/launchers/rpcs3.sh" ;;
        ryujinx) echo "$PZ_EMULATION_ROOT/tools/launchers/ryujinx.sh" ;;
        vita3k|psvita) echo "$PZ_EMULATION_ROOT/tools/launchers/vita3k.sh" ;;
        xemu|xbox) echo "$PZ_EMULATION_ROOT/tools/launchers/xemu-emu.sh" ;;
        xenia|xbox360) echo "$PZ_EMULATION_ROOT/tools/launchers/xenia.sh" ;;
        *) return 1 ;;
    esac
}

cmd_game() {
    local emulator="${1:-}" launcher arg converted=()
    [ -n "$emulator" ] || { pz_error "usage: launchbox.sh game <emulator> [args...]"; return 1; }
    shift || true
    launcher="$(launchbox_emulator_script "$emulator")" || { pz_error "unknown LaunchBox emulator: $emulator"; return 1; }
    [ -f "$launcher" ] || { pz_error "emulator launcher missing: $launcher"; return 1; }
    chmod +x "$launcher" 2>/dev/null || true
    for arg in "$@"; do
        converted+=("$(launchbox_path_arg "$arg")")
    done
    if [ "${#converted[@]}" -gt 0 ] && [[ "${converted[0]}" == steam://* ]]; then
        command -v xdg-open >/dev/null 2>&1 && exec xdg-open "${converted[0]}"
    fi
    pz_info "LaunchBox -> $emulator: $launcher ${converted[*]:-}"
    exec "$launcher" "${converted[@]}"
}

cmd_frontend() {
    local arg converted
    for arg in "$@"; do
        converted="$(launchbox_path_arg "$arg")"
        if [ -f "$converted" ]; then
            chmod +x "$converted" 2>/dev/null || true
            exec "$converted"
        fi
    done
    pz_error "LaunchBox frontend target missing: ${*:-<empty>}"
    return 1
}

cmd_launch() {
    [ -f "$PZ_LAUNCHBOX_ROOT/LaunchBox.exe" ] || cmd_integrate
    command -v wine >/dev/null 2>&1 || { pz_error "wine missing"; return 1; }
    launchbox_configure_wine
    launchbox_install_fonts
    if [ "${PZ_LAUNCHBOX_AUTO_REPAIR:-1}" = "1" ]; then
        launchbox_python repair >/dev/null || pz_warn "LaunchBox data repair reported warnings"
    fi
    launchbox_apply_bigbox_safe_settings
    launchbox_prepare_wine_runtime
    cd "$PZ_LAUNCHBOX_ROOT"
    exec wine "$PZ_LAUNCHBOX_ROOT/LaunchBox.exe" "$@"
}

cmd_bigbox() {
    local bigbox="$PZ_LAUNCHBOX_ROOT/BigBox.exe"
    [ -f "$bigbox" ] || { pz_error "BigBox.exe not found: $PZ_LAUNCHBOX_ROOT"; return 1; }
    command -v wine >/dev/null 2>&1 || { pz_error "wine missing"; return 1; }
    launchbox_configure_wine
    launchbox_install_fonts
    if [ "${PZ_LAUNCHBOX_AUTO_REPAIR:-1}" = "1" ]; then
        launchbox_python repair >/dev/null || pz_warn "LaunchBox data repair reported warnings"
    fi
    launchbox_apply_bigbox_safe_settings
    if [ "${PZ_LAUNCHBOX_USE_CORE_BIGBOX:-0}" = "1" ] && [ -f "$PZ_LAUNCHBOX_ROOT/Core/BigBox.exe" ]; then
        bigbox="$PZ_LAUNCHBOX_ROOT/Core/BigBox.exe"
    fi
    launchbox_prepare_wine_runtime
    cd "$PZ_LAUNCHBOX_ROOT"
    exec wine "$bigbox" "$@"
}

case "$ACTION" in
    status) shift || true; launchbox_python status "$@" ;;
    plan|dry-run) shift || true; launchbox_python plan "$@" ;;
    integrate|apply|repair|install) cmd_integrate ;;
    launch|open) shift || true; cmd_launch "$@" ;;
    bigbox|big-box) shift || true; cmd_bigbox "$@" ;;
    game) shift || true; cmd_game "$@" ;;
    frontend) shift || true; cmd_frontend "$@" ;;
    *)
        pz_error "usage: launchbox.sh (status|plan|integrate|repair|launch|bigbox|game|frontend)"
        exit 1
        ;;
esac
