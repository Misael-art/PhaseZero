#!/usr/bin/env bash
# retrodeck.sh - friendly RetroDECK ecosystem integration orchestrator
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
shift || true

print_identity() {
    local version="unknown"
    pz_retrodeck_manifest_valid && version="$(jq -r '.version // "unknown"' "$PZ_RETRODECK_MANIFEST")"
    echo "=== RetroDECK Ecosystem ==="
    echo "  version: $version"
    echo "  manifest: $PZ_RETRODECK_MANIFEST"
    echo "  data root: $(pz_retrodeck_root)"
    echo "  canonical root: $PZ_EMULATION_ROOT"
}

case "$ACTION" in
    status)
        print_identity
        rc=0
        bash "$PZ_ROOT/linux/emulation/shared-content.sh" status "$@" || rc=1
        bash "$PZ_ROOT/linux/emulation/media.sh" status "$@" || rc=1
        exit "$rc"
        ;;
    plan|dry-run)
        print_identity
        bash "$PZ_ROOT/linux/emulation/shared-content.sh" plan "$@"
        bash "$PZ_ROOT/linux/emulation/media.sh" plan "$@"
        ;;
    integrate|apply|setup)
        print_identity
        bash "$PZ_ROOT/linux/emulation/shared-content.sh" apply "$@"
        bash "$PZ_ROOT/linux/emulation/media.sh" apply "$@"
        pz_info "RetroDECK now shares PhaseZero ROMs, BIOS, saves, states, media and assets"
        ;;
    repair)
        print_identity
        bash "$PZ_ROOT/linux/emulation/shared-content.sh" repair "$@"
        bash "$PZ_ROOT/linux/emulation/media.sh" repair "$@"
        pz_info "RetroDECK ecosystem links repaired"
        ;;
    *)
        pz_error "usage: retrodeck.sh (status|plan|integrate|repair)"
        exit 1
        ;;
esac
