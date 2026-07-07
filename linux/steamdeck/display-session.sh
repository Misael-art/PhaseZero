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
        *eDP*|*DSI*|*LVDS*) return 0 ;;
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
    done
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
