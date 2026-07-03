#!/usr/bin/env bash
# common.sh - PhaseZero Linux shared library
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PZ_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero"
PZ_MANIFEST="$PZ_STATE/manifest.json"
PZ_LOG="$PZ_STATE/pz.log"
PZ_PROFILES="${PZ_ROOT}/profiles"

mkdir -p "$PZ_STATE"

pz_log() {
    local level="$1" msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$PZ_LOG"
    case "$level" in
        ERROR) echo >&2 "ERROR: $msg" ;;
        WARN)  echo >&2 "WARN:  $msg" ;;
        INFO)  echo "INFO:  $msg" ;;
        *)     echo "$msg" ;;
    esac
}

pz_info() { pz_log INFO "$*"; }
pz_warn() { pz_log WARN "$*"; }
pz_error() { pz_log ERROR "$*"; }

pz_can_sudo_noninteractive() {
    command -v sudo &>/dev/null && sudo -n true &>/dev/null
}

pz_write_managed_file() {
    local path="$1" scope="${2:-user}"
    local dir tmp backup
    dir="$(dirname "$path")"
    tmp="$(mktemp)"
    cat > "$tmp"

    if [ "$scope" = "root" ] && [ "$EUID" -ne 0 ]; then
        if [ "${PZ_USE_SUDO:-0}" = "1" ] && pz_can_sudo_noninteractive; then
            backup="${path}.bak.$(date +%s)"
            [ -f "$path" ] && sudo -n cp "$path" "$backup" 2>/dev/null || true
            sudo -n install -d "$dir"
            sudo -n install -m 0644 "$tmp" "$path"
            rm -f "$tmp"
            pz_info "wrote $path"
            return 0
        fi

        rm -f "$tmp"
        pz_warn "$path requires root; skipped non-interactive write"
        return 0
    fi

    mkdir -p "$dir"
    [ -f "$path" ] && cp "$path" "${path}.bak.$(date +%s)" 2>/dev/null || true
    install -m 0644 "$tmp" "$path"
    rm -f "$tmp"
    pz_info "wrote $path"
}

pz_check_deps() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        pz_error "missing dependencies: ${missing[*]}"
        echo "Install: sudo pacman -S ${missing[*]}"
        return 1
    fi
}

pz_require_root() {
    if [ "$EUID" -ne 0 ]; then
        if command -v bigsudo &>/dev/null; then
            exec bigsudo "$0" "$@"
        else
            echo "root required. run with sudo or install bigsudo."
            return 1
        fi
    fi
}

pz_rollback_register() {
    local action="$1" target="$2" backup="$3"
    local entry
    entry=$(jq -n \
        --arg action "$action" \
        --arg target "$target" \
        --arg backup "$backup" \
        --arg ts "$(date -Iseconds)" \
        '{action: $action, target: $target, backup: $backup, timestamp: $ts}')
    if [ -f "$PZ_MANIFEST" ]; then
        jq ". += [$entry]" "$PZ_MANIFEST" > "${PZ_MANIFEST}.tmp" && mv "${PZ_MANIFEST}.tmp" "$PZ_MANIFEST"
    else
        echo "[$entry]" > "$PZ_MANIFEST"
    fi
}

pz_rollback() {
    if [ ! -f "$PZ_MANIFEST" ]; then
        pz_info "nothing to rollback"
        return 0
    fi
    local entries
    entries=$(jq -c 'reverse | .[]' "$PZ_MANIFEST")
    echo "$entries" | while read -r entry; do
        local action target backup
        action=$(echo "$entry" | jq -r '.action')
        target=$(echo "$entry" | jq -r '.target')
        backup=$(echo "$entry" | jq -r '.backup')
        case "$action" in
            file) cp "$backup" "$target" && pz_info "restored $target from $backup" ;;
            package) pz_info "rollback package $target: manual reinstall may be needed" ;;
            service) systemctl disable --now "$target" 2>/dev/null || true ;;
        esac
    done
    rm -f "$PZ_MANIFEST"
    pz_info "rollback complete"
}

pz_run_profile() {
    local profile_file="$1"
    if [ ! -f "$profile_file" ]; then
        pz_error "profile not found: $profile_file"
        return 1
    fi
    local dry_run="${PZ_DRY_RUN:-0}"
    local packages_scripts
    packages=$(jq -r '.packages.linux.pacman // [] | .[]' "$profile_file" 2>/dev/null || true)
    local yay_pkgs
    yay_pkgs=$(jq -r '.packages.linux.yay // [] | .[]' "$profile_file" 2>/dev/null || true)
    local flatpak_pkgs
    flatpak_pkgs=$(jq -r '.packages.linux.flatpak // [] | .[]' "$profile_file" 2>/dev/null || true)
    local scripts
    scripts=$(jq -r '.scripts.linux // [] | .[]' "$profile_file" 2>/dev/null || true)
    local system_services
    system_services=$(jq -r '.systemd.linux.enable // [] | .[]' "$profile_file" 2>/dev/null || true)
    local user_services
    user_services=$(jq -r '.systemd.linux.user // [] | .[]' "$profile_file" 2>/dev/null || true)
    local sysctl_entries
    sysctl_entries=$(jq -r '.tuning.linux.sysctl // {} | to_entries[] | "\(.key)=\(.value)"' "$profile_file" 2>/dev/null || true)

    if [ -n "$packages" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning pacman packages..." || pz_info "installing pacman packages..."
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install pacman package: $pkg"
                continue
            fi
            sudo pacman -S --needed --noconfirm "$pkg"
            pz_rollback_register package "$pkg" ""
        done <<< "$packages"
    fi

    if [ -n "$yay_pkgs" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning AUR packages..." || pz_info "installing AUR packages..."
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install AUR package: $pkg"
                continue
            fi
            yay -S --needed --noconfirm "$pkg"
            pz_rollback_register package "$pkg" ""
        done <<< "$yay_pkgs"
    fi

    if [ -n "$flatpak_pkgs" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning flatpak packages..." || pz_info "installing flatpak packages..."
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install flatpak package: $pkg"
                continue
            fi
            flatpak install -y flathub "$pkg"
            pz_rollback_register package "$pkg" ""
        done <<< "$flatpak_pkgs"
    fi

    if [ -n "$scripts" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning setup scripts..." || pz_info "running setup scripts..."
        while IFS= read -r script; do
            [ -z "$script" ] && continue
            local script_path="$PZ_ROOT/$script"
            if [ -f "$script_path" ]; then
                if [ "$dry_run" = "1" ]; then
                    pz_info "would execute $script_path"
                    continue
                fi
                pz_info "executing $script_path"
                bash "$script_path"
            else
                pz_warn "script not found: $script_path"
            fi
        done <<< "$scripts"
    fi

    if [ -n "$system_services" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning system services..." || pz_info "enabling system services..."
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would enable system service: $service"
                continue
            fi
            sudo systemctl enable --now "$service"
        done <<< "$system_services"
    fi

    if [ -n "$user_services" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning user services..." || pz_info "enabling user services..."
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would enable user service: $service"
                continue
            fi
            systemctl --user enable --now "$service"
        done <<< "$user_services"
    fi

    if [ -n "$sysctl_entries" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning sysctl tuning..." || pz_info "applying sysctl tuning..."
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would set sysctl: $entry"
                continue
            fi
            sudo sysctl -w "$entry"
        done <<< "$sysctl_entries"
    fi

    pz_info "profile $profile_file complete"
}
