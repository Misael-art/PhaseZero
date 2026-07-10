#!/usr/bin/env bash
# webapp.sh - PhaseZero Web App desktop shortcuts
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons"
DIRECTORIES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/desktop-directories"
MENUS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/menus/applications-merged"
WEBAPP_ICONS="$PZ_ROOT/assets/webapp-icons"

# Fields: slug|display name|url|group|icon_source
# Pipe separator avoids conflicts with :// in URLs
WEBAPPS=(
    "discord|Discord|https://discord.com/app|Comunicação|simpleicons"
    "slack|Slack|https://slack.com|Comunicação|ico"
    "whatsapp|WhatsApp|https://web.whatsapp.com|Comunicação|simpleicons"
    "telegram|Telegram|https://web.telegram.org|Comunicação|simpleicons"
    "zoom|Zoom|https://zoom.us|Comunicação|simpleicons"
    "netflix|Netflix|https://netflix.com|Mídia|simpleicons"
    "youtube|YouTube|https://youtube.com|Mídia|simpleicons"
    "spotify|Spotify|https://open.spotify.com|Mídia|simpleicons"
    "amazon-prime-video|Amazon Prime Video|https://primevideo.com|Mídia|ico"
    "photopea|Photopea|https://photopea.com|Mídia|simpleicons"
    "gemini|Gemini|https://gemini.google.com|IA|ico"
    "kimi|Kimi|https://kimi.com|IA|ico"
    "z-ai|Z.ai|https://chat.z.ai|IA|ico"
    "manus|Manus|https://manus.im|IA|ico"
    "google-ai-studio|Google AI Studio|https://aistudio.google.com|IA|ico"
    "xiaomi-ai-studio|Xiaomi AI Studio|https://aistudio.xiaomimimo.com|IA|simpleicons"
    "v0-dev|v0.dev|https://v0.dev|IA|simpleicons"
    "lovable-dev|Lovable.dev|https://lovable.dev|IA|ico"
    "bolt-new|Bolt.new|https://bolt.new|IA|ico"
    "google-drive|Google Drive|https://drive.google.com|Nuvem & Docs|simpleicons"
    "google-docs|Google Docs|https://docs.google.com|Nuvem & Docs|simpleicons"
    "google-sheets|Google Sheets|https://sheets.google.com|Nuvem & Docs|simpleicons"
    "google-slides|Google Slides|https://slides.google.com|Nuvem & Docs|simpleicons"
    "gmail|Gmail|https://mail.google.com|Nuvem & Docs|simpleicons"
    "google-agenda|Google Agenda|https://calendar.google.com|Nuvem & Docs|simpleicons"
    "google-keep|Google Keep|https://keep.google.com|Nuvem & Docs|simpleicons"
    "google-meet|Google Meet|https://meet.google.com|Nuvem & Docs|simpleicons"
    "icloud|iCloud|https://icloud.com|Nuvem & Docs|simpleicons"
    "onedrive|OneDrive|https://onedrive.live.com|Nuvem & Docs|ico"
    "dropbox|Dropbox|https://dropbox.com|Nuvem & Docs|simpleicons"
    "mega|MEGA|https://mega.nz|Nuvem & Docs|simpleicons"
    "notion|Notion|https://notion.so|Produtividade|simpleicons"
    "trello|Trello|https://trello.com|Produtividade|simpleicons"
    "office-word|Office Word|https://www.office.com|Produtividade|ico"
    "office-excel|Office Excel|https://www.office.com|Produtividade|ico"
    "office-powerpoint|Office PowerPoint|https://www.office.com|Produtividade|ico"
)

# Map slug to SimpleIcons name (some differ)
simpleicons_name() {
    case "$1" in
        whatsapp) echo "whatsapp";;
        telegram) echo "telegram";;
        google-docs) echo "googledocs";;
        google-sheets) echo "googlesheets";;
        google-slides) echo "googleslides";;
        google-agenda) echo "googlecalendar";;
        google-keep) echo "googlekeep";;
        google-drive) echo "googledrive";;
        google-meet) echo "googlemeet";;
        v0-dev) echo "v0";;
        xiaomi-ai-studio) echo "xiaomi";;
        *) echo "$1";;
    esac
}

# Find webapp entry by slug
find_webapp() {
    local slug="$1" entry
    for entry in "${WEBAPPS[@]}"; do
        if [ "${entry%%|*}" = "$slug" ]; then
            echo "$entry"
            return 0
        fi
    done
    return 1
}

