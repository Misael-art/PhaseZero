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
PZ_LAUNCHBOX_IMPORTER="$PZ_ROOT/linux/emulation/launchbox_import.py"
PZ_LAUNCHBOX_INSTALLER="${PZ_LAUNCHBOX_INSTALLER:-$PZ_LAUNCHBOX_ROOT/_hidden/_hidden/LaunchBox-13.5-Setup.exe}"
PZ_LAUNCHBOX_VERSION="${PZ_LAUNCHBOX_VERSION:-13.5}"
PZ_LAUNCHBOX_LOCK="${XDG_RUNTIME_DIR:-/tmp}/phasezero-launchbox-install.lock"
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

launchbox_install_runtime_dependencies() {
    [ "${PZ_LAUNCHBOX_SKIP_RUNTIME:-0}" = "1" ] && return 0
    command -v winetricks >/dev/null 2>&1 || {
        pz_error "winetricks missing; clean LaunchBox runtime cannot be prepared"
        return 1
    }
    local verb
    for verb in corefonts dotnet48 d3dcompiler_47 vcrun2022 dxvk; do
        pz_info "LaunchBox Wine dependency: $verb"
        timeout "${PZ_LAUNCHBOX_WINETRICKS_TIMEOUT:-30m}" \
            env WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX" WINEDEBUG=-all \
            winetricks -q "$verb" >/dev/null || {
                pz_error "winetricks failed: $verb"
                return 1
            }
    done
}

launchbox_validate_installer() {
    local installer="${1:-$PZ_LAUNCHBOX_INSTALLER}"
    python3 - "$installer" "$PZ_LAUNCHBOX_VERSION" "${PZ_LAUNCHBOX_ALLOW_UNVERIFIED_SIGNATURE:-0}" <<'PY'
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_version = sys.argv[2]
allow_unverified = sys.argv[3] == "1"
if not path.is_file():
    raise SystemExit(f"LaunchBox {expected_version} installer missing: {path}")
if not re.search(rf"(?<![0-9]){re.escape(expected_version)}(?![0-9])", path.name):
    raise SystemExit(f"unexpected installer name/version: {path.name}")
size = path.stat().st_size
if size < 250 * 1024 * 1024:
    raise SystemExit(f"LaunchBox {expected_version} installer invalid: {size} bytes (expected >250 MiB)")
with path.open("rb") as stream:
    if stream.read(2) != b"MZ":
        raise SystemExit("LaunchBox installer is not a PE executable")
    stream.seek(0x3C)
    pe_offset = struct.unpack("<I", stream.read(4))[0]
    stream.seek(pe_offset)
    if stream.read(4) != b"PE\0\0":
        raise SystemExit("LaunchBox installer has an invalid PE header")
    stream.seek(pe_offset + 24)
    magic = struct.unpack("<H", stream.read(2))[0]
    data_offset = 112 if magic == 0x20B else 96 if magic == 0x10B else 0
    if not data_offset:
        raise SystemExit("LaunchBox installer has an unsupported PE format")
    stream.seek(pe_offset + 24 + data_offset + (8 * 4))
    certificate_offset, certificate_size = struct.unpack("<II", stream.read(8))
    if (not certificate_offset or certificate_size < 8) and not allow_unverified:
        raise SystemExit("LaunchBox installer has no Authenticode certificate table")
digest = hashlib.sha256()
with path.open("rb") as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
print(json.dumps({
    "path": str(path),
    "size": size,
    "sha256": digest.hexdigest(),
    "authenticodeTable": bool(certificate_offset and certificate_size >= 8),
    "expectedVersion": expected_version,
}))
PY
    if command -v osslsigncode >/dev/null 2>&1; then
        osslsigncode verify -in "$installer" >/dev/null || {
            pz_error "LaunchBox installer Authenticode verification failed"
            return 1
        }
    elif [ "${PZ_LAUNCHBOX_ALLOW_UNVERIFIED_SIGNATURE:-0}" != "1" ]; then
        pz_error "osslsigncode missing; Authenticode chain cannot be verified"
        return 1
    else
        pz_warn "Authenticode chain verification explicitly bypassed"
    fi
}

launchbox_apply_bigbox_safe_settings() {
    [ "${PZ_LAUNCHBOX_BIGBOX_SAFE_SETTINGS:-1}" = "1" ] || return 0
    python3 - "$PZ_LAUNCHBOX_ROOT" "$PZ_ROOT" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(Path(sys.argv[2]) / "linux" / "lib"))
