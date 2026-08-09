#!/usr/bin/env bash
# steam-tools.sh - Steam helper tool readiness
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
STEAM_ROOT="${STEAM_ROOT:-$HOME/.local/share/Steam}"

cmd_path() { command -v "$1" 2>/dev/null || true; }
flatpak_has() { flatpak info "$1" >/dev/null 2>&1 && echo true || echo false; }
first_appimage_match() {
    local pattern="$1"
    { find "$PZ_APPLICATIONS_DIR" "$PZ_EMULATION_ROOT/tools" "${PZ_APPIMAGE_DIR:-$HOME/Appimage}" -maxdepth 2 -iname "$pattern" -type f 2>/dev/null || true; } | head -1
}

status_tools() {
    local shortcuts_count compatibility_count steam_rom_manager_appimage boilr_appimage
    shortcuts_count="$({ find "$STEAM_ROOT/userdata" -maxdepth 3 -name shortcuts.vdf 2>/dev/null || true; } | wc -l | tr -d ' ')"
    compatibility_count="$({ find "$STEAM_ROOT/compatibilitytools.d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true; } | wc -l | tr -d ' ')"
    steam_rom_manager_appimage="$(first_appimage_match '*steam*rom*manager*.AppImage')"
    boilr_appimage="$(first_appimage_match '*boilr*.AppImage')"
    jq -n \
        --arg steam "$(cmd_path steam)" \
        --arg steamRoot "$STEAM_ROOT" \
        --arg protontricks "$(cmd_path protontricks)" \
        --arg protonupQt "$(cmd_path protonup-qt)" \
        --arg steamtinkerlaunch "$(cmd_path steamtinkerlaunch)" \
        --arg ludusavi "$(cmd_path ludusavi)" \
        --arg retroarch "$(cmd_path retroarch)" \
        --arg boilr "$(cmd_path boilr)" \
        --arg boilrAppImage "$boilr_appimage" \
        --arg steamRomManager "$(cmd_path steam-rom-manager)" \
        --arg steamRomManagerAppImage "$steam_rom_manager_appimage" \
        --arg steamRomManagerLauncher "$PZ_EMULATION_ROOT/tools/launchers/srm/steamrommanager.sh" \
        --argjson retroarchFlatpak "$(flatpak_has org.libretro.RetroArch)" \
        --argjson ludusaviFlatpak "$(flatpak_has com.github.mtkennerly.ludusavi)" \
        --argjson shortcutsCount "$shortcuts_count" \
        --argjson compatibilityToolsCount "$compatibility_count" \
        --argjson steamRomManagerLauncherInstalled "$([ -f "$PZ_EMULATION_ROOT/tools/launchers/srm/steamrommanager.sh" ] && echo true || echo false)" \
        '{steam: $steam, steamRoot: $steamRoot, shortcutsCount: $shortcutsCount, compatibilityToolsCount: $compatibilityToolsCount, tools: {protontricks: $protontricks, protonupQt: $protonupQt, steamtinkerlaunch: $steamtinkerlaunch, ludusavi: $ludusavi, ludusaviFlatpak: $ludusaviFlatpak, retroarch: $retroarch, retroarchFlatpak: $retroarchFlatpak, boilr: $boilr, boilrAppImage: $boilrAppImage, steamRomManager: $steamRomManager, steamRomManagerAppImage: $steamRomManagerAppImage, steamRomManagerLauncher: $steamRomManagerLauncher, steamRomManagerLauncherInstalled: $steamRomManagerLauncherInstalled}}'
}

dry_run_tools() {
    cat <<'EOF'
Steam tools dry-run
  pacman core: sudo pacman -S --needed protontricks protonup-qt retroarch
  optional: Ludusavi, BoilR, Steam ROM Manager, SteamTinkerLaunch
  flatpak optional: com.github.mtkennerly.ludusavi org.libretro.RetroArch
EOF
}

install_tools() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        dry_run_tools
        return 0
    fi
    if pz_can_sudo_noninteractive; then
        sudo -n pacman -S --needed --noconfirm protontricks protonup-qt retroarch
    else
        pz_warn "sudo password required; run: sudo pacman -S --needed protontricks protonup-qt retroarch"
    fi
}

case "$ACTION" in
    status) status_tools ;;
    dry-run|plan) dry_run_tools ;;
    install) install_tools ;;
    *) pz_error "usage: steam-tools.sh (status|dry-run|install)"; exit 1 ;;
esac
