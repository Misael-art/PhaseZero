#!/usr/bin/env bash
# homelab-status.sh - PhaseZero Homelab aggregate status (schemaVersion 1).
#
# Emits the single source of truth status JSON consumed by the CLI, UI and
# Player. Persists a copy at $HOMELAB_STATE/status.json (no secrets).
#
# `ready=true` only when real proofs exist: runtime installed, configured,
# containers active, all healthchecks healthy, no degrade reasons, and the
# last operation did not fail. Anything else is honest: ready=false + reasons.
#
# Usage:
#   homelab-status.sh status [--json]
#   homelab-status.sh verify [--json]
#   homelab-status.sh repair [--json]       (regenerate .env if missing; validate compose)
#
# Exit codes: 0 = ready, 1 = degraded/blocked, 2 = usage, 3 = state unreadable.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"
# shellcheck source=linux/server/homelab-operations.sh
source "$PZ_ROOT/linux/server/homelab-operations.sh"

HOMELAB_STATE="${PZ_HOMELAB_STATE:-$PZ_STATE/homelab}"
STATUS_FILE="${PZ_HOMELAB_STATUS_FILE:-$HOMELAB_STATE/status.json}"
COMPOSE_DIR="${PZ_HOMELAB_COMPOSE_DIR:-$PZ_ROOT/assets/home-server}"
CORE_FILE="$COMPOSE_DIR/docker-compose.homelab.yml"
LOCK_FILE_JSON="$COMPOSE_DIR/docker-compose.lock.json"

SCHEMA_VERSION="1"

# Render a set of arguments as a JSON array, yielding [] when empty.
arr_json() {
    if [ "$#" -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "$@" | jq -R . | jq -cs .
    fi
}

cmd="${1:-status}"
shift 2>/dev/null || true
# Functions do not inherit $@; keep a copy for subcommand dispatch.
HL_ARGS=("$@")

runtime_installed() {
    [ -x /usr/lib/phasezero/linux/pz ] || [ -x "$PZ_ROOT/linux/pz" ]
}

version_info() {
    if [ -f "$PZ_ROOT/version.json" ]; then
        jq -c '{version, channel, commit, builtAt}' "$PZ_ROOT/version.json"
    else
        echo '{"version":"unknown","channel":"unknown","commit":null,"builtAt":null}'
    fi
}

docker_ver() {
    docker --version 2>/dev/null | sed -E 's/^Docker version ([0-9.]+).*/\1/' || true
}

compose_ver() {
    docker compose version --short 2>/dev/null || docker-compose --version 2>/dev/null || true
}

running_containers() {
    docker ps --filter "name=phasezero-" --format '{{.Names}}' 2>/dev/null | sort
}

container_health() {
    # health: healthy | unhealthy | starting | none
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo unknown
}

health_proofs() {
    # Return JSON: {running:[], unhealthy:[], starting:[], healthy:bool}
    local -a running=() unhealthy=() starting=() health
    local c
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        running+=("$c")
        health="$(container_health "$c")"
        case "$health" in
            healthy) ;;
            unhealthy) unhealthy+=("$c") ;;
            starting) starting+=("$c") ;;
        esac
    done < <(running_containers)
    jq -cn \
        --argjson running "$(arr_json "${running[@]}")" \
        --argjson unhealthy "$(arr_json "${unhealthy[@]}")" \
        --argjson starting "$(arr_json "${starting[@]}")" \
        '{running:$running, unhealthy:$unhealthy, starting:$starting,
          healthy:((($running|length) > 0) and (($unhealthy|length) == 0) and (($starting|length) == 0))}'
}

stack_json() {
    # Pull the detailed stack view from homelab-stack (status ok/blocked).
    bash "$PZ_ROOT/linux/server/homelab-stack.sh" status --json 2>/dev/null || echo '{}'
}

active_profile() {
    if [ -f "$HOMELAB_STATE/profile.active" ]; then
        cat "$HOMELAB_STATE/profile.active" 2>/dev/null || echo null
    else
        echo null
    fi
}

resource_budget_json() {
    local prof
    prof="$(active_profile)"
    [ "$prof" != null ] || { echo null; return 0; }
    bash "$PZ_ROOT/linux/server/homelab-governor.sh" budget "$prof" 2>/dev/null || echo null
}

