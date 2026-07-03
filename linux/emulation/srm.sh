#!/usr/bin/env bash
# srm.sh - configure Steam ROM Manager paths and emulator parsers
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
STEAM_ROOT="${STEAM_ROOT:-$HOME/.local/share/Steam}"
SRM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-rom-manager"
SRM_USERDATA="$SRM_CONFIG_DIR/userData"
SRM_SETTINGS="$SRM_USERDATA/userSettings.json"
SRM_CONFIGS="$SRM_USERDATA/userConfigurations.json"
EMUDECK_SRM_USERDATA="$HOME/.config/EmuDeck/backend/configs/steam-rom-manager/userData"
PZ_APPIMAGE_DIR="${PZ_APPIMAGE_DIR:-$HOME/Appimage}"
SRM_WRAPPER="$PZ_LOCAL_BIN/phasezero-srm"
SRM_DESKTOP="$PZ_DESKTOP_DIR/phasezero-steam-rom-manager.desktop"
SRM_STATE="$PZ_EMULATION_STATE/srm.json"
PZ_SCAN_SAFE_SWITCH="$PZ_EMULATION_ROOT/.phasezero/scan-safe/roms/switch"

first_existing_file() {
    local candidate
    for candidate in "$@"; do
        [ -f "$candidate" ] && { echo "$candidate"; return 0; }
    done
    return 1
}

first_existing_executable() {
    local candidate
    for candidate in "$@"; do
        [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done
    return 1
}

find_srm_appimage() {
    local found
    found="$(first_existing_file \
        "$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage" \
        "$PZ_EMULATION_ROOT/tools/Steam ROM Manager.AppImage" \
        "$PZ_EMULATION_ROOT/tools/srm/Steam-ROM-Manager.AppImage" \
        "$PZ_APPLICATIONS_DIR/Steam-ROM-Manager.AppImage" \
        "$PZ_APPLICATIONS_DIR/Steam ROM Manager.AppImage" \
        "$PZ_APPIMAGE_DIR/Steam-ROM-Manager.AppImage" \
        "$PZ_APPIMAGE_DIR/Steam ROM Manager.AppImage" 2>/dev/null || true)"
    [ -n "$found" ] && { echo "$found"; return 0; }
    { find "$PZ_EMULATION_ROOT/tools" "$PZ_APPLICATIONS_DIR" "$PZ_APPIMAGE_DIR" -maxdepth 2 -iname '*Steam*ROM*Manager*.AppImage' -type f 2>/dev/null || true; } | head -1
}

find_srm_launcher() {
    first_existing_file \
        "$PZ_EMULATION_ROOT/tools/launchers/srm/steamrommanager.sh" \
        "$HOME/.config/EmuDeck/backend/tools/launchers/srm/steamrommanager.sh" 2>/dev/null || true
}

retroarch_launcher() {
    first_existing_executable "$PZ_EMULATION_ROOT/tools/launchers/retroarch.sh" 2>/dev/null ||
        command -v retroarch 2>/dev/null ||
        true
}

ensure_srm_settings() {
    install -d "$SRM_USERDATA"
    if [ -f "$SRM_SETTINGS" ] && jq empty "$SRM_SETTINGS" >/dev/null 2>&1; then
        return 0
    fi
    if [ -f "$EMUDECK_SRM_USERDATA/userSettings.json" ] && jq empty "$EMUDECK_SRM_USERDATA/userSettings.json" >/dev/null 2>&1; then
        cp "$EMUDECK_SRM_USERDATA/userSettings.json" "$SRM_SETTINGS"
        return 0
    fi
    jq -n '{
        environmentVariables: {
            steamDirectory: "",
            romsDirectory: "",
            retroarchPath: "",
            raCoresDirectory: "",
            localImagesDirectory: "",
            userAccounts: []
        },
        previewSettings: {
            retrieveCurrentSteamImages: true,
            disableCategories: false,
            deleteDisabledShortcuts: false
        },
        enabledProviders: ["sgdb"],
        language: "en-US",
        offlineMode: false,
        theme: "EmuDeck",
        autoKillSteam: true,
        autoRestartSteam: true,
        version: 10
    }' > "$SRM_SETTINGS"
}

ensure_srm_configurations() {
    install -d "$SRM_USERDATA"
    if [ -f "$SRM_CONFIGS" ] && jq empty "$SRM_CONFIGS" >/dev/null 2>&1; then
        return 0
    fi
    if [ -f "$EMUDECK_SRM_USERDATA/userConfigurations.json" ] && jq empty "$EMUDECK_SRM_USERDATA/userConfigurations.json" >/dev/null 2>&1; then
        cp "$EMUDECK_SRM_USERDATA/userConfigurations.json" "$SRM_CONFIGS"
        return 0
    fi
    printf '[]\n' > "$SRM_CONFIGS"
}

