#!/usr/bin/env bash
# install-hotkeys.sh - install SteamOS-like keyboard shortcuts on Linux
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-install}"
DRY_RUN=0
[ "$ACTION" = "dry-run" ] && DRY_RUN=1

PZ_BIN="$PZ_ROOT/linux/pz"
SXHKD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sxhkd"
SWHKD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/swhkd"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
KGLOBALSHORTCUTSRC="${XDG_CONFIG_HOME:-$HOME/.config}/kglobalshortcutsrc"

write_managed_file() {
    local path="$1"
    local content="$2"
    local dir
    dir="$(dirname "$path")"

    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $path"
        return 0
    fi

    install -d "$dir"
    if [ -f "$path" ]; then
        cp "$path" "${path}.bak.$(date +%s)"
    fi
    printf '%s\n' "$content" > "$path"
    pz_info "wrote $path"
}

sxhkd_config() {
    cat <<EOF
# PhaseZero Steam Deck Linux hotkeys
# Matches Windows AutoHotkey defaults where possible.

ctrl + alt + F1
    $PZ_BIN steamdeck handheld

ctrl + alt + F2
    $PZ_BIN steamdeck docked-monitor

ctrl + alt + F3
    $PZ_BIN steamdeck docked-tv

ctrl + alt + F4
    $PZ_BIN steamdeck keyboard

ctrl + alt + F5
    $PZ_BIN steamdeck console

ctrl + alt + F6
    $PZ_BIN steamdeck dev
EOF
}

swhkd_config() {
    cat <<EOF
# PhaseZero Steam Deck Linux hotkeys
# Wayland compositors may require compositor-native shortcut binding.

ctrl + alt + f1
    $PZ_BIN steamdeck handheld

ctrl + alt + f2
    $PZ_BIN steamdeck docked-monitor

ctrl + alt + f3
    $PZ_BIN steamdeck docked-tv

ctrl + alt + f4
    $PZ_BIN steamdeck keyboard

ctrl + alt + f5
    $PZ_BIN steamdeck console

ctrl + alt + f6
    $PZ_BIN steamdeck dev
EOF
}

sxhkd_service() {
    cat <<EOF
[Unit]
Description=PhaseZero Steam Deck hotkeys
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/sxhkd -c %h/.config/sxhkd/sxhkdrc
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
}

desktop_entry() {
    local name="$1"
    local exec_line="$2"
    local comment="$3"
    local shortcut="${4:-}"
    local terminal="${5:-false}"
    cat <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$comment
Exec=$exec_line
Terminal=$terminal
Categories=Game;Utility;
${shortcut:+X-KDE-Shortcuts=$shortcut}
EOF
}

boot_reboot_exec() {
    if command -v pkexec >/dev/null 2>&1; then
        printf 'pkexec bash %s/linux/steamdeck/install-steamos-boot.sh next-reboot\n' "$PZ_ROOT"
    else
        printf '%s steamdeck boot next-reboot\n' "$PZ_BIN"
    fi
}

install_desktop_entries() {
    local boot_exec boot_terminal="false"
    boot_exec="$(boot_reboot_exec)"
    command -v pkexec >/dev/null 2>&1 || boot_terminal="true"

    write_managed_file "$APPLICATIONS_DIR/phasezero-steamdeck-handheld.desktop" \
        "$(desktop_entry "PhaseZero Handheld Mode" "$PZ_BIN steamdeck handheld" "Apply Steam Deck handheld mode" "Ctrl+Alt+F1")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-steamdeck-docked-monitor.desktop" \
        "$(desktop_entry "PhaseZero Docked Monitor Mode" "$PZ_BIN steamdeck docked-monitor" "Apply Steam Deck docked monitor mode" "Ctrl+Alt+F2")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-steamdeck-docked-tv.desktop" \
        "$(desktop_entry "PhaseZero Docked TV Mode" "$PZ_BIN steamdeck docked-tv" "Apply Steam Deck docked TV mode" "Ctrl+Alt+F3")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-virtual-keyboard.desktop" \
        "$(desktop_entry "PhaseZero Virtual Keyboard" "$PZ_BIN steamdeck keyboard" "Toggle virtual keyboard" "Ctrl+Alt+F4")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-steam-gamepad-ui.desktop" \
        "$(desktop_entry "PhaseZero Steam Gamepad UI" "$PZ_BIN steamdeck console" "Launch Steam Gamepad UI" "Ctrl+Alt+F5")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-steamdeck-dev.desktop" \
        "$(desktop_entry "PhaseZero Desktop Dev Session" "$PZ_BIN steamdeck dev" "Apply desktop/dev Steam Deck session" "Ctrl+Alt+F6")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-reboot-steamos-plus.desktop" \
        "$(desktop_entry "PhaseZero Reboot to SteamOS Plus" "$boot_exec" "Set one-shot GRUB boot to SteamOS Plus and reboot" "" "$boot_terminal")"
}

