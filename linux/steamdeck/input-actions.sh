#!/usr/bin/env bash
# input-actions.sh - SteamOS-like input/session actions for Linux desktops
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$DIR/common.sh"

steamdeck_has_graphical_session() {
    [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]
}

steamdeck_run_detached() {
    local label="$1"
    shift

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would start $label: $*"
        return 0
    fi

    nohup "$@" >/dev/null 2>&1 &
    local pid="$!"
    disown "$pid" 2>/dev/null || true
    pz_info "started $label (pid $pid)"
}

steamdeck_steam_running() {
    pgrep -x steam >/dev/null 2>&1 || pgrep -f steamwebhelper >/dev/null 2>&1
}

steamdeck_kde_virtual_keyboard_supported() {
    command -v qdbus6 >/dev/null 2>&1 || return 1
    qdbus6 org.kde.KWin /VirtualKeyboard >/dev/null 2>&1 || return 1
}

steamdeck_kde_virtual_keyboard_prop() {
    local prop="$1"
    steamdeck_kde_virtual_keyboard_supported || return 1
    qdbus6 org.kde.KWin /VirtualKeyboard \
        org.freedesktop.DBus.Properties.Get \
        org.kde.kwin.VirtualKeyboard "$prop" 2>/dev/null | tail -1
}

steamdeck_maliit_desktop_file() {
    local desktop
    for desktop in \
        /usr/share/applications/com.github.maliit.keyboard.desktop \
        /usr/share/applications/org.maliit.keyboard.desktop; do
        if [ -f "$desktop" ]; then
            printf '%s\n' "$desktop"
            return 0
        fi
    done
    return 1
}

steamdeck_configure_virtual_keyboard() {
    local method current_enabled current_method kwinrc
    method="$(steamdeck_maliit_desktop_file || true)"

    if ! command -v kwriteconfig6 >/dev/null 2>&1; then
        pz_warn "kwriteconfig6 missing; KDE virtual keyboard config skipped"
        return 0
    fi

    kwinrc="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc"
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would enable KDE virtual keyboard in $kwinrc"
        [ -n "$method" ] && pz_info "dry-run: would set KDE input method to $method"
        return 0
    fi

    [ -f "$kwinrc" ] && cp "$kwinrc" "${kwinrc}.bak.$(date +%s)" 2>/dev/null || true

    kwriteconfig6 --file kwinrc --group Wayland --key VirtualKeyboardEnabled true
    if [ -n "$method" ]; then
        kwriteconfig6 --file kwinrc --group Wayland --key 'InputMethod[$e]' --delete >/dev/null 2>&1 || true
        kwriteconfig6 --file kwinrc --group Wayland --key 'InputMethod\x5b$e\x5d' --delete >/dev/null 2>&1 || true
        kwriteconfig6 --file kwinrc --group Wayland --key InputMethod "$method"
    else
        pz_warn "Maliit desktop file missing; install maliit-keyboard for KDE on-screen keyboard"
    fi

    if steamdeck_kde_virtual_keyboard_supported; then
        qdbus6 org.kde.KWin /VirtualKeyboard \
            org.freedesktop.DBus.Properties.Set \
            org.kde.kwin.VirtualKeyboard enabled true >/dev/null 2>&1 || true
        qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    fi

    current_enabled="$(kreadconfig6 --file kwinrc --group Wayland --key VirtualKeyboardEnabled 2>/dev/null || true)"
    current_method="$(kreadconfig6 --file kwinrc --group Wayland --key InputMethod 2>/dev/null || true)"
    pz_info "KDE virtual keyboard configured: enabled=${current_enabled:-unknown} inputMethod=${current_method:-unknown}"
}

steamdeck_kde_deactivate_virtual_keyboard() {
    steamdeck_kde_virtual_keyboard_supported || return 1
    qdbus6 org.kde.KWin /VirtualKeyboard \
        org.freedesktop.DBus.Properties.Set \
        org.kde.kwin.VirtualKeyboard active false >/dev/null 2>&1 || return 1
    pz_info "KDE virtual keyboard deactivated"
}

steamdeck_kde_open_virtual_keyboard() {
    local available visible active
    steamdeck_kde_virtual_keyboard_supported || return 1
    steamdeck_configure_virtual_keyboard

    available="$(steamdeck_kde_virtual_keyboard_prop available || echo false)"
    [ "$available" = "true" ] || return 1

    qdbus6 org.kde.KWin /VirtualKeyboard \
        org.kde.kwin.VirtualKeyboard.forceActivate >/dev/null 2>&1 || return 1

    sleep 0.2
    visible="$(steamdeck_kde_virtual_keyboard_prop visible || echo false)"
    active="$(steamdeck_kde_virtual_keyboard_prop active || echo false)"
    if [ "$visible" = "true" ]; then
        pz_info "virtual keyboard requested via KDE/KWin"
        return 0
    fi

    if [ "$active" = "true" ]; then
        pz_warn "KDE virtual keyboard active but not visible; trying fallback"
    fi

    return 1
}

steamdeck_stop_virtual_keyboard() {
    local stopped=0
    local name
    for name in wvkbd-mobintl wvkbd onboard maliit-keyboard; do
        if pgrep -x "$name" >/dev/null 2>&1; then
            pkill -x "$name" >/dev/null 2>&1 || true
            pz_info "stopped virtual keyboard: $name"
            stopped=1
        fi
    done

    [ "$stopped" -eq 1 ]
}

