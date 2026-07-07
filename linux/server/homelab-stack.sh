#!/usr/bin/env bash
# homelab-stack.sh - PhaseZero home server stack (Docker Compose) + Tailscale.
#
# Brings up the curated homelab services (Jellyfin media, Syncthing "drive",
# Vaultwarden vault, Uptime-Kuma + Portainer monitoring) from the shared compose
# assets, and optionally the extras (Nextcloud, Prometheus/Grafana, Paperless,
# n8n). Remote access is via Tailscale (no ports opened to the internet).
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

COMPOSE_DIR="${PZ_HOMELAB_COMPOSE_DIR:-$PZ_ROOT/assets/home-server}"
CORE_FILE="$COMPOSE_DIR/docker-compose.homelab.yml"
EXTRAS_FILE="$COMPOSE_DIR/docker-compose.extras.yml"
PROJECT="${PZ_HOMELAB_PROJECT:-phasezero-homelab}"

ACTION="${1:-status}"
shift 2>/dev/null || true
WITH_EXTRAS=0
for a in "$@"; do [ "$a" = "--extras" ] && WITH_EXTRAS=1; done

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
    printf '%s\0' -p "$PROJECT" -f "$CORE_FILE"
    [ "$WITH_EXTRAS" = "1" ] && [ -f "$EXTRAS_FILE" ] && printf '%s\0' -f "$EXTRAS_FILE"
}

run_compose() {
    local args=()
    while IFS= read -r -d '' a; do args+=("$a"); done < <(compose_args)
    docker_cli "${args[@]}" "$@"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || { pz_error "docker not installed (pz install server-homelab, or: sudo pacman -S docker docker-compose)"; return 1; }
    if ! docker info >/dev/null 2>&1; then
        pz_warn "docker daemon not reachable; try: sudo systemctl enable --now docker (and add \$USER to the docker group)"
        return 1
    fi
}

ensure_tailscale() {
    command -v tailscale >/dev/null 2>&1 || { pz_warn "tailscale not installed; remote access disabled (sudo pacman -S tailscale)"; return 0; }
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then pz_info "dry-run: would ensure tailscaled up"; return 0; fi
    if pz_can_sudo_noninteractive; then
        sudo -n systemctl enable --now tailscaled >/dev/null 2>&1 || pz_warn "could not enable tailscaled"
        pz_info "tailscale ready; authenticate once with: sudo tailscale up"
    else
        pz_warn "run once: sudo systemctl enable --now tailscaled && sudo tailscale up"
    fi
}

cmd_up() {
    require_docker || return 1
    [ -f "$CORE_FILE" ] || { pz_error "compose file missing: $CORE_FILE"; return 1; }
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would run compose up -d (project $PROJECT, extras=$WITH_EXTRAS)"
        run_compose config --services 2>/dev/null | sed 's/^/  service: /' || true
        ensure_tailscale
        return 0
    fi
    pz_info "starting homelab stack (project $PROJECT, extras=$WITH_EXTRAS)"
    run_compose up -d
    ensure_tailscale
    pz_info "homelab up. Jellyfin :8096  Vaultwarden :8000  Syncthing :8384  Uptime-Kuma :3001  Portainer :9443"
}

cmd_down() {
    require_docker || return 1
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then pz_info "dry-run: would run compose down"; return 0; fi
    run_compose down
    pz_info "homelab stack stopped (named volumes preserved)"
}

cmd_status() {
    local docker_ok=false tailscale_ok=false running="[]"
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker_ok=true
    command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && tailscale_ok=true
    if $docker_ok; then
        running="$(docker ps --filter "name=phasezero-" --format '{{.Names}}' 2>/dev/null | jq -R . | jq -cs . 2>/dev/null || echo '[]')"
    fi
    jq -n \
        --arg core "$CORE_FILE" --arg extras "$EXTRAS_FILE" --arg project "$PROJECT" \
        --argjson docker "$docker_ok" --argjson tailscale "$tailscale_ok" \
        --argjson running "$running" \
        --argjson coreExists "$([ -f "$CORE_FILE" ] && echo true || echo false)" \
        '{tool:"homelab-stack", project:$project, docker:$docker, tailscale:$tailscale,
          compose:{core:$core, extras:$extras, coreExists:$coreExists}, running:$running}'
}

case "$ACTION" in
    up|install|start) cmd_up ;;
    down|stop) cmd_down ;;
    restart) cmd_down; cmd_up ;;
    tailscale) ensure_tailscale ;;
    status) cmd_status ;;
    dry-run|plan) PZ_DRY_RUN=1 cmd_up ;;
    *) pz_error "usage: homelab-stack.sh (up|down|restart|tailscale|status|dry-run) [--extras]"; exit 2 ;;
esac