backup_state_json() {
    local last backup_root last_file verified=false
    backup_root="${PZ_HOMELAB_BACKUP_ROOT:-$HOMELAB_STATE/backups}"
    last_file="$backup_root/last.json"
    if [ -f "$last_file" ]; then
        last="$(cat "$last_file")"
        verified="$(printf '%s\n' "$last" | jq -r '.verified // false')"
    else
        last="null"
    fi
    local -a dirs=()
    while IFS= read -r d; do
        [ -n "$d" ] && dirs+=("$(basename "$d")")
    done < <(find "$backup_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    jq -cn --argjson last "$last" \
        --argjson backups "$(arr_json "${dirs[@]}")" \
        --argjson verified "$verified" \
        '{lastBackup:$last, backups:$backups, verified:$verified}'
}

digests_json() {
    if [ -f "$LOCK_FILE_JSON" ]; then
        if jq -e . >/dev/null 2>&1 < "$LOCK_FILE_JSON"; then
            jq -c '{schemaVersion: .schemaVersion, images: .images}' "$LOCK_FILE_JSON"
        else
            echo '{"error":"lock manifest unreadable"}'
        fi
    else
        echo 'null'
    fi
}

security_state_json() {
    # Policy broker lands in a later commit; state stays honest until then.
    local audit_file="$HOMELAB_STATE/security-audit.json"
    local last_audit=null
    [ -f "$audit_file" ] && last_audit="$(cat "$audit_file")"
    jq -cn --argjson lastAudit "$last_audit" \
        '{policyActive:false, redaction:true, lastAudit:$lastAudit}'
}

build_status() {
    local stack degraded last_op resume profile versions reason
    local -a reasons=()
    stack="$(stack_json)"
    degraded="$(pz_homelab_degraded_json)"
    last_op="$(pz_homelab_op_last_json)"
    if ! echo "$last_op" | jq -e . >/dev/null 2>&1; then
        last_op='{}'
        reasons+=("operation registry corrupted; status cannot be trusted")
    fi
    resume="$(pz_homelab_resume_info_json)"
    profile="$(active_profile)"
    versions="$(version_info)"

    local env_ok=false core_ok=false
    [ -f "$CORE_FILE" ] && core_ok=true
    [ -f "$HOMELAB_STATE/.env" ] && env_ok=true

    local installed=false configured=false active=false healthy=false ready=false degraded_flag=false
    runtime_installed && installed=true
    { [ "$core_ok" = "true" ] && [ "$env_ok" = "true" ]; } && configured=true

    local hp
    hp="$(health_proofs)"
    [ "$(echo "$hp" | jq -r '.running|length')" -gt 0 ] && active=true
    [ "$(echo "$hp" | jq -r '.healthy')" = "true" ] && healthy=true

    local degraded_flag_raw last_status
    degraded_flag_raw="$(echo "$degraded" | jq -r '.degraded')"
    [ "$degraded_flag_raw" = "true" ] && degraded_flag=true
    last_status="$(echo "$last_op" | jq -r '.status // "none"')"

    # proofs for ready:
    [ "$installed" = "true" ] || reasons+=("runtime not installed")
    [ "$configured" = "true" ] || reasons+=("homelab not configured (compose or .env missing)")
    [ "$active" = "true" ] || reasons+=("no homelab containers running")
    [ "$healthy" = "true" ] || reasons+=("containers missing or unhealthy")
    [ "$degraded_flag" = "true" ] && reasons+=("degraded state active: $(echo "$degraded" | jq -r '.reasons|join("; ")')")
    [ "$last_status" = "failed" ] && reasons+=("last operation failed")
    [ "$last_status" = "interrupted" ] && reasons+=("last operation interrupted; resume with: pz server homelab up --resume")

    if [ "${#reasons[@]}" -eq 0 ]; then
        ready=true
    fi

    local endpoints_json
    endpoints_json="$(echo "$stack" | jq -c '[.apps[]? | select(.running == true) | {key, url, bind}]' 2>/dev/null || echo '[]')"

    local access_mode access_effective
    access_mode="$(echo "$stack" | jq -r '.access.requested // "unknown"' 2>/dev/null)"
    access_effective="$(echo "$stack" | jq -r '.access.effective // "unknown"' 2>/dev/null)"

    jq -n \
        --arg schemaVersion "$SCHEMA_VERSION" \
        --arg tool "homelab-status" \
        --arg profile "$profile" \
        --argjson installed "$installed" \
        --argjson configured "$configured" \
        --argjson active "$active" \
        --argjson healthy "$healthy" \
        --argjson ready "$ready" \
        --argjson degraded "$degraded_flag" \
        --argjson reasons "$(arr_json "${reasons[@]}")" \
        --arg accessMode "$access_mode" \
        --arg accessEffective "$access_effective" \
        --argjson endpoints "$endpoints_json" \
        --argjson versions "$versions" \
        --arg dockerVer "$(docker_ver)" \
        --arg composeVer "$(compose_ver)" \
        --argjson imageDigests "$(digests_json)" \
        --argjson resourceUsage null \
        --argjson resourceBudget "$(resource_budget_json)" \
        --argjson conflicts "[]" \
        --argjson securityState "$(security_state_json)" \
        --argjson backupState "$(backup_state_json)" \
        --argjson lastOperation "$last_op" \
        --argjson rollbackAvailable "$(echo "$last_op" | jq '.rollbackAvailable // false')" \
        --argjson resume "$resume" \
        --argjson stack "$stack" \
        '{schemaVersion:$schemaVersion,
          tool:$tool,
          profile:$profile,
          installed:$installed,
          configured:$configured,
          active:$active,
          healthy:$healthy,
          ready:$ready,
          degraded:$degraded,
          reasons:$reasons,
          accessMode:{requested:$accessMode, effective:$accessEffective},
          endpoints:$endpoints,
          versions:{phasezero:$versions, docker:$dockerVer, compose:$composeVer},
          imageDigests:$imageDigests,
          resourceUsage:$resourceUsage,
          resourceBudget:$resourceBudget,
          conflicts:$conflicts,
          securityState:$securityState,
          backupState:$backupState,
          lastOperation:$lastOperation,
          rollbackAvailable:$rollbackAvailable,
          resume:$resume,
          stack:$stack}'
}