steamdeck_request_steam_keyboard() {
    command -v steam >/dev/null 2>&1 || return 1
    steamdeck_steam_running || return 1
    steam steam://open/keyboard >/dev/null 2>&1 && {
        pz_info "virtual keyboard requested via Steam"
        return 0
    }
    return 1
}

steamdeck_start_keyboard_binary() {
    local candidate
    for candidate in wvkbd-mobintl wvkbd onboard maliit-keyboard; do
        if command -v "$candidate" >/dev/null 2>&1; then
            steamdeck_run_detached "virtual keyboard" "$candidate"
            return 0
        fi
    done

    pz_error "no virtual keyboard found. install wvkbd, onboard, or maliit-keyboard."
    return 1
}

steamdeck_open_virtual_keyboard() {
    steamdeck_has_graphical_session || {
        pz_error "no graphical session detected for virtual keyboard"
        return 1
    }

    steamdeck_kde_open_virtual_keyboard && return 0
    steamdeck_request_steam_keyboard && return 0
    steamdeck_start_keyboard_binary
}

steamdeck_toggle_virtual_keyboard() {
    if steamdeck_kde_virtual_keyboard_supported &&
        [ "$(steamdeck_kde_virtual_keyboard_prop visible || echo false)" = "true" ]; then
        steamdeck_kde_deactivate_virtual_keyboard && return 0
    fi
    steamdeck_stop_virtual_keyboard && return 0
    steamdeck_open_virtual_keyboard
}

steamdeck_virtual_keyboard_status() {
    local provider="none" kde_supported=false kde_available=false kde_enabled=false kde_visible=false kde_active=false method=""
    if steamdeck_kde_virtual_keyboard_supported; then
        provider="kde-kwin"
        kde_supported=true
        kde_available="$(steamdeck_kde_virtual_keyboard_prop available || echo false)"
        kde_enabled="$(steamdeck_kde_virtual_keyboard_prop enabled || echo false)"
        kde_visible="$(steamdeck_kde_virtual_keyboard_prop visible || echo false)"
        kde_active="$(steamdeck_kde_virtual_keyboard_prop active || echo false)"
        method="$(kreadconfig6 --file kwinrc --group Wayland --key InputMethod 2>/dev/null || true)"
    elif command -v wvkbd-mobintl >/dev/null 2>&1; then
        provider="wvkbd-mobintl"
    elif command -v wvkbd >/dev/null 2>&1; then
        provider="wvkbd"
    elif command -v onboard >/dev/null 2>&1; then
        provider="onboard"
    elif command -v maliit-keyboard >/dev/null 2>&1; then
        provider="maliit-keyboard"
    fi

    jq -n \
        --arg provider "$provider" \
        --arg inputMethod "$method" \
        --argjson kdeSupported "$kde_supported" \
        --argjson kdeAvailable "$kde_available" \
        --argjson kdeEnabled "$kde_enabled" \
        --argjson kdeVisible "$kde_visible" \
        --argjson kdeActive "$kde_active" \
        --argjson maliit "$([ -n "$(steamdeck_maliit_desktop_file || true)" ] && echo true || echo false)" \
        '{
            provider: $provider,
            kde: {
                supported: $kdeSupported,
                available: $kdeAvailable,
                enabled: $kdeEnabled,
                visible: $kdeVisible,
                active: $kdeActive,
                inputMethod: $inputMethod
            },
            maliitDesktopFile: $maliit
        }'
}

steamdeck_launch_steam_gamepad_ui() {
    steamdeck_has_graphical_session || {
        pz_error "no graphical session detected for Steam Gamepad UI"
        return 1
    }

    if ! command -v steam >/dev/null 2>&1; then
        pz_error "steam not installed"
        return 1
    fi

    bash "$DIR/plugins.sh" enable-cef-debug >/dev/null 2>&1 || true

    if steamdeck_steam_running; then
        steam steam://open/bigpicture >/dev/null 2>&1 && {
            pz_info "Steam Big Picture requested"
            return 0
        }
    fi

    steamdeck_run_detached "Steam Gamepad UI" steam -gamepadui
}

steamdeck_start_console_session() {
    local mode="${1:-auto}"
    if [ "$mode" = "auto" ]; then
        mode="$(steamdeck_detect_mode)"
    fi

    steamdeck_apply_mode "$mode"
    steamdeck_launch_steam_gamepad_ui
}

steamdeck_start_dev_session() {
    local mode="${1:-docked-monitor}"
    if [ "$mode" != "none" ]; then
        steamdeck_apply_mode "$mode"
    fi

    pz_info "desktop/dev session ready"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-keyboard}" in
        keyboard|virtual-keyboard|toggle|toggle-keyboard) steamdeck_toggle_virtual_keyboard ;;
        configure|install|repair|configure-keyboard|install-keyboard) steamdeck_configure_virtual_keyboard ;;
        status|status-keyboard) steamdeck_virtual_keyboard_status ;;
        console) steamdeck_start_console_session "${2:-auto}" ;;
        dev|desktop) steamdeck_start_dev_session "${2:-docked-monitor}" ;;
        *) pz_error "usage: input-actions.sh (keyboard|configure|status|console|dev)"; exit 1 ;;
    esac
fi