import pz_hostbackup  # noqa: E402

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
    pz_hostbackup.backup_file(path, module="emulation")
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
        # BigBox is WPF. DisableHWAcceleration=1 forces software rendering, which
        # is slow and can leave artwork half-drawn ("lento / imagem incompleta").
        # With DXVK in the prefix, GPU rendering is both faster and correct, so
        # default to HW acceleration ON. Set PZ_LAUNCHBOX_DISABLE_HWACCEL=1 only
        # as a fallback if this GPU/driver yields a black screen under Wine.
        local hwaccel_disable="${PZ_LAUNCHBOX_DISABLE_HWACCEL:-0}"
        timeout 15s wine reg add "HKCU\\Software\\Microsoft\\Avalon.Graphics" \
            /v DisableHWAcceleration /t REG_DWORD /d "$hwaccel_disable" /f >/dev/null 2>&1 || true
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
    local bigbox_nodisplay=false
    [ -f "$PZ_LAUNCHBOX_ROOT/License.xml" ] || bigbox_nodisplay=true
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
NoDisplay=$bigbox_nodisplay
X-PhaseZero-Managed=true
EOF
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1 || true
}

launchbox_data_valid() {
    python3 - "$PZ_LAUNCHBOX_ROOT" <<'PY' >/dev/null 2>&1
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
for relative in ("Data/Platforms.xml", "Data/Parents.xml", "Data/Emulators.xml"):
    ET.parse(root / relative)
PY
}

