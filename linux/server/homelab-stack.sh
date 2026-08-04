#!/usr/bin/env bash
# homelab-stack.sh - PhaseZero home server stack (Docker Compose) + Tailscale.
#
# Core: Portainer, Jellyfin, Syncthing, Vaultwarden, Uptime Kuma.
# Extras: Nextcloud, Prometheus/Grafana, Paperless, n8n.
# Default access is local-only. Tailscale and LAN exposure are explicit.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

COMPOSE_DIR="${PZ_HOMELAB_COMPOSE_DIR:-$PZ_ROOT/assets/home-server}"
CORE_FILE="$COMPOSE_DIR/docker-compose.homelab.yml"
EXTRAS_FILE="$COMPOSE_DIR/docker-compose.extras.yml"
PROJECT="${PZ_HOMELAB_PROJECT:-phasezero-homelab}"
HOMELAB_STATE="${PZ_HOMELAB_STATE:-$PZ_STATE/homelab}"
ENV_FILE="${PZ_HOMELAB_ENV_FILE:-$HOMELAB_STATE/.env}"
BACKUP_ROOT="${PZ_HOMELAB_BACKUP_ROOT:-$HOMELAB_STATE/backups}"

ACTION="${1:-status}"
shift 2>/dev/null || true

WITH_EXTRAS=0
JSON_OUTPUT=0
YES=0
FOLLOW=0
ACCESS_MODE="${PZ_HOMELAB_ACCESS_MODE:-local}"
HOMELAB_PROFILE="${PZ_HOMELAB_PROFILE:-}"
APP=""
DEST=""
SOURCE=""

usage() {
    cat <<EOF
Usage:
  homelab-stack.sh status [--json] [--extras] [--access local|tailscale|lan]
  homelab-stack.sh plan [--json] [--extras] [--access local|tailscale|lan]
  homelab-stack.sh up|down|restart [--extras] [--access local|tailscale|lan] [--profile <key>]
  homelab-stack.sh open <app> [--access local|tailscale|lan]
  homelab-stack.sh logs <app> [--follow]
  homelab-stack.sh backup [--extras] [--dest PATH] [--dry-run]
  homelab-stack.sh restore --source PATH [--yes] [--dry-run]
  homelab-stack.sh update [--extras] [--access local|tailscale|lan] [--dry-run]
  homelab-stack.sh repair [--extras] [--access local|tailscale|lan]
  homelab-stack.sh tailscale

Apps: portainer jellyfin syncthing vaultwarden uptime-kuma nextcloud grafana prometheus paperless n8n
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --extras) WITH_EXTRAS=1 ;;
        --json) JSON_OUTPUT=1 ;;
        --yes|-y) YES=1 ;;
        --follow|-f) FOLLOW=1 ;;
        --dry-run|-n) PZ_DRY_RUN=1 ;;
        --access)
            [ "${2:-}" ] || { pz_error "--access requires value"; exit 2; }
            ACCESS_MODE="$2"
            shift
            ;;
        --access=*) ACCESS_MODE="${1#--access=}" ;;
        --profile)
            [ "${2:-}" ] || { pz_error "--profile requires value"; exit 2; }
            HOMELAB_PROFILE="$2"
            shift
            ;;
        --profile=*) HOMELAB_PROFILE="${1#--profile=}" ;;
        --dest)
            [ "${2:-}" ] || { pz_error "--dest requires path"; exit 2; }
            DEST="$2"
            shift
            ;;
        --source)
            [ "${2:-}" ] || { pz_error "--source requires path"; exit 2; }
            SOURCE="$2"
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *)
            case "$ACTION" in
                open|logs)
                    if [ -z "$APP" ]; then
                        APP="$1"
                    else
                        pz_error "unexpected argument: $1"
                        exit 2
                    fi
                    ;;
                restore)
                    if [ -z "$SOURCE" ]; then
                        SOURCE="$1"
                    else
                        pz_error "unexpected argument: $1"
                        exit 2
                    fi
                    ;;
                *) pz_error "unexpected argument: $1"; usage; exit 2 ;;
            esac
            ;;
    esac
    shift
done

