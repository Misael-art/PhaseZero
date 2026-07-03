#!/usr/bin/env bash
# shortcuts.sh - audit and repair friendly desktop launchers for AppImage-heavy emulation hosts.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"
source "$PZ_ROOT/linux/lib/json-envelope.sh"

PZ_JSON=false
args=()
for arg in "$@"; do
    if [ "$arg" = "--json" ]; then
        PZ_JSON=true
    else
        args+=("$arg")
    fi
done

ACTION="${args[0]:-status}"
PZ_SHORTCUT_BACKUP_DIR="$PZ_EMULATION_ROOT/.phasezero/backups/desktop-shortcuts"
PZ_APPIMAGE_DIR="${PZ_APPIMAGE_DIR:-$HOME/Appimage}"
PZ_SHORTCUTS_DISABLE_RENDER_MENU="${PZ_SHORTCUTS_DISABLE_RENDER_MENU:-1}"

pz_shortcut_apps() {
    cat <<APPS
emudeck|EmuDeck|Configure EmuDeck through PhaseZero launcher|emudeck|$PZ_LOCAL_BIN/phasezero-emudeck|$PZ_DESKTOP_DIR/phasezero-emudeck.desktop|$PZ_APPLICATIONS_DIR/EmuDeck.AppImage;$PZ_APPIMAGE_DIR/EmuDeck*.AppImage|plain||
srm|Steam ROM Manager|Steam ROM Manager managed by PhaseZero|steam-rom-manager|$PZ_LOCAL_BIN/phasezero-srm|$PZ_DESKTOP_DIR/phasezero-steam-rom-manager.desktop|$PZ_EMULATION_ROOT/tools/launchers/srm/steamrommanager.sh;$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage;$PZ_EMULATION_ROOT/tools/Steam ROM Manager.AppImage;$PZ_APPIMAGE_DIR/Steam-ROM-Manager*.AppImage;$PZ_APPIMAGE_DIR/Steam*ROM*Manager*.AppImage|plain||
hydra|Hydra|Hydra launcher managed by PhaseZero|hydralauncher|$PZ_LOCAL_BIN/phasezero-hydra-steamos|$PZ_DESKTOP_DIR/phasezero-hydra.desktop|$PZ_LOCAL_BIN/phasezero-hydra-steamos;$PZ_LOCAL_BIN/phasezero-hydra;$PZ_APPLICATIONS_DIR/Hydra.AppImage;$PZ_APPIMAGE_DIR/Hydra*.AppImage|plain||
eden|Eden|Nintendo Switch emulator launcher managed by PhaseZero|eden|$PZ_LOCAL_BIN/phasezero-eden|$PZ_DESKTOP_DIR/phasezero-eden.desktop|$PZ_APPLICATIONS_DIR/Eden.AppImage;$PZ_APPLICATIONS_DIR/Eden-Linux*.AppImage;$PZ_LOCAL_BIN/phasezero-eden|game|%f|application/x-nx-nsp;application/x-nx-xci;
citron|Citron|Nintendo Switch emulator launcher managed by PhaseZero|citron|$PZ_LOCAL_BIN/phasezero-citron|$PZ_DESKTOP_DIR/phasezero-citron.desktop|$PZ_APPLICATIONS_DIR/Citron.AppImage;$PZ_APPLICATIONS_DIR/citron*.AppImage;$PZ_LOCAL_BIN/phasezero-citron|game|%f|application/x-nx-nsp;application/x-nx-xci;
duckstation|DuckStation|PlayStation 1 emulator launcher managed by PhaseZero|org.duckstation.DuckStation|$PZ_LOCAL_BIN/phasezero-duckstation|$PZ_DESKTOP_DIR/phasezero-duckstation.desktop|$PZ_APPLICATIONS_DIR/DuckStation.AppImage;$PZ_APPIMAGE_DIR/DuckStation*.AppImage|game|%f|
pcsx2|PCSX2|PlayStation 2 emulator launcher managed by PhaseZero|pcsx2|$PZ_LOCAL_BIN/phasezero-pcsx2|$PZ_DESKTOP_DIR/phasezero-pcsx2.desktop|$PZ_APPLICATIONS_DIR/pcsx2-Qt.AppImage;$PZ_APPLICATIONS_DIR/PCSX2.AppImage;$PZ_APPIMAGE_DIR/pcsx2*.AppImage;$PZ_APPIMAGE_DIR/PCSX2*.AppImage|game|%f|
rpcs3|RPCS3|PlayStation 3 emulator launcher managed by PhaseZero|rpcs3|$PZ_LOCAL_BIN/phasezero-rpcs3|$PZ_DESKTOP_DIR/phasezero-rpcs3.desktop|$PZ_APPLICATIONS_DIR/rpcs3.AppImage;$PZ_APPLICATIONS_DIR/RPCS3.AppImage;$PZ_APPIMAGE_DIR/RPCS3*.AppImage;$PZ_APPIMAGE_DIR/rpcs3*.AppImage|game|%f|
cemu|Cemu|Wii U emulator launcher managed by PhaseZero|info.cemu.Cemu|$PZ_LOCAL_BIN/phasezero-cemu|$PZ_DESKTOP_DIR/phasezero-cemu.desktop|$PZ_APPLICATIONS_DIR/Cemu.AppImage;$PZ_APPIMAGE_DIR/Cemu*.AppImage|game|%f|application/x-wii-u-rom;
esde|ES-DE|EmulationStation Desktop Edition managed by PhaseZero|es-de|$PZ_LOCAL_BIN/phasezero-es-de|$PZ_DESKTOP_DIR/phasezero-es-de.desktop|$PZ_APPLICATIONS_DIR/ES-DE.AppImage;$PZ_APPIMAGE_DIR/ES-DE*.AppImage;$PZ_EMULATION_ROOT/tools/launchers/es-de/es-de.sh;$PZ_EMULATION_ROOT/tools/launchers/esde/emulationstationde.sh|plain||
azahar|Azahar|Nintendo 3DS emulator launcher managed by PhaseZero|azahar|$PZ_LOCAL_BIN/phasezero-azahar|$PZ_DESKTOP_DIR/phasezero-azahar.desktop|$PZ_APPLICATIONS_DIR/azahar.AppImage;$PZ_APPIMAGE_DIR/azahar*.AppImage;$PZ_APPIMAGE_DIR/Azahar*.AppImage|game|%f|
shadps4|shadPS4|PlayStation 4 emulator launcher managed by PhaseZero|shadps4|$PZ_LOCAL_BIN/phasezero-shadps4|$PZ_DESKTOP_DIR/phasezero-shadps4.desktop|$PZ_APPLICATIONS_DIR/Shadps4-qt.AppImage;$PZ_APPIMAGE_DIR/Shadps4*.AppImage;$PZ_APPIMAGE_DIR/shadPS4*.AppImage|game|%f|
ryujinx|Ryujinx|Nintendo Switch emulator launcher managed by PhaseZero|ryujinx|$PZ_LOCAL_BIN/phasezero-ryujinx|$PZ_DESKTOP_DIR/phasezero-ryujinx.desktop|$PZ_APPLICATIONS_DIR/publish/Ryujinx.sh;$PZ_APPLICATIONS_DIR/publish/Ryujinx|game|%f|
vita3k|Vita3K|PlayStation Vita emulator launcher managed by PhaseZero|vita3k|$PZ_LOCAL_BIN/phasezero-vita3k|$PZ_DESKTOP_DIR/phasezero-vita3k.desktop|$PZ_APPLICATIONS_DIR/Vita3K/Vita3K|game|%f|
bigpemu|BigPEmu|Atari Jaguar emulator launcher managed by PhaseZero|bigpemu|$PZ_LOCAL_BIN/phasezero-bigpemu|$PZ_DESKTOP_DIR/phasezero-bigpemu.desktop|$PZ_APPLICATIONS_DIR/BigPEmu/bigpemu|game|%f|
APPS
}

