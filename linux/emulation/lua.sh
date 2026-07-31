#!/usr/bin/env bash
# lua.sh - Lua runtime status for emulation launchers and scripts
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"

cmd_path() { command -v "$1" 2>/dev/null || true; }

status_lua() {
    jq -n \
        --arg lua "$(cmd_path lua)" \
        --arg lua54 "$(cmd_path lua5.4)" \
        --arg luajit "$(cmd_path luajit)" \
        --arg luarocks "$(cmd_path luarocks)" \
        --arg luaVersion "$(lua -v 2>&1 | head -1 || true)" \
        --arg lua54Version "$(lua5.4 -v 2>&1 | head -1 || true)" \
        --arg luajitVersion "$(luajit -v 2>&1 | head -1 || true)" \
        '{lua: $lua, lua54: $lua54, luajit: $luajit, luarocks: $luarocks, versions: {lua: $luaVersion, lua54: $lua54Version, luajit: $luajitVersion}, runtimeReady: ($lua != "" and $lua54 != ""), ready: ($lua != "" and $lua54 != "" and $luajit != "" and $luarocks != "")}'
}

dry_run_lua() {
    cat <<'EOF'
Lua dry-run
  pacman: sudo pacman -S --needed lua lua54 luajit luarocks
  purpose: launch scripts, emulator helper scripts, future plugin automation
EOF
}

install_lua() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        dry_run_lua
        return 0
    fi
    if pz_can_sudo_noninteractive; then
        sudo -n pacman -S --needed --noconfirm lua lua54 luajit luarocks
    else
        pz_warn "sudo password required; run: sudo pacman -S --needed lua lua54 luajit luarocks"
    fi
}

case "$ACTION" in
    status) status_lua ;;
    dry-run|plan) dry_run_lua ;;
    install) install_lua ;;
    *) pz_error "usage: lua.sh (status|dry-run|install)"; exit 1 ;;
esac