case "$ACCESS_MODE" in
    local|tailscale|lan) ;;
    *) pz_error "invalid access mode: $ACCESS_MODE"; exit 2 ;;
esac

docker_cli() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        return 127
    fi
}

compose_args() {
    [ -f "$ENV_FILE" ] && printf '%s\0' --env-file "$ENV_FILE"
    printf '%s\0' -p "$PROJECT" -f "$CORE_FILE"
    [ "$WITH_EXTRAS" = "1" ] && [ -f "$EXTRAS_FILE" ] && printf '%s\0' -f "$EXTRAS_FILE"
}

run_compose() {
    local args=()
    while IFS= read -r -d '' a; do args+=("$a"); done < <(compose_args)
    docker_cli "${args[@]}" "$@"
}

docker_installed() { command -v docker >/dev/null 2>&1; }
docker_reachable() { docker_installed && docker info >/dev/null 2>&1; }
compose_available() { docker_cli version >/dev/null 2>&1; }
tailscale_installed() { command -v tailscale >/dev/null 2>&1; }
tailscale_authenticated() { tailscale_installed && tailscale status >/dev/null 2>&1; }

require_docker() {
    docker_installed || { pz_error "docker not installed (pz install server-homelab, or install docker/docker-compose)"; return 1; }
    docker_reachable || { pz_error "docker daemon not reachable; enable docker and add user to docker group"; return 1; }
    compose_available || { pz_error "docker compose unavailable"; return 1; }
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

random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        od -An -tx1 -N 32 /dev/urandom | tr -d ' \n'
    fi
}

env_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$(dirname "$ENV_FILE")"
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    if [ -f "$ENV_FILE" ]; then
        awk -v k="$key" -v v="$value" '
            BEGIN { done = 0 }
            $0 ~ "^" k "=" { print k "=" v; done = 1; next }
            { print }
            END { if (!done) print k "=" v }
        ' "$ENV_FILE" > "$tmp"
    else
        {
            echo "# PhaseZero Homelab environment"
            echo "# Generated locally. Do not commit."
            echo "$key=$value"
        } > "$tmp"
    fi
    install -m 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

lan_ip() {
    hostname -I 2>/dev/null | awk '{print $1; exit}'
}

tailscale_ip() {
    tailscale ip -4 2>/dev/null | head -1
}

access_bind_plan() {
    local mode="$1" ts_ip
    case "$mode" in
        local)
            printf '%s|%s|%s|%s\n' "local" "127.0.0.1" "127.0.0.1" "local-only"
            ;;
        tailscale)
            ts_ip="$(tailscale_ip || true)"
            if [ -n "$ts_ip" ] && tailscale_authenticated; then
                printf '%s|%s|%s|%s\n' "tailscale" "$ts_ip" "$ts_ip" "tailscale"
            else
                printf '%s|%s|%s|%s\n' "blocked" "127.0.0.1" "127.0.0.1" "tailscale-not-authenticated"
            fi
            ;;
        lan)
            printf '%s|%s|%s|%s\n' "lan" "0.0.0.0" "0.0.0.0" "lan-opt-in"
            ;;
    esac
}

access_host_for_urls() {
    local effective="$1" admin_bind="$2" public_bind="$3" host
    case "$effective" in
        tailscale) host="$(tailscale_ip || true)" ;;
        lan) host="$(lan_ip || true)" ;;
        *) host="127.0.0.1" ;;
    esac
    [ -n "$host" ] || host="127.0.0.1"
    printf '%s|%s|%s\n' "$host" "$admin_bind" "$public_bind"
}