cmd_integrate() {
    [ -f "$PZ_LAUNCHBOX_ROOT/LaunchBox.exe" ] || { pz_error "LaunchBox.exe not found: $PZ_LAUNCHBOX_ROOT"; return 1; }
    [ -f "$PZ_LAUNCHBOX_ROOT/BigBox.exe" ] || { pz_error "BigBox.exe not found: $PZ_LAUNCHBOX_ROOT"; return 1; }
    launchbox_data_valid || { pz_error "LaunchBox Data XML missing or invalid; use install-clean/import-esde"; return 1; }
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

cmd_import_esde() {
    [ -f "$PZ_LAUNCHBOX_ROOT/LaunchBox.exe" ] || {
        pz_error "valid LaunchBox installation required before ES-DE import"
        return 1
    }
    pz_emulation_abort_if_frontend_running
    local backup
    backup="$PZ_LAUNCHBOX_ROOT/.phasezero/backups/Data.$(date +%Y%m%d-%H%M%S)"
    install -d "$(dirname "$backup")"
    [ ! -d "$PZ_LAUNCHBOX_ROOT/Data" ] || mv "$PZ_LAUNCHBOX_ROOT/Data" "$backup"
    if ! python3 "$PZ_LAUNCHBOX_IMPORTER" import-esde "$@"; then
        rm -rf "$PZ_LAUNCHBOX_ROOT/Data"
        [ ! -d "$backup" ] || mv "$backup" "$PZ_LAUNCHBOX_ROOT/Data"
        pz_error "ES-DE import failed; previous LaunchBox Data restored"
        return 1
    fi
    launchbox_python repair >/dev/null
    launchbox_apply_bigbox_safe_settings
    launchbox_write_wrappers
    launchbox_write_desktop_entries
}

launchbox_verify_structure() {
    [ -s "$PZ_LAUNCHBOX_ROOT/LaunchBox.exe" ] || { pz_error "LaunchBox.exe missing"; return 1; }
    [ -s "$PZ_LAUNCHBOX_ROOT/BigBox.exe" ] || { pz_error "BigBox.exe missing"; return 1; }
    [ -f "$PZ_LAUNCHBOX_ROOT/.phasezero/esde-import.json" ] || {
        pz_error "ES-DE import report missing"
        return 1
    }
    python3 - "$PZ_LAUNCHBOX_ROOT" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
report = json.loads((root / ".phasezero/esde-import.json").read_text(encoding="utf-8"))
if report.get("games", 0) < 1 or report.get("platforms", 0) < 1:
    raise SystemExit("LaunchBox ES-DE import is empty")
for path in [
    root / "Data/Platforms.xml",
    root / "Data/Parents.xml",
    root / "Data/Emulators.xml",
    *sorted((root / "Data/Platforms").glob("*.xml")),
]:
    ET.parse(path)
print(json.dumps({
    "installed": True,
    "platforms": report["platforms"],
    "games": report["games"],
    "mediaLinks": report["mediaLinks"],
}))
PY
}

launchbox_verify_installed_version() {
    [ "${PZ_LAUNCHBOX_SKIP_VERSION_CHECK:-0}" = "1" ] && return 0
    local candidate version_re
    version_re="${PZ_LAUNCHBOX_VERSION//./[.]}"
    for candidate in "$PZ_LAUNCHBOX_ROOT/LaunchBox.exe" "$PZ_LAUNCHBOX_ROOT/Core/LaunchBox.dll"; do
        [ -f "$candidate" ] || continue
        if strings -a "$candidate" 2>/dev/null | grep -Eq "(^|[^0-9])${version_re}([.]0([.]0)?)?([^0-9]|$)"; then
            return 0
        fi
        if strings -el "$candidate" 2>/dev/null | grep -Eq "(^|[^0-9])${version_re}([.]0([.]0)?)?([^0-9]|$)"; then
            return 0
        fi
    done
    pz_error "installed LaunchBox version $PZ_LAUNCHBOX_VERSION could not be confirmed"
    return 1
}

launchbox_verify_visual() {
    command -v xdotool >/dev/null 2>&1 || { pz_error "xdotool required for real BigBox verification"; return 1; }
    command -v import >/dev/null 2>&1 || { pz_error "ImageMagick import required for real BigBox verification"; return 1; }
    command -v identify >/dev/null 2>&1 || { pz_error "ImageMagick identify required for real BigBox verification"; return 1; }
    launchbox_verify_visual_app "LaunchBox.exe" '^LaunchBox' "launchbox"
    [ "${PZ_LAUNCHBOX_REQUIRE_BIGBOX:-1}" = "0" ] ||
        launchbox_verify_visual_app "BigBox.exe" 'Big Box\\|BigBox' "bigbox"
}

launchbox_verify_visual_app() {
    local executable="$1" title_pattern="$2" label="$3"
    local shot log_file
    shot="$(mktemp "${TMPDIR:-/tmp}/phasezero-${label}-verify.XXXXXX.png")"
    log_file="$(mktemp "${TMPDIR:-/tmp}/phasezero-${label}-verify.XXXXXX.log")"
    local pid window variance dimensions width height
    launchbox_prepare_wine_runtime
    (
        cd "$PZ_LAUNCHBOX_ROOT"
        wine "$PZ_LAUNCHBOX_ROOT/$executable"
    ) >"$log_file" 2>&1 &
    pid=$!
    window=""
    for _ in $(seq 1 "${PZ_LAUNCHBOX_VERIFY_TIMEOUT:-180}"); do
        window="$(xdotool search --onlyvisible --name "$title_pattern" 2>/dev/null | tail -n 1 || true)"
        if [ -n "$window" ]; then
            dimensions="$(xdotool getwindowgeometry --shell "$window" 2>/dev/null || true)"
            width="$(printf '%s\n' "$dimensions" | awk -F= '$1=="WIDTH" {print $2}')"
            height="$(printf '%s\n' "$dimensions" | awk -F= '$1=="HEIGHT" {print $2}')"
            if [ "${width:-0}" -ge 640 ] && [ "${height:-0}" -ge 360 ]; then
                break
            fi
            window=""
        fi
        sleep 1
    done
    if [ -z "$window" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pz_error "$label visible window not found; log: $log_file"
        return 1
    fi
    import -window "$window" "$shot"
    variance="$(identify -format '%[standard-deviation]' "$shot")"
    dimensions="$(identify -format '%w %h' "$shot")"
    read -r width height <<<"$dimensions"
    if [ "$width" -lt 640 ] || [ "$height" -lt 360 ]; then
        kill "$pid" 2>/dev/null || true
        wineserver -k >/dev/null 2>&1 || true
        wait "$pid" 2>/dev/null || true
        pz_error "$label rendered only a small error/dialog window: ${width}x${height}"
        return 1
    fi
    python3 - "$variance" <<'PY'
import sys
if float(sys.argv[1]) < 0.01:
    raise SystemExit("frontend screenshot is blank or effectively monochrome")
PY
    xdotool windowactivate "$window" key Right
    sleep 2
    kill "$pid" 2>/dev/null || true
    wineserver -k >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
    pz_info "$label visual verification passed: $shot"
}

cmd_verify() {
    local real=0
    [ "${1:-}" = "--real" ] && real=1
    launchbox_verify_structure
    [ "$real" = "0" ] || launchbox_verify_visual
}

cmd_install_clean() {
    command -v flock >/dev/null 2>&1 || { pz_error "flock missing"; return 1; }
    exec 9>"$PZ_LAUNCHBOX_LOCK"
    flock -n 9 || { pz_error "another LaunchBox installation is running"; return 1; }
    launchbox_validate_installer "$PZ_LAUNCHBOX_INSTALLER"
    pz_emulation_abort_if_frontend_running
    command -v wine >/dev/null 2>&1 || { pz_error "wine missing"; return 1; }

    local active_root="$PZ_LAUNCHBOX_ROOT"
    local active_prefix="$PZ_LAUNCHBOX_WINEPREFIX"
    local parent stage backup windows_stage timestamp
    parent="$(dirname "$active_root")"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    stage="$parent/.LaunchBox.stage.$timestamp.$$"
    backup="$parent/LaunchBox.preinstall.$timestamp"
    install -d "$stage"

    PZ_LAUNCHBOX_ROOT="$stage"
    PZ_LAUNCHBOX_WINEPREFIX="$stage/.phasezero/wineprefix"
    export PZ_LAUNCHBOX_ROOT PZ_LAUNCHBOX_WINEPREFIX
    trap 'rm -rf "${stage:-}"' ERR INT TERM
    launchbox_configure_wine
    launchbox_install_runtime_dependencies
    windows_stage="$(WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX" winepath -w "$stage")"
    pz_info "Installing LaunchBox $PZ_LAUNCHBOX_VERSION into staging: $stage"
    timeout "${PZ_LAUNCHBOX_SETUP_TIMEOUT:-30m}" \
        env WINEPREFIX="$PZ_LAUNCHBOX_WINEPREFIX" WINEDEBUG=-all \
        wine "$PZ_LAUNCHBOX_INSTALLER" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- "/DIR=$windows_stage"
    [ -s "$stage/LaunchBox.exe" ] && [ -s "$stage/BigBox.exe" ] || {
        pz_error "LaunchBox setup completed without expected executables"
        return 1
    }
    launchbox_verify_installed_version
    install -D -m 0644 "$PZ_LAUNCHBOX_INSTALLER" \
        "$stage/install/$(basename "$PZ_LAUNCHBOX_INSTALLER")"
    if [ -n "${PZ_LAUNCHBOX_LICENSE:-}" ] && [ -f "$PZ_LAUNCHBOX_LICENSE" ]; then
        cp -a "$PZ_LAUNCHBOX_LICENSE" "$stage/License.xml"
    elif [ -f "$active_root/License.xml" ]; then
        cp -a "$active_root/License.xml" "$stage/"
    fi
    if [ -f "$active_root/BigBox.dxvk-cache" ]; then
        cp -a "$active_root/BigBox.dxvk-cache" "$stage/"
    elif [ -f "$active_root/_hidden/BigBox.dxvk-cache" ]; then
        cp -a "$active_root/_hidden/BigBox.dxvk-cache" "$stage/BigBox.dxvk-cache"
    fi
    python3 "$PZ_LAUNCHBOX_IMPORTER" import-esde
    launchbox_apply_bigbox_safe_settings
    launchbox_verify_structure
    launchbox_verify_visual

    PZ_LAUNCHBOX_ROOT="$active_root"
    PZ_LAUNCHBOX_WINEPREFIX="$active_prefix"
    export PZ_LAUNCHBOX_ROOT PZ_LAUNCHBOX_WINEPREFIX
    mv "$active_root" "$backup"
    if ! mv "$stage" "$active_root"; then
        mv "$backup" "$active_root"
        pz_error "LaunchBox promotion failed; previous root restored"
        return 1
    fi
    trap - ERR INT TERM
    launchbox_write_wrappers
    launchbox_write_desktop_entries
    bash "$PZ_ROOT/linux/emulation/frontends.sh" repair >/dev/null || pz_warn "frontend refresh reported warnings"
    if ! cmd_verify; then
        mv "$active_root" "$parent/LaunchBox.failed.$timestamp"
        mv "$backup" "$active_root"
        pz_error "post-promotion verification failed; previous root restored"
        return 1
    fi
    pz_info "LaunchBox $PZ_LAUNCHBOX_VERSION clean install promoted. Previous root: $backup"
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
        dolphin|wii|gamecube) echo "$PZ_EMULATION_ROOT/tools/launchers/dolphin-emu.sh" ;;
        flycast|dreamcast|naomi|atomiswave) echo "$PZ_EMULATION_ROOT/tools/launchers/flycast.sh" ;;
        citron) echo "$PZ_EMULATION_ROOT/tools/launchers/citron.sh" ;;
        duckstation|psx) echo "$PZ_EMULATION_ROOT/tools/launchers/duckstation.sh" ;;
        eden|yuzu|switch) echo "$PZ_EMULATION_ROOT/tools/launchers/eden.sh" ;;
        pcsx2|ps2) echo "$PZ_EMULATION_ROOT/tools/launchers/pcsx2-qt.sh" ;;
        model2) echo "$PZ_EMULATION_ROOT/tools/launchers/model-2-emulator.sh" ;;
        supermodel|model3) echo "$PZ_EMULATION_ROOT/tools/launchers/supermodel.sh" ;;
        retroarch) echo "$PZ_EMULATION_ROOT/tools/launchers/retroarch.sh" ;;
        rpcs3|ps3) echo "$PZ_EMULATION_ROOT/tools/launchers/rpcs3.sh" ;;
        ryujinx) echo "$PZ_EMULATION_ROOT/tools/launchers/ryujinx.sh" ;;
        vita3k|psvita) echo "$PZ_EMULATION_ROOT/tools/launchers/vita3k.sh" ;;
        xemu|xbox) echo "$PZ_EMULATION_ROOT/tools/launchers/xemu-emu.sh" ;;
        xenia|xbox360) echo "$PZ_EMULATION_ROOT/tools/launchers/xenia.sh" ;;
        *) return 1 ;;
    esac
}

