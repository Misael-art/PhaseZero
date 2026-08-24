#!/usr/bin/env bash
# dev-tweaks.sh - apply development environment optimizations
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PZ_TUNE_MODE="${1:-apply}"
case "$PZ_TUNE_MODE" in
    apply) ;;
    --dry-run) ;;
    *) pz_error "usage: ${0##*/} [--dry-run]"; exit 1 ;;
esac
if [ "$PZ_TUNE_MODE" = "--dry-run" ]; then
    # Executa só o plano: imprime a mutação sem rodar git/npm/sudo.
    pz_tune_exec() { pz_info "dry-run: $*"; }
else
    pz_tune_exec() { "$@"; }
fi

pz_apply_sysctl() {
    local sysctl_conf="/etc/sysctl.d/99-phasezero-dev.conf"
    if [ "$PZ_TUNE_MODE" = "--dry-run" ]; then
        pz_info "dry-run: faria backup e escreveria sysctl de dev em: $sysctl_conf"
        return 0
    fi
    pz_backup_file "$sysctl_conf" root >/dev/null

    sudo tee "$sysctl_conf" >/dev/null <<'EOF'
# PhaseZero Dev Tweaks
# Increase file watcher limit (Node.js, VS Code, watchers)
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
fs.inotify.max_queued_events = 32768

# Network tuning for dev tools
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Memory management
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50

# Kernel same-page merging (KSM) for VMs
kernel.nmi_watchdog = 0
EOF
    sudo sysctl --system >/dev/null
    pz_info "sysctl dev tweaks applied: $sysctl_conf"
}

pz_configure_git() {
    pz_tune_exec git config --global core.fsmonitor true
    pz_tune_exec git config --global core.untrackedcache true
    pz_tune_exec git config --global core.autocrlf input
    pz_tune_exec git config --global pull.rebase true
    pz_tune_exec git config --global fetch.prune true
    pz_tune_exec git config --global diff.algorithm histogram
    pz_tune_exec git config --global status.showUntrackedFiles normal
    pz_tune_exec git config --global init.defaultBranch main
    pz_info "git config optimized"
}

pz_configure_npm() {
    pz_tune_exec npm config set fund false
    pz_tune_exec npm config set audit false
    pz_tune_exec npm config set update-notifier false
    pz_tune_exec npm config set cache "${HOME}/.cache/npm"
    pz_info "npm config optimized"
}

pz_apply_sysctl
pz_configure_git
pz_configure_npm
pz_info "dev tweaks complete"