ensure_env_file() {
    local mode="${1:-$ACCESS_MODE}" effective admin_bind public_bind reason
    IFS='|' read -r effective admin_bind public_bind reason < <(access_bind_plan "$mode")
    mkdir -p "$HOMELAB_STATE"
    if [ ! -f "$ENV_FILE" ]; then
        umask 077
        {
            echo "# PhaseZero Homelab environment"
            echo "# Generated locally. Do not commit."
        } > "$ENV_FILE"
        chmod 0600 "$ENV_FILE"
    fi

    env_set HOMELAB_ACCESS_MODE "$mode"
    env_set HOMELAB_ACCESS_EFFECTIVE "$effective"
    env_set HOMELAB_ACCESS_REASON "$reason"
    env_set HOMELAB_ADMIN_BIND_ADDR "$admin_bind"
    env_set HOMELAB_PUBLIC_BIND_ADDR "$public_bind"
    env_has_value HOMELAB_MEDIA_DIR || env_set HOMELAB_MEDIA_DIR "$HOME/Videos"
    env_has_value VW_SIGNUPS_ALLOWED || env_set VW_SIGNUPS_ALLOWED "false"

    env_has_value VW_ADMIN_TOKEN || env_set VW_ADMIN_TOKEN "$(random_secret)"
    env_has_value NEXTCLOUD_DB_ROOT_PASSWORD || env_set NEXTCLOUD_DB_ROOT_PASSWORD "$(random_secret)"
    env_has_value NEXTCLOUD_DB_PASSWORD || env_set NEXTCLOUD_DB_PASSWORD "$(random_secret)"
    env_has_value GRAFANA_ADMIN_PASSWORD || env_set GRAFANA_ADMIN_PASSWORD "$(random_secret)"
    env_has_value PAPERLESS_SECRET_KEY || env_set PAPERLESS_SECRET_KEY "$(random_secret)"
    env_has_value N8N_ENCRYPTION_KEY || env_set N8N_ENCRYPTION_KEY "$(random_secret)"
}

ensure_tailscale() {
    command -v tailscale >/dev/null 2>&1 || { pz_warn "tailscale not installed; remote access disabled"; return 1; }
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would ensure tailscaled up"
        return 0
    fi
    if pz_can_sudo_noninteractive; then
        sudo -n systemctl enable --now tailscaled >/dev/null 2>&1 || pz_warn "could not enable tailscaled"
    else
        pz_warn "run once: phasezero-admin systemctl enable --now tailscaled"
    fi
    if tailscale_authenticated; then
        pz_info "tailscale authenticated ($(tailscale_ip || true))"
    else
        pz_warn "tailscale logged out; authenticate once with: phasezero-admin tailscale up"
        return 1
    fi
}

app_rows() {
    cat <<'EOF'
portainer|Portainer|portainer|phasezero-portainer|core|9000|admin|true|portainer_data
jellyfin|Jellyfin|jellyfin|phasezero-jellyfin|core|8096|public|false|jellyfin_config jellyfin_cache
syncthing|Syncthing|syncthing|phasezero-syncthing|core|8384|admin|true|syncthing_data
vaultwarden|Vaultwarden|vaultwarden|phasezero-vaultwarden|core|8222|admin|true|vaultwarden_data
uptime-kuma|Uptime Kuma|uptime-kuma|phasezero-uptime-kuma|core|3001|admin|true|uptimekuma_data
nextcloud|Nextcloud|nextcloud|phasezero-nextcloud|extras|8080|admin|true|nextcloud_db nextcloud_data
grafana|Grafana|grafana|phasezero-grafana|extras|3000|admin|true|grafana_data
prometheus|Prometheus|prometheus|phasezero-prometheus|extras|9090|admin|true|prometheus_data
node-exporter|Node Exporter|node-exporter|phasezero-node-exporter|extras|9100|admin|true|
paperless|Paperless|paperless|phasezero-paperless|extras|8010|admin|true|paperless_data paperless_media
n8n|n8n|n8n|phasezero-n8n|extras|5678|admin|true|n8n_data
EOF
}

secret_rows() {
    cat <<'EOF'
VW_ADMIN_TOKEN|vaultwarden|core
NEXTCLOUD_DB_ROOT_PASSWORD|nextcloud-db|extras
NEXTCLOUD_DB_PASSWORD|nextcloud|extras
GRAFANA_ADMIN_PASSWORD|grafana|extras
PAPERLESS_SECRET_KEY|paperless|extras
N8N_ENCRYPTION_KEY|n8n|extras
EOF
}

all_volumes() {
    app_rows | awk -F'|' -v extras="$WITH_EXTRAS" '
        $5 == "core" || extras == "1" {
            n = split($9, vols, " ")
            for (i = 1; i <= n; i++) if (vols[i] != "") print vols[i]
        }
    ' | sort -u
}