pz_shortcut_pattern() {
    case "$1" in
        emudeck) echo 'emudeck' ;;
        srm) echo 'steam rom manager|steam-rom-manager|steam_rom_manager|steamrommanager' ;;
        hydra) echo 'hydra' ;;
        eden) echo 'eden' ;;
        citron) echo 'citron' ;;
        duckstation) echo 'duckstation' ;;
        pcsx2) echo 'pcsx2' ;;
        rpcs3) echo 'rpcs3' ;;
        cemu) echo 'cemu' ;;
        esde) echo 'es-de|emulationstation|emulationstationde' ;;
        azahar) echo 'azahar' ;;
        shadps4) echo 'shadps4|shadps4' ;;
        ryujinx) echo 'ryujinx' ;;
        vita3k) echo 'vita3k' ;;
        bigpemu) echo 'bigpemu|bigpemu' ;;
        *) echo "$1" ;;
    esac
}

pz_shortcut_performance_platform() {
    case "$1" in
        eden|citron|ryujinx) echo "switch" ;;
        rpcs3) echo "ps3" ;;
        shadps4) echo "ps4" ;;
        *) return 1 ;;
    esac
}

pz_shortcut_first_existing() {
    local candidates="$1" candidate match
    IFS=';' read -r -a _pz_candidates <<< "$candidates"
    for candidate in "${_pz_candidates[@]}"; do
        [ -z "$candidate" ] && continue
        if [[ "$candidate" == *"*"* || "$candidate" == *"?"* || "$candidate" == *"["* ]]; then
            while IFS= read -r match; do
                [ -f "$match" ] || [ -x "$match" ] || continue
                printf '%s\n' "$match"
                return 0
            done < <(compgen -G "$candidate" | sort 2>/dev/null || true)
        elif [ -f "$candidate" ] || [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

pz_shortcut_emudeck_status() {
    bash "$PZ_ROOT/linux/emulation/emudeck.sh" status 2>/dev/null || echo '{}'
}

pz_shortcut_emudeck_uses_steamdeck_desktop() {
    local status
    status="$(pz_shortcut_emudeck_status)"
    jq -e '.launcher.kind == "steamdeck-desktop"' >/dev/null 2>&1 <<< "$status"
}

pz_shortcut_emudeck_launcher_path() {
    local status
    status="$(pz_shortcut_emudeck_status)"
    jq -r '.launcher.path // empty' <<< "$status" 2>/dev/null
}

pz_shortcut_desktop_value() {
    local file="$1" key="$2"
    sed -n 's/^[[:space:]]*'"$key"'=\(.*\)$/\1/p' "$file" 2>/dev/null | head -n 1
}

pz_shortcut_desktop_hidden() {
    local file="$1"
    grep -qi '^[[:space:]]*\(NoDisplay\|Hidden\)=true' "$file" 2>/dev/null
}

pz_shortcut_desktop_text() {
    local file="$1"
    {
        basename "$file"
        pz_shortcut_desktop_value "$file" "Name"
        pz_shortcut_desktop_value "$file" "Exec"
    } | tr '[:upper:]' '[:lower:]'
}

pz_shortcut_is_duplicate() {
    local file="$1" id="$2" canonical="$3"
    [ "$file" = "$canonical" ] && return 1
    [ -f "$file" ] || return 1
    pz_shortcut_desktop_hidden "$file" && return 1

    local text pattern
    text="$(pz_shortcut_desktop_text "$file")"
    pattern="$(pz_shortcut_pattern "$id")"
    grep -Eiq "$pattern" <<< "$text" || return 1

    if grep -qi '^X-AppImage-Version=' "$file" 2>/dev/null; then
        return 0
    fi
    if grep -qi 'SoftwareRender' "$file" 2>/dev/null; then
        return 0
    fi
    if grep -qi 'appimagekit_' "$file" 2>/dev/null; then
        return 0
    fi
    if grep -qi "$PZ_APPIMAGE_DIR" "$file" 2>/dev/null; then
        return 0
    fi
    if [[ "$(basename "$file")" != phasezero-* ]]; then
        return 0
    fi
    return 1
}

pz_shortcut_duplicates_for_app() {
    local id="$1" canonical="$2" file
    [ -d "$PZ_DESKTOP_DIR" ] || return 0
    while IFS= read -r -d '' file; do
        if pz_shortcut_is_duplicate "$file" "$id" "$canonical"; then
            printf '%s\n' "$file"
        fi
    done < <(find "$PZ_DESKTOP_DIR" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
}

pz_shortcut_exec_ok() {
    local desktop="$1" wrapper="$2" suffix="$3"
    [ -f "$desktop" ] || return 1
    local exec_value
    exec_value="$(pz_shortcut_desktop_value "$desktop" "Exec")"
    case "$exec_value" in
        "$wrapper"|"$wrapper $suffix") return 0 ;;
        *) return 1 ;;
    esac
}

pz_shortcut_desktop_ok() {
    local desktop="$1" wrapper="$2" suffix="$3"
    [ -f "$desktop" ] || return 1
    pz_shortcut_desktop_hidden "$desktop" && return 1
    pz_shortcut_exec_ok "$desktop" "$wrapper" "$suffix" || return 1
    grep -q '^Actions=SoftwareRender' "$desktop" 2>/dev/null && return 1
    grep -qi 'SoftwareRender' "$desktop" 2>/dev/null && return 1
    return 0
}

pz_shortcut_render_menu_user_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user is-active render-menu-options-user.path >/dev/null 2>&1 ||
        systemctl --user is-active render-menu-options-user.service >/dev/null 2>&1
}

