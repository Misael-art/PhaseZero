#!/usr/bin/env bash
# homelab-apps.sh — curated one-click catalog (list/enable/disable/update).
#
# JSON on stdout, logs on stderr. Never prints secret values.
# Docker daemon is optional for list/plan and for persisting enabled state;
# bring-up is skipped with an actionable reason when the daemon is down.
# Host apply of real workloads is a CI-disposable concern, not this script's
# default: callers in the hermetic suite pin PZ_HOMELAB_STATE to tmp.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

COMPOSE_DIR="${PZ_HOMELAB_COMPOSE_DIR:-$PZ_ROOT/assets/home-server}"
CATALOG_FILE="${PZ_HOMELAB_APPS_CATALOG:-$COMPOSE_DIR/apps/catalog.json}"
LOCK_FILE="${PZ_HOMELAB_COMPOSE_LOCK:-$COMPOSE_DIR/docker-compose.lock.json}"
HOMELAB_STATE="${PZ_HOMELAB_STATE:-$PZ_STATE/homelab}"
ENV_FILE="${PZ_HOMELAB_ENV_FILE:-$HOMELAB_STATE/.env}"
ENABLED_FILE="${PZ_HOMELAB_APPS_ENABLED:-$HOMELAB_STATE/apps.enabled.json}"
DIGESTS_FILE="${PZ_HOMELAB_IMAGE_DIGESTS:-$HOMELAB_STATE/image-digests.json}"
PROJECT="${PZ_HOMELAB_PROJECT:-phasezero-homelab}"
SCHEMA_VERSION="1"
HEADROOM_PCT="${PZ_HOMELAB_APP_HEADROOM:-20}"
ACCESS_MODE="${PZ_HOMELAB_ACCESS_MODE:-local}"

SUB="${1:-list}"
shift 2>/dev/null || true

JSON_OUTPUT=0
DRY_RUN=0
UPDATE_ALL=0
APP=""

usage() {
    cat <<EOF
Usage:
  homelab-apps.sh list [--json] [--all]
  homelab-apps.sh enable <app> [--json] [--dry-run|--plan]
  homelab-apps.sh disable <app> [--json] [--dry-run|--plan]
  homelab-apps.sh update [<app>|--all] [--json] [--dry-run|--plan]
EOF
}

INCLUDE_INFRA=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) JSON_OUTPUT=1 ;;
        --dry-run|-n|--plan) DRY_RUN=1 ;;
        --all) UPDATE_ALL=1; INCLUDE_INFRA=1 ;;
        --help|-h) usage; exit 0 ;;
        --access)
            [ "${2:-}" ] || { pz_error "--access requires value"; exit 2; }
            ACCESS_MODE="$2"
            shift
            ;;
        --access=*) ACCESS_MODE="${1#--access=}" ;;
        -*)
            pz_error "unexpected flag: $1"
            usage
            exit 2
            ;;
        *)
            if [ -z "$APP" ]; then
                APP="$1"
            else
                pz_error "unexpected argument: $1"
                exit 2
            fi
            ;;
    esac
    shift
done

catalog_json() {
    if [ ! -f "$CATALOG_FILE" ]; then
        pz_error "app catalog missing: $CATALOG_FILE"
        return 2
    fi
    if ! jq -e '.schemaVersion == 1 and (.apps | type == "array")' "$CATALOG_FILE" >/dev/null 2>&1; then
        pz_error "app catalog invalid: $CATALOG_FILE"
        return 2
    fi
    cat "$CATALOG_FILE"
}

app_record() {
    local key="$1" cat
    cat="$(catalog_json)" || return $?
    jq -c --arg k "$key" '.apps[] | select(.key == $k)' <<< "$cat" | head -1
}

lock_ref_for() {
    local key="$1"
    [ -f "$LOCK_FILE" ] || { printf '%s\n' ""; return 0; }
    jq -r --arg k "$key" '.images[$k] // empty' "$LOCK_FILE"
}

default_enabled_json() {
    catalog_json | jq -c '[.apps[] | select(.userFacing == true and .defaultEnabled == true) | .key]'
}

