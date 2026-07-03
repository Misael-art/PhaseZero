#!/usr/bin/env bash
# steamdeck/common.sh - shared functions for Steam Deck automations
set -euo pipefail

# paths
STEAMDECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hardware constants (Valve Jupiter / AMD VanGogh)
AMDGPU_VENDOR="0x1002"
GPU_PCI="0000:04:00.0"

steamdeck_is_jupiter() {
    local product
    product=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
    [ "$product" = "Jupiter" ]
}

steamdeck_display_connected() {
    local connector="$1"
    local path="/sys/class/drm/${connector}/status"
    [ -f "$path" ] && [ "$(cat "$path")" = "connected" ]
}

steamdeck_is_internal_connector() {
    local connector="$1"
    case "$connector" in
        *eDP*|*DSI*|*LVDS*) return 0 ;;
        *) return 1 ;;
    esac
}

steamdeck_list_connected_external_connectors() {
    local status_path connector
    for status_path in /sys/class/drm/card*-*/status; do
        [ -f "$status_path" ] || continue
        connector="$(basename "$(dirname "$status_path")")"
        steamdeck_is_internal_connector "$connector" && continue
        [ "$(cat "$status_path" 2>/dev/null || true)" = "connected" ] && echo "$connector"
    done
}

steamdeck_connector_looks_like_tv() {
    local connector="$1"
    local edid="/sys/class/drm/${connector}/edid"
    [ -f "$edid" ] || return 1
    strings "$edid" 2>/dev/null | grep -qi "television\|tv\|samsung\|lg\|sony\|tcl\|hisense\|vizio"
}

steamdeck_run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
        return $?
    fi

    [ "${PZ_STEAMDECK_USE_SUDO:-0}" = "1" ] || return 1

    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
        return $?
    fi

    return 1
}

steamdeck_write_value() {
    local path="$1" value="$2" label="${3:-$1}"

    [ -e "$path" ] || return 0

    if [ -w "$path" ]; then
        printf '%s\n' "$value" > "$path" 2>/dev/null || true
        return 0
    fi

    if steamdeck_run_privileged tee "$path" >/dev/null 2>&1 <<< "$value"; then
        return 0
    fi

    pz_warn "$label requires root; skipped non-interactive write"
    return 1
}

steamdeck_apply_privileged_mode() {
    local mode="$1"
    local helper="${PZ_STEAMDECK_PRIVILEGED_HELPER:-/usr/local/lib/phasezero/steamdeck-privileged-control}"

    [ "${PZ_STEAMDECK_USE_SUDO:-auto}" = "0" ] && return 1
    [ -x "$helper" ] || return 1
    if [ "$EUID" -ne 0 ] && { ! command -v sudo >/dev/null 2>&1 || ! sudo -n "$helper" status >/dev/null 2>&1; }; then
        return 1
    fi

    if { [ "$EUID" -eq 0 ] && "$helper" apply "$mode"; } ||
        { [ "$EUID" -ne 0 ] && sudo -n "$helper" apply "$mode"; }; then
        pz_info "privileged mode controls applied: $mode"
        return 0
    fi

    return 1
}

steamdeck_detect_mode() {
    local connector
    connector="$(steamdeck_list_connected_external_connectors | head -1)"
    if [ -z "$connector" ]; then
        echo "handheld"
        return 0
    fi

    if steamdeck_connector_looks_like_tv "$connector"; then
        echo "docked-tv"
    else
        echo "docked-monitor"
    fi
}

steamdeck_set_tdp() {
    local watts="$1"
    if command -v ryzenadj &>/dev/null; then
        local mw
        if [[ "$watts" =~ ^[0-9]+$ ]]; then
            mw=$((watts * 1000))
        elif command -v bc &>/dev/null; then
            mw=$(echo "$watts * 1000" | bc | cut -d. -f1)
        else
            pz_warn "bc not installed, cannot convert fractional TDP"
            return 0
        fi
        steamdeck_run_privileged ryzenadj --stapm-limit="$mw" --fast-limit="$mw" --slow-limit="$mw" --tctl-temp=85 2>/dev/null && \
            pz_info "TDP set to ${watts}W" || pz_warn "ryzenadj failed"
    else
        pz_warn "ryzenadj not installed, cannot set TDP"
    fi
}

steamdeck_set_gpu_profile() {
    local profile="$1" # powersave, auto, high
    local gpu_path="/sys/class/drm/card1/device/power_dpm_force_performance_level"
    if [ -e "$gpu_path" ]; then
        if steamdeck_write_value "$gpu_path" "$profile" "GPU performance profile"; then
            pz_info "GPU profile set to $profile"
        fi
    fi
    return 0
}

