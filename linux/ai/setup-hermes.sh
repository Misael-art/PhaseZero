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

require_workload_release_gate() {
    [ "${PZ_HOMELAB_ALLOW_HOST_WORKLOADS:-0}" = 1 ] && return 0
    pz_error "Hermes changes blocked by Homelab release gate; run: pz ai workspaces plan"
    return 69
}

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

    local tmp size rc=0 args=() ck
    ck="${PZ_HERMES_INSTALL_SHA256:-}"
    if ! bash "$PZ_ROOT/linux/server/ai-policy-broker.sh" check hermes-install checksum="$ck" >/dev/null 2>&1; then
        pz_error "AI policy denies Hermes remote install without pinned sha256; set PZ_HERMES_INSTALL_SHA256=<64 hex>"
        return 1
    fi
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
    if [ -n "$ck" ]; then
        local got
        got="$(sha256sum "$tmp" | cut -d' ' -f1)"
        if [ "$got" != "$ck" ]; then
            rm -f -- "$tmp"
            pz_error "Hermes installer checksum mismatch: got $got, expected $ck"
            return 1
        fi
        pz_info "Hermes installer checksum verified"
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
        '{schemaVersion:1,tool:"hermes",installedAt:$installedAt,commandPath:$commandPath,version:$version,
          home:$hermesHome,configPath:$configPath,envFile:$envFile}' |
        pz_write_managed_file "$STATE_FILE" user
    chmod 0600 "$STATE_FILE"
}

mcp_sdk_available() {
    [ -x "$HERMES_VENV_PY" ] || return 1
    "$HERMES_VENV_PY" - <<'PY' >/dev/null 2>&1
import mcp
PY
}

