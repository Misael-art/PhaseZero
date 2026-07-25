#!/usr/bin/env bash
# setup-memory.sh - install/configure ai-memory for Linux agent CLIs
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

AI_MEMORY_ORIGIN="${AI_MEMORY_SERVER_URL:-http://127.0.0.1:49374}"
AI_MEMORY_ORIGIN="${AI_MEMORY_ORIGIN%/}"
AI_MEMORY_MCP_URL="${AI_MEMORY_ORIGIN}/mcp"
AI_MEMORY_DATA_DIR="${AI_MEMORY_DATA_DIR:-$HOME/.local/share/ai-memory}"
AI_MEMORY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ai-memory"
AI_MEMORY_CONFIG="${AI_MEMORY_CONFIG:-$AI_MEMORY_CONFIG_DIR/config.toml}"
AI_MEMORY_ENV="${AI_MEMORY_ENV:-$AI_MEMORY_CONFIG_DIR/env}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"

ai_memory_cmd() {
    command -v ai-memory 2>/dev/null || {
        [ -x "$LOCAL_BIN/ai-memory" ] && echo "$LOCAL_BIN/ai-memory"
    }
}

is_phasezero_docker_wrapper() {
    local cmd="$1"
    [ -f "$cmd" ] && grep -q 'AI_MEMORY_DOCKER_IMAGE' "$cmd" 2>/dev/null
}

detected_agents() {
    command -v claude >/dev/null 2>&1 && echo "claude-code:claude-code"
    command -v codex >/dev/null 2>&1 && echo "codex:codex"
    command -v opencode >/dev/null 2>&1 && echo "opencode:opencode"
    command -v openclaw >/dev/null 2>&1 && echo "openclaw:openclaw"
    command -v cursor >/dev/null 2>&1 && echo "cursor:cursor"
    command -v gemini >/dev/null 2>&1 && echo "gemini-cli:gemini-cli"
}

auth_args() {
    if [ -n "${AI_MEMORY_AUTH_TOKEN:-}" ]; then
        printf '%s\n' "--auth-token" "$AI_MEMORY_AUTH_TOKEN"
    fi
}

install_via_aur() {
    pz_can_sudo_noninteractive || return 1
    if command -v yay >/dev/null 2>&1; then
        yay -S --needed --noconfirm ai-memory-bin
        return 0
    fi
    if command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm ai-memory-bin
        return 0
    fi
    return 1
}

install_via_docker_wrapper() {
    command -v docker >/dev/null 2>&1 || return 1
    mkdir -p "$LOCAL_BIN"
    pz_write_managed_file "$LOCAL_BIN/ai-memory" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
image="${AI_MEMORY_DOCKER_IMAGE:-akitaonrails/ai-memory:latest}"
data_dir="${AI_MEMORY_DATA_DIR:-$HOME/.local/share/ai-memory}"
workdir="${PWD:-$HOME}"
[ -d "$workdir" ] || workdir="$HOME"
mkdir -p "$data_dir"
exec docker run --rm \
  --network host \
  --user "$(id -u):$(id -g)" \
  -e HOME="$HOME" \
  -e USER="${USER:-$(id -un)}" \
  -e AI_MEMORY_DATA_DIR="/data" \
  -v "$HOME:$HOME" \
  -v "$data_dir:/data" \
  -w "$workdir" \
  "$image" "$@"
EOF
    chmod +x "$LOCAL_BIN/ai-memory"
    export PATH="$LOCAL_BIN:$PATH"
}

install_via_source() {
    command -v git >/dev/null 2>&1 || return 1
    command -v cargo >/dev/null 2>&1 || return 1
    local src="${PZ_AI_SOURCE_DIR:-$HOME/.local/share/phasezero/src}/ai-memory"
    mkdir -p "$(dirname "$src")" "$LOCAL_BIN"
    if [ ! -d "$src/.git" ]; then
        git clone --depth 1 https://github.com/akitaonrails/ai-memory "$src"
    else
        git -C "$src" pull --ff-only
    fi
    cargo build --release --workspace --manifest-path "$src/Cargo.toml"
    install -m 0755 "$src/target/release/ai-memory" "$LOCAL_BIN/ai-memory"
    pz_record_created ai "$LOCAL_BIN/ai-memory"
    export PATH="$LOCAL_BIN:$PATH"
}

install_ai_memory() {
    local existing=""
    existing="$(ai_memory_cmd || true)"
    if [ -n "$existing" ]; then
        if is_phasezero_docker_wrapper "$existing"; then
            install_via_docker_wrapper
            pz_info "ai-memory docker wrapper refreshed: $existing"
            return 0
        fi
        pz_info "ai-memory already installed: $existing"
        return 0
    fi
    if install_via_aur; then
        pz_info "ai-memory installed via AUR package ai-memory-bin"
        return 0
    fi
    if install_via_docker_wrapper; then
        pz_info "ai-memory docker wrapper installed at $LOCAL_BIN/ai-memory"
        return 0
    fi
    if install_via_source; then
        pz_info "ai-memory built from source into $LOCAL_BIN/ai-memory"
        return 0
    fi
    pz_error "could not install ai-memory; install yay/paru, docker, or git+cargo"
    return 1
}

