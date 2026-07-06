#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux AI helpers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_WORKSPACE_ROOT="$TMP_ROOT/workspace"
export PZ_LOCAL_BIN="$TMP_ROOT/bin"
export PZ_NPM_PREFIX="$TMP_ROOT/npm"

mkdir -p "$HOME" "$PZ_WORKSPACE_ROOT" "$PZ_LOCAL_BIN"

"$REPO_ROOT/linux/pz" ai status | jq -e '.schemaVersion == 1 and .runtime.node.available | type == "boolean"' >/dev/null
"$REPO_ROOT/linux/pz" ai mcp status | jq -e '.schemaVersion == 1 and (.definitions | length) >= 1' >/dev/null
"$REPO_ROOT/linux/pz" ai mcp sync >/dev/null
test -f "$XDG_CONFIG_HOME/opencode/opencode.jsonc"
test -f "$XDG_CONFIG_HOME/claude/claude.json"
test -f "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json"
test -f "$HOME/.codex/config.toml"
test -f "$PZ_WORKSPACE_ROOT/.vscode/mcp.json"
test -f "$XDG_CONFIG_HOME/Code/User/mcp.json"
test -f "$XDG_CONFIG_HOME/Cursor/User/mcp.json"
test -f "$XDG_CONFIG_HOME/zed/settings.json"
test -f "$XDG_CONFIG_HOME/ai.z.zcode/store.json"
test -f "$HOME/.hermes/config.yaml"
test -f "$HOME/.openclaw/config.json"
jq -e 'has("mcpServers") | not' "$XDG_CONFIG_HOME/opencode/opencode.jsonc" >/dev/null
jq -e '.mcp."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$XDG_CONFIG_HOME/opencode/opencode.jsonc" >/dev/null
jq -e '.servers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$PZ_WORKSPACE_ROOT/.vscode/mcp.json" >/dev/null
jq -e '.servers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$XDG_CONFIG_HOME/Code/User/mcp.json" >/dev/null
jq -e '.mcpServers."ai-memory".command == "npx"' "$XDG_CONFIG_HOME/Cursor/User/mcp.json" >/dev/null
jq -e '.context_servers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$XDG_CONFIG_HOME/zed/settings.json" >/dev/null
jq -e '."mcp-storage" | fromjson | .state.config.mcp.mcpServers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$XDG_CONFIG_HOME/ai.z.zcode/store.json" >/dev/null
grep -q 'BEGIN PHASEZERO MCP ai-memory' "$HOME/.hermes/config.yaml"
jq -e '.mcp.servers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$HOME/.openclaw/config.json" >/dev/null
grep -q 'BEGIN PHASEZERO MCP ai-memory' "$HOME/.codex/config.toml"

"$REPO_ROOT/linux/pz" ai mcp install context7 >/dev/null
jq -e '.mcp.context7.url == "https://mcp.context7.com/mcp"' "$XDG_CONFIG_HOME/opencode/opencode.jsonc" >/dev/null
jq -e '.servers.context7.url == "https://mcp.context7.com/mcp"' "$PZ_WORKSPACE_ROOT/.vscode/mcp.json" >/dev/null
grep -q 'BEGIN PHASEZERO MCP context7' "$HOME/.hermes/config.yaml"
jq -e '.mcp.servers.context7.url == "https://mcp.context7.com/mcp"' "$HOME/.openclaw/config.json" >/dev/null
grep -q 'BEGIN PHASEZERO MCP context7' "$HOME/.codex/config.toml"

"$REPO_ROOT/linux/pz" ai mcp remove context7 >/dev/null
if jq -e '.mcp.context7' "$XDG_CONFIG_HOME/opencode/opencode.jsonc" >/dev/null; then
    echo "context7 should have been removed from opencode" >&2
    exit 1
fi
if grep -q 'BEGIN PHASEZERO MCP context7' "$HOME/.codex/config.toml"; then
    echo "context7 should have been removed from codex" >&2
    exit 1
fi
if grep -q 'BEGIN PHASEZERO MCP context7' "$HOME/.hermes/config.yaml"; then
    echo "context7 should have been removed from hermes" >&2
    exit 1
fi
if jq -e '.mcp.servers.context7' "$HOME/.openclaw/config.json" >/dev/null; then
    echo "context7 should have been removed from openclaw" >&2
    exit 1
fi