app_info() {
    local key="$1"
    app_rows | awk -F'|' -v key="$key" '$1 == key {print; found=1} END {exit found ? 0 : 1}'
}

service_for_app() {
    app_info "$1" | awk -F'|' '{print $3}'
}

container_for_app() {
    app_info "$1" | awk -F'|' '{print $4}'
}

app_port() {
    app_info "$1" | awk -F'|' '{print $6}'
}

app_bind_kind() {
    app_info "$1" | awk -F'|' '{print $7}'
}

running_containers_json() {
    if docker_reachable; then
        docker ps --filter "name=phasezero-" --format '{{.Names}}' 2>/dev/null | jq -R . | jq -cs .
    else
        echo '[]'
    fi
}

services_json() {
    if compose_available && [ -f "$CORE_FILE" ]; then
        run_compose config --services 2>/dev/null | jq -R . | jq -cs .
    else
        echo '[]'
    fi
}

secrets_json() {
    local rows=()
    while IFS='|' read -r key service layer; do
        local present=false required=false
        env_has_value "$key" && present=true
        [ "$layer" = "core" ] || [ "$WITH_EXTRAS" = "1" ] && required=true
        rows+=("$(jq -cn \
            --arg key "$key" --arg service "$service" --arg layer "$layer" \
            --argjson present "$present" --argjson required "$required" \
            '{key:$key, service:$service, layer:$layer, present:$present, required:$required, sensitive:true}')")
    done < <(secret_rows)
    printf '%s\n' "${rows[@]}" | jq -s .
}

apps_json() {
    local effective admin_bind public_bind reason host admin_host public_host running names_json rows=()
    IFS='|' read -r effective admin_bind public_bind reason < <(access_bind_plan "$ACCESS_MODE")
    IFS='|' read -r host _ _ < <(access_host_for_urls "$effective" "$admin_bind" "$public_bind")
    names_json="$(running_containers_json)"
    while IFS='|' read -r key title service container layer port bind_kind sensitive volumes; do
        [ "$layer" = "core" ] || [ "$WITH_EXTRAS" = "1" ] || continue
        local bind="$public_bind"
        [ "$bind_kind" = "admin" ] && bind="$admin_bind"
        local url="http://$host:$port"
        local running=false
        echo "$names_json" | jq -e --arg c "$container" 'index($c)' >/dev/null 2>&1 && running=true
        rows+=("$(jq -cn \
            --arg key "$key" --arg title "$title" --arg service "$service" --arg container "$container" \
            --arg layer "$layer" --arg bind "$bind" --arg url "$url" --arg volumes "$volumes" \
            --argjson port "$port" --argjson sensitive "$sensitive" --argjson running "$running" \
            '{key:$key,title:$title,service:$service,container:$container,layer:$layer,port:$port,bind:$bind,url:$url,sensitive:$sensitive,running:$running,volumes:($volumes|split(" ")|map(select(.!="")))}')")
    done < <(app_rows)
    printf '%s\n' "${rows[@]}" | jq -s .
}

blockers_json() {
    local blockers=()
    [ -f "$CORE_FILE" ] || blockers+=("compose core missing: $CORE_FILE")
    [ "$WITH_EXTRAS" = "0" ] || [ -f "$EXTRAS_FILE" ] || blockers+=("compose extras missing: $EXTRAS_FILE")
    docker_installed || blockers+=("docker not installed")
    docker_reachable || blockers+=("docker daemon not reachable")
    compose_available || blockers+=("docker compose unavailable")
    [ -f "$ENV_FILE" ] || blockers+=("homelab .env missing; run: pz server homelab repair")
    while IFS='|' read -r key service layer; do
        if { [ "$layer" = "core" ] || [ "$WITH_EXTRAS" = "1" ]; } && ! env_has_value "$key"; then
            blockers+=("missing secret $key for $service")
        fi
    done < <(secret_rows)
    if [ "$ACCESS_MODE" = "tailscale" ] && ! tailscale_authenticated; then
        blockers+=("tailscale logged out; sensitive services stay local-only")
    fi
    [ "${#blockers[@]}" -gt 0 ] || { echo '[]'; return 0; }
    printf '%s\n' "${blockers[@]}" | jq -R . | jq -cs .
}

