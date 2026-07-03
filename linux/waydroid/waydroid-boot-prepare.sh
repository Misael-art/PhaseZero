#!/usr/bin/env bash
# waydroid-boot-prepare.sh - switch SDDM session for PhaseZero Waydroid boot
set -euo pipefail

TARGET_USER="${PZ_WAYDROID_BOOT_USER:-misael}"
CMDLINE="${PZ_BOOT_CMDLINE:-$(cat /proc/cmdline 2>/dev/null || true)}"
CONF_DIR="${PZ_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
CONF_FILE="$CONF_DIR/92-phasezero-waydroid.conf"
STEAMOS_CONF="$CONF_DIR/90-phasezero-steamos.conf"
WINDOWS_VM_CONF="$CONF_DIR/91-phasezero-windows-vm.conf"
SESSION="phasezero-waydroid.desktop"

log() {
    local msg="phasezero-waydroid-boot: $*"
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$msg" | systemd-cat -t phasezero-waydroid-boot >/dev/null 2>&1 || printf '%s\n' "$msg"
    else
        printf '%s\n' "$msg"
    fi
}

write_value() {
    local path="$1" value="$2"
    [ -e "$path" ] || return 0
    printf '%s\n' "$value" > "$path" 2>/dev/null || true
}

apply_waydroid_tuning() {
    command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set performance >/dev/null 2>&1 || true
    sysctl -w vm.swappiness=1 >/dev/null 2>&1 || true
    sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
    sysctl -w kernel.nmi_watchdog=0 >/dev/null 2>&1 || true
    write_value /sys/kernel/mm/transparent_hugepage/enabled madvise
    write_value /sys/kernel/mm/transparent_hugepage/defrag madvise
    local governor
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$governor" ] || continue
        write_value "$governor" performance
    done
    log "host Waydroid tuning applied"
}

ensure_binder_runtime() {
    modprobe binder_linux devices="binder,hwbinder,vndbinder" >/dev/null 2>&1 || true
    if [ ! -d /dev/binderfs ] && grep -qw binder /proc/filesystems 2>/dev/null; then
        install -d /dev/binderfs
        mount -t binder binder /dev/binderfs >/dev/null 2>&1 || true
    fi
}

start_waydroid_container() {
    systemctl list-unit-files waydroid-container.service >/dev/null 2>&1 || {
        log "waydroid-container.service missing"
        return 0
    }
    systemctl enable waydroid-container.service >/dev/null 2>&1 || true
    systemctl start waydroid-container.service >/dev/null 2>&1 || true
    log "waydroid-container service requested"
}

remove_managed_conf() {
    local file="$1"
    if [ -f "$file" ] && grep -q 'PhaseZero managed' "$file" 2>/dev/null; then
        rm -f "$file"
    fi
}

if printf '%s\n' "$CMDLINE" | grep -qw 'phasezero.waydroid=1'; then
    apply_waydroid_tuning
    ensure_binder_runtime
    start_waydroid_container
    install -d "$CONF_DIR"
    remove_managed_conf "$STEAMOS_CONF"
    remove_managed_conf "$WINDOWS_VM_CONF"
    cat > "$CONF_FILE" <<EOF
# PhaseZero managed: Waydroid one-shot GRUB boot profile
[Autologin]
User=$TARGET_USER
Session=$SESSION
Relogin=true
EOF
    chmod 0644 "$CONF_FILE"
    log "phasezero.waydroid=1 detected; wrote SDDM autologin for user=$TARGET_USER session=$SESSION"
    exit 0
fi

if [ -f "$CONF_FILE" ] && grep -q 'PhaseZero managed' "$CONF_FILE" 2>/dev/null; then
    rm -f "$CONF_FILE"
    log "normal boot detected; removed stale SDDM Waydroid autologin"
else
    log "normal boot detected; no Waydroid autologin changes"
fi
