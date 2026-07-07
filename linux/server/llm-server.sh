#!/usr/bin/env bash
# llm-server.sh - PhaseZero local LLM server mode (Ollama).
#
# Installs/enables Ollama, pulls a small default model and (opt-in) exposes it on
# the LAN so other devices on the Tailscale/home network can use it. The LAN bind
# is a reversible systemd drop-in.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

DROPIN_DIR="/etc/systemd/system/ollama.service.d"
DROPIN="$DROPIN_DIR/10-phasezero-llm-server.conf"
DEFAULT_MODEL="${PZ_LLM_SERVER_MODEL:-qwen2.5-coder:1.5b}"

admin_run() {
    if pz_can_sudo_noninteractive; then sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then phasezero-admin "$@"
    else return 127; fi
}

cmd_install() {
    bash "$PZ_ROOT/linux/ai/setup-ollama.sh" || pz_warn "ollama base setup reported issues"
    if command -v ollama >/dev/null 2>&1 && ! ollama list 2>/dev/null | grep -q "${DEFAULT_MODEL%%:*}"; then
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would pull $DEFAULT_MODEL"
        else
            pz_info "pulling $DEFAULT_MODEL (server default; background)"
            nohup ollama pull "$DEFAULT_MODEL" >/dev/null 2>&1 &
        fi
    fi
    [ "${PZ_LLM_SERVER_LAN:-0}" = "1" ] && cmd_expose_lan
    pz_info "LLM server ready. Local API: http://127.0.0.1:11434"
}

cmd_expose_lan() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would write $DROPIN (OLLAMA_HOST=0.0.0.0) and restart ollama"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<'EOF'
# PhaseZero managed: expose Ollama on the LAN/Tailscale interface for the home
# server. Remove this drop-in (llm-server.sh restore) to revert to localhost.
[Service]
Environment=OLLAMA_HOST=0.0.0.0:11434
EOF
    if admin_run install -Dm644 "$tmp" "$DROPIN"; then
        admin_run systemctl daemon-reload
        admin_run systemctl restart ollama || pz_warn "restart ollama manually"
        pz_info "Ollama now listening on 0.0.0.0:11434 (reach it via Tailscale IP)"
    else
        pz_warn "need root to write $DROPIN; run: sudo $0 expose-lan"
    fi
    rm -f "$tmp"
}

cmd_restore() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then pz_info "dry-run: would remove $DROPIN"; return 0; fi
    admin_run rm -f "$DROPIN" 2>/dev/null || true
    admin_run systemctl daemon-reload 2>/dev/null || true
    admin_run systemctl restart ollama 2>/dev/null || true
    pz_info "Ollama LAN exposure reverted to localhost"
}

cmd_status() {
    local installed=false active=false lan=false models="[]"
    command -v ollama >/dev/null 2>&1 && installed=true
    systemctl is-active ollama >/dev/null 2>&1 && active=true
    [ -f "$DROPIN" ] && lan=true
    if $active; then
        models="$(curl -fsS http://127.0.0.1:11434/api/tags 2>/dev/null | jq -c '[.models[].name]' 2>/dev/null || echo '[]')"
    fi
    jq -n --argjson installed "$installed" --argjson active "$active" --argjson lan "$lan" \
        --arg default "$DEFAULT_MODEL" --argjson models "$models" \
        '{tool:"llm-server", installed:$installed, serviceActive:$active, lanExposed:$lan, defaultModel:$default, models:$models}'
}

case "${1:-status}" in
    install|setup|up) cmd_install ;;
    expose-lan|lan) cmd_expose_lan ;;
    restore|revert) cmd_restore ;;
    status) cmd_status ;;
    dry-run|plan) PZ_DRY_RUN=1 cmd_install ;;
    *) pz_error "usage: llm-server.sh (install|expose-lan|restore|status|dry-run)"; exit 2 ;;
esac
