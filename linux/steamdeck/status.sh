#!/usr/bin/env bash
# status.sh - concise Steam Deck UX status
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/steamdeck/common.sh"
source "$PZ_ROOT/linux/steamdeck/display-session.sh"

json_escape() {
    jq -Rsa .
}

cmd_path() {
    command -v "$1" 2>/dev/null || true
}

bool_cmd() {
    command -v "$1" >/dev/null 2>&1 && echo true || echo false
}

bool_file() {
    [ -e "$1" ] && echo true || echo false
}

mode="$(steamdeck_detect_mode)"
watcher_active=false
systemctl --user is-active phasezero-steamdeck-mode-watcher.service >/dev/null 2>&1 && watcher_active=true

kde_hotkeys=false
if command -v qdbus6 >/dev/null 2>&1 && qdbus6 org.kde.kglobalaccel 2>/dev/null | grep -q 'phasezero_.*_desktop'; then
    kde_hotkeys=true
fi

helper="/usr/local/lib/phasezero/steamdeck-privileged-control"
helper_installed=false
[ -x "$helper" ] && helper_installed=true
steam_plus_fallback="${XDG_CONFIG_HOME:-$HOME/.config}/gamescope-session-plus/sessions.d/steam-plus"

sudoers_active=false
if [ "$helper_installed" = true ] && command -v sudo >/dev/null 2>&1 && sudo -n "$helper" status >/dev/null 2>&1; then
    sudoers_active=true
fi

decky_plugins_json="$(bash "$PZ_ROOT/linux/steamdeck/plugins.sh" status 2>/dev/null || echo '{}')"
virtual_keyboard_json="$(bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" status 2>/dev/null || echo '{}')"
boot_status_text="$(bash "$PZ_ROOT/linux/steamdeck/install-steamos-boot.sh" status 2>/dev/null || true)"
boot_grub_entry="$(awk -F': ' '$1 == "grub_cfg_entry" {print $2; exit}' <<< "$boot_status_text")"
boot_next_entry="$(awk -F': ' '$1 == "grub_next_entry" {print $2; exit}' <<< "$boot_status_text")"
boot_direct_note="$(awk -F': ' '$1 == "deck_grub_input" {print $2; exit}' <<< "$boot_status_text")"

display_profile="$(pz_display_profile || echo unknown)"
display_ext="$(pz_display_external_connectors_csv || true)"
_session_vars="$(pz_display_resolved_session_vars 2>/dev/null || true)"
screen_w="$(printf '%s\n' "$_session_vars" | sed -n '1p')"; [ -n "$screen_w" ] || screen_w=1280
screen_h="$(printf '%s\n' "$_session_vars" | sed -n '2p')"; [ -n "$screen_h" ] || screen_h=800
screen_conn="$(printf '%s\n' "$_session_vars" | sed -n '3p')"; [ -n "$screen_conn" ] || screen_conn='*,eDP-1'

jq -n \
    --arg mode "$mode" \
    --arg steam "$(cmd_path steam)" \
    --arg gamescope "$(cmd_path gamescope)" \
    --arg opengamepadui "$(cmd_path opengamepadui)" \
    --arg mangohud "$(cmd_path mangohud)" \
    --arg gamemode "$(cmd_path gamemoderun)" \
    --arg ryzenadj "$(cmd_path ryzenadj)" \
    --arg bootGrubEntry "${boot_grub_entry:-unknown}" \
    --arg bootNextEntry "${boot_next_entry:-none}" \
    --arg bootDirectNote "${boot_direct_note:-unknown}" \
    --argjson watcherActive "$watcher_active" \
    --argjson kdeHotkeys "$kde_hotkeys" \
    --argjson helperInstalled "$helper_installed" \
    --argjson sudoersActive "$sudoers_active" \
    --argjson steamPlusFallback "$([ -f "$steam_plus_fallback" ] && echo true || echo false)" \
    --argjson virtualKeyboard "$virtual_keyboard_json" \
    --argjson deckyPlugins "$decky_plugins_json" \
    --arg displayProfile "$display_profile" \
    --arg displayExternal "$display_ext" \
    --arg screenW "$screen_w" \
    --arg screenH "$screen_h" \
    --arg screenConn "$screen_conn" \
    '{
        mode: $mode,
        tools: {
            steam: $steam,
            gamescope: $gamescope,
            opengamepadui: $opengamepadui,
            mangohud: $mangohud,
            gamemode: $gamemode,
            ryzenadj: $ryzenadj
        },
        automation: {
            watcherActive: $watcherActive,
            kdeHotkeys: $kdeHotkeys,
            privilegedHelperInstalled: $helperInstalled,
            privilegedSudoersActive: $sudoersActive,
            steamPlusFallback: $steamPlusFallback
        },
        virtualKeyboard: $virtualKeyboard,
        boot: {
            grubCfgEntry: $bootGrubEntry,
            nextEntry: $bootNextEntry,
            deckGrubInput: $bootDirectNote
        },
        display: {
            profile: $displayProfile,
            externalConnectors: $displayExternal,
            screenWidth: $screenW,
            screenHeight: $screenH,
            outputConnector: $screenConn
        },
        plugins: $deckyPlugins
    }'
