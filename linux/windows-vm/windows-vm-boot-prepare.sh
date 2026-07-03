#!/usr/bin/env bash
# windows-vm-boot-prepare.sh - switch SDDM session for PhaseZero Windows VM boot
set -euo pipefail

TARGET_USER="${PZ_WINDOWS_VM_BOOT_USER:-misael}"
CMDLINE="${PZ_BOOT_CMDLINE:-$(cat /proc/cmdline 2>/dev/null || true)}"
CONF_DIR="${PZ_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
CONF_FILE="$CONF_DIR/91-phasezero-windows-vm.conf"
STEAMOS_CONF="$CONF_DIR/90-phasezero-steamos.conf"
WAYDROID_CONF="$CONF_DIR/92-phasezero-waydroid.conf"
SESSION="phasezero-windows-vm.desktop"

log() {
    local msg="phasezero-windows-vm-boot: $*"
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$msg" | systemd-cat -t phasezero-windows-vm-boot >/dev/null 2>&1 || printf '%s\n' "$msg"
    else
        printf '%s\n' "$msg"
    fi
}

write_value() {
    local path="$1" value="$2"
    [ -e "$path" ] || return 0
    printf '%s\n' "$value" > "$path" 2>/dev/null || true
}

apply_vm_tuning() {
    command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set performance >/dev/null 2>&1 || true
    sysctl -w vm.swappiness=1 >/dev/null 2>&1 || true
    sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
    sysctl -w kernel.nmi_watchdog=0 >/dev/null 2>&1 || true
    write_value /sys/kernel/mm/transparent_hugepage/enabled madvise
    write_value /sys/kernel/mm/transparent_hugepage/defrag madvise
    write_value /sys/kernel/mm/ksm/run 1
    write_value /sys/kernel/mm/ksm/pages_to_scan 1000
    write_value /sys/kernel/mm/ksm/sleep_millisecs 20
    local governor
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$governor" ] || continue
        write_value "$governor" performance
    done
    log "host VM tuning applied"
}

if printf '%s\n' "$CMDLINE" | grep -qw 'phasezero.windowsvm=1'; then
    apply_vm_tuning
    install -d "$CONF_DIR"
    if [ -f "$STEAMOS_CONF" ] && grep -q 'PhaseZero managed' "$STEAMOS_CONF" 2>/dev/null; then
        rm -f "$STEAMOS_CONF"
    fi
    if [ -f "$WAYDROID_CONF" ] && grep -q 'PhaseZero managed' "$WAYDROID_CONF" 2>/dev/null; then
        rm -f "$WAYDROID_CONF"
    fi
    cat > "$CONF_FILE" <<EOF
# PhaseZero managed: Windows VM one-shot GRUB boot profile
[Autologin]
User=$TARGET_USER
Session=$SESSION
Relogin=true
EOF
    chmod 0644 "$CONF_FILE"
    log "phasezero.windowsvm=1 detected; wrote SDDM autologin for user=$TARGET_USER session=$SESSION"
    exit 0
fi

if [ -f "$CONF_FILE" ] && grep -q 'PhaseZero managed' "$CONF_FILE" 2>/dev/null; then
    rm -f "$CONF_FILE"
    log "normal boot detected; removed stale SDDM Windows VM autologin"
else
    log "normal boot detected; no Windows VM autologin changes"
fi
