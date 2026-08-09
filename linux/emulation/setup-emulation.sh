#!/usr/bin/env bash
# setup-emulation.sh - install PhaseZero Linux emulation stack
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-install}"

case "$ACTION" in
    install)
        bash "$PZ_ROOT/linux/emulation/lua.sh" install
        pz_emulation_ensure_layout
        bash "$PZ_ROOT/linux/emulation/emudeck.sh" install
        bash "$PZ_ROOT/linux/emulation/eden.sh" install
        bash "$PZ_ROOT/linux/emulation/eden.sh" integrate
        bash "$PZ_ROOT/linux/emulation/citron.sh" install
        bash "$PZ_ROOT/linux/emulation/citron.sh" integrate
        bash "$PZ_ROOT/linux/emulation/hydra.sh" install
        bash "$PZ_ROOT/linux/emulation/srm.sh" configure --skip-if-configured
        bash "$PZ_ROOT/linux/emulation/sony.sh" ps1 configure
        bash "$PZ_ROOT/linux/emulation/sony.sh" ps2 configure
        bash "$PZ_ROOT/linux/emulation/ps3.sh" configure
        bash "$PZ_ROOT/linux/emulation/performance.sh" apply
        bash "$PZ_ROOT/linux/emulation/steam-tools.sh" status
        bash "$PZ_ROOT/linux/emulation/nsz.sh" install
        bash "$PZ_ROOT/linux/emulation/retrodeck.sh" integrate
        bash "$PZ_ROOT/linux/emulation/pc-games.sh" repair
        bash "$PZ_ROOT/linux/emulation/shortcuts.sh" repair
        bash "$PZ_ROOT/linux/emulation/launchbox.sh" integrate
        bash "$PZ_ROOT/linux/emulation/frontends.sh" repair
        bash "$PZ_ROOT/linux/emulation/optimizers.sh" apply-all
        bash "$PZ_ROOT/linux/emulation/heroic.sh" repair
        bash "$PZ_ROOT/linux/emulation/bios.sh" status
        ;;
    dry-run|plan)
        pz_emulation_layout_dirs
        bash "$PZ_ROOT/linux/emulation/lua.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/emudeck.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/eden.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/citron.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/hydra.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/srm.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/sony.sh" ps1 dry-run
        bash "$PZ_ROOT/linux/emulation/sony.sh" ps2 dry-run
        bash "$PZ_ROOT/linux/emulation/ps3.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/performance.sh" plan
        bash "$PZ_ROOT/linux/emulation/steam-tools.sh" dry-run
        bash "$PZ_ROOT/linux/emulation/nsz.sh" plan
        bash "$PZ_ROOT/linux/emulation/retrodeck.sh" plan
        bash "$PZ_ROOT/linux/emulation/pc-games.sh" plan
        bash "$PZ_ROOT/linux/emulation/shortcuts.sh" plan
        bash "$PZ_ROOT/linux/emulation/launchbox.sh" plan
        bash "$PZ_ROOT/linux/emulation/frontends.sh" plan
        bash "$PZ_ROOT/linux/emulation/optimizers.sh" plan
        bash "$PZ_ROOT/linux/emulation/heroic.sh" plan
        ;;
    status)
        bash "$PZ_ROOT/linux/emulation/bios.sh" status
        ;;
    *)
        pz_error "usage: setup-emulation.sh (install|dry-run|status)"
        exit 1
        ;;
esac
