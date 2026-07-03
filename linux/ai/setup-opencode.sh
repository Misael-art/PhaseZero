#!/usr/bin/env bash
# setup-opencode.sh - configure OpenCode with MCPs and secrets
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps npm jq

OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.jsonc"
NPM_PREFIX="${PZ_NPM_PREFIX:-$HOME/.local/share/npm}"
mkdir -p "$(dirname "$OPENCODE_CONFIG")"

install_npm_tool() {
    local package="$1" command_name="$2"
    if command -v "$command_name" &>/dev/null || [ -x "$NPM_PREFIX/bin/$command_name" ]; then
        pz_info "$command_name already installed"
        return 0
    fi
    mkdir -p "$NPM_PREFIX"
    pz_info "installing $package into user npm prefix: $NPM_PREFIX"
    npm install -g --prefix "$NPM_PREFIX" "$package"
    export PATH="$NPM_PREFIX/bin:$PATH"
    command -v "$command_name" &>/dev/null || pz_warn "$command_name installed but not on PATH; add $NPM_PREFIX/bin"
}

link_managed_bin() {
    local command_name="$1" source_path="$2" local_bin="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
    [ -x "$source_path" ] || return 0
    mkdir -p "$local_bin"
    ln -sfn "$source_path" "$local_bin/$command_name"
    pz_info "linked $command_name into $local_bin"
}

if [ ! -f "$OPENCODE_CONFIG" ]; then
    pz_info "creating default OpenCode config"
    pz_write_managed_file "$OPENCODE_CONFIG" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {}
}
EOF
fi

TEMPLATE_DIR="$PZ_ROOT/linux/ai/templates"
if [ -d "$TEMPLATE_DIR" ]; then
    for tmpl in "$TEMPLATE_DIR"/*; do
        [ -f "$tmpl" ] || continue
        name=""
        name=$(basename "$tmpl")
        target="${HOME}/.config/opencode/${name}"
        if [ ! -f "$target" ]; then
            cp "$tmpl" "$target"
            pz_info "installed template: $name"
        fi
    done
fi

install_npm_tool opencode-ai opencode
link_managed_bin opencode "$NPM_PREFIX/bin/opencode"
bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync opencode >/dev/null || pz_warn "OpenCode MCP sync failed"

pz_info "OpenCode setup complete. Config at $OPENCODE_CONFIG"
