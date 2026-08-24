#!/usr/bin/env bash
# install-privileged-controls.sh - install least-privilege TDP/GPU bridge for mode watcher
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
DRY_RUN=0
[ "$ACTION" = "dry-run" ] && DRY_RUN=1

resolve_target_user() {
    if [ -n "${PZ_TARGET_USER:-}" ]; then
        echo "$PZ_TARGET_USER"
        return 0
    fi

    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
        echo "$SUDO_USER"
        return 0
    fi

    local login_user
    login_user="$(logname 2>/dev/null || true)"
    if [ -n "$login_user" ] && [ "$login_user" != "root" ]; then
        echo "$login_user"
        return 0
    fi

    # CCS-038: último recurso é o UID 1000 do host, não um nome fixo.
    local uid_user
    uid_user="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
    if [ -n "$uid_user" ]; then
        echo "$uid_user"
        return 0
    fi
    echo "${USER:-}"
}

resolve_user_home() {
    local user="$1"
    getent passwd "$user" | cut -d: -f6
}

SOURCE_HELPER="$PZ_ROOT/linux/steamdeck/privileged-control.sh"
TARGET_DIR="/usr/local/lib/phasezero"
TARGET_HELPER="$TARGET_DIR/steamdeck-privileged-control"
SUDOERS_FILE="/etc/sudoers.d/phasezero-steamdeck"
WATCHER_UNIT="phasezero-steamdeck-mode-watcher.service"
TARGET_USER="$(resolve_target_user)"
TARGET_HOME="$(resolve_user_home "$TARGET_USER")"
if [ -z "$TARGET_HOME" ]; then
    pz_error "could not resolve home for target user: $TARGET_USER"
    exit 1
fi
DROPIN_DIR="$TARGET_HOME/.config/systemd/user/phasezero-steamdeck-mode-watcher.service.d"
DROPIN_FILE="$DROPIN_DIR/10-privileged-controls.conf"

sudoers_content() {
    cat <<EOF
# PhaseZero Steam Deck constrained privileged controls
# Allows only validated mode application through a fixed helper path.
$TARGET_USER ALL=(root) NOPASSWD: $TARGET_HELPER apply handheld
$TARGET_USER ALL=(root) NOPASSWD: $TARGET_HELPER apply docked-tv
$TARGET_USER ALL=(root) NOPASSWD: $TARGET_HELPER apply docked-monitor
$TARGET_USER ALL=(root) NOPASSWD: $TARGET_HELPER status
EOF
}

dropin_content() {
    cat <<EOF
[Service]
Environment=PZ_STEAMDECK_USE_SUDO=1
Environment=PZ_STEAMDECK_PRIVILEGED_HELPER=$TARGET_HELPER
EOF
}

need_root() {
    if [ "$EUID" -eq 0 ]; then
        return 0
    fi
    pz_error "root required. run: sudo $PZ_ROOT/linux/steamdeck/install-privileged-controls.sh install"
    return 1
}

install_user_dropin() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $DROPIN_FILE"
        return 0
    fi

    if [ "$EUID" -eq 0 ]; then
        install -d -o "$TARGET_USER" -g "$TARGET_USER" "$DROPIN_DIR"
        dropin_content > "$DROPIN_FILE"
        chown "$TARGET_USER:$TARGET_USER" "$DROPIN_FILE"
    else
        install -d "$DROPIN_DIR"
        dropin_content > "$DROPIN_FILE"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if [ "$EUID" -eq 0 ]; then
            runuser -u "$TARGET_USER" -- systemctl --user daemon-reload 2>/dev/null || true
            runuser -u "$TARGET_USER" -- systemctl --user restart "$WATCHER_UNIT" 2>/dev/null || true
        else
            systemctl --user daemon-reload 2>/dev/null || true
            systemctl --user restart "$WATCHER_UNIT" 2>/dev/null || true
        fi
    fi

    pz_info "wrote $DROPIN_FILE"
}

install_files() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would install $TARGET_HELPER"
        pz_info "dry-run: would write $SUDOERS_FILE for user $TARGET_USER"
        pz_info "dry-run: would write $DROPIN_FILE"
        return 0
    fi

    if [ "$EUID" -ne 0 ]; then
        install_user_dropin
        need_root
        return 1
    fi

    install -d "$TARGET_DIR"
    install -m 0755 "$SOURCE_HELPER" "$TARGET_HELPER"

    local tmp
    # shellcheck disable=SC2119 # pz_tempfile template arg optional; default mktemp template intended
    tmp="$(pz_tempfile)"
    sudoers_content > "$tmp"
    visudo -cf "$tmp" >/dev/null
    install -m 0440 "$tmp" "$SUDOERS_FILE"
    rm -f "$tmp"

    install_user_dropin

    pz_info "privileged controls installed"
}

remove_files() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would remove $TARGET_HELPER"
        pz_info "dry-run: would remove $SUDOERS_FILE"
        pz_info "dry-run: would remove $DROPIN_FILE"
        return 0
    fi

    need_root
    rm -f "$SUDOERS_FILE" "$TARGET_HELPER" "$DROPIN_FILE"
    runuser -u "$TARGET_USER" -- systemctl --user daemon-reload 2>/dev/null || true
    runuser -u "$TARGET_USER" -- systemctl --user restart "$WATCHER_UNIT" 2>/dev/null || true
    pz_info "privileged controls removed"
}

status_controls() {
    echo "helper: $TARGET_HELPER"
    [ -x "$TARGET_HELPER" ] && echo "helper_installed: yes" || echo "helper_installed: no"
    if [ -f "$SUDOERS_FILE" ] 2>/dev/null; then
        echo "sudoers_installed: yes"
    elif sudo -n "$TARGET_HELPER" status >/dev/null 2>&1; then
        echo "sudoers_installed: yes"
    else
        echo "sudoers_installed: no"
    fi
    [ -f "$DROPIN_FILE" ] && echo "watcher_dropin: yes" || echo "watcher_dropin: no"
    echo "target_user: $TARGET_USER"
    echo "target_home: $TARGET_HOME"
    if [ -x "$TARGET_HELPER" ] && command -v sudo >/dev/null 2>&1; then
        sudo -n "$TARGET_HELPER" status 2>/dev/null || true
    fi
}

case "$ACTION" in
    install) install_files ;;
    remove) remove_files ;;
    dry-run) install_files ;;
    status) status_controls ;;
    *) pz_error "usage: install-privileged-controls.sh (install|remove|dry-run|status)"; exit 1 ;;
esac