append_template_parser_by_title() {
    local title="$1" tmp
    [ -f "$EMUDECK_SRM_USERDATA/userConfigurations.json" ] || return 0
    jq -e --arg title "$title" 'map(.configTitle == $title) | any' "$SRM_CONFIGS" >/dev/null 2>&1 && return 0
    jq -e --arg title "$title" 'map(select(.configTitle == $title)) | length > 0' "$EMUDECK_SRM_USERDATA/userConfigurations.json" >/dev/null 2>&1 || return 0
    tmp="$(mktemp)"
    jq --slurpfile src "$EMUDECK_SRM_USERDATA/userConfigurations.json" --arg title "$title" \
        '. + ($src[0] | map(select(.configTitle == $title)))' "$SRM_CONFIGS" > "$tmp"
    mv "$tmp" "$SRM_CONFIGS"
}

backup_srm_file() {
    local file="$1"
    [ -f "$file" ] && cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true
}

ensure_srm_appimage_link() {
    local app target
    app="$(find_srm_appimage)"
    target="$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage"
    [ -n "$app" ] || return 0
    chmod +x "$app" 2>/dev/null || true
    [ "$app" = "$target" ] && return 0
    if [ ! -e "$target" ]; then
        install -d "$(dirname "$target")"
        ln -sfn "$app" "$target"
        pz_info "linked Steam ROM Manager AppImage: $target -> $app"
    fi
}

