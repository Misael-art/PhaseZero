#!/usr/bin/env bash
# display-session.sh - display/compositor decisions for direct boot sessions

pz_display_dmi_root() {
    printf '%s\n' "${PZ_DISPLAY_DMI_ROOT:-/sys/devices/virtual/dmi/id}"
}

pz_display_sysfs_root() {
    printf '%s\n' "${PZ_DISPLAY_SYSFS_ROOT:-/sys}"
}

pz_display_product_name() {
    local root
    root="$(pz_display_dmi_root)"
    cat "$root/product_name" 2>/dev/null || true
}

pz_display_is_jupiter() {
    [ "$(pz_display_product_name)" = "Jupiter" ]
}

pz_display_is_internal_connector() {
    local connector="$1"
    case "$connector" in
        *eDP*|*edp*|*DSI*|*dsi*|*LVDS*|*lvds*) return 0 ;;
        *) return 1 ;;
    esac
}

pz_display_connected_external_connectors() {
    local root status_path connector status
    root="$(pz_display_sysfs_root)"
    for status_path in "$root"/class/drm/card*-*/status; do
        [ -f "$status_path" ] || continue
        connector="$(basename "$(dirname "$status_path")")"
        pz_display_is_internal_connector "$connector" && continue
        status="$(cat "$status_path" 2>/dev/null || true)"
        [ "$status" = "connected" ] && printf '%s\n' "$connector"
    done | sort -V
}

pz_display_connected_internal_connector() {
    local root status_path connector status
    root="$(pz_display_sysfs_root)"
    for status_path in "$root"/class/drm/card*-*/status; do
        [ -f "$status_path" ] || continue
        connector="$(basename "$(dirname "$status_path")")"
        pz_display_is_internal_connector "$connector" || continue
        status="$(cat "$status_path" 2>/dev/null || true)"
        [ "$status" = "connected" ] && printf '%s\n' "$connector"
    done | sort -V | head -n1
}

pz_display_external_connectors_csv() {
    local connector out=""
    while IFS= read -r connector; do
        [ -n "$connector" ] || continue
        out="${out:+$out,}$connector"
    done < <(pz_display_connected_external_connectors)
    printf '%s\n' "$out"
}

pz_display_profile() {
    if pz_display_is_jupiter; then
        if [ -z "$(pz_display_external_connectors_csv)" ]; then
            printf '%s\n' "steamdeck-lcd-handheld"
        else
            printf '%s\n' "steamdeck-docked"
        fi
        return 0
    fi
    printf '%s\n' "generic"
}

# Native resolution of a connector from its first (preferred) sysfs mode.
# Returns "W H" or empty when modes are unavailable.
pz_display_native_resolution() {
    local connector="$1" root modes
    case "$connector" in
        ""|*[!A-Za-z0-9_.:-]*) return 0 ;;
    esac
    root="$(pz_display_sysfs_root)"
    modes="$root/class/drm/$connector/modes"
    [ -f "$modes" ] || return 0
    local first
    first="$(head -n1 "$modes" 2>/dev/null || true)"
    [ -n "$first" ] || return 0
    printf '%s\n' "$first" | sed -nE 's/^([0-9]+)x([0-9]+).*/\1 \2/p'
}

pz_display_kde_output_config() {
    printf '%s\n' "${PZ_DISPLAY_KDE_OUTPUT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/kwinoutputconfig.json}"
}

# Resolve the physical mode KDE saved for the monitor currently connected to a
# DRM connector. KWin keeps historical entries with the same connector name, so
# connector name alone is unsafe: match the connected panel's EDID hash.
pz_display_kde_resolution() {
    local connector="$1" connector_name root edid_path edid_hash config resolution
    case "$connector" in
        ""|*[!A-Za-z0-9_.:-]*) return 0 ;;
    esac
    command -v jq >/dev/null 2>&1 || return 0
    command -v md5sum >/dev/null 2>&1 || return 0

    root="$(pz_display_sysfs_root)"
    edid_path="$root/class/drm/$connector/edid"
    # sysfs reports EDID files with st_size=0 even when reads return data.
    [ -r "$edid_path" ] || return 0
    edid_hash="$(md5sum "$edid_path" 2>/dev/null | awk '{print $1}')"
    [ -n "$edid_hash" ] || return 0

    config="$(pz_display_kde_output_config)"
    [ -r "$config" ] || return 0
    connector_name="${connector#card*-}"
    resolution="$(jq -er \
        --arg connector "$connector_name" \
        --arg edid "$edid_hash" \
        '[.[] | select(.name == "outputs") | .data[] |
          select(.connectorName == $connector and .edidHash == $edid) |
          .mode | select((.width | type) == "number" and (.height | type) == "number") |
          "\(.width) \(.height)"] | .[0] // empty' \
        "$config" 2>/dev/null || true)"
    [ -n "$resolution" ] && printf '%s\n' "$resolution"
}

pz_display_valid_dimension() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 320 ] && [ "$value" -le 16384 ]
}

pz_display_valid_connector() {
    local value="$1"
    [[ "$value" =~ ^\*,[A-Za-z0-9_.:-]+$ ]]
}