steamdeck_set_refresh_rate() {
    local rate="$1" # 48, 60, etc
    local connector="${2:-eDP-1}"
    if command -v xrandr &>/dev/null; then
        xrandr --output "$connector" --rate "$rate" 2>/dev/null || true
        pz_info "refresh rate set to ${rate}Hz on $connector"
    elif command -v wlr-randr &>/dev/null; then
        wlr-randr --output "$connector" --mode "${rate}Hz" 2>/dev/null || true
    fi
}

steamdeck_set_screen_brightness() {
    local pct="$1"
    local backlight="/sys/class/backlight/amdgpu_bl1/brightness"
    local max="/sys/class/backlight/amdgpu_bl1/max_brightness"
    if [ -f "$max" ]; then
        local max_val
        max_val=$(cat "$max")
        local val
        val=$(( pct * max_val / 100 ))
        if steamdeck_write_value "$backlight" "$val" "screen brightness"; then
            pz_info "brightness set to ${pct}%"
        fi
    fi
    return 0
}

steamdeck_set_power_profile() {
    local profile="$1" # power-saver, balanced, performance
    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set "$profile" 2>/dev/null || true
    elif [ -f "/sys/firmware/acpi/platform_profile" ]; then
        steamdeck_write_value /sys/firmware/acpi/platform_profile "$profile" "ACPI platform profile"
    fi
    pz_info "power profile set to $profile"
}

steamdeck_set_kbd_backlight() {
    local pct="$1"
    local kbd_path="/sys/class/leds/platform::kbd_backlight/brightness"
    if [ -e "$kbd_path" ]; then
        local val=$(( pct * 3 / 100 )) # 0-3 range
        steamdeck_write_value "$kbd_path" "$val" "keyboard backlight" || true
    fi
}

steamdeck_apply_mode() {
    local mode="$1"
    local privileged_applied=0
    pz_info "applying Steam Deck mode: $mode"
    steamdeck_apply_privileged_mode "$mode" && privileged_applied=1
    case "$mode" in
        handheld)
            if [ "$privileged_applied" -ne 1 ]; then
                steamdeck_set_tdp 9
                steamdeck_set_gpu_profile low
            fi
            steamdeck_set_refresh_rate 60 "eDP-1"
            steamdeck_set_power_profile power-saver
            steamdeck_set_kbd_backlight 100
            pz_info "handheld mode applied: 9W TDP, GPU low, 60Hz"
            ;;
        docked-tv)
            if [ "$privileged_applied" -ne 1 ]; then
                steamdeck_set_tdp 15
                steamdeck_set_gpu_profile auto
            fi
            steamdeck_set_power_profile balanced
            steamdeck_set_kbd_backlight 0
            pz_info "docked TV mode applied: 15W TDP, GPU auto, kbd backlight off"
            ;;
        docked-monitor)
            if [ "$privileged_applied" -ne 1 ]; then
                steamdeck_set_tdp 15
                steamdeck_set_gpu_profile auto
            fi
            steamdeck_set_power_profile balanced
            steamdeck_set_kbd_backlight 0
            pz_info "docked monitor mode applied: 15W TDP, GPU auto"
            ;;
    esac
}

steamdeck_apply_handheld() { steamdeck_apply_mode "handheld"; }
steamdeck_apply_docked_tv() { steamdeck_apply_mode "docked-tv"; }
steamdeck_apply_docked_monitor() { steamdeck_apply_mode "docked-monitor"; }

steamdeck_mode_watcher() {
    local poll_seconds="${PZ_STEAMDECK_POLL_SECONDS:-5}"
    local stable_samples="${PZ_STEAMDECK_STABLE_SAMPLES:-2}"
    local cooldown_seconds="${PZ_STEAMDECK_COOLDOWN_SECONDS:-10}"
    local candidate_mode="" candidate_count=0 last_applied="" last_applied_at=0

    pz_info "starting mode-watcher (poll ${poll_seconds}s, stable samples ${stable_samples}, cooldown ${cooldown_seconds}s)..."
    while true; do
        local current
        current=$(steamdeck_detect_mode)

        if [ "$current" = "$candidate_mode" ]; then
            candidate_count=$((candidate_count + 1))
        else
            candidate_mode="$current"
            candidate_count=1
        fi

        local now
        now=$(date +%s)
        if [ "$candidate_count" -ge "$stable_samples" ] &&
            [ "$current" != "$last_applied" ] &&
            [ $((now - last_applied_at)) -ge "$cooldown_seconds" ]; then
            pz_info "mode change detected: ${last_applied:-none} -> $current"
            steamdeck_apply_mode "$current"
            last_applied="$current"
            last_applied_at="$now"
        fi

        sleep "$poll_seconds"
    done
}

# Auto-execute mode detection if script is sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-detect}" in
        detect) steamdeck_detect_mode ;;
        handheld) steamdeck_apply_handheld ;;
        docked-tv) steamdeck_apply_docked_tv ;;
        docked-monitor) steamdeck_apply_docked_monitor ;;
        watch) steamdeck_mode_watcher ;;
    esac
fi