pz_shortcut_disable_render_menu_user() {
    [ "$PZ_SHORTCUTS_DISABLE_RENDER_MENU" = "1" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    if pz_shortcut_render_menu_user_active ||
        systemctl --user is-enabled render-menu-options-user.path >/dev/null 2>&1 ||
        systemctl --user is-enabled render-menu-options-user.service >/dev/null 2>&1; then
        systemctl --user disable --now render-menu-options-user.path render-menu-options-user.service >/dev/null 2>&1 || true
        systemctl --user mask --now render-menu-options-user.path render-menu-options-user.service >/dev/null 2>&1 || \
            pz_warn "could not disable render-menu-options user watcher"
        systemctl --user stop render-menu-options-user.service render-menu-options-user.path >/dev/null 2>&1 || true
        pz_info "masked render-menu-options user watcher to prevent SoftwareRender menu pollution"
    fi
}

pz_shortcut_write_wrapper() {
    local id="$1" wrapper="$2" target="$3" mode="$4"
    local platform=""
    [ -n "$target" ] || return 0
    if [ "$target" = "$wrapper" ] && [ -x "$wrapper" ]; then
        return 0
    fi
    chmod +x "$target" 2>/dev/null || true
    install -d "$(dirname "$wrapper")"
    case "$mode" in
        game)
            platform="$(pz_shortcut_performance_platform "$id" 2>/dev/null || true)"
            pz_emulation_write_file "$wrapper" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
app="$target"
performance="$PZ_LOCAL_BIN/phasezero-emulation-launch"
if [ ! -x "\$app" ] && [ -f "\$app" ]; then
    chmod +x "\$app" 2>/dev/null || true
fi
if [ ! -e "\$app" ]; then
    echo "$id target not found: \$app" >&2
    exit 1
fi
if [ -n "$platform" ] && [ -x "\$performance" ]; then
    exec "\$performance" "$platform" -- "\$app" "\$@"
fi
if command -v gamemoderun >/dev/null 2>&1; then
    exec env MANGOHUD=1 gamemoderun "\$app" "\$@"
fi
exec env MANGOHUD=1 "\$app" "\$@"
EOF
            ;;
        *)
            pz_emulation_write_file "$wrapper" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
