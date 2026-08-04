#!/usr/bin/env bash
# homelab-operations.sh - atomic lifecycle primitives for the Homelab appliance.
#
# Provides:
#   - Cross-process operation lock (flock on $HOMELAB_STATE/homelab.lock).
#   - Operation registry: $HOMELAB_STATE/operations/<op-id>.json, versioned.
#   - Resume after crash/interruption, safe cancel, idempotent re-entry.
#   - Persisted degraded state ($HOMELAB_STATE/degraded.json).
#
# Sourcable from other homelab scripts; also runs standalone for the CLI.
# NOTE: the lock only survives while held by the owning shell process. Long
# operations must `source` this file and call pz_homelab_lock directly.
# Usage (standalone):
#   homelab-operations.sh lock [--wait N]      (self-test only)
#   homelab-operations.sh unlock
#   homelab-operations.sh start <action> [key=value ...]
#   homelab-operations.sh step <op-id> <step>
#   homelab-operations.sh finish <op-id> <status> [--rollback-available]
#   homelab-operations.sh abort <op-id> [<status>]
#   homelab-operations.sh list [--json]
#   homelab-operations.sh last [--json]
#   homelab-operations.sh resume-info [--json]
#   homelab-operations.sh mark-degraded <reason>
#   homelab-operations.sh clear-degraded
#   homelab-operations.sh degraded [--json]
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

HOMELAB_STATE="${PZ_HOMELAB_STATE:-$PZ_STATE/homelab}"
OP_DIR="${PZ_HOMELAB_OP_DIR:-$HOMELAB_STATE/operations}"
LOCK_FILE="${PZ_HOMELAB_LOCK_FILE:-$HOMELAB_STATE/homelab.lock}"
DEGRADED_FILE="$HOMELAB_STATE/degraded.json"

mkdir -p "$OP_DIR"

# --- lock/unlock --------------------------------------------------------------
# fd 9 is reserved for the flock. Callers that source this file must not close it.
PZ_HOMELAB_LOCK_FD=9

pz_homelab_lock() {
    local wait="${1:-10}"
    if ! mkdir -p "$HOMELAB_STATE" 2>/dev/null; then
        pz_error "homelab state dir not writable: $HOMELAB_STATE"
        return 1
    fi
    if ! exec "$PZ_HOMELAB_LOCK_FD>" "$LOCK_FILE" 2>/dev/null; then
        pz_error "cannot open homelab lock file: $LOCK_FILE"
        return 1
    fi
    if ! flock -w "$wait" "$PZ_HOMELAB_LOCK_FD" 2>/dev/null; then
        pz_error "another homelab operation is running (lock: $LOCK_FILE)"
        return 1
    fi
    return 0
}

pz_homelab_unlock() {
    flock -u "$PZ_HOMELAB_LOCK_FD" 2>/dev/null || true
}

# --- operation registry -------------------------------------------------------
pz_homelab_op_new_id() {
    printf '%s-%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$RANDOM"
}

# pz_homelab_op_start <action> [key=value ...]
pz_homelab_op_start() {
    local action="${1:?action required}"
    shift
    local op_id now extra='{}' kv k v
    op_id="$(pz_homelab_op_new_id)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        extra="$(jq -cn --argjson e "$extra" --arg k "$k" --arg v "$v" '$e + {($k):$v}')"
    done
    jq -n --arg a "$action" --arg id "$op_id" --arg t "$now" --argjson pid "$$" --argjson extra "$extra" \
        '{schemaVersion:1, operationId:$id, action:$a, status:"running", step:"init",
          startedAt:$t, updatedAt:$t, attempts:1, rollbackAvailable:false, pid:$pid}
         + $extra' > "$OP_DIR/$op_id.json"
    printf '%s\n' "$op_id"
}

# pz_homelab_op_step <op-id> <step>
pz_homelab_op_step() {
    local op="${1:?op-id required}" step="${2:?step required}" now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local tmp="$OP_DIR/$op.json.tmp"
    jq --arg s "$step" --arg t "$now" '. + {status:"running", step:$s, updatedAt:$t}' \
        "$OP_DIR/$op.json" > "$tmp" 2>/dev/null || return 1
    mv "$tmp" "$OP_DIR/$op.json"
}

