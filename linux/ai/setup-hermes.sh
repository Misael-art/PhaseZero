#!/usr/bin/env bash
# setup-hermes.sh - install/configure Hermes Agent for PhaseZero Linux agents
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_CONFIG="$HERMES_HOME/config.yaml"
HERMES_AGENT_DIR="$HERMES_HOME/hermes-agent"
HERMES_VENV_PY="$HERMES_AGENT_DIR/venv/bin/python"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
PHASEZERO_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai"
ENV_FILE="$PHASEZERO_CONFIG_DIR/hermes.env"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai/hermes.json"
INSTALL_TIMEOUT="${PZ_HERMES_INSTALL_TIMEOUT:-1800}"

hermes_cmd() {
    command -v hermes 2>/dev/null || {
        [ -x "$LOCAL_BIN/hermes" ] && echo "$LOCAL_BIN/hermes" && return 0
        [ -x "$HOME/.local/bin/hermes" ] && echo "$HOME/.local/bin/hermes" && return 0
        [ -x "$HERMES_AGENT_DIR/venv/bin/hermes" ] && echo "$HERMES_AGENT_DIR/venv/bin/hermes" && return 0
        return 1
    }
}

link_managed_bin() {
    local source_path="$1"
    [ -x "$source_path" ] || return 0
    mkdir -p "$LOCAL_BIN"
    if [ "$(readlink -f "$source_path" 2>/dev/null || printf '%s' "$source_path")" = "$(readlink -f "$LOCAL_BIN/hermes" 2>/dev/null || printf '%s' "$LOCAL_BIN/hermes")" ]; then
        pz_info "hermes already linked in $LOCAL_BIN"
        return 0
    fi
    ln -sfn "$source_path" "$LOCAL_BIN/hermes"
    pz_info "linked hermes into $LOCAL_BIN"
}

install_hermes() {
    pz_check_deps curl git jq xz
    if hermes_cmd >/dev/null 2>&1; then
        pz_info "Hermes already installed: $(hermes_cmd)"
        return 0
    fi

    local tmp size rc=0 args=()
    tmp="$(pz_tempfile "${TMPDIR:-/tmp}/phasezero-hermes.XXXXXX")"
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 120 \
        https://hermes-agent.nousresearch.com/install.sh -o "$tmp"; then
        rm -f -- "$tmp"
        pz_error "Hermes installer download failed"
        return 1
    fi
    size="$(wc -c < "$tmp")"
    if [ "$size" -lt 256 ] || [ "$size" -gt 2097152 ] || ! head -n 1 "$tmp" | grep -q '^#!'; then
        rm -f -- "$tmp"
        pz_error "Hermes installer failed content validation (size=$size)"
        return 1
    fi
    args+=(--skip-setup --non-interactive)
    [ "${PZ_HERMES_SKIP_BROWSER:-0}" = "1" ] && args+=(--skip-browser)
    [ "${PZ_HERMES_INCLUDE_DESKTOP:-0}" = "1" ] && args+=(--include-desktop)
    pz_info "installing Hermes Agent into $HERMES_HOME"
    HERMES_HOME="$HERMES_HOME" timeout "$INSTALL_TIMEOUT" bash "$tmp" "${args[@]}" || rc=$?
    rm -f -- "$tmp"
    [ "$rc" -eq 0 ] || { pz_error "Hermes installer failed (exit=$rc)"; return "$rc"; }

    if [ -x "$HOME/.local/bin/hermes" ]; then
        link_managed_bin "$HOME/.local/bin/hermes"
    elif [ -x "$HERMES_AGENT_DIR/venv/bin/hermes" ]; then
        link_managed_bin "$HERMES_AGENT_DIR/venv/bin/hermes"
    fi
}

write_env_template() {
    mkdir -p "$PHASEZERO_CONFIG_DIR"
    if [ ! -f "$ENV_FILE" ]; then
        pz_write_managed_file "$ENV_FILE" <<'EOF'
# PhaseZero Hermes env template. No raw keys in repo files.
# Prefer official auth/config flows:
#   hermes setup --portal
#   hermes model
# Optional BYOK examples:
# OPENAI_API_KEY=<manual-secret-store-value>
# ANTHROPIC_API_KEY=<manual-secret-store-value>
# OPENROUTER_API_KEY=<manual-secret-store-value>
EOF
        chmod 600 "$ENV_FILE" 2>/dev/null || true
    fi
}

install_mcp_sdk() {
    if [ ! -x "$HERMES_VENV_PY" ]; then
        pz_warn "Hermes venv python not found; skipping MCP SDK install"
        return 0
    fi
    if "$HERMES_VENV_PY" - <<'PY' >/dev/null 2>&1
import mcp
PY
    then
        pz_info "Hermes MCP SDK already installed"
        return 0
    fi
    "$HERMES_VENV_PY" -m pip install mcp >/dev/null 2>&1 || \
        pz_warn "could not install Python mcp package into Hermes venv"
}

