#!/usr/bin/env bash
# json-envelope.sh - JSON envelope builder for PhaseZero UI
set -euo pipefail

PZ_JSON_MODULE=""
PZ_JSON_STATUS="ok"
PZ_JSON_OK=true
PZ_JSON_GENERATED=""
PZ_JSON_CHECKS='[]'
PZ_JSON_ACTIONS='[]'
PZ_JSON_BLOCKERS='[]'
PZ_JSON_LOGS='[]'

pz_json_envelope_start() {
    local module="${1:-system}" status="${2:-ok}"
    PZ_JSON_MODULE="$module"
    PZ_JSON_STATUS="$status"
    PZ_JSON_OK=true
    PZ_JSON_CHECKS='[]'
    PZ_JSON_ACTIONS='[]'
    PZ_JSON_BLOCKERS='[]'
    PZ_JSON_LOGS='[]'
    PZ_JSON_GENERATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

pz_json_append_check() {
    local name="$1" status="$2" message="$3"
    local entry
    entry="$(jq -n --arg n "$name" --arg s "$status" --arg m "$message" '{name: $n, status: $s, message: $m}')"
    PZ_JSON_CHECKS="$(jq --argjson entry "$entry" '. + [$entry]' <<< "$PZ_JSON_CHECKS")"
}

pz_json_append_action() {
    local name="$1" label="$2" mutable="${3:-false}"
    local entry
    entry="$(jq -n --arg n "$name" --arg l "$label" --argjson m "$mutable" '{name: $n, label: $l, mutable: $m}')"
    PZ_JSON_ACTIONS="$(jq --argjson entry "$entry" '. + [$entry]' <<< "$PZ_JSON_ACTIONS")"
}

pz_json_append_blocker() {
    local reason="$1"
    PZ_JSON_BLOCKERS="$(jq --arg reason "$reason" '. + [$reason]' <<< "$PZ_JSON_BLOCKERS")"
}

pz_json_append_log() {
    local level="$1" message="$2"
    local entry
    entry="$(jq -n --arg l "$level" --arg m "$message" '{level: $l, message: $m}')"
    PZ_JSON_LOGS="$(jq --argjson entry "$entry" '. + [$entry]' <<< "$PZ_JSON_LOGS")"
}

pz_json_envelope_end() {
    local ok="$PZ_JSON_OK" module="$PZ_JSON_MODULE" status="$PZ_JSON_STATUS"
    local checks="$PZ_JSON_CHECKS" actions="$PZ_JSON_ACTIONS"
    local blockers="$PZ_JSON_BLOCKERS" logs="$PZ_JSON_LOGS" generated="$PZ_JSON_GENERATED"
    jq -n \
        --argjson ok "$ok" \
        --arg module "$module" \
        --arg status "$status" \
        --argjson checks "$checks" \
        --argjson actions "$actions" \
        --argjson blockers "$blockers" \
        --argjson logs "$logs" \
        --arg generatedAt "$generated" \
        '{ok: $ok, module: $module, status: $status, checks: $checks, actions: $actions, blockers: $blockers, logs: $logs, generatedAt: $generatedAt}'
}

pz_json_envelope_simple() {
    local module="$1" status="$2" checks_extra="${3:-}"
    pz_json_envelope_start "$module" "$status"
    [ -n "$checks_extra" ] && PZ_JSON_CHECKS="$checks_extra"
    pz_json_envelope_end
}

# --- envelope result (correção 4) ----------------------------------------
#
# Contrato: TODO apply/preview termina com um result legível, inclusive quando
# falha e inclusive em modo degradado. A UI e a CLI nunca ficam sem resposta.
#
#   { ok, code, summary, howToFix[], ledgerRef, logPath }
#
# `code` é o vocabulário fechado abaixo. `degraded` não é erro: a operação
# rodou em dry-run porque faltou a admin bridge, e `howToFix` diz o que fazer.

PZ_RESULT_CODES="ok degraded blocked failed refused"

pz_result_valid_code() {
    case " $PZ_RESULT_CODES " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac
}

# pz_result_envelope <code> <summary> [howToFix...]
pz_result_envelope() {
    local code="${1:-failed}" summary="${2:-}" ok
    shift 2 2>/dev/null || shift $#
    pz_result_valid_code "$code" || code="failed"
    case "$code" in
        ok|degraded) ok=true ;;
        *) ok=false ;;
    esac
    [ -n "$summary" ] || summary="operação sem resumo"

    local how_to_fix='[]'
    if [ "$#" -gt 0 ]; then
        how_to_fix="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    fi

    jq -n \
        --argjson ok "$ok" \
        --arg code "$code" \
        --arg summary "$summary" \
        --argjson howToFix "$how_to_fix" \
        --arg ledgerRef "$(command -v pz_ledger_ref >/dev/null 2>&1 && pz_ledger_ref || echo '')" \
        --arg logPath "${PZ_LOG:-}" \
        --arg module "${PZ_MODULE:-unknown}" \
        --arg operationId "${PZ_OPERATION_ID:-unknown}" \
        --argjson dryRun "$([ "${PZ_DRY_RUN:-0}" = "1" ] && echo true || echo false)" \
        '{
            ok: $ok,
            code: $code,
            summary: $summary,
            howToFix: $howToFix,
            ledgerRef: $ledgerRef,
            logPath: $logPath,
            module: $module,
            operationId: $operationId,
            dryRun: $dryRun
        }'
}

# Envelope de degradação por falta de admin bridge.
#
# Existe porque `pz_result_envelope degraded "..." $(pz_admin_howtofix)` é uma
# armadilha: a substituição sem aspas quebra as instruções em palavras soltas e
# o usuário recebe howToFix=["Instale","a","admin",...]. Aqui as linhas são
# lidas inteiras.
#
#   pz_result_degraded_admin <summary> [instrução extra]...
pz_result_degraded_admin() {
    local summary="${1:-mutação de sistema não aplicada}"
    shift 2>/dev/null || true
    local -a steps=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && steps+=("$line")
    done < <(pz_admin_howtofix)
    for line in "$@"; do
        [ -n "$line" ] && steps+=("$line")
    done
    pz_result_envelope degraded "$summary" "${steps[@]}"
}

# Rede de segurança: instale com `trap` para que uma saída inesperada (erro
# não tratado, set -e, sinal) ainda produza um envelope legível.
#
#   pz_result_guard_install "meu-modulo"
#
# Se o comando terminar normalmente e já tiver emitido um envelope, chame
# `pz_result_emitted` antes de sair para desarmar a rede.
PZ_RESULT_EMITTED=0

pz_result_emitted() { PZ_RESULT_EMITTED=1; }

pz_result_guard() {
    local rc=$?
    [ "${PZ_RESULT_EMITTED:-0}" = "1" ] && return 0
    [ "$rc" -eq 0 ] && return 0
    PZ_RESULT_EMITTED=1
    pz_result_envelope failed \
        "${PZ_MODULE:-operação} terminou com código $rc sem emitir resultado" \
        "Consulte o log: ${PZ_LOG:-<log indisponível>}" \
        "Reexecute com PZ_DEBUG=1 para rastreio detalhado"
}

pz_result_guard_install() {
    PZ_MODULE="${1:-${PZ_MODULE:-unknown}}"
    PZ_RESULT_EMITTED=0
    trap pz_result_guard EXIT
}
