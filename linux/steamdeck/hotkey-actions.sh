#!/usr/bin/env bash
# hotkey-actions.sh - run a PhaseZero desktop-mode hotkey action with
# discreet on-screen feedback. Desktop entries, KDE global shortcuts and the
# tray menu all dispatch through here so the user always sees what fired.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"
# shellcheck source=./osd.sh
source "$DIR/osd.sh"

PZ_BIN="$PZ_ROOT/linux/pz"

keyboard_visible_now() {
    bash "$DIR/input-actions.sh" status 2>/dev/null |
        jq -e '.kde.visible == true' >/dev/null 2>&1 && return 0
    pgrep -x wvkbd-mobintl >/dev/null 2>&1 || pgrep -x wvkbd >/dev/null 2>&1 ||
        pgrep -x onboard >/dev/null 2>&1
}

run_keyboard_toggle() {
    bash "$DIR/input-actions.sh" keyboard || true
    sleep 0.4
    if keyboard_visible_now; then
        pz_osd_show "input-keyboard-virtual-on" "Meta+Shift+F4 — Teclado virtual ativado"
    else
        pz_osd_show "input-keyboard-virtual-off" "Meta+Shift+F4 — Teclado virtual desativado"
    fi
}

ACTION="${1:-}"
shift || true

case "$ACTION" in
    handheld)
        pz_osd_show "computer-symbolic" "Meta+Shift+F1 — Aplicando modo Handheld…"
        exec "$PZ_BIN" steamdeck handheld
        ;;
    docked-monitor)
        pz_osd_show "video-display" "Meta+Shift+F2 — Aplicando modo Docked Monitor…"
        exec "$PZ_BIN" steamdeck docked-monitor
        ;;
    docked-tv)
        pz_osd_show "video-television" "Meta+Shift+F3 — Aplicando modo Docked TV…"
        exec "$PZ_BIN" steamdeck docked-tv
        ;;
    keyboard)
        run_keyboard_toggle
        ;;
    console)
        pz_osd_show "applications-games" "Meta+Shift+F5 — Abrindo Steam Gamepad UI…"
        exec "$PZ_BIN" steamdeck console
        ;;
    dev)
        pz_osd_show "utilities-terminal" "Meta+Shift+F6 — Sessão desktop/dev"
        exec "$PZ_BIN" steamdeck dev
        ;;
    cheatsheet)
        exec bash "$DIR/tray.sh" cheatsheet
        ;;
    voice)
        exec bash "$DIR/voice-typing.sh" toggle
        ;;
    *)
        pz_error "usage: hotkey-actions.sh (handheld|docked-monitor|docked-tv|keyboard|console|dev|cheatsheet|voice)"
        exit 1
        ;;
esac