ensure_dirs() {
    mkdir -p "$APPLICATIONS_DIR" "$ICONS_DIR" "$DIRECTORIES_DIR" "$MENUS_DIR"
}

download_icon() {
    local slug="$1" icon_source="${2:-simpleicons}" ico_file
    ico_file="$WEBAPP_ICONS/$slug.ico"
    local si_name; si_name="$(simpleicons_name "$slug")"
    local svg_dest="$ICONS_DIR/hicolor/scalable/apps/phz-$slug.svg"
    local png_dest="$ICONS_DIR/hicolor/256x256/apps/phz-$slug.png"
    local svg_tmp

    mkdir -p "$(dirname "$svg_dest")" "$(dirname "$png_dest")"

    # Prefer bundled ICO where catalog requests it; parse in a subprocess and
    # pass paths as argv so unusual HOME paths cannot become Python source.
    if [ "$icon_source" = "ico" ] && [ -f "$ico_file" ]; then
        if python3 - "$ico_file" "$png_dest" <<'PY' >/dev/null 2>&1
from PIL import Image
import sys
try:
    img = Image.open(sys.argv[1])
    img.verify()
    img = Image.open(sys.argv[1])
    img = img.resize((256, 256), Image.LANCZOS)
    img.save(sys.argv[2], 'PNG')
except Exception as e:
    print(f'FAIL: {e}', file=sys.stderr)
    sys.exit(1)
PY
        then
            echo "  icon: PNG 256px (from ICO)"
            return 0
        fi
    fi

    # SimpleIcons endpoint is fixed; validate bounded passive SVG before use.
    svg_tmp="$(mktemp "${svg_dest}.tmp.XXXXXX")"
    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
        "https://cdn.simpleicons.org/$si_name" -o "$svg_tmp" 2>/dev/null &&
        grep -q '<svg' "$svg_tmp" &&
        ! grep -Eqi '<script|<foreignObject|on[a-z]+[[:space:]]*=|href[[:space:]]*=|url[[:space:]]*\(' "$svg_tmp"; then
        mv "$svg_tmp" "$svg_dest"
        chmod 0644 "$svg_dest"
        echo "  icon: SVG simpleicons/$si_name"
        return 0
    fi
    rm -f "$svg_tmp"

    echo "  icon: MISSING (no SimpleIcons SVG or ICO for $slug)"
    return 1
}

write_desktop() {
    local slug="$1" name="$2" url="$3" group="$4"
    local file="$APPLICATIONS_DIR/phz-$slug.desktop"
    cat > "$file" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$name Web App
Exec=xdg-open $url
Icon=phz-$slug
Categories=X-PhaseZero-WebApp;
X-PHZ-Group=$group
Terminal=false
StartupNotify=true
EOF
    chmod 0644 "$file"
    echo "  desktop: $file"
}

install_webapp() {
    local slug="$1" entry name url group icon_source
    entry="$(find_webapp "$slug")" || { echo "ERROR: unknown webapp '$slug'"; return 1; }
    IFS='|' read -r slug name url group icon_source <<< "$entry"

    echo "Installing $name ($slug)..."
    download_icon "$slug" "$icon_source" || true
    write_desktop "$slug" "$name" "$url" "$group"
    echo ""
}

remove_webapp() {
    local slug="$1"
    rm -f "$APPLICATIONS_DIR/phz-$slug.desktop"
    rm -f "$ICONS_DIR/hicolor/scalable/apps/phz-$slug.svg"
    rm -f "$ICONS_DIR/hicolor/256x256/apps/phz-$slug.png"
    for size in 16 32 48 64 128 256 512; do
        rm -f "$ICONS_DIR/${size}x${size}/apps/phz-$slug.png"
        rm -f "$ICONS_DIR/${size}x${size}/apps/phz-$slug.svg"
    done
    echo "Removed $slug"
}

cmd_install() {
    ensure_dirs
    local slug="$1"
    if [ -z "$slug" ]; then
        echo "Usage: $0 install <slug>"
        exit 1
    fi
    install_webapp "$slug"
}

cmd_install_all() {
    ensure_dirs
    for entry in "${WEBAPPS[@]}"; do
        local slug="${entry%%|*}"
        install_webapp "$slug"
    done
    cmd_menu
}

cmd_remove() {
    local slug="$1"
    [ -z "$slug" ] && { echo "Usage: $0 remove <slug>"; exit 1; }
    remove_webapp "$slug"
}