read_enabled_json() {
    local raw
    if [ ! -f "$ENABLED_FILE" ]; then
        default_enabled_json
        return 0
    fi
    raw="$(cat "$ENABLED_FILE" 2>/dev/null || true)"
    if ! jq -e '.schemaVersion == 1 and (.enabled | type == "array")' <<< "$raw" >/dev/null 2>&1; then
        pz_error "enabled-apps registry corrupt: $ENABLED_FILE"
        return 1
    fi
    jq -c '.enabled' <<< "$raw"
}

write_enabled_json() {
    local enabled_json="$1" tmp
    mkdir -p "$HOMELAB_STATE"
    tmp="$(pz_tempfile)"
    jq -cn --argjson schemaVersion 1 --arg tool "homelab-apps-enabled" \
        --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson enabled "$enabled_json" \
        '{schemaVersion:$schemaVersion, tool:$tool, updatedAt:$updatedAt, enabled:$enabled}' \
        > "$tmp"
    install -m 0600 "$tmp" "$ENABLED_FILE"
    rm -f "$tmp"
}

env_get() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE"
}

env_has_value() {
    local value
    value="$(env_get "$1")"
    [ -n "$value" ]
}

docker_cli() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        return 127
    fi
}

docker_installed() { command -v docker >/dev/null 2>&1; }
docker_reachable() { docker_installed && docker info >/dev/null 2>&1; }
compose_available() { docker_cli version >/dev/null 2>&1; }
# Hermetic tests set PZ_HOMELAB_APPS_NO_DOCKER=1 so this module never
# compose-up on the developer host or the shell-test runner.
apps_may_apply() {
    [ "${PZ_HOMELAB_APPS_NO_DOCKER:-0}" != "1" ] && docker_reachable && compose_available
}

tailscale_ip() { tailscale ip -4 2>/dev/null | head -1; }
lan_ip() { hostname -I 2>/dev/null | awk '{print $1; exit}'; }

access_host() {
    case "$ACCESS_MODE" in
        tailscale) tailscale_ip || printf '127.0.0.1\n' ;;
        lan) lan_ip || printf '127.0.0.1\n' ;;
        *) printf '127.0.0.1\n' ;;
    esac
}

access_bind() {
    case "$ACCESS_MODE" in
        tailscale)
            local ts
            ts="$(tailscale_ip || true)"
            if [ -n "$ts" ]; then
                printf '%s\n' "$ts"
            else
                printf '127.0.0.1\n'
            fi
            ;;
        lan) printf '0.0.0.0\n' ;;
        *) printf '127.0.0.1\n' ;;
    esac
}

keys_with_deps() {
    local key="$1"
    catalog_json | jq -r --arg k "$key" '
        .apps as $apps
        | ($apps[] | select(.key == $k) | .dependsOn[]? // empty), $k
    '
}

compose_files_for_keys() {
    local -a keys=("$@") k file
    local seen=""
    for k in "${keys[@]}"; do
        file="$(catalog_json | jq -r --arg k "$k" '.apps[] | select(.key == $k) | .composeFile')"
        [ -n "$file" ] && [ "$file" != "null" ] || continue
        case " $seen " in
            *" $file "*) continue ;;
        esac
        seen="$seen $file"
        printf '%s\n' "$COMPOSE_DIR/$file"
    done
}

services_for_keys() {
    local -a keys=("$@")
    catalog_json | jq -r --args '
        .apps as $apps
        | $ARGS.positional[] as $k
        | $apps[] | select(.key == $k) | .services[]?
    ' -- "${keys[@]}"
}

is_enabled() {
    local key="$1" enabled
    enabled="$(read_enabled_json)" || return 1
    jq -e --arg k "$key" 'index($k) != null' <<< "$enabled" >/dev/null 2>&1
}

union_enabled() {
    local add_json="$1" current
    current="$(read_enabled_json)" || return 1
    jq -n -c --argjson add "$add_json" --argjson cur "$current" \
        '($cur + $add) | unique | sort'
}

subtract_enabled() {
    local remove_json="$1" current
    current="$(read_enabled_json)" || return 1
    jq -n -c --argjson rm "$remove_json" --argjson cur "$current" \
        '$cur - $rm | unique | sort'
}