configure_hermes() {
    local cmd=""
    write_env_template
    mkdir -p "$HERMES_HOME"
    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync hermes >/dev/null || pz_warn "Hermes MCP sync failed"
    install_mcp_sdk
    cmd="$(hermes_cmd || true)"
    if [ -n "$cmd" ]; then
        timeout 30 "$cmd" config check >/dev/null 2>&1 || pz_warn "Hermes config check reported issues; run: hermes config check"
        timeout 30 "$cmd" doctor >/dev/null 2>&1 || pz_warn "Hermes doctor reported issues; run: hermes doctor"
    else
        pz_warn "Hermes not installed; config prepared only"
    fi
    write_state "$cmd"
}

write_state() {
    local cmd="${1:-}" version=""
    [ -n "$cmd" ] && version="$(timeout 10 "$cmd" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
    mkdir -p "$(dirname "$STATE_FILE")"
    jq -n \
        --arg installedAt "$(date -Iseconds)" \
        --arg commandPath "$cmd" \
        --arg version "$version" \
        --arg hermesHome "$HERMES_HOME" \
        --arg configPath "$HERMES_CONFIG" \
        --arg envFile "$ENV_FILE" \
        '{tool:"hermes",installedAt:$installedAt,commandPath:$commandPath,version:$version,home:$hermesHome,configPath:$configPath,envFile:$envFile}' > "$STATE_FILE"
}

mcp_sdk_available() {
    [ -x "$HERMES_VENV_PY" ] || return 1
    "$HERMES_VENV_PY" - <<'PY' >/dev/null 2>&1
import mcp
PY
}

doctor_text() {
    local cmd="$1"
    [ -n "$cmd" ] || return 0
    timeout 15 "$cmd" doctor 2>&1 | head -40 | tr -d '\r' || true
}

status_json() {
    local cmd="" version="" mcp_count=0 sdk=false doctor="" config_check=false
    cmd="$(hermes_cmd || true)"
    if [ -n "$cmd" ]; then
        version="$(timeout 10 "$cmd" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
        timeout 15 "$cmd" config check >/dev/null 2>&1 && config_check=true
        doctor="$(doctor_text "$cmd")"
    fi
    [ -f "$HERMES_CONFIG" ] && mcp_count="$(grep -E '^  # BEGIN PHASEZERO MCP ' "$HERMES_CONFIG" 2>/dev/null | wc -l | tr -d ' ')"
    mcp_sdk_available && sdk=true
    jq -cn \
        --arg commandPath "$cmd" \
        --arg version "$version" \
        --arg hermesHome "$HERMES_HOME" \
        --arg configPath "$HERMES_CONFIG" \
        --arg envFile "$ENV_FILE" \
        --arg stateFile "$STATE_FILE" \
        --arg doctor "$doctor" \
        --argjson available "$([ -n "$cmd" ] && echo true || echo false)" \
        --argjson configExists "$([ -f "$HERMES_CONFIG" ] && echo true || echo false)" \
        --argjson envExists "$([ -f "$ENV_FILE" ] && echo true || echo false)" \
        --argjson stateExists "$([ -f "$STATE_FILE" ] && echo true || echo false)" \
        --argjson mcpServerCount "$mcp_count" \
        --argjson mcpSdk "$sdk" \
        --argjson configCheckOk "$config_check" \
        '{tool:"hermes",available:$available,commandPath:$commandPath,version:$version,home:$hermesHome,configPath:$configPath,configExists:$configExists,envFile:$envFile,envExists:$envExists,stateFile:$stateFile,stateExists:$stateExists,mcp:{serverCount:$mcpServerCount,pythonSdk:$mcpSdk},configCheckOk:$configCheckOk,doctor:$doctor}'
}

dry_run() {
    jq -cn \
        --arg home "$HERMES_HOME" \
        --arg configPath "$HERMES_CONFIG" \
        --arg envFile "$ENV_FILE" \
        --arg skipBrowser "${PZ_HERMES_SKIP_BROWSER:-0}" \
        '{tool:"hermes",planned:["download official install.sh","run install.sh --skip-setup --non-interactive","sync PhaseZero MCP servers into ~/.hermes/config.yaml","install Python mcp SDK in Hermes venv when available","write env template without secrets"],home:$home,configPath:$configPath,envFile:$envFile,skipBrowserEnv:$skipBrowser}'
}

case "${1:-setup}" in
    setup)
        install_hermes
        configure_hermes
        status_json
        ;;
    install) install_hermes ;;
    configure) configure_hermes ;;
    mcp) bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync hermes ;;
    status) status_json ;;
    dry-run|plan) dry_run ;;
    portal)
        cmd="$(hermes_cmd || true)"
        [ -n "$cmd" ] || { pz_error "Hermes not installed"; exit 1; }
        "$cmd" setup --portal
        ;;
    *) echo "usage: setup-hermes.sh (setup|install|configure|mcp|status|dry-run|portal)"; exit 1 ;;
esac
