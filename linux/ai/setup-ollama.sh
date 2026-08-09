#!/usr/bin/env bash
# setup-ollama.sh - install and configure Ollama
#
# Model pulls are never automatic. Use --pull <model> to request one after
# setup; the request is gated by the AI policy broker (conservative default
# denies automatic pulls, explicit=1 opt-in is allowed).
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/lib/pacman.sh"

PULL_MODEL=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --pull) [ "${2:-}" ] || { pz_error "--pull requires a model name"; exit 2; }; PULL_MODEL="$2"; shift ;;
        --pull=*) PULL_MODEL="${1#--pull=}" ;;
        --help|-h)
            cat <<EOF
usage: setup-ollama.sh [--pull <model>]
  --pull <model>  pull a specific model after setup (broker-gated, opt-in)
EOF
            exit 0
            ;;
        *) pz_error "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

pz_check_deps systemctl

if ! command -v ollama &>/dev/null; then
    if pz_pkg_is_installed ollama; then
        pz_info "ollama package installed but command not found in PATH"
    elif pz_can_sudo_noninteractive && pacman -Si ollama >/dev/null 2>&1; then
        pz_info "installing ollama via pacman"
        sudo -n pacman -S --needed --noconfirm ollama
    else
        pz_warn "ollama missing; install with: sudo pacman -S --needed ollama"
        exit 0
    fi
else
    pz_info "ollama already installed"
fi

if systemctl is-active ollama >/dev/null 2>&1; then
    pz_info "ollama service already active"
elif pz_can_sudo_noninteractive; then
    sudo -n systemctl enable --now ollama
else
    pz_warn "sudo non-interactive unavailable; run: sudo systemctl enable --now ollama"
fi

if [ -n "$PULL_MODEL" ]; then
    if ! bash "$PZ_ROOT/linux/server/ai-policy-broker.sh" check ollama-pull explicit=1 >/dev/null 2>&1; then
        pz_warn "policy denies model pull; set permissive or use explicit opt-in"
    elif command -v ollama >/dev/null 2>&1; then
        pz_info "pulling $PULL_MODEL (foreground, policy-approved)"
        ollama pull "$PULL_MODEL"
    fi
fi

pz_info "ollama setup complete"