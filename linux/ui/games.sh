#!/usr/bin/env bash
# games.sh - PhaseZero Game/Emulator desktop menu shortcuts
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DIRECTORIES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/desktop-directories"
MENUS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/menus/applications-merged"

# Game apps: slug:display:binary/exec:group:system_desktop
GAMES=(
    "steam:Steam:steam:Jogos PC:steam.desktop"
    "heroic:Heroic Games Launcher:heroic:Jogos PC:heroic.desktop"
    "lutris:Lutris:lutris:Jogos PC:net.lutris.Lutris.desktop"
    "retroarch:RetroArch:retroarch:Emuladores:com.libretro.RetroArch.desktop"
    "dolphin:Dolphin Emulator:dolphin-emu:Emuladores:dolphin-emu.desktop"
    "pcsx2:PCSX2:pcsx2:Emuladores:pcsx2.desktop"
    "rpcs3:RPCS3:rpcs3:Emuladores:rpcs3.desktop"
    "duckstation:DuckStation:duckstation:Emuladores:duckstation.desktop"
    "ryujinx:Ryujinx:ryujinx:Emuladores:ryujinx.desktop"
    "citron:Citron:citron:Emuladores:citron.desktop"
    "eden:Eden:eden:Emuladores:eden.desktop"
    "emudeck:EmuDeck:emudeck:Frontends:emudeck.desktop"
    "retrodeck:RetroDECK:retrodeck:Frontends:retrodeck.desktop"
    "launchbox:LaunchBox:launchbox:Frontends:launchbox.desktop"
    "esde:ES-DE:es-de:Frontends:es-de.desktop"
    "srm:Steam ROM Manager:srm:Frontends:srm.desktop"
)

# Find system .desktop file in XDG paths
find_system_desktop() {
    local name="$1"
    IFS=':' read -ra dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    for d in "${dirs[@]}"; do
        local f="$d/applications/$name"
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    # Also check home
    local home_f="$APPLICATIONS_DIR/$name"
    [ -f "$home_f" ] && { echo "$home_f"; return 0; }
    return 1
}

binary_exists() {
    command -v "$1" &>/dev/null || [ -f "$1" ]
}

ensure_dirs() {
    mkdir -p "$APPLICATIONS_DIR" "$DIRECTORIES_DIR" "$MENUS_DIR"
}

detect_game() {
    local slug="$1" binary="$2" system_desk="$3"
    # Check binary
    if binary_exists "$binary"; then return 0; fi
    # Check system .desktop
    if find_system_desktop "$system_desk" &>/dev/null; then return 0; fi
    return 1
}

install_game() {
    local slug="$1" entry name binary group desk
    for entry in "${GAMES[@]}"; do
        IFS=':' read -r slug_ name binary group desk <<< "$entry"
        [ "$slug_" = "$slug" ] || continue

        if ! detect_game "$slug" "$binary" "$desk"; then
            echo "  SKIP: $name ($slug) not installed"
            return 1
        fi

        local sys_desk_file
        sys_desk_file="$(find_system_desktop "$desk" || echo "")"
        if [ -z "$sys_desk_file" ]; then
            # Create wrapper .desktop pointing to binary
            local file="$APPLICATIONS_DIR/phz-game-$slug.desktop"
            cat > "$file" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$name
Exec=$binary %f
Icon=phz-game-$slug
Categories=X-PhaseZero-Game;
X-PHZ-Group=$group
Terminal=false
StartupNotify=true
EOF
            chmod 0644 "$file"
            echo "  desktop (wrapper): $file"
        else
            # Link existing system .desktop via phz wrapper
            # Parse the existing .desktop to preserve Exec/Icon
            local exec_str icon_str
            exec_str=$(grep -m1 '^Exec=' "$sys_desk_file" | sed 's/^Exec=//' || echo "$binary %f")
            icon_str=$(grep -m1 '^Icon=' "$sys_desk_file" | sed 's/^Icon=//' || echo "phz-game-$slug")

            local file="$APPLICATIONS_DIR/phz-game-$slug.desktop"
            cat > "$file" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$name
Exec=$exec_str
Icon=$icon_str
Categories=X-PhaseZero-Game;
X-PHZ-Group=$group
Terminal=false
StartupNotify=true
EOF
            chmod 0644 "$file"
            echo "  desktop (phz wrapper): $file"
        fi
        return 0
    done
    echo "  ERROR: unknown game '$slug'"
    return 1
}

remove_game() {
    local slug="$1"
    rm -f "$APPLICATIONS_DIR/phz-game-$slug.desktop"
    echo "Removed phz-game-$slug"
}

cmd_install() {
    ensure_dirs
    local slug="$1"
    [ -z "$slug" ] && { echo "Usage: $0 install <slug>"; exit 1; }
    install_game "$slug"
}

