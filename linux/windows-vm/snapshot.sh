#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

SNAPSHOT_DIR="${SNAPSHOT_DIR:-${PZ_STATE}/windows-vm/snapshots}"

snapshot_create() {
    local name="" disk_path="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name="${2:-}"; shift 2 ;;
            --name=*) name="${1#*=}"; shift ;;
            --disk) disk_path="${2:-}"; shift 2 ;;
            --disk=*) disk_path="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown snapshot option: $1"; return 1 ;;
        esac
    done

    [ -n "$name" ] || { pz_error "--name required"; return 1; }
    [ -f "$disk_path" ] || { pz_error "disk not found: $disk_path"; return 1; }

    mkdir -p "$SNAPSHOT_DIR"
    chmod 0700 "$SNAPSHOT_DIR"

    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local snapshot_name="${name}-${timestamp}"
    local snapshot_path="$SNAPSHOT_DIR/$snapshot_name.qcow2"
    local metadata_path="$SNAPSHOT_DIR/$snapshot_name.json"

    local disk_size sha256
    disk_size="$(stat -c%s "$disk_path" 2>/dev/null || echo 0)"
    sha256="$(sha256sum "$disk_path" | cut -d' ' -f1)"

    jq -n \
        --arg name "$snapshot_name" \
        --arg source "$disk_path" \
        --arg created "$timestamp" \
        --arg sha256 "$sha256" \
        --argjson size "$disk_size" \
        '{
            snapshot: $name,
            source: $source,
            created: $created,
            sha256: $sha256,
            size: $size,
            verified: false,
            profile: "performance-safe"
        }' > "$metadata_path"
    chmod 0600 "$metadata_path"

    qemu-img create -f qcow2 -b "$disk_path" -F qcow2 "$snapshot_path" >/dev/null

    if [ "$json" = "1" ]; then
        jq -n \
            --arg path "$snapshot_path" \
            --arg name "$snapshot_name" \
            --arg metadata "$metadata_path" \
            '{path: $path, name: $name, metadata: $metadata, created: true}'
    else
        pz_info "snapshot created: $snapshot_path"
    fi
}

snapshot_verify() {
    local path="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --path) path="${2:-}"; shift 2 ;;
            --path=*) path="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown snapshot verify option: $1"; return 1 ;;
        esac
    done

    [ -f "$path" ] || { pz_error "snapshot not found: $path"; return 1; }

    local metadata_path="${path%.qcow2}.json"
    local valid=1 issues=()

    if [ ! -f "$metadata_path" ]; then
        valid=0
        issues+=("metadata missing")
    fi

    if ! qemu-img check "$path" >/dev/null 2>&1; then
        valid=0
        issues+=("qemu-img check failed")
    fi

    local backing_file
    backing_file="$(qemu-img info "$path" 2>/dev/null | grep 'backing file:' | sed 's/.*backing file: //' || true)"
    if [ -n "$backing_file" ] && [ ! -f "$backing_file" ]; then
        valid=0
        issues+=("backing file missing: $backing_file")
    fi

    if [ "$json" = "1" ]; then
        jq -n \
            --arg path "$path" \
            --argjson valid "$valid" \
            --argjson issues "$(jq -n --arg v "$(IFS=,; echo "${issues[*]}")" '$v | split(",")')" \
            '{path: $path, valid: ($valid == 1), issues: $issues}'
    else
        if [ "$valid" = "1" ]; then
            pz_info "snapshot verified: $path"
        else
            pz_warn "snapshot has issues: ${issues[*]}"
        fi
    fi
    return $((1 - valid))
}

snapshot_list() {
    local json=0
    while [ $# -gt 0 ]; do
        case "$1" in --json) json=1; shift ;; *) shift ;; esac
    done

    mkdir -p "$SNAPSHOT_DIR"
    local snapshots=()
    for f in "$SNAPSHOT_DIR"/*.qcow2; do
        [ -f "$f" ] || continue
        local meta="${f%.qcow2}.json"
        local info
        if [ -f "$meta" ]; then
            info="$(cat "$meta")"
        else
            info="$(jq -n --arg name "$(basename "$f" .qcow2)" '{snapshot: $name, verified: false}')"
        fi
        snapshots+=("$info")
    done

    local sep=""
    echo -n "["
    for s in "${snapshots[@]}"; do echo -n "$sep$s"; sep=","; done
    echo "]"
}

case "${1:-list}" in
    create) shift; snapshot_create "$@" ;;
    verify) shift; snapshot_verify "$@" ;;
    list) shift; snapshot_list "$@" ;;
    *) echo "usage: snapshot (create|verify|list) [options]"; exit 1 ;;
esac