install_sxhkd_service() {
    write_managed_file "$SYSTEMD_USER_DIR/phasezero-steamdeck-hotkeys.service" "$(sxhkd_service)"

    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would enable user service phasezero-steamdeck-hotkeys.service if sxhkd exists"
        return 0
    fi

    if command -v sxhkd >/dev/null 2>&1; then
        systemctl --user daemon-reload
        systemctl --user enable --now phasezero-steamdeck-hotkeys.service
        pz_info "enabled phasezero-steamdeck-hotkeys.service"
    else
        pz_warn "sxhkd not installed; configs written, service not enabled"
    fi
}

is_kde_session() {
    case "${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}:${KDE_SESSION_VERSION:-}" in
        *KDE*|*plasma*|*:*:6|*:*:5) return 0 ;;
        *) return 1 ;;
    esac
}

kde_write_shortcut() {
    local desktop_file="$1"
    local shortcut="$2"
    local name="$3"

    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would bind KDE shortcut $shortcut -> $desktop_file"
        return 0
    fi

    kwriteconfig6 --file kglobalshortcutsrc \
        --group services \
        --group "$desktop_file" \
        --key _launch \
        "$shortcut,none,$name"

    kwriteconfig6 --file kglobalshortcutsrc \
        --group services \
        --group "$desktop_file" \
        --key _k_friendly_name \
        "$name"
}

install_kde_shortcuts() {
    if ! is_kde_session || ! command -v kwriteconfig6 >/dev/null 2>&1; then
        pz_info "KDE native shortcuts skipped"
        return 0
    fi

    if [ "$DRY_RUN" != "1" ] && [ -f "$KGLOBALSHORTCUTSRC" ]; then
        cp "$KGLOBALSHORTCUTSRC" "${KGLOBALSHORTCUTSRC}.bak.$(date +%s)"
    fi

    kde_write_shortcut "phasezero-steamdeck-handheld.desktop" "Ctrl+Alt+F1" "PhaseZero Handheld Mode"
    kde_write_shortcut "phasezero-steamdeck-docked-monitor.desktop" "Ctrl+Alt+F2" "PhaseZero Docked Monitor Mode"
    kde_write_shortcut "phasezero-steamdeck-docked-tv.desktop" "Ctrl+Alt+F3" "PhaseZero Docked TV Mode"
    kde_write_shortcut "phasezero-virtual-keyboard.desktop" "Ctrl+Alt+F4" "PhaseZero Virtual Keyboard"
    kde_write_shortcut "phasezero-steam-gamepad-ui.desktop" "Ctrl+Alt+F5" "PhaseZero Steam Gamepad UI"
    kde_write_shortcut "phasezero-steamdeck-dev.desktop" "Ctrl+Alt+F6" "PhaseZero Desktop Dev Session"

    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would rebuild KDE service cache and restart kglobalaccel"
        return 0
    fi

    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1 || true
    if command -v kquitapp6 >/dev/null 2>&1; then
        kquitapp6 kglobalaccel >/dev/null 2>&1 || true
        qdbus6 org.kde.kglobalaccel /kglobalaccel org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 || true
    fi
    pz_info "KDE native shortcuts installed"
}

print_status() {
    echo "PhaseZero SteamOS UX status"
    echo "pz: $PZ_BIN"
    echo "sxhkd config: $SXHKD_DIR/sxhkdrc"
    echo "swhkd config: $SWHKD_DIR/swhkdrc"
    echo "desktop entries: $APPLICATIONS_DIR/phasezero-*.desktop"
    echo "KDE shortcuts: $KGLOBALSHORTCUTSRC"
    if command -v sxhkd >/dev/null 2>&1; then
        systemctl --user is-active phasezero-steamdeck-hotkeys.service 2>/dev/null || true
    else
        echo "sxhkd missing"
    fi
    if is_kde_session && [ -f "$KGLOBALSHORTCUTSRC" ]; then
        grep -A2 -E '^\[services\]\[phasezero-' "$KGLOBALSHORTCUTSRC" 2>/dev/null || true
    fi
}

install_hotkeys() {
    write_managed_file "$SXHKD_DIR/sxhkdrc" "$(sxhkd_config)"
    write_managed_file "$SWHKD_DIR/swhkdrc" "$(swhkd_config)"
    install_desktop_entries
    PZ_DRY_RUN="$DRY_RUN" bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" configure || pz_warn "virtual keyboard configuration failed"
    install_sxhkd_service
    install_kde_shortcuts
    pz_info "SteamOS-like hotkeys installed"
}

case "$ACTION" in
    install|dry-run) install_hotkeys ;;
    status) print_status ;;
    *) pz_error "usage: install-hotkeys.sh (install|dry-run|status)"; exit 1 ;;
esac