"$REPO_ROOT/linux/ai/setup-ides.sh" dry-run | jq -e '.tool == "ides"' >/dev/null
"$REPO_ROOT/linux/ai/setup-ides.sh" configure >/dev/null
test -f "$PZ_WORKSPACE_ROOT/.vscode/extensions.json"
test -f "$XDG_CONFIG_HOME/nvim/lua/phasezero_ai.lua"
jq -e '.recommendations | index("GitHub.copilot")' "$PZ_WORKSPACE_ROOT/.vscode/extensions.json" >/dev/null

"$REPO_ROOT/linux/ai/setup-opencode.sh" dry-run | jq -e '.tool == "opencode" and .launcher == "opencode-deck"' >/dev/null
"$REPO_ROOT/linux/ai/setup-opencode.sh" desktop-integration >/dev/null
test -x "$PZ_LOCAL_BIN/opencode-deck"
bash -n "$PZ_LOCAL_BIN/opencode-deck"
test -f "$XDG_DATA_HOME/applications/phasezero-opencode.desktop"
grep -q "opencode-deck" "$XDG_DATA_HOME/applications/phasezero-opencode.desktop"

# oh-my-openagent (OMO) wrapper: status contract, dry-run safety, and the
# enable/disable round-trip must preserve the opencode.jsonc MCP block.
"$REPO_ROOT/linux/ai/setup-omo.sh" status | jq -e '.tool == "omo" and (.plugin.registered | type == "boolean") and (.bun.present | type == "boolean") and .telemetryOff == true' >/dev/null
"$REPO_ROOT/linux/ai/setup-omo.sh" dry-run >/dev/null
if [ -f "$XDG_CONFIG_HOME/opencode/opencode.jsonc" ]; then
    "$REPO_ROOT/linux/ai/setup-omo.sh" enable >/dev/null
    "$REPO_ROOT/linux/ai/setup-omo.sh" status | jq -e '.plugin.registered == true' >/dev/null
    jq -e '(.plugin // []) | any(startswith("oh-my-openagent"))' "$XDG_CONFIG_HOME/opencode/opencode.jsonc" >/dev/null
    jq -e '.mcp."ai-memory".url | test("mcp$")' "$XDG_CONFIG_HOME/opencode/opencode.jsonc" >/dev/null
    "$REPO_ROOT/linux/ai/setup-omo.sh" disable >/dev/null
    "$REPO_ROOT/linux/ai/setup-omo.sh" status | jq -e '.plugin.registered == false' >/dev/null
    jq -e '.mcp."ai-memory".url | test("mcp$")' "$XDG_CONFIG_HOME/opencode/opencode.jsonc" >/dev/null
fi
"$REPO_ROOT/linux/pz" ai omo status | jq -e '.tool == "omo"' >/dev/null

# OpenCode CLI<->desktop version lockstep: status contract + dry-run safety.
"$REPO_ROOT/linux/ai/setup-opencode.sh" version-status | jq -e '.tool == "opencode-version" and (.inSync | type == "boolean") and (.cliManaged | type == "boolean") and (.autoSyncHook | type == "boolean") and (.model.usable | type == "boolean")' >/dev/null
PZ_DRY_RUN=1 "$REPO_ROOT/linux/ai/setup-opencode.sh" sync >/dev/null
PZ_DRY_RUN=1 "$REPO_ROOT/linux/ai/setup-opencode.sh" install-hook >/dev/null
# local-model config is dry-run safe and reachable via pz (skips cleanly if no Ollama)
PZ_DRY_RUN=1 PZ_OLLAMA_URL="http://127.0.0.1:1" "$REPO_ROOT/linux/ai/setup-opencode.sh" local-model >/dev/null
"$REPO_ROOT/linux/pz" ai opencode status | jq -e '.tool == "opencode-version"' >/dev/null

"$REPO_ROOT/linux/ai/setup-memory.sh" dry-run | jq -e '.tool == "ai-memory"' >/dev/null
"$REPO_ROOT/linux/ai/setup-usagebar.sh" dry-run | jq -e '.tool == "ai-usagebar"' >/dev/null
"$REPO_ROOT/linux/ai/setup-hermes.sh" dry-run | jq -e '.tool == "hermes"' >/dev/null
"$REPO_ROOT/linux/ai/setup-openclaw.sh" dry-run | jq -e '.tool == "openclaw"' >/dev/null
"$REPO_ROOT/linux/pz" ai status | jq -e '(.clis.hermes.available | type == "boolean") and (.clis.openclaw.available | type == "boolean")' >/dev/null
"$REPO_ROOT/linux/pz" install dev-ai --dry-run >/dev/null

echo "linux-ai smoke ok"