cmd_status() {
    echo "=== Web Apps Status ==="
    printf "%-25s %-20s %-12s %s\n" "SLUG" "NAME" "INSTALLED" "ICON"
    for entry in "${WEBAPPS[@]}"; do
        IFS='|' read -r slug name _ group _ <<< "$entry"
        local installed="no"; [ -f "$APPLICATIONS_DIR/phz-$slug.desktop" ] && installed="yes"
        local icon=""; [ -f "$ICONS_DIR/hicolor/scalable/apps/phz-$slug.svg" ] && icon="svg"
        [ -z "$icon" ] && [ -f "$ICONS_DIR/hicolor/256x256/apps/phz-$slug.png" ] && icon="png"
        [ -z "$icon" ] && icon="-"
        printf "%-25s %-20s %-12s %s\n" "$slug" "$name" "$installed" "$icon"
    done
}

cmd_icons() {
    ensure_dirs
    echo "Downloading/converting icons..."
    local ok=0 fail=0
    for entry in "${WEBAPPS[@]}"; do
        local slug="${entry%%|*}"
        local icon_source
        icon_source="${entry##*|}"
        if download_icon "$slug" "$icon_source"; then
            ok=$((ok+1))
        else
            fail=$((fail+1))
        fi
    done
    echo "Done: $ok OK, $fail failed"
}

write_directory() {
    local dir_name="$1" dir_file="$2" icon="$3"
    local file="$DIRECTORIES_DIR/$dir_file"
    cat > "$file" <<EOF
[Desktop Entry]
Type=Directory
Name=$dir_name
Icon=$icon
EOF
    chmod 0644 "$file"
}

cmd_menu() {
    ensure_dirs

    # Root directory
    write_directory "Web Apps" "phz-webapps.directory" "applications-internet"

    # Subgroup directories
    write_directory "Comunicação"  "phz-communication.directory" "applications-internet"
    write_directory "Mídia"        "phz-media.directory"        "applications-multimedia"
    write_directory "IA"           "phz-ai.directory"           "applications-science"
    write_directory "Nuvem & Docs" "phz-cloud.directory"        "folder-remote"
    write_directory "Produtividade" "phz-productivity.directory" "office-applications"

    # Build .menu XML with submenus
    local menu_file="$MENUS_DIR/phz-webapps.menu"
    mkdir -p "$(dirname "$menu_file")"

    cat > "$menu_file" <<'MENUEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
<Menu>
  <Name>Web Apps</Name>
  <Directory>phz-webapps.directory</Directory>
  <Include>
    <Category>X-PhaseZero-WebApp</Category>
  </Include>
MENUEOF

    for sub in "Comunicação" "Mídia" "IA" "Nuvem & Docs" "Produtividade"; do
        local sub_dir sub_xml="$sub"
        case "$sub" in
            "Comunicação")  sub_dir="phz-communication.directory" ;;
            "Mídia")        sub_dir="phz-media.directory" ;;
            "IA")           sub_dir="phz-ai.directory" ;;
            "Nuvem & Docs") sub_dir="phz-cloud.directory" ;;
            "Produtividade") sub_dir="phz-productivity.directory" ;;
        esac
        [ "$sub" = "Nuvem & Docs" ] && sub_xml="Nuvem &amp; Docs"

        cat >> "$menu_file" <<SUBEOF
  <Menu>
    <Name>$sub_xml</Name>
    <Directory>$sub_dir</Directory>
    <Include>
SUBEOF
        for entry in "${WEBAPPS[@]}"; do
            IFS='|' read -r slug _ _ group _ <<< "$entry"
            if [ "$group" = "$sub" ]; then
                echo "      <Filename>phz-$slug.desktop</Filename>" >> "$menu_file"
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
        icons)        cmd_icons ;;
        menu)         cmd_menu ;;
        help|--help|-h)
            echo "Usage: $0 <command> [slug]"
            echo ""
            echo "Commands:"
            echo "  install <slug>     Create .desktop + icon for webapp"
            echo "  install-all        Install all webapps + menu"
            echo "  remove <slug>      Remove .desktop + icon"
            echo "  status             List installed webapps"
            echo "  icons              Download/convert all icons"
            echo "  menu               Generate .directory + .menu XML"
            ;;
        *) echo "Unknown command: $cmd"; exit 1 ;;
    esac
}

main "$@"