env_has_auth_reference() {
    [ -f "$ENV_FILE" ] || return 1
    awk -F= '
        /^(OPENAI|ANTHROPIC|OPENROUTER)_API_KEY=/ {
            value=$0; sub(/^[^=]*=/, "", value)
            if (value != "" && value !~ /^<.*>$/ && value !~ /manual-secret-store-value/) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$ENV_FILE"
}

path_is_local_regular() {
    local path="$1" root="$2" resolved
    [ ! -e "$path" ] && [ ! -L "$path" ] && return 0
    [ -f "$path" ] || return 1
    resolved="$(realpath -e -- "$path" 2>/dev/null || true)"
    [ -n "$resolved" ] && [[ "$resolved" == "$root"/* ]]
}

status_json() {
    local cmd="" version="" mcp_count=0 sdk=false config_check=false doctor_ok=false
    local installed=false configured=false ready=false auth=false config_safe=false mcp_ready=false
    local config_mode="missing" env_mode="missing" state_mode="missing"
    cmd="$(hermes_cmd || true)"
    if [ -n "$cmd" ]; then
        installed=true
        version="$(timeout 10 "$cmd" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
        timeout 15 "$cmd" config check >/dev/null 2>&1 && config_check=true
        timeout 30 "$cmd" doctor >/dev/null 2>&1 && doctor_ok=true
    fi
    [ -f "$HERMES_CONFIG" ] && mcp_count="$(grep -c -E '^  # BEGIN PHASEZERO MCP ' "$HERMES_CONFIG" 2>/dev/null || true)"
    mcp_sdk_available && sdk=true
    path_is_local_regular "$HERMES_CONFIG" "$HERMES_HOME" && config_safe=true
    [ -f "$HERMES_CONFIG" ] && config_mode="$(stat -c %a "$HERMES_CONFIG" 2>/dev/null || echo unknown)"
    [ -f "$ENV_FILE" ] && env_mode="$(stat -c %a "$ENV_FILE" 2>/dev/null || echo unknown)"
    [ -f "$STATE_FILE" ] && state_mode="$(stat -c %a "$STATE_FILE" 2>/dev/null || echo unknown)"
    env_has_auth_reference && auth=true
    [ "$mcp_count" -gt 0 ] && [ "$sdk" = true ] && mcp_ready=true
    if [ -f "$HERMES_CONFIG" ] && [ -f "$ENV_FILE" ] && [ "$config_safe" = true ] &&
        [ "$config_mode" = 600 ] && [ "$env_mode" = 600 ]; then
        configured=true
    fi
    if [ "$installed" = true ] && [ "$configured" = true ] && [ "$config_check" = true ] &&
        [ "$doctor_ok" = true ] && [ "$auth" = true ] && [ "$mcp_ready" = true ]; then
        ready=true
    fi
    jq -cn \
        --argjson schemaVersion 1 \
        --arg commandPath "$cmd" \
        --arg version "$version" \
        --arg hermesHome "$HERMES_HOME" \
        --arg configPath "$HERMES_CONFIG" \
        --arg envFile "$ENV_FILE" \
        --arg stateFile "$STATE_FILE" \
        --arg configMode "$config_mode" \
        --arg envMode "$env_mode" \
        --arg stateMode "$state_mode" \
        --argjson available "$installed" \
        --argjson installed "$installed" \
        --argjson configured "$configured" \
        --argjson ready "$ready" \
        --argjson authConfigured "$auth" \
        --argjson configPathSafe "$config_safe" \
        --argjson configExists "$([ -f "$HERMES_CONFIG" ] && echo true || echo false)" \
        --argjson envExists "$([ -f "$ENV_FILE" ] && echo true || echo false)" \
        --argjson stateExists "$([ -f "$STATE_FILE" ] && echo true || echo false)" \
        --argjson mcpServerCount "$mcp_count" \
        --argjson mcpSdk "$sdk" \
        --argjson mcpReady "$mcp_ready" \
        --argjson configCheckOk "$config_check" \
        --argjson doctorOk "$doctor_ok" \
        '{schemaVersion:$schemaVersion,tool:"hermes",id:"hermes",available:$available,installed:$installed,
          configured:$configured,ready:$ready,commandPath:$commandPath,version:$version,home:$hermesHome,
          configPath:$configPath,configExists:$configExists,configMode:$configMode,configPathSafe:$configPathSafe,
          envFile:$envFile,envExists:$envExists,envMode:$envMode,stateFile:$stateFile,stateExists:$stateExists,
          stateMode:$stateMode,auth:{configured:$authConfigured,secretsRedacted:true},
          mcp:{serverCount:$mcpServerCount,pythonSdk:$mcpSdk,ready:$mcpReady},configCheckOk:$configCheckOk,
          doctor:{ok:$doctorOk,outputRedacted:true},secretsRedacted:true}'
}

doctor_json() {
    local status policy checksum="${PZ_HERMES_INSTALL_SHA256:-}" tailscale=false tailscale_auth=false
    status="$(status_json)"
    policy="$(bash "$PZ_ROOT/linux/server/ai-policy-broker.sh" check hermes-install checksum="$checksum" 2>/dev/null || echo '{"allow":false,"reasons":["policy probe failed"]}')"
    command -v tailscale >/dev/null 2>&1 && tailscale=true
    [ "$tailscale" = true ] && tailscale status >/dev/null 2>&1 && tailscale_auth=true
    jq -cn --argjson status "$status" --argjson policy "$policy" \
        --argjson tailscaleInstalled "$tailscale" --argjson tailscaleAuthenticated "$tailscale_auth" \
        --argjson checksumPinned "$([[ "$checksum" =~ ^[0-9a-fA-F]{64}$ ]] && echo true || echo false)" \
        '{schemaVersion:1,id:"hermes",diagnosticComplete:true,ready:$status.ready,status:$status,
          distribution:{installer:"https://hermes-agent.nousresearch.com/install.sh",sha256Pinned:$checksumPinned,
            policyAllowed:$policy.allow},remoteAccess:{provider:"tailscale",installed:$tailscaleInstalled,
            authenticated:$tailscaleAuthenticated},issues:([
              if ($status.installed|not) then {severity:"error",component:"hermes",code:"hermes-not-installed"} else empty end,
              if ($checksumPinned|not) then {severity:"error",component:"hermes",code:"hermes-installer-untrusted"} else empty end,
              if ($status.auth.configured|not) then {severity:"warning",component:"hermes",code:"hermes-auth-unconfigured"} else empty end,
              if ($status.configExists and $status.configMode != "600") then {severity:"error",component:"hermes",code:"hermes-config-permissions-unsafe"} else empty end,
              if ($status.envExists and $status.envMode != "600") then {severity:"error",component:"hermes",code:"hermes-env-permissions-unsafe"} else empty end,
              if ($status.mcp.ready|not) then {severity:"warning",component:"hermes",code:"hermes-mcp-not-ready"} else empty end,
              if ($status.configPathSafe|not) then {severity:"error",component:"hermes",code:"hermes-config-path-unsafe"} else empty end,
              if ($tailscaleAuthenticated|not) then {severity:"warning",component:"tailscale",code:"tailscale-unavailable"} else empty end
            ]),secretsRedacted:true}'
}

plan_json() {
    local doctor gate=false allowed=false
    doctor="$(doctor_json)"
    [ "${PZ_HOMELAB_ALLOW_HOST_WORKLOADS:-0}" = 1 ] && gate=true
    if [ "$gate" = true ] && jq -e '.distribution.sha256Pinned == true and .distribution.policyAllowed == true' \
        >/dev/null 2>&1 <<< "$doctor"; then
        allowed=true
    fi
    jq -cn \
        --arg home "$HERMES_HOME" --arg configPath "$HERMES_CONFIG" --arg envFile "$ENV_FILE" \
        --argjson doctor "$doctor" --argjson releaseGate "$gate" --argjson deploymentAllowed "$allowed" \
        '{schemaVersion:1,tool:"hermes",id:"hermes",mode:"read-only-plan",releaseGate:$releaseGate,
          deploymentAllowed:$deploymentAllowed,ready:$doctor.ready,home:$home,configPath:$configPath,envFile:$envFile,
          phases:["verify immutable installer checksum","verify policy and release gate","stage isolated install",
            "sync MCP configuration without raw secrets","run config check and doctor","complete official authentication",
            "record version, paths and rollback manifest"],
          blockers:(([if ($releaseGate|not) then "roadmap-host-deployment-blocked" else empty end,
            if ($doctor.distribution.sha256Pinned|not) then "hermes-installer-untrusted" else empty end,
            if ($doctor.distribution.policyAllowed|not) then "policy-denied" else empty end] +
            [$doctor.issues[]?.code]) | unique),secretsRedacted:true}'
}

case "${1:-setup}" in
    setup)
        require_workload_release_gate
        install_hermes
        configure_hermes
        status_json
        ;;
    install) require_workload_release_gate; install_hermes ;;
    configure) require_workload_release_gate; configure_hermes ;;
    mcp) require_workload_release_gate; bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync hermes ;;
    status) status_json ;;
    dry-run|plan) plan_json ;;
    doctor|diagnose) doctor_json ;;
    portal)
        require_workload_release_gate
        cmd="$(hermes_cmd || true)"
        [ -n "$cmd" ] || { pz_error "Hermes not installed"; exit 1; }
        "$cmd" setup --portal
        ;;
    *) echo "usage: setup-hermes.sh (setup|install|configure|mcp|status|doctor|dry-run|portal)"; exit 1 ;;
esac