cmd_status() {
    local data
    data="$(build_status)"
    mkdir -p "$HOMELAB_STATE"
    printf '%s\n' "$data" > "$STATUS_FILE"
    chmod 0644 "$STATUS_FILE"
    printf '%s\n' "$data"
    if [ "$(echo "$data" | jq -r '.ready')" = "true" ]; then
        return 0
    else
        return 1
    fi
}

cmd_verify() {
    # Re-derive live status and compare against persisted checks.
    local live persisted mismatch=0 checks=()
    live="$(build_status)"
    if [ -f "$STATUS_FILE" ]; then
        persisted="$(cat "$STATUS_FILE" 2>/dev/null || echo '{}')"
        local lr pr
        lr="$(echo "$live" | jq -r '.ready')"
        pr="$(echo "$persisted" | jq -r 'if has("ready") then .ready else "unknown" end')"
        [ "$lr" = "$pr" ] || { mismatch=1; checks+=("ready mismatch: live=$lr persisted=$pr"); }
    else
        mismatch=1
        checks+=("no persisted status.json yet")
    fi
    echo "$live" | jq -e '.schemaVersion == "1"' >/dev/null 2>&1 || { mismatch=1; checks+=("schemaVersion invalid"); }
    local last_status
    last_status="$(echo "$live" | jq -r '.lastOperation.status // "none"')"
    case "$last_status" in
        succeeded|interrupted|cancelled|failed|none) ;;
        *) mismatch=1; checks+=("lastOperation in unexpected state: $last_status") ;;
    esac
    local checks_json
    if [ "${#checks[@]}" -gt 0 ]; then
        checks_json="$(printf '%s\n' "${checks[@]}" | jq -R . | jq -cs .)"
    else
        checks_json="[]"
    fi
    jq -n \
        --argjson verified "$([ "$mismatch" -eq 0 ] && echo true || echo false)" \
        --argjson checks "$checks_json" \
        --argjson status "$live" \
        '{tool:"homelab-status", action:"verify", schemaVersion:"1", verified:$verified, checks:$checks, status:$status}'
    [ "$mismatch" -eq 0 ] && return 0 || return 1
}

cmd_repair() {
    # Regenerate missing .env secrets and validate compose; clear stale degraded
    # marker only when proofs recovered.
    local -a stack_args=(--access local)
    [ "${#HL_ARGS[@]}" -gt 0 ] && stack_args=("${HL_ARGS[@]}")
    local before after
    before="$(build_status)"
    bash "$PZ_ROOT/linux/server/homelab-stack.sh" repair "${stack_args[@]}" >/dev/null 2>&1 || true
    after="$(build_status)"
    jq -n --argjson before "$before" --argjson after "$after" \
        '{tool:"homelab-status", action:"repair", schemaVersion:"1", before:$before, after:$after}'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$cmd" in
        status) cmd_status ;;
        verify) cmd_verify ;;
        repair) cmd_repair ;;
        *) echo "usage: homelab-status.sh (status|verify|repair) [--json]" >&2; exit 2 ;;
    esac
fi