dependents_of() {
    local key="$1" enabled
    enabled="$(read_enabled_json)" || return 1
    catalog_json | jq -r --arg k "$key" --argjson en "$enabled" '
        .apps[]
        | select((.dependsOn // []) | index($k) != null)
        | select(.key as $d | ($en | index($d) != null))
        | .key
    '
}

governor_for_keys() {
    local -a keys=("$@")
    local available usable need verdict reasons
    available="$(awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || true)"
    if [ -n "${PZ_HOMELAB_RAM_TOTAL_OVERRIDE:-}" ]; then
        available="$PZ_HOMELAB_RAM_TOTAL_OVERRIDE"
    fi
    if [ -z "$available" ]; then
        jq -cn --arg verdict "fail" --arg reason "cannot read total RAM" \
            '{verdict:$verdict, availableMB:null, budgetMB:null, reasons:[$reason]}'
        return 0
    fi
    need="$(catalog_json | jq -r --args '
        .apps as $apps
        | [$ARGS.positional[] as $k | ($apps[] | select(.key == $k) | .budgetMB // 0)] | add // 0
    ' -- "${keys[@]}")"
    usable=$((available - available * HEADROOM_PCT / 100))
    [ "$usable" -lt 0 ] && usable=0
    if [ "$need" -le "$usable" ]; then
        verdict="pass"
        reasons='[]'
    else
        verdict="fail"
        reasons="$(jq -cn --arg m "app overcommits memory: budget ${need} MiB > usable ${usable} MiB (headroom ${HEADROOM_PCT}%)" '[$m]')"
    fi
    jq -cn --argjson availableMB "$available" --argjson budgetMB "$need" \
        --argjson headroomPct "$HEADROOM_PCT" --arg verdict "$verdict" --argjson reasons "$reasons" \
        '{verdict:$verdict, availableMB:$availableMB, budgetMB:$budgetMB, headroomPct:$headroomPct, reasons:$reasons}'
}

missing_secrets_for_keys() {
    local -a keys=("$@") secret
    catalog_json | jq -r --args '
        .apps as $apps
        | $ARGS.positional[] as $k
        | $apps[] | select(.key == $k) | .secrets[]?
    ' -- "${keys[@]}" | while IFS= read -r secret; do
        [ -n "$secret" ] || continue
        if ! env_has_value "$secret"; then
            printf '%s\n' "$secret"
        fi
    done
}

running_names_json() {
    if docker_reachable; then
        docker ps --filter "name=phasezero-" --format '{{.Names}}' 2>/dev/null | jq -R . | jq -cs .
    else
        echo '[]'
    fi
}

digest_for_lock_key() {
    local key="$1"
    [ -f "$DIGESTS_FILE" ] || { printf '\n'; return 0; }
    jq -r --arg k "$key" '.digests[$k] // empty' "$DIGESTS_FILE" 2>/dev/null || true
}

emit_app_row() {
    local rec="$1" enabled_json="$2" running_json="$3"
    local key title layer port bind_kind image_ref lock_key container user_facing
    local enabled=false running=false host bind url digest
    key="$(jq -r '.key' <<< "$rec")"
    title="$(jq -r '.title' <<< "$rec")"
    layer="$(jq -r '.layer' <<< "$rec")"
    port="$(jq -r '.port' <<< "$rec")"
    bind_kind="$(jq -r '.bindKind' <<< "$rec")"
    lock_key="$(jq -r '.imageLockKey' <<< "$rec")"
    image_ref="$(lock_ref_for "$lock_key")"
    [ -n "$image_ref" ] || image_ref="$(jq -r '.imageRef' <<< "$rec")"
    container="$(jq -r '.container' <<< "$rec")"
    user_facing="$(jq -r '.userFacing' <<< "$rec")"
    jq -e --arg k "$key" 'index($k) != null' <<< "$enabled_json" >/dev/null 2>&1 && enabled=true
    jq -e --arg c "$container" 'index($c) != null' <<< "$running_json" >/dev/null 2>&1 && running=true
    host="$(access_host)"
    bind="$(access_bind)"
    [ "$bind_kind" = "public" ] || bind="$(access_bind)"
    if [ "$port" = "0" ] || [ -z "$port" ] || [ "$port" = "null" ]; then
        url=""
    else
        url="http://$host:$port"
    fi
    digest="$(digest_for_lock_key "$lock_key")"
    jq -cn \
        --arg key "$key" --arg title "$title" --arg layer "$layer" \
        --arg imageRef "$image_ref" --arg digest "$digest" \
        --arg bind "$bind" --arg url "$url" --arg container "$container" \
        --argjson port "${port:-0}" \
        --argjson userFacing "$user_facing" \
        --argjson enabled "$enabled" --argjson running "$running" \
        --argjson budgetMB "$(jq -r '.budgetMB' <<< "$rec")" \
        --argjson secrets "$(jq -c '.secrets' <<< "$rec")" \
        --argjson dependsOn "$(jq -c '.dependsOn' <<< "$rec")" \
        '{
            key:$key, title:$title, layer:$layer, userFacing:$userFacing,
            enabled:$enabled, running:$running, budgetMB:$budgetMB,
            imageRef:$imageRef, digest:(if $digest == "" then null else $digest end),
            port:$port, bind:$bind, url:$url, container:$container,
            secrets:$secrets, dependsOn:$dependsOn,
            usesLatest:( ($imageRef | test(":latest$")) or ($imageRef == "latest") )
        }'
}

cmd_list() {
    local cat enabled running rows='[]' rec
    cat="$(catalog_json)" || return $?
    enabled="$(read_enabled_json)" || return $?
    running="$(running_names_json)"
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        if [ "$INCLUDE_INFRA" != "1" ]; then
            jq -e '.userFacing == true' <<< "$rec" >/dev/null 2>&1 || continue
        fi
        local row gov_row
        row="$(emit_app_row "$rec" "$enabled" "$running")"
        local -a gkeys=()
        mapfile -t gkeys < <(jq -n -r --argjson cur "$enabled" \
            --argjson add "$(keys_with_deps "$(jq -r '.key' <<< "$rec")" | jq -R . | jq -cs .)" \
            '$cur + $add | unique | .[]')
        gov_row="$(governor_for_keys "${gkeys[@]}")"
        row="$(jq -c --argjson g "$gov_row" '. + {governor:$g}' <<< "$row")"
        rows="$(jq -c --argjson row "$row" '. + [$row]' <<< "$rows")"
    done < <(jq -c '.apps[]' <<< "$cat")
    local payload
    payload="$(jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
        --arg action "list" --argjson apps "$rows" --argjson enabled "$enabled" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, enabled:$enabled, apps:$apps}')"
    if [ "$JSON_OUTPUT" = "1" ]; then
        printf '%s\n' "$payload"
        return 0
    fi
    echo "$payload" | jq -r '
        "PhaseZero Homelab apps",
        (.apps[] | "  - \(.key)\t enabled=\(.enabled) running=\(.running) \(.imageRef)")
    '
}

json_bool() {
    if [ "$1" = "1" ] || [ "$1" = "true" ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

apps_lock() {
    mkdir -p "$HOMELAB_STATE"
    # Literal fd; do not quote the redirection target token.
    exec 9>"$HOMELAB_STATE/apps.enabled.lock"
    if ! flock -w 10 9; then
        pz_error "another homelab apps operation is running"
        return 1
    fi
}

apps_unlock() {
    flock -u 9 2>/dev/null || true
}

compose_config_subset() {
    local -a files=() args=()
    mapfile -t files
    [ "${#files[@]}" -gt 0 ] || return 1
    [ -f "$ENV_FILE" ] && args+=(--env-file "$ENV_FILE")
    args+=(-p "$PROJECT")
    local f
    for f in "${files[@]}"; do
        [ -f "$f" ] || { pz_error "compose module missing: $f"; return 1; }
        args+=(-f "$f")
    done
    docker_cli "${args[@]}" config --quiet
}

compose_up_subset() {
    local -a files=() services=() args=()
    local f
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --) shift; break ;;
            *) files+=("$1"); shift ;;
        esac
    done
    services=("$@")
    [ -f "$ENV_FILE" ] && args+=(--env-file "$ENV_FILE")
    args+=(-p "$PROJECT")
    for f in "${files[@]}"; do
        args+=(-f "$f")
    done
    docker_cli "${args[@]}" up -d "${services[@]}"
}

compose_rm_subset() {
    local -a files=() services=() args=()
    local f
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --) shift; break ;;
            *) files+=("$1"); shift ;;
        esac
    done
    services=("$@")
    [ -f "$ENV_FILE" ] && args+=(--env-file "$ENV_FILE")
    args+=(-p "$PROJECT")
    for f in "${files[@]}"; do
        args+=(-f "$f")
    done
    docker_cli "${args[@]}" rm -sf "${services[@]}"
}