# Resolve the gamescope-session-plus output vars for the current connector state.
# Handheld (no external connector) -> the Deck LCD logical size and eDP-1.
# Docked -> the first external connector's native mode, preferring that output.
# Prints three lines: SCREEN_WIDTH, SCREEN_HEIGHT, OUTPUT_CONNECTOR.
pz_display_resolved_session_vars() {
    local first_ext width height connector internal
    first_ext="$(pz_display_connected_external_connectors | head -n1 || true)"
    if [ -z "$first_ext" ]; then
        width="${PZ_STEAMDECK_LCD_LOGICAL_WIDTH:-1280}"
        height="${PZ_STEAMDECK_LCD_LOGICAL_HEIGHT:-800}"
        pz_display_valid_dimension "$width" || width=1280
        pz_display_valid_dimension "$height" || height=800
        internal="$(pz_display_connected_internal_connector || true)"
        internal="${internal#card*-}"
        connector="*,${internal:-eDP-1}"
        pz_display_valid_connector "$connector" || connector='*,eDP-1'
        printf '%s\n%s\n%s\n' "$width" "$height" "$connector"
        return 0
    fi
    local configured native w h
    configured="$(pz_display_kde_resolution "$first_ext" || true)"
    native="$(pz_display_native_resolution "$first_ext" || true)"
    if [ -n "$configured" ]; then
        w="${configured%% *}"
        h="${configured##* }"
    elif [ -n "$native" ]; then
        w="${native%% *}"
        h="${native##* }"
    else
        # modes unavailable (e.g. EDID unreadable) -> safe 1080p docked fallback.
        w=1920; h=1080
    fi
    # Strip the cardN- prefix so OUTPUT_CONNECTOR matches the connector name
    # gamescope expects (DP-1, HDMI-A-1, ...).
    local conn="${first_ext#card*-}"
    pz_display_valid_dimension "$w" || w=1920
    pz_display_valid_dimension "$h" || h=1080
    pz_display_valid_connector "*,$conn" || conn="DP-1"
    printf '%s\n%s\n%s\n' "$w" "$h" "*,$conn"
}

pz_display_status() {
    local profile ext w h conn
    local -a session_vars=()
    profile="$(pz_display_profile)"
    ext="$(pz_display_external_connectors_csv)"
    mapfile -t session_vars < <(pz_display_resolved_session_vars)
    w="${session_vars[0]:-1280}"
    h="${session_vars[1]:-800}"
    conn="${session_vars[2]:-*,eDP-1}"
    jq -n \
        --arg profile "$profile" \
        --arg externalConnectors "$ext" \
        --arg width "$w" \
        --arg height "$h" \
        --arg connector "$conn" \
        '{displayProfile: $profile, externalConnectors: $externalConnectors,
          screenWidth: $width, screenHeight: $height, outputConnector: $connector}'
}

pz_display_gamescope_orientation() {
    printf '%s\n' "${PZ_STEAMDECK_LCD_ORIENTATION:-right}"
}

pz_display_gamescope_width() {
    printf '%s\n' "${PZ_STEAMDECK_LCD_LOGICAL_WIDTH:-1280}"
}

pz_display_gamescope_height() {
    printf '%s\n' "${PZ_STEAMDECK_LCD_LOGICAL_HEIGHT:-800}"
}

pz_display_shell_join() {
    local out="" arg
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        out="${out:+$out }$arg"
    done
    printf '%s\n' "$out"
}

pz_display_gamescope_command() {
    local target="$1"
    shift || true
    pz_display_shell_join \
        dbus-run-session -- env "$@" gamescope \
        --backend drm \
        --expose-wayland \
        --force-orientation "$(pz_display_gamescope_orientation)" \
        -W "$(pz_display_gamescope_width)" \
        -H "$(pz_display_gamescope_height)" \
        -w "$(pz_display_gamescope_width)" \
        -h "$(pz_display_gamescope_height)" \
        --force-windows-fullscreen \
        -- "$target"
}

# Subcommand dispatch for `pz steamdeck display`.
# This file is normally sourced for its helpers; when executed directly it acts
# as a status/detect reporter (no runtime apply — resolution is boot-time).
pz_display_main() {
    local action="${1:-status}"
    case "$action" in
        status|json)
            pz_display_status
            ;;
        detect)
            local profile ext w h c
            local -a session_vars=()
            profile="$(pz_display_profile)"
            ext="$(pz_display_external_connectors_csv)"
            printf 'profile: %s\n' "$profile"
            [ -n "$ext" ] && printf 'external connectors: %s\n' "$ext"
            mapfile -t session_vars < <(pz_display_resolved_session_vars)
            w="${session_vars[0]:-1280}"
            h="${session_vars[1]:-800}"
            c="${session_vars[2]:-*,eDP-1}"
            printf 'screen_width: %s\nscreen_height: %s\noutput_connector: %s\n' "$w" "$h" "$c"
            printf 'note: resolution applies at Game Mode boot (steam-plus session drop-in)\n'
            ;;
        *)
            printf 'usage: pz steamdeck display (status|detect)\n' >&2
            return 1
            ;;
    esac
}

# Run the dispatch when executed directly (pz steamdeck display).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    pz_display_main "$@"
fi
