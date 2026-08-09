#!/usr/bin/env bash
# setup-usagebar.sh - install/configure ai-usagebar on Linux
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ai-usagebar"
CONFIG_FILE="$CONFIG_DIR/config.toml"

install_usagebar() {
    if command -v ai-usagebar >/dev/null 2>&1; then
        pz_info "ai-usagebar already installed: $(command -v ai-usagebar)"
        return 0
    fi
    if ! pz_can_sudo_noninteractive; then
        pz_warn "sudo non-interactive unavailable; install with: yay -S --needed ai-usagebar-bin"
        return 0
    fi
    if command -v yay >/dev/null 2>&1; then
        yay -S --needed --noconfirm ai-usagebar-bin
        return 0
    fi
    if command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm ai-usagebar-bin
        return 0
    fi
    pz_error "ai-usagebar requires AUR package ai-usagebar-bin on this Linux path"
    return 1
}

configure_usagebar() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        pz_write_managed_file "$CONFIG_FILE" <<'EOF'
# PhaseZero managed ai-usagebar config. No raw keys here.
[providers.openai]
enabled = true
api_key_env = "OPENAI_API_KEY"

[providers.anthropic]
enabled = true
api_key_env = "ANTHROPIC_API_KEY"

[providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"

[providers.deepseek]
enabled = false
api_key_env = "DEEPSEEK_API_KEY"

[providers.zai]
enabled = false
api_key_env = "ZAI_API_KEY"
EOF
    fi
    pz_info "ai-usagebar config ready: $CONFIG_FILE"
}

status_json() {
    bash "$PZ_ROOT/linux/ai/status.sh" | jq \
        --arg path "$CONFIG_FILE" \
        --argjson exists "$([ -f "$CONFIG_FILE" ] && echo true || echo false)" \
        '.clis["ai-usagebar"] + {configPath:$path,configExists:$exists}'
}

dry_run() {
    jq -cn --arg config "$CONFIG_FILE" \
        '{tool:"ai-usagebar",planned:["install AUR ai-usagebar-bin when available","write config using env var names only"],configPath:$config}'
}

case "${1:-setup}" in
    setup)
        install_usagebar
        configure_usagebar
        status_json
        ;;
    install) install_usagebar ;;
    configure) configure_usagebar ;;
    status) status_json ;;
    dry-run|plan) dry_run ;;
    *) echo "usage: setup-usagebar.sh (setup|install|configure|status|dry-run)"; exit 1 ;;
esac
