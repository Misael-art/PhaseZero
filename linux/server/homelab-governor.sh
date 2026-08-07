#!/usr/bin/env bash
# homelab-governor.sh - resource governor for the PhaseZero homelab appliance.
#
# Reads the profile registry (assets/home-server/homelab-profiles.json) and
# computes a memory budget for a profile against available RAM. The verdict
# fails closed: any unknown profile, unreadable registry, or overcommit means
# the check returns non-zero so bring-up can gate on it.
#
# RAM is read from /proc/meminfo unless PZ_HOMELAB_RAM_TOTAL_OVERRIDE (MiB) is
# set, which keeps hermetically-testable environments deterministic.
#
#   homelab-governor.sh list
#   homelab-governor.sh weights [--json]
#   homelab-governor.sh budget <profile> [--headroom PCT]
#   homelab-governor.sh check <profile> [--headroom PCT]
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

COMPOSE_DIR="${PZ_HOMELAB_COMPOSE_DIR:-$PZ_ROOT/assets/home-server}"
REGISTRY_FILE="${PZ_HOMELAB_PROFILES_FILE:-$COMPOSE_DIR/homelab-profiles.json}"

SCHEMA_VERSION="1"

# pz_governor_registry -> registry JSON (fails closed on missing/invalid)
pz_governor_registry() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        pz_error "profile registry missing: $REGISTRY_FILE"
        return 2
    fi
    if ! jq -e '.schemaVersion == 1 and (.profiles | type == "array")' "$REGISTRY_FILE" >/dev/null 2>&1; then
        pz_error "profile registry invalid: $REGISTRY_FILE"
        return 2
    fi
    cat "$REGISTRY_FILE"
}

pz_governor_available_mb() {
    if [ -n "${PZ_HOMELAB_RAM_TOTAL_OVERRIDE:-}" ]; then
        printf '%s\n' "$PZ_HOMELAB_RAM_TOTAL_OVERRIDE"
        return 0
    fi
    awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null \
        || { pz_error "cannot read total RAM"; return 1; }
}

# pz_governor_budget <profile> [headroom] -> budget JSON
pz_governor_budget() {
    local profile="${1:?profile required}" headroom="${2:-20}"
    local reg base used=0 total available verdict reasons="[]"
    reg="$(pz_governor_registry)" || return $?
    if ! jq -e --arg k "$profile" '[.profiles[].key] | index($k) != null' <<< "$reg" >/dev/null 2>&1; then
        pz_error "unknown homelab profile: $profile"
        return 2
    fi
    base="$(jq -r '.coreBaseMB' <<< "$reg")"
    used="$(jq -r --arg k "$profile" \
        '(.weightsMB) as $w | [.profiles[] | select(.key == $k) | .services[] as $s | $w[$s] // 0] | add // 0' \
        <<< "$reg")"
    total=$((base + used))
    available="$(pz_governor_available_mb)" || return $?
    local usable=$(( available - available * headroom / 100 ))
    if [ "$total" -le "$usable" ]; then
        verdict="pass"
    else
        verdict="fail"
        reasons="$(jq -cn --argjson total "$total" --argjson usable "$usable" --argjson headroom "$headroom" \
            --arg profile "$profile" \
            '["profile overcommits memory: budget \($total) MiB > usable \($usable) MiB (headroom \($headroom)%)"]')"
    fi
    local title
    title="$(jq -r --arg k "$profile" '[.profiles[] | select(.key == $k) | .title] | .[0]' <<< "$reg")"
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --arg tool "homelab-governor" \
        --arg profile "$profile" \
        --arg profileTitle "$title" \
        --argjson coreBaseMB "$base" \
        --argjson serviceMB "$used" \
        --argjson budgetMB "$total" \
        --argjson availableMB "$available" \
        --argjson headroomPct "$headroom" \
        --arg verdict "$verdict" \
        --argjson reasons "$reasons" \
        '{schemaVersion:$schemaVersion, tool:$tool, profile:$profile, profileTitle:$profileTitle,
          coreBaseMB:$coreBaseMB, serviceMB:$serviceMB, budgetMB:$budgetMB,
          availableMB:$availableMB, headroomPct:$headroomPct, verdict:$verdict, reasons:$reasons}'
}

pz_governor_list_json() {
    local reg
    reg="$(pz_governor_registry)" || return $?
    local def
    def="$(jq -r '.default' <<< "$reg")"
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --arg default "$def" \
        --argjson profiles "$(jq -c '[.profiles[] | {key, title, description, extras, services}]' <<< "$reg")" \
        '{schemaVersion:$schemaVersion, tool:"homelab-governor", default:$default, profiles:$profiles}'
}

pz_governor_weights_json() {
    local reg
    reg="$(pz_governor_registry)" || return $?
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --argjson weights "$(jq -c '.weightsMB' <<< "$reg")" \
        '{schemaVersion:$schemaVersion, tool:"homelab-governor", weightsMB:$weights}'
}

main() {
    local cmd="${1:-list}"
    shift 2>/dev/null || true
    case "$cmd" in
        list)
            pz_governor_list_json
            ;;
        weights)
            pz_governor_weights_json
            ;;
        budget)
            local profile="${1:-}" headroom="${2:-}"
            [ -n "$profile" ] || { pz_error "budget requires a profile"; return 2; }
            if [ -n "$headroom" ]; then
                pz_governor_budget "$profile" "$headroom"
            else
                pz_governor_budget "$profile"
            fi
            ;;
        check)
            local profile="${1:-}" headroom="${2:-}"
            [ -n "$profile" ] || { pz_error "check requires a profile"; return 2; }
            local out
            if [ -n "$headroom" ]; then
                out="$(pz_governor_budget "$profile" "$headroom")" || return $?
            else
                out="$(pz_governor_budget "$profile")" || return $?
            fi
            printf '%s\n' "$out"
            [ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "pass" ]
            ;;
        *)
            echo "usage: homelab-governor.sh (list|weights|budget <profile>|check <profile>) [--headroom PCT]" >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi