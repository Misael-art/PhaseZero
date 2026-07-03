#!/usr/bin/env bash
# headroom-agent.sh - explicit Headroom helper for Linux agent CLIs
set -euo pipefail

resolve_cmd() {
    local name="$1"
    command -v "$name" 2>/dev/null || {
        [ -x "$HOME/.local/bin/$name" ] && echo "$HOME/.local/bin/$name" && return 0
        return 1
    }
}

headroom_cmd() {
    resolve_cmd headroom
}

run_headroom() {
    local cmd
    cmd="$(headroom_cmd || true)"
    [ -n "$cmd" ] || {
        echo "headroom not found. Run: linux/pz ai setup headroom" >&2
        return 1
    }
    "$cmd" "$@"
}

status() {
    run_headroom --version || return 1
    for name in claude codex aider cursor copilot gemini openclaw opencode n8n; do
        local path=""
        path="$(resolve_cmd "$name" || true)"
        if [ -n "$path" ]; then
            printf '%s: %s\n' "$name" "$path"
        else
            printf '%s: missing\n' "$name"
        fi
    done
}

case "${1:-status}" in
    status) status ;;
    proxy) shift; run_headroom proxy --port "${1:-8787}" "${@:2}" ;;
    wrap-claude) shift; run_headroom wrap claude --memory "$@" ;;
    wrap-codex) shift; run_headroom wrap codex --memory "$@" ;;
    wrap-aider) shift; run_headroom wrap aider "$@" ;;
    wrap-cursor) shift; run_headroom wrap cursor "$@" ;;
    wrap-copilot) shift; run_headroom wrap copilot "$@" ;;
    wrap-gemini) shift; run_headroom wrap gemini "$@" ;;
    wrap-openclaw) shift; run_headroom wrap openclaw "$@" ;;
    mcp-install) shift; run_headroom mcp install "$@" ;;
    stats) shift; run_headroom stats "$@" ;;
    *) echo "usage: headroom-agent.sh (status|proxy|wrap-claude|wrap-codex|wrap-aider|wrap-cursor|wrap-copilot|wrap-gemini|wrap-openclaw|mcp-install|stats)" >&2; exit 1 ;;
esac
