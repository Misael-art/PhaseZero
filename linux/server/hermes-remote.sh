#!/usr/bin/env bash
# hermes-remote.sh - Hermes agent for remote actuation on the home server.
#
# Thin wrapper over linux/ai/setup-hermes.sh: installs+configures Hermes and
# surfaces the remote portal. Remote reachability itself is provided by Tailscale
# (see homelab-stack.sh); Hermes is the actuation layer on top.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

HERMES="$PZ_ROOT/linux/ai/setup-hermes.sh"

case "${1:-status}" in
    setup|install)
        bash "$HERMES" setup
        pz_info "Hermes ready. Remote actuation over Tailscale; open the portal with: pz server hermes start"
        ;;
    start|portal)
        if command -v hermes >/dev/null 2>&1 || [ -x "$HOME/.hermes/bin/hermes" ]; then
            bash "$HERMES" portal || pz_warn "hermes portal not available; run: pz ai setup hermes"
        else
            pz_warn "Hermes not installed; run: pz server hermes setup"
        fi
        ;;
    status) bash "$HERMES" status ;;
    dry-run|plan) bash "$HERMES" dry-run ;;
    *) pz_error "usage: hermes-remote.sh (setup|start|status|dry-run)"; exit 2 ;;
esac