next_steps_json() {
    local steps=()
    docker_reachable || steps+=("ativar Docker e permitir acesso do usuário")
    [ -f "$ENV_FILE" ] || steps+=("gerar secrets com: pz server homelab repair")
    if [ "$ACCESS_MODE" = "tailscale" ] && ! tailscale_authenticated; then
        steps+=("autenticar Tailscale com: phasezero-admin tailscale up")
    fi
    steps+=("subir core com: pz server homelab up --access local")
    steps+=("subir extras só se precisar: pz server homelab up --extras --access tailscale")
    printf '%s\n' "${steps[@]}" | jq -R . | jq -cs .
}

emit_status_json() {
    local effective admin_bind public_bind reason host blockers secrets apps running services
    IFS='|' read -r effective admin_bind public_bind reason < <(access_bind_plan "$ACCESS_MODE")
    host="$(access_host_for_urls "$effective" "$admin_bind" "$public_bind" | cut -d'|' -f1)"
    blockers="$(blockers_json)"
    secrets="$(secrets_json)"
    apps="$(apps_json)"
    running="$(running_containers_json)"
    services="$(services_json)"
    jq -n \
        --arg project "$PROJECT" \
        --arg stateDir "$HOMELAB_STATE" \
        --arg envFile "$ENV_FILE" \
        --arg core "$CORE_FILE" \
        --arg extras "$EXTRAS_FILE" \
        --arg access "$ACCESS_MODE" \
        --arg effective "$effective" \
        --arg reason "$reason" \
        --arg adminBind "$admin_bind" \
        --arg publicBind "$public_bind" \
        --arg host "$host" \
        --argjson withExtras "$WITH_EXTRAS" \
        --argjson dockerInstalled "$(docker_installed && echo true || echo false)" \
        --argjson dockerReachable "$(docker_reachable && echo true || echo false)" \
        --argjson composeAvailable "$(compose_available && echo true || echo false)" \
        --argjson tailscaleInstalled "$(tailscale_installed && echo true || echo false)" \
        --argjson tailscaleAuthenticated "$(tailscale_authenticated && echo true || echo false)" \
        --argjson coreExists "$([ -f "$CORE_FILE" ] && echo true || echo false)" \
        --argjson extrasExists "$([ -f "$EXTRAS_FILE" ] && echo true || echo false)" \
        --argjson envExists "$([ -f "$ENV_FILE" ] && echo true || echo false)" \
        --argjson blockers "$blockers" \
        --argjson secrets "$secrets" \
        --argjson apps "$apps" \
        --argjson running "$running" \
        --argjson services "$services" \
        --argjson nextSteps "$(next_steps_json)" \
        '{
          tool:"homelab-stack",
          status:(if ($blockers|length)==0 then "ok" else "blocked" end),
          project:$project,
          withExtras:$withExtras,
          paths:{stateDir:$stateDir, envFile:$envFile, composeCore:$core, composeExtras:$extras},
          docker:{installed:$dockerInstalled, reachable:$dockerReachable, compose:$composeAvailable},
          tailscale:{installed:$tailscaleInstalled, authenticated:$tailscaleAuthenticated},
          access:{requested:$access, effective:$effective, reason:$reason, host:$host, adminBind:$adminBind, publicBind:$publicBind},
          compose:{coreExists:$coreExists, extrasExists:$extrasExists, services:$services},
          env:{exists:$envExists, secrets:$secrets},
          apps:$apps,
          running:$running,
          blockers:$blockers,
          nextSteps:$nextSteps
        }'
}

cmd_status() {
    emit_status_json
}

