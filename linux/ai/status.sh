#!/usr/bin/env bash
# status.sh - PhaseZero Linux AI portability status
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps jq >/dev/null

AI_MEMORY_URL="${AI_MEMORY_SERVER_URL:-http://127.0.0.1:49374}"

first_line() {
    timeout 5 "$@" 2>/dev/null | head -1 | tr -d '\r' || true
}

command_record() {
    local name="$1" cmd="$2"
    shift 2 || true
    local path="" version="" available=false
    for candidate in \
        "${PZ_LOCAL_BIN:-$HOME/.local/bin}/$cmd" \
        "${PZ_NPM_PREFIX:-$HOME/.local/share/npm}/bin/$cmd" \
        "$HOME/.cargo/bin/$cmd"; do
        if [ -x "$candidate" ]; then
            path="$candidate"
            available=true
            break
        fi
    done
    if [ "$available" != "true" ] && path="$(command -v "$cmd" 2>/dev/null)"; then
        available=true
    fi
    if [ "$available" = "true" ]; then
        if [ "$#" -gt 0 ]; then
            version="$(first_line "$path" "$@")"
        fi
    fi
    jq -cn --arg name "$name" --arg command "$cmd" --arg path "$path" --arg version "$version" \
        --argjson available "$available" \
        '{name:$name,command:$command,available:$available,path:$path,version:$version}'
}

records_to_object() {
    jq -s 'map({(.name): del(.name)}) | add'
}

service_record() {
    local name="$1" unit="$2" scope="${3:-system}" active=false enabled=false
    if [ "$scope" = "user" ]; then
        systemctl --user is-active "$unit" >/dev/null 2>&1 && active=true
        systemctl --user is-enabled "$unit" >/dev/null 2>&1 && enabled=true
    else
        systemctl is-active "$unit" >/dev/null 2>&1 && active=true
        systemctl is-enabled "$unit" >/dev/null 2>&1 && enabled=true
    fi
    jq -cn --arg name "$name" --arg unit "$unit" --arg scope "$scope" \
        --argjson active "$active" --argjson enabled "$enabled" \
        '{name:$name,unit:$unit,scope:$scope,active:$active,enabled:$enabled}'
}

ide_record() {
    local name="$1" cmd="$2" config="$3" path="" available=false
    if path="$(command -v "$cmd" 2>/dev/null)"; then
        available=true
    fi
    jq -cn --arg name "$name" --arg command "$cmd" --arg path "$path" --arg config "$config" \
        --argjson available "$available" --argjson configExists "$([ -e "$config" ] && echo true || echo false)" \
        '{name:$name,command:$command,available:$available,path:$path,configPath:$config,configExists:$configExists}'
}

memory_reachable() {
    if command -v curl >/dev/null 2>&1; then
        local code
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "${AI_MEMORY_URL%/}/mcp" 2>/dev/null || echo 000)"
        [ "$code" != "000" ] && return 0
    fi
    return 1
}

memory_configured_marker() {
    local candidate
    for candidate in \
        "$HOME/.claude.json" \
        "$HOME/.claude/settings.json" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json" \
        "$HOME/.codex/config.toml" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/ai-memory.ts" \
        "$HOME/.openclaw/config.json" \
        "$HOME/.hermes/config.yaml" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/Cursor/User/mcp.json" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/mcp.json" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/zed/settings.json" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/ai.z.zcode/store.json" \
        "$PZ_ROOT/.vscode/mcp.json"; do
        [ -f "$candidate" ] || continue
        grep -qi 'ai-memory' "$candidate" && return 0
    done
    return 1
}

docker_container_record() {
    local name="$1" exists=false running=false status=""
    if command -v docker >/dev/null 2>&1; then
        status="$(timeout 5 docker ps -a --filter "name=^/${name}$" --format '{{.Status}}' 2>/dev/null | head -1 || true)"
        [ -n "$status" ] && exists=true
        timeout 5 docker ps --filter "name=^/${name}$" --format '{{.Names}}' 2>/dev/null | grep -qx "$name" && running=true
    fi
    jq -cn --arg name "$name" --arg status "$status" --argjson exists "$exists" --argjson running "$running" \
        '{name:$name,exists:$exists,running:$running,status:$status}'
}

