#!/usr/bin/env bash
# dev-tweaks.sh - apply development environment optimizations
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_apply_sysctl() {
    local sysctl_conf="/etc/sysctl.d/99-phasezero-dev.conf"
    local backup="$sysctl_conf.bak.$(date +%s)"
    [ -f "$sysctl_conf" ] && sudo cp "$sysctl_conf" "$backup"

    cat | sudo tee "$sysctl_conf" >/dev/null <<'EOF'
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
    git config --global core.fsmonitor true
    git config --global core.untrackedcache true
    git config --global core.autocrlf input
    git config --global pull.rebase true
    git config --global fetch.prune true
    git config --global diff.algorithm histogram
    git config --global status.showUntrackedFiles normal
    git config --global init.defaultBranch main
    pz_info "git config optimized"
}

pz_configure_npm() {
    npm config set fund false
    npm config set audit false
    npm config set update-notifier false
    npm config set cache "${HOME}/.cache/npm"
    pz_info "npm config optimized"
}

pz_apply_sysctl
pz_configure_git
pz_configure_npm
pz_info "dev tweaks complete"
