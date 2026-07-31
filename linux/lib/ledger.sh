#!/usr/bin/env bash
# ledger.sh - PhaseZero host mutation ledger
#
# Ponto ÚNICO de registro de mutação do host. Toda função que cria, modifica,
# instala ou habilita algo fora do processo precisa chamar `ledger_record`.
# O uninstall/wipe lê este ledger para saber exatamente o que remover
# ("leave no trace"), e o rollback usa `rollback_cmd`.
#
# Formato: JSON Lines em $PZ_STATE/ledger/ledger.jsonl (uma linha por operação).
# Campos por linha:
#   operation_id  string  id da operação pz que gerou a mutação
#   module        string  módulo lógico (steamdeck, ai, boot, emulation, ...)
#   action        string  verbo curto (write-managed-file, install-unit, backup, ...)
#   timestamp     string  ISO-8601
#   created       array   paths criados por esta operação (removíveis no wipe)
#   modified      array   paths pré-existentes alterados (restauráveis via backup)
#   backups       array   paths de backup dentro de $PZ_STATE/backups
#   services      array   unidades systemd tocadas ("user:nome" / "system:nome")
#   packages      array   pacotes instalados ("pacman:foo", "flatpak:org.x.Y")
#   scope         string  user | system
#   reversible    bool    se a operação pode ser desfeita automaticamente
#   rollback_cmd  string  comando de reversão (vazio quando não aplicável)
#
# Dry-run: `PZ_DRY_RUN=1` NÃO grava no ledger (nada mutou); a intenção é
# registrada no log com prefixo "[dry] ledger". Isso mantém dry-run
# leave-no-trace de verdade.
set -euo pipefail

[ -n "${PZ_LEDGER_SH_LOADED:-}" ] && return 0
PZ_LEDGER_SH_LOADED=1

PZ_LEDGER_DIR="${PZ_LEDGER_DIR:-$PZ_STATE/ledger}"
PZ_LEDGER_FILE="${PZ_LEDGER_FILE:-$PZ_LEDGER_DIR/ledger.jsonl}"

pz_ledger_init() {
    mkdir -p "$PZ_LEDGER_DIR"
    chmod 0700 "$PZ_LEDGER_DIR" 2>/dev/null || true
    [ -f "$PZ_LEDGER_FILE" ] || : > "$PZ_LEDGER_FILE"
    chmod 0600 "$PZ_LEDGER_FILE" 2>/dev/null || true
}

# ledger_record --module M --action A [--created P]... [--modified P]...
#               [--backup P]... [--service user:foo]... [--package pacman:foo]...
#               [--scope user|system] [--reversible true|false]
#               [--rollback-cmd "cmd"]
#
# Nunca falha a operação chamadora: erro de ledger vira WARN. Registrar é
# obrigatório, mas um ledger quebrado não pode derrubar uma instalação já feita.
ledger_record() {
    local module="" action="" scope="user" reversible="false" rollback_cmd=""
    local created=() modified=() backups=() services=() packages=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --module)       module="${2:-}"; shift 2 ;;
            --action)       action="${2:-}"; shift 2 ;;
            --created)      created+=("${2:-}"); shift 2 ;;
            --modified)     modified+=("${2:-}"); shift 2 ;;
            --backup)       backups+=("${2:-}"); shift 2 ;;
            --service)      services+=("${2:-}"); shift 2 ;;
            --package)      packages+=("${2:-}"); shift 2 ;;
            --scope)        scope="${2:-user}"; shift 2 ;;
            --reversible)   reversible="${2:-false}"; shift 2 ;;
            --rollback-cmd) rollback_cmd="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    [ -n "$module" ] || module="${PZ_MODULE:-unknown}"
    [ -n "$action" ] || action="unknown"
    case "$scope" in user|system) ;; *) scope="user" ;; esac
    case "$reversible" in true|false) ;; *) reversible="false" ;; esac

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_debug "[dry] ledger $module/$action created=${#created[@]} modified=${#modified[@]} backups=${#backups[@]}"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        pz_warn "jq ausente: mutação $module/$action não registrada no ledger"
        return 0
    fi

    pz_ledger_init || { pz_warn "ledger indisponível: $PZ_LEDGER_FILE"; return 0; }

    local line
    if ! line="$(
        jq -cn \
            --arg operation_id "${PZ_OPERATION_ID:-unknown}" \
            --arg module "$module" \
            --arg action "$action" \
            --arg timestamp "$(date -Iseconds)" \
            --arg scope "$scope" \
            --argjson reversible "$reversible" \
            --arg rollback_cmd "$rollback_cmd" \
            --args \
            '{
                operation_id: $operation_id,
                module: $module,
                action: $action,
                timestamp: $timestamp,
                created: ($ARGS.positional[0] | fromjson),
                modified: ($ARGS.positional[1] | fromjson),
                backups: ($ARGS.positional[2] | fromjson),
                services: ($ARGS.positional[3] | fromjson),
                packages: ($ARGS.positional[4] | fromjson),
                scope: $scope,
                reversible: $reversible,
                rollback_cmd: $rollback_cmd
            }' \
            "$(pz_ledger_json_array ${created[@]+"${created[@]}"})" \
            "$(pz_ledger_json_array ${modified[@]+"${modified[@]}"})" \
            "$(pz_ledger_json_array ${backups[@]+"${backups[@]}"})" \
            "$(pz_ledger_json_array ${services[@]+"${services[@]}"})" \
            "$(pz_ledger_json_array ${packages[@]+"${packages[@]}"})" \
        2>/dev/null
    )"; then
        pz_warn "falha ao serializar entrada de ledger: $module/$action"
        return 0
    fi

    printf '%s\n' "$line" >> "$PZ_LEDGER_FILE" 2>/dev/null \
        || pz_warn "falha ao gravar ledger: $PZ_LEDGER_FILE"
}

# Serializa argumentos em um array JSON (string). Sem argumentos -> "[]".
pz_ledger_json_array() {
    if [ "$#" -eq 0 ]; then
        printf '[]'
        return 0
    fi
    printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# --- leitura -------------------------------------------------------------

pz_ledger_entries() {
    [ -f "$PZ_LEDGER_FILE" ] || return 0
    cat "$PZ_LEDGER_FILE"
}

# Todos os paths criados pelo PhaseZero, deduplicados. Base do `host wipe`.
pz_ledger_created_paths() {
    [ -f "$PZ_LEDGER_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r 'select(.created != null) | .created[]' "$PZ_LEDGER_FILE" 2>/dev/null | sort -u
}

pz_ledger_modified_paths() {
    [ -f "$PZ_LEDGER_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r 'select(.modified != null) | .modified[]' "$PZ_LEDGER_FILE" 2>/dev/null | sort -u
}

pz_ledger_services() {
    [ -f "$PZ_LEDGER_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r 'select(.services != null) | .services[]' "$PZ_LEDGER_FILE" 2>/dev/null | sort -u
}

pz_ledger_packages() {
    [ -f "$PZ_LEDGER_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r 'select(.packages != null) | .packages[]' "$PZ_LEDGER_FILE" 2>/dev/null | sort -u
}

pz_ledger_count() {
    [ -f "$PZ_LEDGER_FILE" ] || { echo 0; return 0; }
    wc -l < "$PZ_LEDGER_FILE" | tr -d ' '
}

# Referência estável para o envelope result (`ledgerRef`).
pz_ledger_ref() {
    printf '%s#%s\n' "$PZ_LEDGER_FILE" "${PZ_OPERATION_ID:-unknown}"
}
