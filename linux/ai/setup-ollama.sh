#!/usr/bin/env bash
# setup-ollama.sh - install and configure Ollama
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/lib/pacman.sh"

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

if command -v ollama >/dev/null 2>&1 && ! ollama list 2>/dev/null | grep -q "llama3.1"; then
    pz_info "pulling llama3.1 model (background)..."
    nohup ollama pull llama3.1 &>/dev/null &
fi

if command -v ollama >/dev/null 2>&1 && ! ollama list 2>/dev/null | grep -q "gemma3"; then
    pz_info "pulling gemma3 model (background)..."
    nohup ollama pull gemma3 &>/dev/null &
fi

pz_info "ollama setup complete"