emit_result() {
    jq -cn "$@"
}

cmd_enable() {
    local rec keys_json missing gov payload started=false validated=false reason=""
    [ -n "$APP" ] || { pz_error "usage: homelab-apps.sh enable <app>"; return 2; }
    rec="$(app_record "$APP")" || return $?
    if [ -z "$rec" ]; then
        pz_error "unknown homelab app: $APP"
        return 2
    fi
    local -a bundle=() check_keys=()
    local current_enabled
    mapfile -t bundle < <(keys_with_deps "$APP")
    keys_json="$(printf '%s\n' "${bundle[@]}" | jq -R . | jq -cs .)"
    current_enabled="$(read_enabled_json)" || return $?
    mapfile -t check_keys < <(jq -n -r --argjson cur "$current_enabled" --argjson add "$keys_json" \
        '$cur + $add | unique | .[]')
    gov="$(governor_for_keys "${check_keys[@]}")"
    local dry_json
    dry_json="$(json_bool "$DRY_RUN")"
    if [ "$(jq -r '.verdict' <<< "$gov")" != "pass" ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
            --arg action "enable" --arg app "$APP" --argjson dryRun "$dry_json" \
            --argjson ok false --argjson enabled false --argjson governor "$gov" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok,
              enabled:$enabled, dryRun:$dryRun, governor:$governor,
              reason:($governor.reasons[0] // "governor refused")}'
        return 1
    fi
    missing="$(missing_secrets_for_keys "${bundle[@]}" | jq -R . | jq -cs .)"
    if [ "$(jq -r 'length' <<< "$missing")" != "0" ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
            --arg action "enable" --arg app "$APP" --argjson ok false --argjson dryRun "$dry_json" \
            --argjson missing "$missing" --argjson governor "$gov" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok, dryRun:$dryRun,
              enabled:false, governor:$governor, missingSecrets:$missing,
              reason:("missing secrets: " + ($missing | join(", ")) + "; run: pz server homelab repair")}'
        return 1
    fi
    local -a files=() services=()
    mapfile -t files < <(compose_files_for_keys "${bundle[@]}")
    mapfile -t services < <(services_for_keys "${bundle[@]}")
    if compose_available; then
        if printf '%s\n' "${files[@]}" | compose_config_subset; then
            validated=true
        else
            reason="compose config failed for subset"
            emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
                --arg action "enable" --arg app "$APP" --argjson ok false --arg reason "$reason" \
                '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok, reason:$reason}'
            return 1
        fi
    fi
    if [ "$DRY_RUN" = "1" ]; then
        emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
            --arg action "enable" --arg app "$APP" --argjson ok true --argjson dryRun true \
            --argjson enabled true --argjson governor "$gov" --argjson keys "$keys_json" \
            --argjson composeValidated "$validated" --argjson files "$(printf '%s\n' "${files[@]}" | jq -R . | jq -cs .)" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok, dryRun:$dryRun,
              wouldEnable:$keys, governor:$governor, composeValidated:$composeValidated, composeFiles:$files,
              applied:false}'
        return 0
    fi
    apps_lock || return 1
    local new_enabled
    new_enabled="$(union_enabled "$keys_json")" || { apps_unlock; return 1; }
    write_enabled_json "$new_enabled" || { apps_unlock; return 1; }
    apps_unlock
    if apps_may_apply; then
        if compose_up_subset "${files[@]}" -- "${services[@]}"; then
            started=true
        else
            reason="compose up failed for ${APP}"
            emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
                --arg action "enable" --arg app "$APP" --argjson ok false --argjson enabled true \
                --arg reason "$reason" \
                '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok,
                  enabled:$enabled, started:false, reason:$reason}'
            return 1
        fi
    else
        reason="docker daemon not reachable; app marked enabled, start deferred"
    fi
    emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
        --arg action "enable" --arg app "$APP" --argjson ok true --argjson dryRun false \
        --argjson enabled true --argjson started "$started" --argjson composeValidated "$validated" \
        --argjson governor "$gov" --argjson keys "$keys_json" --arg reason "$reason" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok, dryRun:$dryRun,
          enabled:$enabled, started:$started, composeValidated:$composeValidated, enabledKeys:$keys,
          governor:$governor, reason:(if $reason == "" then null else $reason end)}'
}