app="$target"
if [ ! -x "\$app" ] && [ -f "\$app" ]; then
    chmod +x "\$app" 2>/dev/null || true
fi
if [ ! -e "\$app" ]; then
    echo "$id target not found: \$app" >&2
    exit 1
fi
exec "\$app" "\$@"
EOF
            ;;
    esac
}

pz_shortcut_write_desktop() {
    local name="$1" comment="$2" icon="$3" wrapper="$4" desktop="$5" mode="$6" suffix="$7" mime="$8"
    local exec_line="$wrapper"
    [ -n "$suffix" ] && exec_line="$exec_line $suffix"
    local categories="Game;Emulator;"
    [ "$mode" = "plain" ] && categories="Game;Emulator;"
    pz_emulation_write_file "$desktop" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$comment
Exec=$exec_line
Terminal=false
Icon=$icon
Categories=$categories
${mime:+MimeType=$mime}
StartupNotify=false
X-PhaseZero-Managed=true
EOF
    pz_shortcut_strip_software_render "$desktop"
}

pz_shortcut_strip_software_render() {
    local file="$1" tmp
    [ -f "$file" ] || return 0
    grep -qi 'SoftwareRender\|Software Render' "$file" 2>/dev/null || return 0
    tmp="$(mktemp)"
    awk '
        function clean_actions(line,    value,n,i,item,out,count) {
            sub(/^Actions=/, "", line)
            n = split(line, item, ";")
            out = ""
            count = 0
            for (i = 1; i <= n; i++) {
                if (item[i] == "" || item[i] == "SoftwareRender") {
                    continue
                }
                out = out item[i] ";"
                count++
            }
            if (count > 0) {
                print "Actions=" out
            }
        }
        /^[[:space:]]*\[Desktop Action SoftwareRender\][[:space:]]*$/ {
            skip = 1
            next
        }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            skip = 0
            print
            next
        }
        skip {
            next
        }
        /^Actions=/ {
            clean_actions($0)
            next
        }
        {
            print
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

pz_shortcut_hide_duplicate() {
    local file="$1"
    install -d "$PZ_SHORTCUT_BACKUP_DIR"
    local backup="$PZ_SHORTCUT_BACKUP_DIR/$(basename "$file").bak.$(date +%s)"
    cp "$file" "$backup" 2>/dev/null || true
    pz_shortcut_set_desktop_key "$file" "NoDisplay" "true"
    pz_shortcut_set_desktop_key "$file" "Hidden" "true"
    pz_info "hidden duplicate launcher: $file"
}

pz_shortcut_set_desktop_key() {
    local file="$1" key="$2" value="$3" tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        BEGIN { in_entry = 0; wrote = 0 }
        /^[[:space:]]*\[Desktop Entry\][[:space:]]*$/ {
            in_entry = 1
            print
            next
        }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            if (in_entry && !wrote) {
                print key "=" value
                wrote = 1
            }
            in_entry = 0
            print
            next
        }
        {
            if (in_entry && $0 ~ "^[[:space:]]*" key "=") {
                if (!wrote) {
                    print key "=" value
                    wrote = 1
                }
                next
            }
            print
        }
        END {
            if (!wrote) {
                print key "=" value
            }
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

pz_shortcut_status_line() {
    local id="$1" name="$2" wrapper="$3" desktop="$4" candidates="$5" suffix="$6"
    local target dup_count=0 desktop_state wrapper_state target_state
    if [ "$id" = "emudeck" ] && pz_shortcut_emudeck_uses_steamdeck_desktop; then
        target="$(pz_shortcut_emudeck_launcher_path)"
    else
        target="$(pz_shortcut_first_existing "$candidates" 2>/dev/null || true)"
    fi
    [ -n "$target" ] && target_state="found" || target_state="missing"
    [ -x "$wrapper" ] && wrapper_state="ok" || wrapper_state="missing"
    pz_shortcut_desktop_ok "$desktop" "$wrapper" "$suffix" && desktop_state="ok" || desktop_state="bad"
    dup_count="$(pz_shortcut_duplicates_for_app "$id" "$desktop" | wc -l | tr -d ' ')"
    printf "  %-18s target=%-7s wrapper=%-7s desktop=%-4s duplicates=%s\n" "$name" "$target_state" "$wrapper_state" "$desktop_state" "$dup_count"
    [ -n "$target" ] && printf "    target: %s\n" "$target"
    return 0
}

cmd_status() {
    echo "=== Desktop Shortcut Status ==="
    if pz_shortcut_render_menu_user_active; then
        echo "  render-menu-options user watcher: active (will inject SoftwareRender actions)"
    else
        echo "  render-menu-options user watcher: inactive"
    fi
    local id name comment icon wrapper desktop candidates mode suffix mime
    while IFS='|' read -r id name comment icon wrapper desktop candidates mode suffix mime; do
        [ -z "$id" ] && continue
        pz_shortcut_status_line "$id" "$name" "$wrapper" "$desktop" "$candidates" "$suffix"
    done < <(pz_shortcut_apps)
}

cmd_plan() {
    echo "=== Desktop Shortcut Repair Plan (dry-run) ==="
    if pz_shortcut_render_menu_user_active; then
        echo "  disable render-menu-options user watcher"
    fi
    local id name comment icon wrapper desktop candidates mode suffix mime target dup
    while IFS='|' read -r id name comment icon wrapper desktop candidates mode suffix mime; do
        [ -z "$id" ] && continue
        if [ "$id" = "emudeck" ] && pz_shortcut_emudeck_uses_steamdeck_desktop; then
            target="$(pz_shortcut_emudeck_launcher_path)"
        else
            target="$(pz_shortcut_first_existing "$candidates" 2>/dev/null || true)"
        fi
        if [ -z "$target" ]; then
            dup="$(pz_shortcut_duplicates_for_app "$id" "$desktop" | wc -l | tr -d ' ')"
            [ "$dup" -gt 0 ] && echo "  $name: hide $dup duplicate launcher(s); no canonical target found"
            continue
        fi
        [ ! -x "$wrapper" ] && echo "  $name: create wrapper $wrapper -> $target"
        if ! pz_shortcut_desktop_ok "$desktop" "$wrapper" "$suffix"; then
            echo "  $name: write clean desktop launcher $desktop"
        fi
        while IFS= read -r dup; do
            [ -z "$dup" ] && continue
            echo "  $name: hide duplicate $dup"
        done < <(pz_shortcut_duplicates_for_app "$id" "$desktop")
    done < <(pz_shortcut_apps)
}

cmd_repair() {
    pz_emulation_ensure_layout
    bash "$PZ_ROOT/linux/emulation/performance.sh" apply >/dev/null
    install -d "$PZ_DESKTOP_DIR" "$PZ_LOCAL_BIN" "$PZ_SHORTCUT_BACKUP_DIR"
    pz_shortcut_disable_render_menu_user
    local id name comment icon wrapper desktop candidates mode suffix mime target dup
    while IFS='|' read -r id name comment icon wrapper desktop candidates mode suffix mime; do
        [ -z "$id" ] && continue
        if [ "$id" = "emudeck" ] && [ "$(pz_emulation_host_class)" = "steam-deck" ]; then
            bash "$PZ_ROOT/linux/emulation/emudeck.sh" install
            while IFS= read -r dup; do
                [ -z "$dup" ] && continue
                pz_shortcut_hide_duplicate "$dup"
            done < <(pz_shortcut_duplicates_for_app "$id" "$desktop")
            continue
        fi
        target="$(pz_shortcut_first_existing "$candidates" 2>/dev/null || true)"
        if [ -n "$target" ]; then
            pz_shortcut_write_wrapper "$id" "$wrapper" "$target" "$mode"
            pz_shortcut_write_desktop "$name" "$comment" "$icon" "$wrapper" "$desktop" "$mode" "$suffix" "$mime"
        fi
        while IFS= read -r dup; do
            [ -z "$dup" ] && continue
            pz_shortcut_hide_duplicate "$dup"
        done < <(pz_shortcut_duplicates_for_app "$id" "$desktop")
    done < <(pz_shortcut_apps)
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1 || true
    while IFS='|' read -r id name comment icon wrapper desktop candidates mode suffix mime; do
        [ -z "$id" ] && continue
        pz_shortcut_strip_software_render "$desktop"
    done < <(pz_shortcut_apps)
    pz_info "desktop shortcut repair complete"
}

cmd_status_json() {
    pz_json_envelope_start "emulation" "ok"
    local id name comment icon wrapper desktop candidates mode suffix mime target dup_count check_status msg overall="ok"
    if pz_shortcut_render_menu_user_active; then
        pz_json_append_check "shortcuts.render-menu-options-user" "warn" "active; will inject SoftwareRender actions"
        overall="warn"
    else
        pz_json_append_check "shortcuts.render-menu-options-user" "ok" "inactive"
    fi
    while IFS='|' read -r id name comment icon wrapper desktop candidates mode suffix mime; do
        [ -z "$id" ] && continue
        if [ "$id" = "emudeck" ] && pz_shortcut_emudeck_uses_steamdeck_desktop; then
            target="$(pz_shortcut_emudeck_launcher_path)"
        else
            target="$(pz_shortcut_first_existing "$candidates" 2>/dev/null || true)"
        fi
        dup_count="$(pz_shortcut_duplicates_for_app "$id" "$desktop" | wc -l | tr -d ' ')"
        check_status="ok"
        if [ -z "$target" ]; then
            if [ "$dup_count" -gt 0 ]; then
                check_status="warn"
                overall="warn"
            else
                check_status="info"
            fi
        elif ! [ -x "$wrapper" ] || ! pz_shortcut_desktop_ok "$desktop" "$wrapper" "$suffix" || [ "$dup_count" -gt 0 ]; then
            check_status="warn"
            overall="warn"
        fi
        msg="target=${target:-missing} wrapper=$([ -x "$wrapper" ] && echo ok || echo missing) desktop=$([ -f "$desktop" ] && echo present || echo missing) duplicates=$dup_count"
        pz_json_append_check "shortcuts.$id" "$check_status" "$msg"
    done < <(pz_shortcut_apps)
    pz_json_append_action "emulation.shortcuts.plan" "Ver plano de atalhos" false
    pz_json_append_action "emulation.shortcuts.repair" "Reparar atalhos" true
    PZ_JSON_STATUS="$overall"
    [ "$overall" != "ok" ] && PZ_JSON_OK=false
    pz_json_envelope_end
}

case "$ACTION" in
    status) if $PZ_JSON; then cmd_status_json; else cmd_status; fi ;;
    plan|dry-run) cmd_plan ;;
    repair|apply) cmd_repair ;;
    *)
        pz_error "usage: shortcuts.sh (status|plan|repair)"
        exit 1
        ;;
esac