cmd_install_all() {
    ensure_dirs
    for entry in "${GAMES[@]}"; do
        IFS=':' read -r slug name binary group desk <<< "$entry"
        echo "Checking $name..."
        install_game "$slug" || true
    done
    cmd_menu
}

cmd_remove() {
    local slug="$1"
    [ -z "$slug" ] && { echo "Usage: $0 remove <slug>"; exit 1; }
    remove_game "$slug"
}

cmd_status() {
    echo "=== Games Status ==="
    printf "%-25s %-30s %-12s %s\n" "SLUG" "NAME" "DETECTED" "DESKTOP"
    for entry in "${GAMES[@]}"; do
        IFS=':' read -r slug name binary _ desk <<< "$entry"
        local detected="no"
        detect_game "$slug" "$binary" "$desk" && detected="yes"
        local installed="no"
        [ -f "$APPLICATIONS_DIR/phz-game-$slug.desktop" ] && installed="yes"
        printf "%-25s %-30s %-12s %s\n" "$slug" "$name" "$detected" "$installed"
    done
}

cmd_scan() {
    echo "=== Scanning for installed games/emulators ==="
    local found=0
    for entry in "${GAMES[@]}"; do
        IFS=':' read -r slug name binary _ desk <<< "$entry"
        if detect_game "$slug" "$binary" "$desk"; then
            echo "  FOUND: $name ($slug)"
            found=$((found+1))
        fi
    done
    echo "Total found: $found"
}

cmd_menu() {
    ensure_dirs

    # Root directory
    cat > "$DIRECTORIES_DIR/phz-games.directory" <<EOF
[Desktop Entry]
Type=Directory
Name=Jogos
Icon=applications-games
EOF

    # Subgroup directories
    for sub_data in "Jogos PC:phz-games-pc.directory:applications-games" \
                    "Emuladores:phz-emulators.directory:applications-games" \
                    "Frontends:phz-frontends.directory:applications-games" \
                    "Ferramentas:phz-gaming-tools.directory:preferences-system"
    do
        IFS=':' read -r sub_name sub_file sub_icon <<< "$sub_data"
        cat > "$DIRECTORIES_DIR/$sub_file" <<EOF
[Desktop Entry]
Type=Directory
Name=$sub_name
Icon=$sub_icon
EOF
    done

    # Build .menu XML
    local menu_file="$MENUS_DIR/phz-games.menu"
    mkdir -p "$(dirname "$menu_file")"

    cat > "$menu_file" <<'MENUEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
<Menu>
  <Name>Jogos</Name>
  <Directory>phz-games.directory</Directory>
  <Include>
    <Category>X-PhaseZero-Game</Category>
  </Include>
MENUEOF

    for sub in "Jogos PC" "Emuladores" "Frontends" "Ferramentas"; do
        local sub_dir
        case "$sub" in
            "Jogos PC")  sub_dir="phz-games-pc.directory" ;;
            "Emuladores") sub_dir="phz-emulators.directory" ;;
            "Frontends") sub_dir="phz-frontends.directory" ;;
            "Ferramentas") sub_dir="phz-gaming-tools.directory" ;;
        esac

        cat >> "$menu_file" <<SUBEOF
  <Menu>
    <Name>$sub</Name>
    <Directory>$sub_dir</Directory>
    <Include>
SUBEOF
        for entry in "${GAMES[@]}"; do
            IFS=':' read -r slug _ _ group _ <<< "$entry"
            if [ "$group" = "$sub" ]; then
                echo "      <Filename>phz-game-$slug.desktop</Filename>" >> "$menu_file"
            fi
        done
        cat >> "$menu_file" <<SUBEOF
    </Include>
  </Menu>
SUBEOF
    done

    echo "</Menu>" >> "$menu_file"
    chmod 0644 "$menu_file"
    echo "Generated $menu_file"
}

main() {
    local cmd="${1:-help}"; shift 2>/dev/null || true
    case "$cmd" in
        install)      cmd_install "$@" ;;
        install-all)  cmd_install_all ;;
        remove)       cmd_remove "$@" ;;
        status)       cmd_status ;;
        scan)         cmd_scan ;;
        menu)         cmd_menu ;;
        help|--help|-h)
            echo "Usage: $0 <command> [slug]"
            echo ""
            echo "Commands:"
            echo "  install <slug>     Create .desktop for game app"
            echo "  install-all        Install .desktop for all detected + menu"
            echo "  remove <slug>      Remove .desktop"
            echo "  status             List games with detection + desktop status"
            echo "  scan               Detect installed games/emulators on system"
            echo "  menu               Generate .directory + .menu XML"
            ;;
        *) echo "Unknown command: $cmd"; exit 1 ;;
    esac
}

main "$@"