github_auth_record() {
    local installed=false authenticated=false auth_status="missing"
    if command -v gh >/dev/null 2>&1; then
        installed=true
        if timeout 8 gh auth status >/dev/null 2>&1; then
            authenticated=true
            auth_status="authenticated"
        else
            case "$?" in
                124) auth_status="timeout" ;;
                *) auth_status="unauthenticated" ;;
            esac
        fi
    fi
    jq -cn --arg authStatus "$auth_status" \
        --argjson installed "$installed" \
        --argjson authenticated "$authenticated" \
        '{installed:$installed,authenticated:$authenticated,authStatus:$authStatus}'
}

tmp_runtime="$(mktemp)"
tmp_clis="$(mktemp)"
tmp_ides="$(mktemp)"
tmp_services="$(mktemp)"
trap 'rm -f "$tmp_runtime" "$tmp_clis" "$tmp_ides" "$tmp_services"' EXIT

command_record node node --version >> "$tmp_runtime"
command_record npm npm --version >> "$tmp_runtime"
command_record pnpm pnpm --version >> "$tmp_runtime"
command_record python3 python3 --version >> "$tmp_runtime"
command_record uv uv --version >> "$tmp_runtime"
command_record pipx pipx --version >> "$tmp_runtime"
command_record cargo cargo --version >> "$tmp_runtime"
command_record rustc rustc --version >> "$tmp_runtime"
command_record go go version >> "$tmp_runtime"
command_record jq jq --version >> "$tmp_runtime"
command_record yq yq --version >> "$tmp_runtime"
command_record git git --version >> "$tmp_runtime"
command_record gitLfs git-lfs --version >> "$tmp_runtime"
command_record rg rg --version >> "$tmp_runtime"

command_record codex codex --version >> "$tmp_clis"
command_record claude claude --version >> "$tmp_clis"
command_record opencode opencode --version >> "$tmp_clis"
command_record hermes hermes --version >> "$tmp_clis"
command_record openclaw openclaw --version >> "$tmp_clis"
command_record gemini gemini --version >> "$tmp_clis"
command_record aider aider --version >> "$tmp_clis"
command_record goose goose --version >> "$tmp_clis"
command_record gh gh --version >> "$tmp_clis"
command_record ollama ollama --version >> "$tmp_clis"
command_record ai-memory ai-memory --version >> "$tmp_clis"
command_record ai-usagebar ai-usagebar --help >> "$tmp_clis"
command_record ai-usagebar-tui ai-usagebar-tui --help >> "$tmp_clis"
command_record headroom headroom --version >> "$tmp_clis"
command_record rtk rtk --version >> "$tmp_clis"

ide_record vscode code "${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json" >> "$tmp_ides"
ide_record code-oss codium "${XDG_CONFIG_HOME:-$HOME/.config}/VSCodium/User/settings.json" >> "$tmp_ides"
ide_record cursor cursor "${XDG_CONFIG_HOME:-$HOME/.config}/Cursor/User/settings.json" >> "$tmp_ides"
ide_record windsurf windsurf "${XDG_CONFIG_HOME:-$HOME/.config}/Windsurf/User/settings.json" >> "$tmp_ides"
ide_record zed zed "${XDG_CONFIG_HOME:-$HOME/.config}/zed/settings.json" >> "$tmp_ides"
ide_record zcode zcode "${XDG_CONFIG_HOME:-$HOME/.config}/ai.z.zcode/store.json" >> "$tmp_ides"
ide_record neovim nvim "${XDG_CONFIG_HOME:-$HOME/.config}/nvim/init.lua" >> "$tmp_ides"

service_record docker docker system >> "$tmp_services"
service_record ollama ollama system >> "$tmp_services"
service_record ai-memory ai-memory user >> "$tmp_services"
service_record openclaw openclaw user >> "$tmp_services"
service_record openclaw-gateway openclaw-gateway user >> "$tmp_services"
service_record codex-update-guard phasezero-codex-desktop-guard.service user >> "$tmp_services"
service_record ai-desktop-update phasezero-ai-desktop-update.timer user >> "$tmp_services"

