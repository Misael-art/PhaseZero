#!/usr/bin/env bash
# steamos-boot-prepare.sh - switch SDDM session for PhaseZero GRUB console boot
set -euo pipefail

# CCS-038: resolução sem nome fixo.
TARGET_USER="${PZ_STEAMOS_BOOT_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
fi
CMDLINE="${PZ_BOOT_CMDLINE:-$(cat /proc/cmdline 2>/dev/null || true)}"
CONF_DIR="${PZ_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
CONF_FILE="$CONF_DIR/90-phasezero-steamos.conf"
WINDOWS_VM_CONF="$CONF_DIR/91-phasezero-windows-vm.conf"
WAYDROID_CONF="$CONF_DIR/92-phasezero-waydroid.conf"
SESSION="${PZ_STEAMOS_SESSION:-phasezero-steamos.desktop}"
SESSION_DIR="${PZ_WAYLAND_SESSION_DIR:-/usr/share/wayland-sessions}"

log() {
    local msg="phasezero-steamos-boot: $*"
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$msg" | systemd-cat -t phasezero-steamos-boot >/dev/null 2>&1 || printf '%s\n' "$msg"
    else
        printf '%s\n' "$msg"
    fi
}

if [ ! -f "$SESSION_DIR/$SESSION" ]; then
    log "managed session missing; falling back to gamescope-session-steam-plus.desktop"
    SESSION="gamescope-session-steam-plus.desktop"
fi
if [ ! -f "$SESSION_DIR/$SESSION" ]; then
    log "Steam Plus session missing; falling back to gamescope-session-steam.desktop"
    SESSION="gamescope-session-steam.desktop"
fi

if printf '%s\n' "$CMDLINE" | grep -qw 'phasezero.steamos=1'; then
    install -d "$CONF_DIR"
    rm -f "$WINDOWS_VM_CONF" "$WAYDROID_CONF"
    cat > "$CONF_FILE" <<EOF
# PhaseZero managed: SteamOS-like one-shot GRUB boot profile
[Autologin]
User=$TARGET_USER
Session=$SESSION
Relogin=true
EOF
    chmod 0644 "$CONF_FILE"
    log "phasezero.steamos=1 detected; wrote SDDM autologin for user=$TARGET_USER session=$SESSION"
    exit 0
fi

if [ -f "$CONF_FILE" ] && grep -q 'PhaseZero managed' "$CONF_FILE" 2>/dev/null; then
    rm -f "$CONF_FILE"
    log "normal boot detected; removed stale SDDM SteamOS autologin"
else
    log "normal boot detected; no SteamOS autologin changes"
fi
