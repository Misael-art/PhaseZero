#!/usr/bin/env bash
# waydroid-escape.sh - break the Waydroid GRUB kiosk loop (CCS-007).
#
# Espelha o padrão de escape do WinVM rescue (sem QGA): remove o drop-in SDDM
# gerenciado pelo PhaseZero e arma um pedido para que o próximo boot
# phasezero.waydroid=1 NÃO reescreva o autologin — o host cai no greeter
# normal em vez de reentrar na sessão Android que falha.
set -euo pipefail

CONF_DIR="${PZ_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
WAYDROID_CONF="$CONF_DIR/92-phasezero-waydroid.conf"
MARKER="${PZ_WAYDROID_ESCAPE_MARKER:-${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/waydroid/autologin-escape.request}"

is_managed() {
    [ -f "$1" ] && grep -q 'PhaseZero managed' "$1" 2>/dev/null
}

cmd_strip() {
    # Ownership (ADR de artefatos): este escape só remove o drop-in do
    # Waydroid; confs da SteamOS e da Windows VM têm donos próprios.
    if is_managed "$WAYDROID_CONF"; then
        rm -f "$WAYDROID_CONF"
        printf 'removed managed autologin drop-in: %s\n' "$WAYDROID_CONF"
    else
        printf 'no managed Waydroid autologin under %s\n' "$CONF_DIR"
    fi
    if mkdir -p "$(dirname "$MARKER")" 2>/dev/null && printf '%s\n' "$(date -Is 2>/dev/null || date)" > "$MARKER" 2>/dev/null; then
        printf 'escape armed: next phasezero.waydroid=1 boot keeps the greeter (%s)\n' "$MARKER"
    else
        printf 'warning: could not write escape marker %s\n' "$MARKER"
    fi
}

cmd_status() {
    local armed="no"
    [ -f "$MARKER" ] && armed="yes"
    if is_managed "$WAYDROID_CONF"; then
        printf 'managed_autologin: %s\n' "$WAYDROID_CONF"
    else
        printf 'managed_autologin: none\n'
    fi
    printf 'escape_armed: %s\n' "$armed"
}

case "${1:-status}" in
    strip) cmd_strip ;;
    status) cmd_status ;;
    *) printf 'usage: %s (strip|status)\n' "${0##*/}" >&2; exit 1 ;;
esac
