#!/usr/bin/env bash
# fixes.sh - friendly non-destructive emulation repair catalog
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-list}"

list_fixes() {
    jq -n '[
        {id:"hydra-missing-appimage", priority:"medium", safeAction:"linux/pz emulation hydra install", destructive:false},
        {id:"hydra-classic-config", priority:"medium", safeAction:"linux/pz emulation hydra classic-config", destructive:false},
        {id:"hydra-steam-shortcut", priority:"medium", safeAction:"linux/pz emulation hydra steam-shortcut", destructive:false},
        {id:"steam-rom-manager-paths", priority:"medium", safeAction:"linux/pz emulation srm configure", destructive:false},
        {id:"ps3-rpcs3-paths", priority:"medium", safeAction:"linux/pz emulation ps3 configure", destructive:false},
        {id:"emulator-performance-profiles", priority:"medium", safeAction:"linux/pz emulation performance apply", destructive:false},
        {id:"lsfg-vulkan-layer", priority:"medium", safeAction:"linux/pz emulation performance prepare-lsfg", destructive:false},
        {id:"emudeck-eden-integration", priority:"low", safeAction:"linux/pz emulation eden integrate", destructive:false},
        {id:"emudeck-citron-integration", priority:"low", safeAction:"linux/pz emulation citron integrate", destructive:false},
        {id:"switch-keys-local-import", priority:"low", safeAction:"linux/pz emulation switch import-keys <owned-dump-path>", destructive:false},
        {id:"switch-firmware-local-import", priority:"low", safeAction:"linux/pz emulation switch import-firmware <owned-dump-path>", destructive:false},
        {id:"lua-luarocks-missing", priority:"low", safeAction:"linux/pz emulation lua install", destructive:false},
        {id:"steam-tools-missing", priority:"low", safeAction:"linux/pz emulation steam-tools dry-run", destructive:false},
        {id:"pc-games-frontends-unconfigured", priority:"high", safeAction:"linux/pz emulation pc-games repair", destructive:false},
        {id:"retrodeck-content-isolated", priority:"high", safeAction:"linux/pz emulation retrodeck integrate", destructive:false}
    ]'
}

apply_safe() {
    bash "$PZ_ROOT/linux/emulation/lua.sh" install || true
    bash "$PZ_ROOT/linux/emulation/steam-tools.sh" install || true
    bash "$PZ_ROOT/linux/emulation/hydra.sh" configure
    bash "$PZ_ROOT/linux/emulation/srm.sh" configure || true
    bash "$PZ_ROOT/linux/emulation/ps3.sh" configure || true
    bash "$PZ_ROOT/linux/emulation/performance.sh" apply || true
    bash "$PZ_ROOT/linux/emulation/hydra.sh" steam-shortcut || true
    bash "$PZ_ROOT/linux/emulation/eden.sh" integrate || true
    bash "$PZ_ROOT/linux/emulation/citron.sh" integrate || true
    bash "$PZ_ROOT/linux/emulation/retrodeck.sh" integrate || true
    bash "$PZ_ROOT/linux/emulation/pc-games.sh" repair || true
    bash "$PZ_ROOT/linux/emulation/bios.sh" status
}

case "$ACTION" in
    list|status) list_fixes ;;
    apply-safe) apply_safe ;;
    *) pz_error "usage: fixes.sh (list|apply-safe)"; exit 1 ;;
esac