runtime="$(records_to_object < "$tmp_runtime")"
clis="$(records_to_object < "$tmp_clis")"
ides="$(records_to_object < "$tmp_ides")"
services="$(records_to_object < "$tmp_services")"
mcp="$(bash "$PZ_ROOT/linux/ai/mcp-manager.sh" status 2>/dev/null || jq -cn '{schemaVersion:1,definitions:[],targets:{}}')"
open_webui="$(docker_container_record open-webui)"
desktop_apps="$(bash "$PZ_ROOT/linux/ai/desktop-apps.sh" status 2>/dev/null || jq -cn '{schemaVersion:1,claudeDesktop:{installed:false},codexDesktop:{},updater:{}}')"
github="$(github_auth_record)"
admin_bridge="$(bash "$PZ_ROOT/linux/ai/setup-admin-bridge.sh" status 2>/dev/null || jq -cn '{schemaVersion:1,ready:false,backend:"missing"}')"
agent_compat="$(bash "$PZ_ROOT/linux/ai/setup-agent-compat.sh" status 2>/dev/null || jq -cn '{schemaVersion:1,mode:"degraded",rules:{ok:false,files:[]},tools:{}}')"

rtk_available="$(jq -r '.rtk.available' <<< "$clis")"
memory_available="$(jq -r '."ai-memory".available' <<< "$clis")"
memory_reach=false
memory_marker=false
memory_reachable && memory_reach=true
memory_configured_marker && memory_marker=true
mode="degraded"
[ "$rtk_available" = "true" ] && [ "$memory_available" = "true" ] && mode="ready"
mode="$(jq -r '.mode // empty' <<< "$agent_compat" 2>/dev/null || echo "$mode")"

recommendations="$(mktemp)"
[ "$memory_available" = "true" ] || echo "linux/pz ai setup memory" >> "$recommendations"
jq -e '.tools.rtk.configured == true' <<< "$agent_compat" >/dev/null || echo "linux/pz ai setup rtk" >> "$recommendations"
jq -e '.tools.caveman.configured == true' <<< "$agent_compat" >/dev/null || echo "linux/pz ai setup caveman" >> "$recommendations"
jq -e '.ready == true' <<< "$admin_bridge" >/dev/null || echo "linux/pz ai setup admin" >> "$recommendations"
jq -e '.tools.headroom.configured == true' <<< "$agent_compat" >/dev/null || echo "linux/pz ai setup headroom" >> "$recommendations"
jq -e '.tools.aiContextFrugality.configured == true' <<< "$agent_compat" >/dev/null || echo "linux/pz ai setup frugality" >> "$recommendations"
jq -e '.opencode.available == true' <<< "$clis" >/dev/null || echo "linux/pz ai setup opencode" >> "$recommendations"
jq -e '.claude.available == true' <<< "$clis" >/dev/null || echo "linux/pz ai setup claude" >> "$recommendations"
jq -e '.hermes.available == true' <<< "$clis" >/dev/null || echo "linux/pz ai setup hermes" >> "$recommendations"
jq -e '.openclaw.available == true' <<< "$clis" >/dev/null || echo "linux/pz ai setup openclaw" >> "$recommendations"
bash "$PZ_ROOT/linux/ai/mcp-manager.sh" doctor 2>/dev/null | jq -e '(.problems | length) == 0' >/dev/null || echo "linux/pz ai repair" >> "$recommendations"
if ! jq -e '.ollama.available == true' <<< "$clis" >/dev/null; then
    echo "linux/pz ai setup ollama" >> "$recommendations"
elif ! jq -e '.ollama.active == true' <<< "$services" >/dev/null; then
    echo "sudo systemctl enable --now ollama" >> "$recommendations"
fi
jq -e '.gh.available == true' <<< "$clis" >/dev/null || echo "sudo pacman -S github-cli" >> "$recommendations"
jq -e '.gitLfs.available == true' <<< "$runtime" >/dev/null || echo "sudo pacman -S git-lfs" >> "$recommendations"
if jq -e '.gh.available == true' <<< "$clis" >/dev/null && ! jq -e '.authenticated == true' <<< "$github" >/dev/null; then
    echo "gh auth login" >> "$recommendations"