cmd_plan() {
    local data
    data="$(emit_status_json)"
    if [ "$JSON_OUTPUT" = "1" ]; then
        printf '%s\n' "$data"
        return 0
    fi
    echo "$data" | jq -r '
        "PhaseZero Homelab plan",
        "  status: \(.status)",
        "  access: \(.access.requested) -> \(.access.effective) (\(.access.reason))",
        "  docker: installed=\(.docker.installed) reachable=\(.docker.reachable) compose=\(.docker.compose)",
        "  env: \(.paths.envFile) exists=\(.env.exists)",
        "  apps:",
        (.apps[] | "    - \(.key): \(.url) bind=\(.bind) running=\(.running)"),
        "  blockers:",
        (if (.blockers|length)==0 then "    none" else (.blockers[] | "    - " + .) end),
        "  next:",
        (.nextSteps[] | "    - " + .)
    '
}

cmd_up() {
    require_docker || return 1
    [ -f "$CORE_FILE" ] || { pz_error "compose file missing: $CORE_FILE"; return 1; }
    [ "$WITH_EXTRAS" = "0" ] || [ -f "$EXTRAS_FILE" ] || { pz_error "extras compose file missing: $EXTRAS_FILE"; return 1; }
    if [ "$ACCESS_MODE" = "tailscale" ] && ! tailscale_authenticated; then
        pz_error "tailscale access requested but Tailscale is logged out; run: pz server homelab tailscale"
        return 1
    fi
    if [ -n "$HOMELAB_PROFILE" ]; then
        if ! bash "$PZ_ROOT/linux/server/homelab-governor.sh" check "$HOMELAB_PROFILE" >/dev/null 2>&1; then
            pz_error "profile $HOMELAB_PROFILE rejected by resource governor; check budget: pz server homelab governor budget $HOMELAB_PROFILE"
            return 1
        fi
        mkdir -p "$HOMELAB_STATE"
        printf '%s\n' "$HOMELAB_PROFILE" > "$HOMELAB_STATE/profile.active"
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would generate .env, validate compose, and run compose up -d (project $PROJECT, extras=$WITH_EXTRAS, access=$ACCESS_MODE)"
        PZ_DRY_RUN=1 cmd_plan
        return 0
    fi
    ensure_env_file "$ACCESS_MODE"
    run_compose config --services >/dev/null
    pz_info "starting homelab stack (project $PROJECT, extras=$WITH_EXTRAS, access=$ACCESS_MODE)"
    run_compose up -d
    if [ "$ACCESS_MODE" = "tailscale" ]; then
        ensure_tailscale || true
    fi
    cmd_plan
}

cmd_down() {
    require_docker || return 1
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would run compose down (volumes preserved)"
        return 0
    fi
    run_compose down
    pz_info "homelab stack stopped (named volumes preserved)"
}

url_for_app() {
    local key="$1" row port bind_kind effective admin_bind public_bind reason host
    row="$(app_info "$key")" || { pz_error "unknown homelab app: $key"; return 1; }
    port="$(echo "$row" | awk -F'|' '{print $6}')"
    bind_kind="$(echo "$row" | awk -F'|' '{print $7}')"
    IFS='|' read -r effective admin_bind public_bind reason < <(access_bind_plan "$ACCESS_MODE")
    host="$(access_host_for_urls "$effective" "$admin_bind" "$public_bind" | cut -d'|' -f1)"
    printf 'http://%s:%s\n' "$host" "$port"
}

cmd_open() {
    [ -n "$APP" ] || { pz_error "usage: homelab-stack.sh open <app>"; return 2; }
    local url
    url="$(url_for_app "$APP")" || return 1
    if [ "$JSON_OUTPUT" = "1" ]; then
        jq -n --arg app "$APP" --arg url "$url" '{app:$app,url:$url}'
        return 0
    fi
    echo "$url"
    if [ "${PZ_DRY_RUN:-0}" = "1" ] || [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    else
        pz_warn "xdg-open unavailable; open manually: $url"
    fi
}

cmd_logs() {
    [ -n "$APP" ] || { pz_error "usage: homelab-stack.sh logs <app>"; return 2; }
    require_docker || return 1
    local container args=(--tail=200)
    container="$(container_for_app "$APP")" || { pz_error "unknown homelab app: $APP"; return 1; }
    [ "$FOLLOW" = "1" ] && args+=("--follow")
    docker logs "${args[@]}" "$container"
}

volume_actual_name() {
    local logical="$1" found
    found="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PROJECT}_${logical}$|_${logical}$|^${logical}$" | head -1 || true)"
    [ -n "$found" ] && printf '%s\n' "$found" || printf '%s_%s\n' "$PROJECT" "$logical"
}