merge_srm_settings() {
    local tmp retro
    retro="$(retroarch_launcher)"
    backup_srm_file "$SRM_SETTINGS"
    tmp="$(mktemp)"
    jq \
        --arg steam "$STEAM_ROOT" \
        --arg roms "$PZ_EMULATION_ROOT/roms" \
        --arg retro "$retro" \
        '.environmentVariables = (.environmentVariables // {})
        | .environmentVariables.steamDirectory = $steam
        | .environmentVariables.romsDirectory = $roms
        | .environmentVariables.retroarchPath = $retro
        | .environmentVariables.userAccounts = (.environmentVariables.userAccounts // [])
        | .autoKillSteam = true
        | .autoRestartSteam = true
        | .theme = (.theme // "EmuDeck")
        | .phasezeroManaged = true
        | .phasezeroPolicy = "user-owned-games-only"' "$SRM_SETTINGS" > "$tmp"
    mv "$tmp" "$SRM_SETTINGS"
}

normalize_srm_parsers() {
    local tmp
    append_template_parser_by_title "Nintendo Switch - Eden"
    append_template_parser_by_title "Nintendo Switch - Citron"
    append_template_parser_by_title "Nintendo Switch - Ryujinx"
    append_template_parser_by_title "Microsoft Xbox 360 - Xenia"
    append_template_parser_by_title "Microsoft Xbox 360 - Xbox Live Arcade - Xenia"
    append_template_parser_by_title "Sony PlayStation - DuckStation"
    append_template_parser_by_title "Sony PlayStation 2 - PCSX2"
    append_template_parser_by_title "Sony PlayStation 3 - RPCS3 (Extracted ISO/PSN)"
    append_template_parser_by_title "Sony PlayStation 3 - RPCS3 (Installed PKG)"
    append_template_parser_by_title "Sony PlayStation 4 - ShadPS4 (Shortcut)"

    backup_srm_file "$SRM_CONFIGS"
    tmp="$(mktemp)"
    jq '
        map(select((.configTitle // "") != ""))
    ' "$SRM_CONFIGS" > "$tmp"
    mv "$tmp" "$SRM_CONFIGS"
    tmp="$(mktemp)"
    jq \
        --arg eden "$PZ_LOCAL_BIN/phasezero-eden" \
        --arg citron "$PZ_LOCAL_BIN/phasezero-citron" \
        --arg duck "$PZ_EMULATION_ROOT/tools/launchers/duckstation.sh" \
        --arg pcsx2 "$PZ_EMULATION_ROOT/tools/launchers/pcsx2-qt.sh" \
        --arg rpcs3 "$PZ_LOCAL_BIN/phasezero-rpcs3" \
        --arg shadps4 "$PZ_LOCAL_BIN/phasezero-shadps4-srm" \
        --arg ps3pkg "$PZ_EMULATION_ROOT/storage/rpcs3/dev_hdd0/game" \
        --arg switchView "$PZ_SCAN_SAFE_SWITCH" \
        --arg switchGlob '${title}@(.nro|.NRO|.nsp|.NSP|.nsz|.NSZ|.xci|.XCI)' \
        --arg xbox360Glob '{${title}@(.iso|.ISO|.zar|.ZAR),${title}/@(default.xex|Default.xex|DEFAULT.XEX)}' \
        --arg ps3Glob '{${title}@(.iso|.ISO),${title}/PS3_GAME/USRDIR/@(eboot.bin|EBOOT.BIN|ISO.BIN.EDAT|iso.bin.edat)}' \
        --arg switchArgs '-f -g "${filePath}"' \
        --arg duckArgs '-batch -fullscreen -nogui "${filePath}"' \
        --arg pcsx2Args '-batch -fullscreen -nogui "${filePath}"' \
        --arg rpcs3Args '--no-gui "${filePath}"' \
        --arg shadps4Args '"${filePath}"' \
        'map(
            if .configTitle == "Nintendo Switch - Eden" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = $switchView
                | .parserInputs = (.parserInputs // {})
                | .parserInputs.glob = $switchGlob
                | .executable.path = $eden
                | .executableArgs = $switchArgs
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .configTitle == "Nintendo Switch - Citron" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = $switchView
                | .parserInputs = (.parserInputs // {})
                | .parserInputs.glob = $switchGlob
                | .executable.path = $citron
                | .executableArgs = $switchArgs
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .configTitle == "Nintendo Switch - Ryujinx" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = $switchView
                | .parserInputs = (.parserInputs // {})
                | .parserInputs.glob = $switchGlob
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .configTitle == "Microsoft Xbox 360 - Xenia" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = "${romsdirglobal}/xbox360/roms"
                | .parserInputs = (.parserInputs // {})
                | .parserInputs.glob = $xbox360Glob
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .configTitle == "Sony PlayStation - DuckStation" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = "${romsdirglobal}/psx"
                | .executable.path = $duck
                | .executableArgs = $duckArgs
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .configTitle == "Sony PlayStation 2 - PCSX2" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = "${romsdirglobal}/ps2"
                | .executable.path = $pcsx2
                | .executableArgs = $pcsx2Args
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .configTitle == "Sony PlayStation 3 - RPCS3 (Extracted ISO/PSN)" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = "${romsdirglobal}/ps3"
                | .parserInputs = (.parserInputs // {})
                | .parserInputs.glob = $ps3Glob
                | .executable.path = $rpcs3
                | .executableArgs = $rpcs3Args
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .configTitle == "Sony PlayStation 3 - RPCS3 (Installed PKG)" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = $ps3pkg
                | .executable.path = $rpcs3
                | .executableArgs = $rpcs3Args
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .configTitle == "Sony PlayStation 4 - ShadPS4 (Shortcut)" then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = "${steamdirglobal}"
                | .romDirectory = "${romsdirglobal}/ps4/shortcuts"
                | .parserInputs = (.parserInputs // {})
                | .parserInputs.glob = "${title}@(.desktop)"
                | .executable.path = $shadps4
                | .executableArgs = $shadps4Args
                | .disabled = false
                | .userAccounts.specifiedAccounts = ["Global"]
            elif .phasezeroManaged == true then
                .parserType = (.parserType // "Glob")
                | .steamDirectory = (.steamDirectory // "${steamdirglobal}")
                | .userAccounts = (.userAccounts // {specifiedAccounts:["Global"]})
                | .userAccounts.specifiedAccounts = (.userAccounts.specifiedAccounts // ["Global"])
                | .executable = (.executable // {})
                | .executable.shortcutPassthrough = (.executable.shortcutPassthrough // false)
                | .executable.appendArgsToExecutable = (.executable.appendArgsToExecutable // true)
                | .executableModifier = (.executableModifier // "\"${exePath}\"")
                | .startInDirectory = (.startInDirectory // "")
                | .titleModifier = (.titleModifier // "${fuzzyTitle}")
                | .onlineImageQueries = (.onlineImageQueries // ["${fuzzyTitle}"])
                | .imagePool = (.imagePool // "${fuzzyTitle}")
                | .imageProviders = (.imageProviders // ["sgdb"])
                | .titleFromVariable = (.titleFromVariable // {caseInsensitiveVariables:false, skipFileIfVariableWasNotFound:false, limitToGroups:[]})
                | .fuzzyMatch = (.fuzzyMatch // {replaceDiacritics:true, removeCharacters:true, removeBrackets:true})
                | .imageProviderAPIs = (.imageProviderAPIs // {sgdb:{nsfw:false, humor:false, imageMotionTypes:["static"], styles:[], stylesHero:[], stylesLogo:[], stylesIcon:[]}})
                | .controllers = (.controllers // {ps4:null, ps5:null, xbox360:null, xboxone:null, switch_joycon_left:null, switch_joycon_right:null, switch_pro:null, neptune:null})
                | .defaultImage = (.defaultImage // {long:"", tall:"", hero:"", logo:"", icon:""})
                | .localImages = (.localImages // {long:"", tall:"", hero:"", logo:"", icon:""})
                | .steamInputEnabled = (.steamInputEnabled // "1")
                | .drmProtect = (.drmProtect // false)
                | .disabled = false
                | .version = 25
                | .presetVersion = 19
            else . end
        )' "$SRM_CONFIGS" > "$tmp"
    mv "$tmp" "$SRM_CONFIGS"
}

write_shadps4_srm_wrapper() {
    local launcher="$PZ_EMULATION_ROOT/tools/launchers/shadps4.sh"
    if [ ! -f "$launcher" ]; then
        launcher="$HOME/.config/EmuDeck/backend/tools/launchers/shadps4.sh"
    fi
    [ -f "$launcher" ] || return 0
    chmod +x "$launcher" 2>/dev/null || true
    pz_emulation_write_file "$PZ_LOCAL_BIN/phasezero-shadps4-srm" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
performance="$PZ_LOCAL_BIN/phasezero-emulation-launch"
launcher="$launcher"
if [ -x "\$performance" ]; then
    exec "\$performance" ps4 -- "\$launcher" "\$@"
fi
exec "\$launcher" "\$@"
EOF
}

write_srm_wrapper() {
    local app launcher
    app="$(find_srm_appimage)"
    launcher="$(find_srm_launcher)"
    [ -n "$app" ] && chmod +x "$app" 2>/dev/null || true
    [ -n "$launcher" ] && chmod +x "$launcher" 2>/dev/null || true
    pz_emulation_write_file "$SRM_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
launcher="$launcher"
app="$app"
if [ -n "\$launcher" ] && [ -f "\$launcher" ]; then
    exec "\$launcher" "\$@"
fi
if [ -n "\$app" ] && [ -f "\$app" ]; then
    exec "\$app" "\$@"
fi
echo "Steam ROM Manager not found. Run EmuDeck or place AppImage in $PZ_EMULATION_ROOT/tools." >&2
exit 1
EOF
}

write_srm_desktop() {
    pz_emulation_write_file "$SRM_DESKTOP" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=Steam ROM Manager
Comment=Steam ROM Manager managed by PhaseZero
Exec=$SRM_WRAPPER
Terminal=false
Icon=$PZ_EMULATION_ROOT/media/icons/phasezero/srm.svg
Categories=Game;Emulator;
X-PhaseZero-Managed=true
EOF
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1 || true
}

srm_configured_bool() {
    [ -f "$SRM_SETTINGS" ] || { echo false; return 0; }
    [ -f "$SRM_CONFIGS" ] || { echo false; return 0; }
    jq -e --arg steam "$STEAM_ROOT" --arg roms "$PZ_EMULATION_ROOT/roms" \
        '.environmentVariables.steamDirectory == $steam and .environmentVariables.romsDirectory == $roms' "$SRM_SETTINGS" >/dev/null 2>&1 || { echo false; return 0; }
    jq -e '
        ([.[] | select((.configTitle // "") == "" or (.parserType // "") == "")] | length == 0) as $valid
        | [.[].configTitle] as $titles
        | $valid
        and ($titles | index("Nintendo Switch - Eden")) != null
        and ($titles | index("Nintendo Switch - Citron")) != null
        and ($titles | index("Sony PlayStation - DuckStation")) != null
        and ($titles | index("Sony PlayStation 2 - PCSX2")) != null
        and ($titles | index("Sony PlayStation 3 - RPCS3 (Extracted ISO/PSN)")) != null
        and ($titles | index("Sony PlayStation 4 - ShadPS4 (Shortcut)")) != null
    ' "$SRM_CONFIGS" >/dev/null 2>&1 || { echo false; return 0; }
    echo true
}

status_srm() {
    local app launcher config_count managed_count invalid_count settings_exists=false configs_exists=false
    app="$(find_srm_appimage)"
    launcher="$(find_srm_launcher)"
    [ -f "$SRM_SETTINGS" ] && settings_exists=true
    [ -f "$SRM_CONFIGS" ] && configs_exists=true
    config_count=0
    managed_count=0
    invalid_count=0
    if [ -f "$SRM_CONFIGS" ] && jq empty "$SRM_CONFIGS" >/dev/null 2>&1; then
        config_count="$(jq 'length' "$SRM_CONFIGS")"
        managed_count="$(jq '[.[] | select(.configTitle | test("Nintendo Switch - (Eden|Citron)|Sony PlayStation - DuckStation|Sony PlayStation 2 - PCSX2|Sony PlayStation 3 - RPCS3|Sony PlayStation 4 - ShadPS4"; "i"))] | length' "$SRM_CONFIGS")"
        invalid_count="$(jq '[.[] | select((.configTitle // "") == "" or (.parserType // "") == "")] | length' "$SRM_CONFIGS")"
    fi
    jq -n \
        --arg appImage "$app" \
        --arg launcher "$launcher" \
        --arg wrapper "$SRM_WRAPPER" \
        --arg desktop "$SRM_DESKTOP" \
        --arg settings "$SRM_SETTINGS" \
        --arg configs "$SRM_CONFIGS" \
        --arg steamRoot "$STEAM_ROOT" \
        --arg romsRoot "$PZ_EMULATION_ROOT/roms" \
        --arg retroarchPath "$(retroarch_launcher)" \
        --argjson appImageInstalled "$([ -f "$app" ] && echo true || echo false)" \
        --argjson launcherInstalled "$([ -f "$launcher" ] && echo true || echo false)" \
        --argjson wrapperInstalled "$([ -x "$SRM_WRAPPER" ] && echo true || echo false)" \
        --argjson desktopInstalled "$([ -f "$SRM_DESKTOP" ] && echo true || echo false)" \
        --argjson settingsInstalled "$settings_exists" \
        --argjson configurationsInstalled "$configs_exists" \
        --argjson configurationsCount "$config_count" \
        --argjson managedParsers "$managed_count" \
        --argjson invalidParsers "$invalid_count" \
        --argjson configured "$(srm_configured_bool)" \
        '{appImage: $appImage, launcher: $launcher, wrapper: $wrapper, desktop: $desktop, settings: $settings, configurations: $configs, steamRoot: $steamRoot, romsRoot: $romsRoot, retroarchPath: $retroarchPath, appImageInstalled: $appImageInstalled, launcherInstalled: $launcherInstalled, wrapperInstalled: $wrapperInstalled, desktopInstalled: $desktopInstalled, settingsInstalled: $settingsInstalled, configurationsInstalled: $configurationsInstalled, configurationsCount: $configurationsCount, managedParsers: $managedParsers, invalidParsers: $invalidParsers, configured: $configured}'
}

configure_srm() {
    pz_emulation_ensure_layout
    bash "$PZ_ROOT/linux/emulation/media.sh" prepare-scan >/dev/null
    bash "$PZ_ROOT/linux/emulation/performance.sh" apply >/dev/null
    bash "$PZ_ROOT/linux/emulation/shortcuts.sh" repair >/dev/null
    ensure_srm_appimage_link
    ensure_srm_settings
    ensure_srm_configurations
    merge_srm_settings
    write_shadps4_srm_wrapper
    normalize_srm_parsers
    write_srm_wrapper
    write_srm_desktop
    jq -n \
        --arg configuredAt "$(date -Iseconds)" \
        --arg settings "$SRM_SETTINGS" \
        --arg configs "$SRM_CONFIGS" \
        --arg policy "user-owned-games-only" \
        '{configuredAt: $configuredAt, settings: $settings, configurations: $configs, policy: $policy}' > "$SRM_STATE"
    pz_info "Steam ROM Manager configured: $SRM_CONFIG_DIR"
}

dry_run_srm() {
    cat <<EOF
Steam ROM Manager dry-run
  appimage:  $(find_srm_appimage)
  launcher:  $(find_srm_launcher)
  settings:  $SRM_SETTINGS
  configs:   $SRM_CONFIGS
  steam:     $STEAM_ROOT
  roms:      $PZ_EMULATION_ROOT/roms
  retroarch: $(retroarch_launcher)
  policy:    user-owned-games-only; no ROM/BIOS/firmware/key download
EOF
}

open_srm() {
    [ -x "$SRM_WRAPPER" ] || configure_srm
    nohup "$SRM_WRAPPER" >/dev/null 2>&1 &
    pz_info "Steam ROM Manager launched"
}

case "$ACTION" in
    configure|integrate) configure_srm ;;
    status) status_srm ;;
    dry-run|plan) dry_run_srm ;;
    open|launch) open_srm ;;
    *) pz_error "usage: srm.sh (status|dry-run|configure|open)"; exit 1 ;;
esac