cmd_disable() {
    local rec deps keys_json payload
    [ -n "$APP" ] || { pz_error "usage: homelab-apps.sh disable <app>"; return 2; }
    rec="$(app_record "$APP")" || return $?
    if [ -z "$rec" ]; then
        pz_error "unknown homelab app: $APP"
        return 2
    fi
    deps="$(dependents_of "$APP" | jq -R . | jq -cs .)"
    if [ "$(jq -r 'length' <<< "$deps")" != "0" ]; then
        payload="$(jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
            --arg action "disable" --arg app "$APP" --argjson ok false --argjson dependents "$deps" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok,
              reason:("still required by: " + ($dependents | join(", "))), dependents:$dependents}')"
        printf '%s\n' "$payload"
        return 1
    fi
    local -a bundle=()
    mapfile -t bundle < <(keys_with_deps "$APP")
    keys_json="$(printf '%s\n' "${bundle[@]}" | jq -R . | jq -cs .)"
    local -a files=() services=()
    mapfile -t files < <(compose_files_for_keys "${bundle[@]}")
    mapfile -t services < <(services_for_keys "${bundle[@]}")
    if [ "$DRY_RUN" = "1" ]; then
        emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
            --arg action "disable" --arg app "$APP" --argjson ok true --argjson dryRun true \
            --argjson keys "$keys_json" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok, dryRun:$dryRun,
              wouldDisable:$keys, applied:false}'
        return 0
    fi
    apps_lock || return 1
    local new_enabled stopped=false reason=""
    new_enabled="$(subtract_enabled "$keys_json")" || { apps_unlock; return 1; }
    write_enabled_json "$new_enabled" || { apps_unlock; return 1; }
    apps_unlock
    if apps_may_apply && [ "${#services[@]}" -gt 0 ]; then
        if compose_rm_subset "${files[@]}" -- "${services[@]}"; then
            stopped=true
        else
            reason="compose rm failed; app unmarked enabled"
        fi
    elif ! docker_reachable; then
        reason="docker daemon not reachable; app unmarked enabled, containers unchanged"
    fi
    emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
        --arg action "disable" --arg app "$APP" --argjson ok true --argjson dryRun false \
        --argjson enabled false --argjson stopped "$stopped" --argjson keys "$keys_json" \
        --argjson remaining "$new_enabled" --arg reason "$reason" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, app:$app, ok:$ok, dryRun:$dryRun,
          enabled:$enabled, stopped:$stopped, disabledKeys:$keys, remaining:$remaining,
          reason:(if $reason == "" then null else $reason end)}'
}

