#!/usr/bin/env bash
# pacman.sh - PhaseZero Linux unified package manager wrapper
set -euo pipefail

pz_pkg_install() {
    local pkg="$1" manager="${2:-auto}"
    case "$manager" in
        pacman)
            sudo pacman -S --needed --noconfirm "$pkg"
            ;;
        yay)
            yay -S --needed --noconfirm "$pkg"
            ;;
        paru)
            paru -S --needed --noconfirm "$pkg"
            ;;
        flatpak)
            flatpak install -y flathub "$pkg"
            ;;
        auto)
            if pacman -Si "$pkg" &>/dev/null 2>&1; then
                sudo pacman -S --needed --noconfirm "$pkg"
            elif yay -Si "$pkg" &>/dev/null 2>&1; then
                yay -S --needed --noconfirm "$pkg"
            else
                flatpak install -y flathub "$pkg" 2>/dev/null || {
                    pz_error "could not install $pkg via any manager"
                    return 1
                }
            fi
            ;;
    esac
}

pz_pkg_list_installed() {
    pacman -Qq 2>/dev/null
}

pz_pkg_is_installed() {
    pacman -Qi "$1" &>/dev/null
}

pz_pkg_search() {
    local query="$1"
    echo "=== pacman ==="
    pacman -Ss "$query" 2>/dev/null | head -20
    if command -v yay &>/dev/null; then
        echo "=== AUR (yay) ==="
        yay -Ss "$query" 2>/dev/null | head -20
    fi
}

pz_pkg_update() {
    sudo pacman -Syu --noconfirm
    if command -v yay &>/dev/null; then
        yay -Sua --noconfirm
    fi
    if command -v flatpak &>/dev/null; then
        flatpak update -y
    fi
}

pz_pkg_cleanup() {
    sudo pacman -Sc --noconfirm
    sudo pacman -Rns "$(pacman -Qdtq 2>/dev/null)" --noconfirm 2>/dev/null || true
}
