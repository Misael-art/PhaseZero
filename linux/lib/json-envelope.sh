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
    PZ_JSON_CHECKS="$(echo "$PZ_JSON_CHECKS" | jq ". + [$entry]")"
}

pz_json_append_action() {
    local name="$1" label="$2" mutable="${3:-false}"
    local entry
    entry="$(jq -n --arg n "$name" --arg l "$label" --argjson m "$mutable" '{name: $n, label: $l, mutable: $m}')"
    PZ_JSON_ACTIONS="$(echo "$PZ_JSON_ACTIONS" | jq ". + [$entry]")"
}

pz_json_append_blocker() {
    local reason="$1"
    PZ_JSON_BLOCKERS="$(echo "$PZ_JSON_BLOCKERS" | jq ". + [\"$reason\"]")"
}

pz_json_append_log() {
    local level="$1" message="$2"
    local entry
    entry="$(jq -n --arg l "$level" --arg m "$message" '{level: $l, message: $m}')"
    PZ_JSON_LOGS="$(echo "$PZ_JSON_LOGS" | jq ". + [$entry]")"
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
