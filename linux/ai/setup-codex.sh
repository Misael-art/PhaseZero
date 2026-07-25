#!/usr/bin/env bash
# setup-codex.sh - install/update OpenAI Codex CLI in the user npm prefix.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps npm

NPM_PREFIX="${PZ_NPM_PREFIX:-$HOME/.local/share/npm}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"

install_codex() {
    mkdir -p "$NPM_PREFIX"
    pz_info "installing/updating Codex CLI into user npm prefix: $NPM_PREFIX"
    npm install -g --prefix "$NPM_PREFIX" @openai/codex@latest
}

link_managed_bin() {
    local command_name="$1" source_path="$2"
    [ -x "$source_path" ] || return 0
    mkdir -p "$LOCAL_BIN"
    ln -sfn "$source_path" "$LOCAL_BIN/$command_name"
    pz_info "linked $command_name into $LOCAL_BIN"
}

install_codex
link_managed_bin codex "$NPM_PREFIX/bin/codex"

if command -v codex >/dev/null 2>&1; then
    active_path="$(command -v codex)"
    active_version="$(codex --version 2>/dev/null | head -1 || true)"
    pz_info "active codex: $active_version ($active_path)"
    if [ "$active_path" != "$LOCAL_BIN/codex" ] && [ -x "$LOCAL_BIN/codex" ]; then
        pz_warn "PATH resolves codex to $active_path before $LOCAL_BIN/codex"
    fi
else
    pz_warn "codex installed but not on PATH; add $LOCAL_BIN"
fi
