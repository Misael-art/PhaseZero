#!/usr/bin/env bash
# privileged-control.sh - root-only Steam Deck power controls with strict mode validation
set -euo pipefail

usage() {
    echo "usage: privileged-control.sh (apply <handheld|docked-tv|docked-monitor>|status)"
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "root required" >&2
        exit 1
    fi
}

tdp_watts_for_mode() {
    case "$1" in
        handheld) echo 9 ;;
        docked-tv|docked-monitor) echo 15 ;;
        *) return 1 ;;
    esac
}

gpu_profile_for_mode() {
    case "$1" in
        handheld) echo low ;;
        docked-tv|docked-monitor) echo auto ;;
        *) return 1 ;;
    esac
}

find_gpu_dpm_path() {
    local path
    for path in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        [ -e "$path" ] || continue
        echo "$path"
        return 0
    done
    return 1
}

apply_tdp() {
    local watts="$1" mw
    command -v ryzenadj >/dev/null 2>&1 || return 0
    mw=$((watts * 1000))
    ryzenadj --stapm-limit="$mw" --fast-limit="$mw" --slow-limit="$mw" --tctl-temp=85 >/dev/null 2>&1 || {
        echo "ryzenadj failed" >&2
        return 1
    }
}

apply_gpu_profile() {
    local profile="$1" path
    path="$(find_gpu_dpm_path || true)"
    [ -n "$path" ] || return 0
    printf '%s\n' "$profile" > "$path"
}

apply_mode() {
    local mode="$1" watts gpu_profile
    case "$mode" in
        handheld|docked-tv|docked-monitor) ;;
        *) echo "invalid mode: $mode" >&2; exit 2 ;;
    esac

    require_root
    watts="$(tdp_watts_for_mode "$mode")"
    gpu_profile="$(gpu_profile_for_mode "$mode")"
    apply_tdp "$watts"
    apply_gpu_profile "$gpu_profile"
    echo "applied privileged controls: mode=$mode tdp=${watts}W gpu=$gpu_profile"
}

status() {
    echo "helper: $0"
    echo "root: $([ "$EUID" -eq 0 ] && echo yes || echo no)"
    command -v ryzenadj >/dev/null 2>&1 && echo "ryzenadj: $(command -v ryzenadj)" || echo "ryzenadj: missing"
    local path
    path="$(find_gpu_dpm_path || true)"
    echo "gpu_dpm_path: ${path:-missing}"
    [ -n "$path" ] && echo "gpu_dpm_value: $(cat "$path" 2>/dev/null || echo unreadable)"
}

case "${1:-}" in
    apply) [ -n "${2:-}" ] || { usage; exit 2; }; apply_mode "$2" ;;
    status) status ;;
    *) usage; exit 2 ;;
esac