uses_latest() {
    local ref="$1"
    case "$ref" in
        *:latest|latest) return 0 ;;
        *) return 1 ;;
    esac
}

cmd_update() {
    local targets=() rec key lock_key ref digest_map='{}'
    if [ "$UPDATE_ALL" = "1" ] || [ -z "$APP" ]; then
        local enabled
        enabled="$(read_enabled_json)" || return $?
        mapfile -t targets < <(jq -r '.[]' <<< "$enabled")
    else
        rec="$(app_record "$APP")" || return $?
        if [ -z "$rec" ]; then
            pz_error "unknown homelab app: $APP"
            return 2
        fi
        targets=("$APP")
    fi
    local rows='[]' latest_hit=false
    for key in "${targets[@]}"; do
        rec="$(app_record "$key")"
        [ -n "$rec" ] || continue
        lock_key="$(jq -r '.imageLockKey' <<< "$rec")"
        ref="$(lock_ref_for "$lock_key")"
        [ -n "$ref" ] || ref="$(jq -r '.imageRef' <<< "$rec")"
        if uses_latest "$ref"; then
            latest_hit=true
        fi
        rows="$(jq -c --arg key "$key" --arg imageRef "$ref" --arg lockKey "$lock_key" \
            --arg digest "$(digest_for_lock_key "$lock_key")" \
            '. + [{key:$key, imageRef:$imageRef, lockKey:$lockKey, digest:(if $digest=="" then null else $digest end), usesLatest:($imageRef | test(":latest$"))}]' <<< "$rows")"
    done
    if [ "$latest_hit" = true ]; then
        emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
            --arg action "update" --argjson ok false --argjson apps "$rows" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, apps:$apps,
              reason:"refusing latest tag; pin a version in docker-compose.lock.json"}'
        return 1
    fi
    if [ "$DRY_RUN" = "1" ]; then
        emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
            --arg action "update" --argjson ok true --argjson dryRun true --argjson apps "$rows" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, dryRun:$dryRun, apps:$apps, applied:false}'
        return 0
    fi
    local pulled=false reason=""
    if apps_may_apply && [ "${#targets[@]}" -gt 0 ]; then
        local -a files=() services=()
        mapfile -t files < <(compose_files_for_keys "${targets[@]}")
        mapfile -t services < <(services_for_keys "${targets[@]}")
        local args=() f
        [ -f "$ENV_FILE" ] && args+=(--env-file "$ENV_FILE")
        args+=(-p "$PROJECT")
        for f in "${files[@]}"; do
            args+=(-f "$f")
        done
        if docker_cli "${args[@]}" pull "${services[@]}"; then
            pulled=true
            mkdir -p "$HOMELAB_STATE"
            digest_map="$(cat "$DIGESTS_FILE" 2>/dev/null || echo '{"schemaVersion":1,"tool":"homelab-image-digests","digests":{}}')"
            jq -e '.schemaVersion == 1' <<< "$digest_map" >/dev/null 2>&1 || digest_map='{"schemaVersion":1,"tool":"homelab-image-digests","digests":{}}'
            local svc img dgst lockk
            for key in "${targets[@]}"; do
                rec="$(app_record "$key")"
                img="$(jq -r '.imageRef' <<< "$rec")"
                lockk="$(jq -r '.imageLockKey' <<< "$rec")"
                dgst="$(docker image inspect "$img" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null || true)"
                if [ -n "$dgst" ]; then
                    digest_map="$(jq -c --arg k "$lockk" --arg d "$dgst" '.digests[$k]=$d' <<< "$digest_map")"
                fi
            done
            local tmp
            tmp="$(pz_tempfile)"
            printf '%s\n' "$digest_map" > "$tmp"
            install -m 0600 "$tmp" "$DIGESTS_FILE"
            rm -f "$tmp"
            docker_cli "${args[@]}" up -d "${services[@]}" || reason="pull ok; compose up failed"
        else
            reason="compose pull failed"
            emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
                --arg action "update" --argjson ok false --arg reason "$reason" --argjson apps "$rows" \
                '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, reason:$reason, apps:$apps}'
            return 1
        fi
    else
        reason="docker daemon not reachable; update not applied"
    fi
    local ok=true
    [ -z "$reason" ] || [ "$pulled" = true ] || ok=false
    [ "$pulled" = true ] && ok=true
    emit_result --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-apps" \
        --arg action "update" --argjson ok "$ok" --argjson dryRun false --argjson pulled "$pulled" \
        --argjson apps "$rows" --arg reason "$reason" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, dryRun:$dryRun,
          pulled:$pulled, apps:$apps, reason:(if $reason == "" then null else $reason end)}'
}

case "$SUB" in
    list) cmd_list ;;
    enable) cmd_enable ;;
    disable) cmd_disable ;;
    update) cmd_update ;;
    *)
        usage >&2
        exit 2
        ;;
esac
