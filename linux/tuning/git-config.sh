#!/usr/bin/env bash
# git-config.sh - apply idempotent Git defaults for PhaseZero Linux profiles
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_configure_git() {
    git config --global core.fsmonitor true
    git config --global core.untrackedcache true
    git config --global core.autocrlf input
    git config --global pull.rebase true
    git config --global fetch.prune true
    git config --global diff.algorithm histogram
    git config --global status.showUntrackedFiles normal
    git config --global init.defaultBranch main
    if command -v git-lfs >/dev/null 2>&1; then
        git lfs install --skip-repo >/dev/null 2>&1 || true
    fi
    pz_info "git config optimized"
}

pz_check_deps git >/dev/null
pz_configure_git