write_default_config() {
    mkdir -p "$AI_MEMORY_CONFIG_DIR" "$AI_MEMORY_DATA_DIR"
    if [ ! -f "$AI_MEMORY_CONFIG" ]; then
        pz_write_managed_file "$AI_MEMORY_CONFIG" <<EOF
# PhaseZero managed ai-memory user config.
# Loopback default. Put provider credentials in $AI_MEMORY_ENV, never in repo files.
bind = "127.0.0.1:49374"
data_dir = "$AI_MEMORY_DATA_DIR"
EOF
    fi
    if [ ! -f "$AI_MEMORY_ENV" ]; then
        pz_write_managed_file "$AI_MEMORY_ENV" <<'EOF'
# PhaseZero managed ai-memory env.
# Optional:
# AI_MEMORY_LLM_PROVIDER=anthropic
# ANTHROPIC_API_KEY=<put-in-secret-store-or-edit-manually>
EOF
        chmod 600 "$AI_MEMORY_ENV" 2>/dev/null || true
    fi
}

init_ai_memory() {
    local cmd
    cmd="$(ai_memory_cmd || true)"
    [ -n "$cmd" ] || { pz_warn "ai-memory not installed; skipping init"; return 0; }
    mkdir -p "$AI_MEMORY_DATA_DIR" "$AI_MEMORY_CONFIG_DIR"
    if is_phasezero_docker_wrapper "$cmd"; then
        "$cmd" init >/dev/null 2>&1 || pz_warn "ai-memory docker init failed; continuing"
        return 0
    fi
    "$cmd" --data-dir "$AI_MEMORY_DATA_DIR" --config "$AI_MEMORY_CONFIG" init >/dev/null 2>&1 || \
        "$cmd" init >/dev/null 2>&1 || \
        pz_warn "ai-memory init failed; continuing with config/service wiring"
}

install_user_service() {
    local cmd service_dir service_path
    cmd="$(ai_memory_cmd || true)"
    [ -n "$cmd" ] || { pz_warn "ai-memory not installed; skipping service"; return 0; }
    service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    service_path="$service_dir/ai-memory.service"
    mkdir -p "$service_dir"
    if [ ! -f "$service_path" ] || grep -q 'PhaseZero managed' "$service_path" 2>/dev/null; then
        local exec_start
        if is_phasezero_docker_wrapper "$cmd"; then
            exec_start="$cmd serve --transport http --bind 127.0.0.1:49374"
        else
            exec_start="$cmd --data-dir $AI_MEMORY_DATA_DIR --config $AI_MEMORY_CONFIG serve --transport http --bind 127.0.0.1:49374"
        fi
        pz_write_managed_file "$service_path" <<EOF
[Unit]
Description=ai-memory local loopback server
Documentation=https://github.com/akitaonrails/ai-memory

[Service]
# PhaseZero managed
EnvironmentFile=-$AI_MEMORY_ENV
ExecStart=$exec_start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    else
        pz_info "existing ai-memory user service preserved: $service_path"
    fi
    if systemctl --user daemon-reload >/dev/null 2>&1; then
        systemctl --user enable --now ai-memory.service >/dev/null 2>&1 || \
            pz_warn "could not enable ai-memory user service; run: systemctl --user enable --now ai-memory.service"
    else
        pz_warn "systemd user session unavailable; service file written only"
    fi
}

wire_agents() {
    local cmd pair client agent args=()
    cmd="$(ai_memory_cmd || true)"
    [ -n "$cmd" ] || { pz_warn "ai-memory not installed; skipping agent wiring"; return 0; }
    mapfile -t args < <(auth_args)
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        client="${pair%%:*}"
        agent="${pair##*:}"
        "$cmd" install-mcp --client "$client" --apply --server-url "$AI_MEMORY_MCP_URL" "${args[@]}" >/dev/null 2>&1 || \
            pz_warn "ai-memory MCP wiring failed for $client"
        "$cmd" install-hooks --agent "$agent" --apply --project-strategy repo-root --server-url "$AI_MEMORY_ORIGIN" "${args[@]}" >/dev/null 2>&1 || \
            pz_warn "ai-memory hooks wiring failed for $agent"
    done < <(detected_agents)
}

status_json() {
    bash "$PZ_ROOT/linux/ai/status.sh" | jq '.memory'
}

dry_run() {
    jq -cn --arg dataDir "$AI_MEMORY_DATA_DIR" --arg config "$AI_MEMORY_CONFIG" --arg origin "$AI_MEMORY_ORIGIN" \
        --arg agents "$(detected_agents | cut -d: -f1 | paste -sd ',' -)" \
        '{tool:"ai-memory",planned:["install ai-memory-bin via AUR when available","create user config/env","enable user service","install MCP/hooks for detected agents"],dataDir:$dataDir,config:$config,serverUrl:$origin,detectedAgents:($agents|split(",")|map(select(length>0)))}'
}

configure_ai_memory() {
    write_default_config
    init_ai_memory
    install_user_service
    wire_agents
    status_json
}

case "${1:-setup}" in
    setup)
        install_ai_memory
        configure_ai_memory
        ;;
    install) install_ai_memory ;;
    configure) configure_ai_memory ;;
    service)
        write_default_config
        init_ai_memory
        install_user_service
        ;;
    wire) wire_agents ;;
    status) status_json ;;
    dry-run|plan) dry_run ;;
    *) echo "usage: setup-memory.sh (setup|install|configure|service|wire|status|dry-run)"; exit 1 ;;
esac
