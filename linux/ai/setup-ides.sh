#!/usr/bin/env bash
# setup-ides.sh - Linux IDE/editor AI integration helpers
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps jq

WORKSPACE_ROOT="${PZ_WORKSPACE_ROOT:-$PZ_ROOT}"
EXTENSIONS_JSON="$WORKSPACE_ROOT/.vscode/extensions.json"
IDE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai"
IDE_STATE="$IDE_STATE_DIR/ides.json"

recommended_extensions_json() {
    jq -cn '[
      "GitHub.copilot",
      "GitHub.copilot-chat",
      "Continue.continue",
      "saoudrizwan.claude-dev",
      "saoudrizwan.cline-nightly"
    ]'
}

ide_status() {
    bash "$PZ_ROOT/linux/ai/status.sh" | jq '.ides'
}

write_workspace_recommendations() {
    mkdir -p "$(dirname "$EXTENSIONS_JSON")"
    local recs tmp
    recs="$(recommended_extensions_json)"
    tmp="$(pz_tempfile)"
    if [ -f "$EXTENSIONS_JSON" ] && jq empty "$EXTENSIONS_JSON" >/dev/null 2>&1; then
        jq --argjson recs "$recs" '
          .recommendations = ((.recommendations // []) + $recs | unique)
        ' "$EXTENSIONS_JSON" > "$tmp"
    else
        jq -n --argjson recs "$recs" '{recommendations:$recs}' > "$tmp"
    fi
    pz_backup_file "$EXTENSIONS_JSON" user >/dev/null
    mv "$tmp" "$EXTENSIONS_JSON"
    pz_info "wrote VS Code workspace extension recommendations: $EXTENSIONS_JSON"
}

write_state() {
    mkdir -p "$IDE_STATE_DIR"
    bash "$PZ_ROOT/linux/ai/status.sh" | jq '{schemaVersion:1,writtenAt:now|todate,ides,mcp:.mcp.targets,compatibility}' > "$IDE_STATE"
    pz_info "wrote IDE AI state: $IDE_STATE"
}

install_extensions_for() {
    local cli="$1" ext installed
    command -v "$cli" >/dev/null 2>&1 || return 0
    installed="$("$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    while IFS= read -r ext; do
        [ -n "$ext" ] || continue
        if grep -qx "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')" <<< "$installed"; then
            pz_info "$cli extension already installed: $ext"
            continue
        fi
        "$cli" --install-extension "$ext" --force >/dev/null 2>&1 || pz_warn "$cli could not install extension: $ext"
    done < <(recommended_extensions_json | jq -r '.[]')
}

install_extensions() {
    install_extensions_for code
    install_extensions_for code-oss
    install_extensions_for codium
    install_extensions_for cursor
    install_extensions_for windsurf
}

install_pacman_app() {
    local command_name="$1" package_name="$2" label="$3"
    if command -v "$command_name" >/dev/null 2>&1; then
        pz_info "$label already installed"
        return 0
    fi
    if ! pacman -Si "$package_name" >/dev/null 2>&1; then
        pz_warn "$label pacman package not found: $package_name"
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm "$package_name"
    else
        pz_warn "sudo missing; install manually: sudo pacman -S --needed $package_name"
    fi
}

install_aur_app() {
    local command_name="$1" package_name="$2" label="$3"
    if command -v "$command_name" >/dev/null 2>&1; then
        pz_info "$label already installed"
        return 0
    fi
    if ! command -v yay >/dev/null 2>&1; then
        pz_warn "yay missing; install manually from AUR: $package_name"
        return 0
    fi
    if ! yay -Si "$package_name" >/dev/null 2>&1; then
        pz_warn "$label AUR package not found: $package_name"
        return 0
    fi
    yay -S --needed --noconfirm "$package_name"
}

install_apps() {
    install_pacman_app code code "VS Code OSS"
    install_pacman_app zed zed "Zed"
    install_aur_app cursor cursor-bin "Cursor"
    install_aur_app zcode z-code-bin "ZCode"
    configure_ides >/dev/null
    ide_status
}

write_neovim_helper() {
    local nvim_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nvim/lua"
    local helper="$nvim_dir/phasezero_ai.lua"
    mkdir -p "$nvim_dir"
    pz_write_managed_file "$helper" <<EOF
-- PhaseZero AI helper. Optional: require("phasezero_ai").status()
local M = {}

function M.status()
  local handle = io.popen("$PZ_ROOT/linux/pz ai status 2>/dev/null")
  if not handle then
    print("PhaseZero AI status unavailable")
    return
  end
  local output = handle:read("*a")
  handle:close()
  print(output)
end

return M
EOF
}

configure_ides() {
    write_workspace_recommendations
    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync vscode >/dev/null
    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync vscode-user >/dev/null
    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync cursor >/dev/null
    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync zed >/dev/null
    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync zcode >/dev/null
    write_neovim_helper
    write_state
    ide_status
}

dry_run() {
    jq -cn --arg extensions "$EXTENSIONS_JSON" --arg state "$IDE_STATE" \
        --argjson recs "$(recommended_extensions_json)" \
        '{tool:"ides",planned:["write .vscode/extensions.json","write VS Code/Cursor/Zed/ZCode MCP configs via safe MCP manager","write Neovim optional helper","write PhaseZero IDE state"],extensionsPath:$extensions,statePath:$state,recommendedExtensions:$recs}'
}

case "${1:-configure}" in
    configure|setup) configure_ides ;;
    recommendations|workspace-recommendations) write_workspace_recommendations ;;
    status) ide_status ;;
    install-apps|apps) install_apps ;;
    install-extensions) install_extensions ;;
    dry-run|plan) dry_run ;;
    *) echo "usage: setup-ides.sh (configure|recommendations|status|install-apps|install-extensions|dry-run)"; exit 1 ;;
esac