cmd_backup() {
    local dest="${DEST:-$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')}" vol actual mount
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        jq -n --arg dest "$dest" --argjson volumes "$(all_volumes | jq -R . | jq -cs .)" \
            '{action:"backup", dryRun:true, destination:$dest, volumes:$volumes}'
        return 0
    fi
    require_docker || return 1
    mkdir -p "$dest"
    while IFS= read -r vol; do
        [ -n "$vol" ] || continue
        actual="$(volume_actual_name "$vol")"
        if ! docker volume inspect "$actual" >/dev/null 2>&1; then
            pz_warn "volume missing, skipped: $actual"
            continue
        fi
        mount="$(docker volume inspect -f '{{ .Mountpoint }}' "$actual")"
        tar -C "$mount" -czf "$dest/$vol.tgz" .
        pz_info "backed up $actual -> $dest/$vol.tgz"
    done < <(all_volumes)
    jq -n --arg destination "$dest" '{action:"backup", destination:$destination, ok:true}'
}

cmd_restore() {
    [ -n "$SOURCE" ] || { pz_error "restore requires --source PATH"; return 2; }
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        jq -n --arg source "$SOURCE" --argjson archives "$(find "$SOURCE" -maxdepth 1 -name '*.tgz' -printf '%f\n' 2>/dev/null | jq -R . | jq -cs .)" \
            '{action:"restore", dryRun:true, source:$source, archives:$archives, requiresConfirmation:true}'
        return 0
    fi
    [ "$YES" = "1" ] || { pz_error "restore is destructive; pass --yes after verifying backup"; return 1; }
    require_docker || return 1
    [ -d "$SOURCE" ] || { pz_error "restore source missing: $SOURCE"; return 1; }
    cmd_down || true
    local archive vol actual mount
    for archive in "$SOURCE"/*.tgz; do
        [ -e "$archive" ] || continue
        vol="$(basename "$archive" .tgz)"
        actual="$(volume_actual_name "$vol")"
        docker volume inspect "$actual" >/dev/null 2>&1 || docker volume create "$actual" >/dev/null
        mount="$(docker volume inspect -f '{{ .Mountpoint }}' "$actual")"
        tar -C "$mount" -xzf "$archive"
        pz_info "restored $archive -> $actual"
    done
    jq -n --arg source "$SOURCE" '{action:"restore", source:$source, ok:true}'
}

cmd_update() {
    require_docker || return 1
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would backup, pull pinned images, then compose up -d"
        cmd_backup
        return 0
    fi
    ensure_env_file "$ACCESS_MODE"
    cmd_backup >/dev/null
    run_compose pull
    run_compose up -d
    pz_info "homelab updated using pinned compose tags"
}

cmd_repair() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would generate missing secrets and validate compose"
        cmd_plan
        return 0
    fi
    ensure_env_file "$ACCESS_MODE"
    if compose_available && [ -f "$CORE_FILE" ]; then
        run_compose config --services >/dev/null || pz_warn "compose config reported issues"
    fi
    if [ "$ACCESS_MODE" = "tailscale" ]; then
        ensure_tailscale || true
    fi
    cmd_plan
}

case "$ACTION" in
    up|install|start) cmd_up ;;
    down|stop) cmd_down ;;
    restart) cmd_down; cmd_up ;;
    tailscale) ensure_tailscale ;;
    status) cmd_status ;;
    plan|dry-run) PZ_DRY_RUN="${PZ_DRY_RUN:-0}" cmd_plan ;;
    open) cmd_open ;;
    logs|log) cmd_logs ;;
    backup) cmd_backup ;;
    restore) cmd_restore ;;
    update) cmd_update ;;
    repair) cmd_repair ;;
    *) pz_error "usage: homelab-stack.sh (up|down|restart|tailscale|status|plan|open|logs|backup|restore|update|repair) [--extras]"; exit 2 ;;
esac