# pz_homelab_op_finish <op-id> <status> [--rollback-available]
pz_homelab_op_finish() {
    local op="${1:?op-id required}" status="${2:?status required}" now rb=false tmp
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$status" in
        succeeded|failed|interrupted|cancelled) ;;
        *) pz_error "invalid terminal status: $status"; return 2 ;;
    esac
    for a in "$@"; do [ "$a" = "--rollback-available" ] && rb=true; done
    tmp="$OP_DIR/$op.json.tmp"
    jq --arg s "$status" --arg t "$now" --argjson rb "$rb" \
        '. + {status:$s, updatedAt:$t, completedAt:$t, rollbackAvailable:$rb}' \
        "$OP_DIR/$op.json" > "$tmp" 2>/dev/null || return 1
    mv "$tmp" "$OP_DIR/$op.json"
}

# pz_homelab_op_abort <op-id> [status] -- records interruption (trap path)
pz_homelab_op_abort() {
    pz_homelab_op_finish "$1" "${2:-interrupted}"
}

pz_homelab_op_newest_file() {
    find "$OP_DIR" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-
}

pz_homelab_op_last_json() {
    local f
    f="$(pz_homelab_op_newest_file)"
    if [ -n "$f" ]; then
        cat "$f"
    else
        echo '{}'
    fi
}

pz_homelab_resume_info_json() {
    local f
    f="$(find "$OP_DIR" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)" || true
    if [ -n "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
        jq -c 'if .status == "running" or .status == "interrupted" then
                  {resumable:true, operationId:.operationId, action:.action, lastStep:.step,
                   resumed:true, startedAt:.startedAt}
                else {resumable:false, operationId:.operationId, action:.action,
                      status:.status, resumed:false} end' "$f" 2>/dev/null || echo '{"resumable":false, "resumed":false}'
    else
        echo '{"resumable":false, "resumed":false}'
    fi
}

# --- degraded state -----------------------------------------------------------
pz_homelab_mark_degraded() {
    local reason="${1:?reason required}" now prev='[]'
    mkdir -p "$HOMELAB_STATE"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -f "$DEGRADED_FILE" ] && prev="$(jq -c '.reasons' "$DEGRADED_FILE" 2>/dev/null || echo '[]')"
    jq -n --arg r "$reason" --arg t "$now" --argjson prev "$prev" \
        '{reasons: (($prev + [{reason:$r, at:$t}]) | unique_by(.reason)), updatedAt:$t}' \
        > "$DEGRADED_FILE"
    chmod 0600 "$DEGRADED_FILE"
}

pz_homelab_clear_degraded() {
    rm -f "$DEGRADED_FILE"
}

pz_homelab_degraded_json() {
    if [ -f "$DEGRADED_FILE" ]; then
        jq -c '{degraded:true, reasons:(.reasons|map(.reason)), updatedAt}' "$DEGRADED_FILE" 2>/dev/null \
            || echo '{"degraded":true,"reasons":["unreadable degraded state"],"updatedAt":null}'
    else
        echo '{"degraded":false,"reasons":[],"updatedAt":null}'
    fi
}

# --- CLI main (only when executed directly, never when sourced) ---------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift 2>/dev/null || true
    case "$cmd" in
        lock)
            [ "${PZ_HOMELAB_SO_LOCK:-0}" = "1" ] && pz_homelab_lock
            ;;
        unlock) pz_homelab_unlock ;;
        start) pz_homelab_op_start "$@" ;;
        step) pz_homelab_op_step "$@" ;;
        finish) pz_homelab_op_finish "$@" ;;
        abort) pz_homelab_op_abort "$@" ;;
        list)
            if printf '%s' "${1:-}" | grep -q -- --json; then
                find "$OP_DIR" -maxdepth 1 -name '*.json' -print0 2>/dev/null \
                    | xargs -0 -r jq -c . | jq -s .
            else
                find "$OP_DIR" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//'
            fi
            ;;
        last) pz_homelab_op_last_json ;;
        resume-info) pz_homelab_resume_info_json ;;
        mark-degraded) pz_homelab_mark_degraded "${1:?reason required}" ;;
        clear-degraded) pz_homelab_clear_degraded ;;
        degraded) pz_homelab_degraded_json ;;
        *)
            echo "usage: homelab-operations.sh (lock|unlock|start|step|finish|abort|list|last|resume-info|mark-degraded|clear-degraded|degraded)" >&2
            exit 2
            ;;
    esac
fi