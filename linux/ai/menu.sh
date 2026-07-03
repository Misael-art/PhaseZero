#!/usr/bin/env bash
# menu.sh - small terminal UI for Linux AI stack management.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

run_action() {
    case "$1" in
        status) bash "$PZ_ROOT/linux/ai/status.sh" | jq '.' ;;
        doctor) bash "$PZ_ROOT/linux/ai/mcp-manager.sh" doctor | jq '.' ;;
        repair) bash "$PZ_ROOT/linux/ai/mcp-manager.sh" repair all ;;
        sync-safe) bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync all ;;
        setup-codex) bash "$PZ_ROOT/linux/ai/setup-codex.sh" ;;
        setup-opencode) bash "$PZ_ROOT/linux/ai/setup-opencode.sh" ;;
        setup-claude) bash "$PZ_ROOT/linux/ai/setup-claude-code.sh" ;;
        install-claude-desktop) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-claude ;;
        repair-codex-desktop) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" repair-codex ;;
        desktop-status) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" status | jq '.' ;;
        desktop-services) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-services ;;
        setup-compat) bash "$PZ_ROOT/linux/ai/setup-agent-compat.sh" setup ;;
        compat-status) bash "$PZ_ROOT/linux/ai/setup-agent-compat.sh" status | jq '.' ;;
        setup-admin) bash "$PZ_ROOT/linux/ai/setup-admin-bridge.sh" setup ;;
        admin-status) bash "$PZ_ROOT/linux/ai/setup-admin-bridge.sh" status | jq '.' ;;
        setup-ides) bash "$PZ_ROOT/linux/ai/setup-ides.sh" configure ;;
        install-ide-apps) bash "$PZ_ROOT/linux/ai/setup-ides.sh" install-apps ;;
        setup-all) bash "$PZ_ROOT/linux/pz" ai setup all ;;
        quit) exit 0 ;;
        *) pz_error "unknown menu action: $1"; return 1 ;;
    esac
}

menu_text() {
    cat <<'EOF'
PhaseZero AI Linux

1. Status
2. MCP doctor
3. Repair MCP configs
4. Sync safe MCPs
5. Update Codex CLI
6. Setup OpenCode
7. Setup Claude Code
8. Install/update Claude Desktop
9. Repair Codex Desktop update
D. Desktop apps status
S. Enable desktop auto-updates
C. Setup agent compatibility (RTK/Caveman/Headroom)
T. Agent compatibility status
B. Setup admin bridge (bigsudo)
N. Admin bridge status
I. Setup IDE integration
J. Install IDE apps
A. Setup all AI tools
0. Quit
EOF
}

while true; do
    menu_text
    printf 'Select: '
    read -r choice
    case "$choice" in
        1) run_action status ;;
        2) run_action doctor ;;
        3) run_action repair ;;
        4) run_action sync-safe ;;
        5) run_action setup-codex ;;
        6) run_action setup-opencode ;;
        7) run_action setup-claude ;;
        8) run_action install-claude-desktop ;;
        9) run_action repair-codex-desktop ;;
        D|d) run_action desktop-status ;;
        S|s) run_action desktop-services ;;
        C|c) run_action setup-compat ;;
        T|t) run_action compat-status ;;
        B|b) run_action setup-admin ;;
        N|n) run_action admin-status ;;
        I|i) run_action setup-ides ;;
        J|j) run_action install-ide-apps ;;
        A|a) run_action setup-all ;;
        0) run_action quit ;;
        *) pz_warn "invalid option" ;;
    esac
    echo
done
