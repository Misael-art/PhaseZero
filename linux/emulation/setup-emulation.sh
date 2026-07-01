#!/usr/bin/env bash
# setup-emulation.sh - install PhaseZero Linux emulation stack
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-install}"

case "$ACTION" in
    install)
        pz_emulation_ensure_layout
        bash "$PZ_ROOT/linux/emulation/emudeck.sh" install
        bash "$PZ_ROOT/linux/emulation/eden.sh" install
        bash "$PZ_ROOT/linux/emulation/citron.sh" install
        bash "$PZ_ROOT/linux/emulation/hydra.sh" install
        bash "$PZ_ROOT/linux/emulation/bios.sh" status
        ;;
    dry-run|plan)
        pz_emulation_layout_dirs
        bash "$PZ_ROOT/linux/emulation/emudeck.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/eden.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/citron.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/hydra.sh" dry-run
        ;;
    status)
        bash "$PZ_ROOT/linux/emulation/bios.sh" status
        ;;
    *)
        pz_error "usage: setup-emulation.sh (install|dry-run|status)"
        exit 1
        ;;
esac
