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
BINDERFS_DIR="${PZ_WAYDROID_BINDERFS_DIR:-/dev/binderfs}"
LXC_CONFIG_BASE="${PZ_WAYDROID_LXC_CONFIG_BASE:-/usr/lib/waydroid/data/configs/config_base}"
LXC_CONFIG="${PZ_WAYDROID_LXC_CONFIG:-/var/lib/waydroid/lxc/waydroid/config}"

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
    if [ "${PZ_WAYDROID_SKIP_RUNTIME:-0}" = "1" ]; then
        log "host Waydroid tuning skipped by environment"
        return 0
    fi
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
    if [ "${PZ_WAYDROID_SKIP_RUNTIME:-0}" = "1" ]; then
        log "binder runtime skipped by environment"
        return 0
    fi
    modprobe binder_linux devices="binder,hwbinder,vndbinder" >/dev/null 2>&1 || true
    if grep -qw binder /proc/filesystems 2>/dev/null; then
        install -d "$BINDERFS_DIR"
        if ! mountpoint -q "$BINDERFS_DIR"; then
            mount -t binder binder "$BINDERFS_DIR" >/dev/null 2>&1 ||
                log "failed to mount binder filesystem at $BINDERFS_DIR"
        fi
    fi
    if [ ! -e "$BINDERFS_DIR/binder" ] && [ ! -e /dev/binder ]; then
        log "binder device missing after runtime setup"
    fi
}

repair_lxc_post_stop_hook() {
    [ "${PZ_WAYDROID_SKIP_RUNTIME:-0}" = "1" ] && return 0
    local file
    for file in "$LXC_CONFIG_BASE" "$LXC_CONFIG"; do
        [ -f "$file" ] || continue
        if grep -Fqx 'lxc.hook.post-stop = /dev/null' "$file"; then
            sed -i 's|^lxc\.hook\.post-stop = /dev/null$|lxc.hook.post-stop = /usr/bin/true|' "$file"
            log "repaired non-executable LXC post-stop hook in $file"
        fi
    done
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

ensure_binder_runtime
repair_lxc_post_stop_hook

if printf '%s\n' "$CMDLINE" | grep -qw 'phasezero.waydroid=1'; then
    apply_waydroid_tuning
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