cmd_system() {
    local system="${1:-}" mode core rom launcher
    [ -n "$system" ] || { pz_error "usage: launchbox.sh system <esde-system> <rom>"; return 1; }
    shift || true
    rom="$(launchbox_path_arg "${1:-}")"
    case "$system" in
        mastersystem|genesis|gamegear|megadrive) mode=retroarch; core=genesis_plus_gx ;;
        sfc|snes|snesna) mode=retroarch; core=snes9x ;;
        saturn|saturnjp) mode=retroarch; core=mednafen_saturn ;;
        x68000) mode=retroarch; core=px68k ;;
        sega32xna) mode=retroarch; core=picodrive ;;
        neogeocdjp) mode=retroarch; core=neocd ;;
        switch) mode=eden ;;
        psx) mode=duckstation ;;
        n3ds) mode=azahar ;;
        ps2) mode=pcsx2 ;;
        ps3) mode=rpcs3 ;;
        wii) mode=dolphin ;;
        wiiu) mode=cemu ;;
        naomi|dreamcast|atomiswave) mode=flycast ;;
        model2) mode=model2 ;;
        model3) mode=supermodel ;;
        steam|frontends|emulators) mode=shell ;;
        *) pz_error "unsupported ES-DE system: $system"; return 1 ;;
    esac
    if [ "$mode" = "shell" ]; then
        [ -e "$rom" ] || { pz_error "shell target missing: $rom"; return 1; }
        case "$rom" in
            *.desktop) exec gio launch "$rom" ;;
            *) chmod +x "$rom" 2>/dev/null || true; exec "$rom" ;;
        esac
    fi
    if [ "$mode" = "retroarch" ]; then
        launcher="$PZ_EMULATION_ROOT/tools/launchers/retroarch.sh"
        exec "$launcher" -L "$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores/${core}_libretro.so" "$rom"
    fi
    case "$mode" in
        eden|azahar) cmd_game "$mode" -f -g "$rom" ;;
        duckstation) cmd_game "$mode" -batch "$rom" ;;
        pcsx2) cmd_game "$mode" -batch "$rom" ;;
        rpcs3) cmd_game "$mode" --no-gui "$rom" ;;
        dolphin) cmd_game "$mode" -b -e "$rom" ;;
        cemu) cmd_game "$mode" -g "$rom" ;;
        model2) cmd_game "$mode" "$(basename "${rom%.*}")" ;;
        *) cmd_game "$mode" "$rom" ;;
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
    install-clean) shift || true; cmd_install_clean "$@" ;;
    import-esde) shift || true; cmd_import_esde "$@" ;;
    verify) shift || true; cmd_verify "$@" ;;
    integrate|apply|repair) cmd_integrate ;;
    launch|open) shift || true; cmd_launch "$@" ;;
    bigbox|big-box) shift || true; cmd_bigbox "$@" ;;
    game) shift || true; cmd_game "$@" ;;
    system) shift || true; cmd_system "$@" ;;
    frontend) shift || true; cmd_frontend "$@" ;;
    *)
        pz_error "usage: launchbox.sh (status|plan|install-clean|import-esde|verify|repair|launch|bigbox|game|system|frontend)"
        exit 1
        ;;
esac
