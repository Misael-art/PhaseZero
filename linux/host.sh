#!/usr/bin/env bash
# host.sh - higiene do host PhaseZero (ledger, backups, pegada)
#
# Dry-run é o padrão em tudo que muta. Nada aqui toca ~/Emulation.
#
#   pz host status                   pegada atual (JSON)
#   pz host backups migrate          move .bak legados p/ store central
#   pz host backups migrate --apply  idem, de verdade
#   pz host backups list             lista backups centralizados
#   pz host backups prune [--keep N] mantém só os N mais recentes por arquivo
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PZ_MODULE="host"
PRESERVE="$HOME/Emulation"

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,14p'
}

# --- backups --------------------------------------------------------------

host_backups_migrate() {
    local apply=0 arg
    for arg in "$@"; do
        case "$arg" in
            --apply) apply=1 ;;
            --dry-run|-n) apply=0 ;;
            *) pz_warn "flag desconhecida ignorada: $arg" ;;
        esac
    done

    if [ "$apply" = 1 ]; then
        PZ_DRY_RUN=0 migrate_legacy_baks
    else
        printf 'MODO: DRY-RUN (nada será movido). Para aplicar: --apply\n'
        PZ_DRY_RUN=1 migrate_legacy_baks
    fi
}

host_backups_list() {
    local dir origin count
    if [ ! -d "$PZ_BACKUP_ROOT" ]; then
        printf 'nenhum backup centralizado em %s\n' "$PZ_BACKUP_ROOT"
        return 0
    fi
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        origin="$(cat "$dir/origin" 2>/dev/null || echo '(origem desconhecida)')"
        count="$({ find "$dir" -maxdepth 1 -type f -name '*.bak.*' 2>/dev/null || true; } | wc -l | tr -d ' ')"
        printf '%-4s %s\n' "$count" "$origin"
    done < <({ find "$PZ_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; } | sort)
}

host_backups_prune() {
    local keep=5 arg
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep) keep="${2:-5}"; shift 2 ;;
            --keep=*) keep="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -d "$PZ_BACKUP_ROOT" ] || { printf 'nada a podar\n'; return 0; }
    local dir origin
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        origin="$(cat "$dir/origin" 2>/dev/null || true)"
        [ -n "$origin" ] || continue
        pz_backup_prune "$origin" "$keep"
    done < <(find "$PZ_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    printf 'poda concluída (keep=%s por arquivo)\n' "$keep"
}

# --- status ---------------------------------------------------------------

host_status() {
    # `set -o pipefail` está ativo: todo pipeline com `find` sobre diretório
    # ainda inexistente precisa de guarda explícita, senão o status morre calado.
    local legacy_count backup_groups ledger_entries
    legacy_count="$(PZ_DRY_RUN=1 migrate_legacy_baks 2>/dev/null | grep -c '^  \[dry\] migrar' || true)"
    backup_groups="$( { find "$PZ_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; } | wc -l | tr -d ' ')"
    ledger_entries="$(pz_ledger_count || echo 0)"
    [ -n "$legacy_count" ] || legacy_count=0
    [ -n "$backup_groups" ] || backup_groups=0
    [ -n "$ledger_entries" ] || ledger_entries=0

    jq -n \
        --arg stateDir "$PZ_STATE" \
        --arg backupRoot "$PZ_BACKUP_ROOT" \
        --arg ledgerFile "$PZ_LEDGER_FILE" \
        --argjson ledgerEntries "${ledger_entries:-0}" \
        --argjson backupGroups "${backup_groups:-0}" \
        --argjson legacyBaks "${legacy_count:-0}" \
        --arg preserved "$PRESERVE" \
        '{
            ok: true,
            module: "host",
            status: (if $legacyBaks > 0 then "attention" else "ok" end),
            stateDir: $stateDir,
            backupRoot: $backupRoot,
            ledgerFile: $ledgerFile,
            ledgerEntries: $ledgerEntries,
            backupGroups: $backupGroups,
            legacyBaksPending: $legacyBaks,
            preserved: [$preserved]
        }'
}

# --- dispatch -------------------------------------------------------------

main() {
    local action="${1:-status}"
    shift 2>/dev/null || true
    case "$action" in
        status) host_status ;;
        backups)
            local sub="${1:-list}"
            shift 2>/dev/null || true
            case "$sub" in
                migrate) host_backups_migrate "$@" ;;
                list)    host_backups_list ;;
                prune)   host_backups_prune "$@" ;;
                *) pz_error "pz host backups: ação desconhecida: $sub"; usage; return 2 ;;
            esac
            ;;
        help|--help|-h) usage ;;
        *) pz_error "pz host: ação desconhecida: $action"; usage; return 2 ;;
    esac
}

main "$@"
