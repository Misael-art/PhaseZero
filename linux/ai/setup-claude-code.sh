#!/usr/bin/env bash
# setup-claude-code.sh - install Claude Code CLI
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps npm

NPM_PREFIX="${PZ_NPM_PREFIX:-$HOME/.local/share/npm}"

install_claude() {
    mkdir -p "$NPM_PREFIX"
    pz_info "installing Claude Code into user npm prefix: $NPM_PREFIX"
    npm install -g --prefix "$NPM_PREFIX" @anthropic-ai/claude-code
    export PATH="$NPM_PREFIX/bin:$PATH"
    command -v claude &>/dev/null || pz_warn "claude installed but not on PATH; add $NPM_PREFIX/bin"
}

link_managed_bin() {
    local command_name="$1" source_path="$2" local_bin="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
    [ -x "$source_path" ] || return 0
    mkdir -p "$local_bin"
    ln -sfn "$source_path" "$local_bin/$command_name"
    pz_info "linked $command_name into $local_bin"
}

if command -v claude &>/dev/null || [ -x "$NPM_PREFIX/bin/claude" ]; then
    pz_info "Claude Code already installed"
else
    install_claude
    pz_info "Claude Code installed. Use official login/config flow; PhaseZero will not store raw keys."
fi

link_managed_bin claude "$NPM_PREFIX/bin/claude"

CLAUDE_CONFIG="${HOME}/.config/claude/claude.json"
mkdir -p "$(dirname "$CLAUDE_CONFIG")"
if [ ! -f "$CLAUDE_CONFIG" ]; then
    pz_write_managed_file "$CLAUDE_CONFIG" <<'EOF'
{
  "mcpServers": {},
  "projectSettings": {}
}
EOF
    pz_info "created default Claude config at $CLAUDE_CONFIG"
fi

bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync claude >/dev/null || pz_warn "Claude MCP sync failed"
bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync claude-desktop >/dev/null || pz_warn "Claude Desktop MCP sync failed"
