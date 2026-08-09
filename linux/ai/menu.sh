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
        install-qwen-desktop) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-qwen ;;
        repair-codex-desktop) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" repair-codex ;;
        desktop-status) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" status | jq '.' ;;
        desktop-services) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-services ;;
        setup-compat) bash "$PZ_ROOT/linux/ai/setup-agent-compat.sh" setup ;;
        compat-status) bash "$PZ_ROOT/linux/ai/setup-agent-compat.sh" status | jq '.' ;;
        setup-admin) bash "$PZ_ROOT/linux/ai/setup-admin-bridge.sh" setup ;;
        admin-status) bash "$PZ_ROOT/linux/ai/setup-admin-bridge.sh" status | jq '.' ;;
        init-project)
            printf 'Project dir [%s]: ' "$PWD"
            read -r project_dir
            bash "$PZ_ROOT/linux/ai/setup-agent-compat.sh" init "${project_dir:-$PWD}"
            ;;
        setup-ides) bash "$PZ_ROOT/linux/ai/setup-ides.sh" configure ;;
        install-ide-apps) bash "$PZ_ROOT/linux/ai/setup-ides.sh" install-apps ;;
        router-menu) router_menu ;;
        odysseus-menu) odysseus_menu ;;
        updates-menu) updates_menu ;;
        setup-all) bash "$PZ_ROOT/linux/pz" ai setup all ;;
        quit) exit 0 ;;
        *) pz_error "unknown menu action: $1"; return 1 ;;
    esac
}

router_menu() {
    local choice
    while true; do
        cat <<'EOF'
9Router
1. Status seguro
2. Abrir dashboard
3. Providers
4. Combos
5. Teste sob demanda
6. Clientes/variáveis
7. Verificar atualização
8. Atualizar com rollback
9. Doctor
0. Voltar
EOF
        read -r -p 'Select: ' choice
        case "$choice" in
            1) bash "$PZ_ROOT/linux/ai/9router-manager.sh" status | jq '.' ;;
            2) bash "$PZ_ROOT/linux/ai/9router-manager.sh" dashboard ;;
            3) bash "$PZ_ROOT/linux/ai/9router-manager.sh" provider status | jq '.' ;;
            4) bash "$PZ_ROOT/linux/ai/9router-manager.sh" combo list | jq '.' ;;
            5) bash "$PZ_ROOT/linux/ai/9router-manager.sh" test | jq '.' ;;
            6) bash "$PZ_ROOT/linux/ai/9router-manager.sh" client status | jq '.' ;;
            7) bash "$PZ_ROOT/linux/ai/9router-manager.sh" check-update | jq '.' ;;
            8) bash "$PZ_ROOT/linux/ai/9router-manager.sh" update ;;
            9) bash "$PZ_ROOT/linux/ai/9router-manager.sh" doctor | jq '.' ;;
            0) return ;;
            *) pz_warn "invalid option" ;;
        esac
    done
}

odysseus_menu() {
    local choice
    while true; do
        cat <<'EOF'
Odysseus workspace
1. Status
2. Provisionar
3. Abrir
4. Logs
5. Verificar atualização
6. Atualizar com rollback
7. Backup
8. Doctor
0. Voltar
EOF
        read -r -p 'Select: ' choice
        case "$choice" in
            1) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" status | jq '.' ;;
            2) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" install ;;
            3) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" open ;;
            4) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" logs ;;
            5) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" check-update | jq '.' ;;
            6) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" update ;;
            7) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" backup | jq '.' ;;
            8) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" doctor | jq '.' ;;
            0) return ;;
            *) pz_warn "invalid option" ;;
        esac
    done
}

updates_menu() {
    local choice
    while true; do
        cat <<'EOF'
Atualizações PhaseZero
1. Verificar tudo
2. Último estado
3. Reparar Codex Desktop
4. Atualizar 9Router
5. Atualizar Odysseus
6. Ativar verificação diária
0. Voltar
EOF
        read -r -p 'Select: ' choice
        case "$choice" in
            1) bash "$PZ_ROOT/linux/updates/app-updates.sh" check | jq '.' ;;
            2) bash "$PZ_ROOT/linux/updates/app-updates.sh" latest | jq '.' ;;
            3) bash "$PZ_ROOT/linux/updates/app-updates.sh" apply codex-desktop ;;
            4) bash "$PZ_ROOT/linux/updates/app-updates.sh" apply 9router ;;
            5) bash "$PZ_ROOT/linux/updates/app-updates.sh" apply odysseus ;;
            6) bash "$PZ_ROOT/linux/updates/app-updates.sh" install-service ;;
            0) return ;;
            *) pz_warn "invalid option" ;;
        esac
    done
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
9. Install/update Qwen Code Desktop
X. Repair Codex Desktop update
D. Desktop apps status
S. Enable desktop auto-updates
C. Setup agent compatibility (RTK/Caveman/Headroom)
T. Agent compatibility status
B. Setup admin bridge (bigsudo)
N. Admin bridge status
I. Setup IDE integration
J. Install IDE apps
R. 9Router organizado
O. Odysseus workspace
U. Atualizações PhaseZero
P. Init project rules (inject PhaseZero into any project)
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
        9) run_action install-qwen-desktop ;;
        R|r) run_action router-menu ;;
        X|x) run_action repair-codex-desktop ;;
        O|o) run_action odysseus-menu ;;
        U|u) run_action updates-menu ;;
        D|d) run_action desktop-status ;;
        S|s) run_action desktop-services ;;
        C|c) run_action setup-compat ;;
        T|t) run_action compat-status ;;
        B|b) run_action setup-admin ;;
        N|n) run_action admin-status ;;
        I|i) run_action setup-ides ;;
        J|j) run_action install-ide-apps ;;
        P|p) run_action init-project ;;
        A|a) run_action setup-all ;;
        0) run_action quit ;;
        *) pz_warn "invalid option" ;;
    esac
    echo
done
