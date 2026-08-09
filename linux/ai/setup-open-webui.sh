#!/usr/bin/env bash
# setup-open-webui.sh - deploy Open WebUI via Docker
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps docker

OPEN_WEBUI_VOLUME="${HOME}/ollama-webui"

if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "open-webui"; then
    pz_info "deploying Open WebUI"
    mkdir -p "$OPEN_WEBUI_VOLUME"
    docker run -d \
        --name open-webui \
        --restart unless-stopped \
        -p 3000:8080 \
        --add-host=host.docker.internal:host-gateway \
        -v "$OPEN_WEBUI_VOLUME:/app/backend/data" \
        -e OLLAMA_BASE_URL="http://host.docker.internal:11434" \
        ghcr.io/open-webui/open-webui:main
    pz_info "Open WebUI running at http://localhost:3000"
else
    pz_info "Open WebUI already deployed"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "open-webui"; then
        pz_info "starting existing container"
        docker start open-webui
    fi
fi