fi
jq -e '.vscode.available == true or .cursor.available == true or .windsurf.available == true or .neovim.available == true' <<< "$ides" >/dev/null || echo "install an AI-capable IDE/editor" >> "$recommendations"
jq -e '.claudeDesktop.installed == true' <<< "$desktop_apps" >/dev/null || echo "linux/pz ai desktop install-claude" >> "$recommendations"
jq -e '.updater.timerEnabled == true and .codexDesktop.guardEnabled == true' <<< "$desktop_apps" >/dev/null || echo "linux/pz ai desktop install-services" >> "$recommendations"

jq -cn \
    --arg mode "$mode" \
    --arg memoryUrl "$AI_MEMORY_URL" \
    --argjson runtime "$runtime" \
    --argjson clis "$clis" \
    --argjson ides "$ides" \
    --argjson services "$services" \
    --argjson mcp "$mcp" \
    --argjson openWebui "$open_webui" \
    --argjson desktopApps "$desktop_apps" \
    --argjson github "$github" \
    --argjson adminBridge "$admin_bridge" \
    --argjson agentCompat "$agent_compat" \
    --argjson memoryReachable "$memory_reach" \
    --argjson memoryConfigured "$memory_marker" \
    --arg hermesConfig "$HOME/.hermes/config.yaml" \
    --arg openclawConfig "$HOME/.openclaw/config.json" \
    --argjson hermesConfigExists "$([ -f "$HOME/.hermes/config.yaml" ] && echo true || echo false)" \
    --argjson openclawConfigExists "$([ -f "$HOME/.openclaw/config.json" ] && echo true || echo false)" \
    --argjson hermesMcpCount "$([ -f "$HOME/.hermes/config.yaml" ] && grep -E '^  # BEGIN PHASEZERO MCP ' "$HOME/.hermes/config.yaml" 2>/dev/null | wc -l | tr -d ' ' || echo 0)" \
    --argjson openclawMcpCount "$([ -f "$HOME/.openclaw/config.json" ] && jq '.mcp.servers // {} | length' "$HOME/.openclaw/config.json" 2>/dev/null || echo 0)" \
    --argjson recommendations "$(jq -R . "$recommendations" | jq -s .)" \
    '{
      schemaVersion: 1,
      mode: $mode,
      runtime: $runtime,
      clis: $clis,
      ides: $ides,
      services: $services,
      containers: {openWebui: $openWebui},
      desktopApps: $desktopApps,
      github: $github,
      adminBridge: $adminBridge,
      agentCompat: $agentCompat,
      mcp: $mcp,
      agentConfigs: {
        hermes: {
          path: $hermesConfig,
          exists: $hermesConfigExists,
          mcpServerCount: $hermesMcpCount
        },
        openclaw: {
          path: $openclawConfig,
          exists: $openclawConfigExists,
          mcpServerCount: $openclawMcpCount
        }
      },
      memory: {
        installed: $clis["ai-memory"].available,
        commandPath: $clis["ai-memory"].path,
        version: $clis["ai-memory"].version,
        serverUrl: $memoryUrl,
        serverReachable: $memoryReachable,
        configuredMarker: $memoryConfigured,
        userServiceActive: $services["ai-memory"].active
      },
      compatibility: {
        caveman: ($agentCompat.tools.caveman.configured // false),
        rulesOk: ($agentCompat.rules.ok // false),
        rtkAvailable: $clis.rtk.available,
        aiMemoryAvailable: $clis["ai-memory"].available,
        headroomAvailable: $clis.headroom.available,
        adminBridgeReady: ($adminBridge.ready // false),
        adminBackend: ($adminBridge.backend // "missing"),
        ponytailStatus: ($agentCompat.tools.ponytail.status // "inactive"),
        aiContextFrugality: ($agentCompat.tools.aiContextFrugality.status // "notConfigured"),
        graphifyPlaceholder: ($agentCompat.tools.graphify.placeholder // true),
        mode: $mode
      },
      recommendations: $recommendations
    }'

rm -f "$recommendations"
