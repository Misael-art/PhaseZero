#!/usr/bin/env bash
# apply-common.sh - shared applier for the server-* profiles. Sourced by the
# per-mode wrapper scripts (profiles run scripts without args, so each mode gets
# its own tiny wrapper that calls pz_server_apply with the right flags).
set -euo pipefail

PZ_SERVER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_SERVER_ROOT/linux/lib/common.sh"

pz_server_apply() {
    local llm=0 homelab=0 hermes=0 extras=0 install_boot=1 flags=() a
    for a in "$@"; do
        case "$a" in
            --llm) llm=1 ;;
            --homelab) homelab=1 ;;
            --hermes) hermes=1 ;;
            --extras) extras=1 ;;
            --no-boot) install_boot=0 ;;
        esac
    done

    if [ "$llm" = 1 ]; then
        pz_info "server: setting up local LLM (Ollama)"
        bash "$PZ_SERVER_ROOT/linux/server/llm-server.sh" install || pz_warn "llm-server setup reported issues"
        flags+=(--llm)
    fi
    if [ "$homelab" = 1 ]; then
        pz_info "server: bringing up homelab stack"
        local extra_flag=""; [ "$extras" = 1 ] && extra_flag="--extras"
        bash "$PZ_SERVER_ROOT/linux/server/homelab-stack.sh" up $extra_flag || pz_warn "homelab stack reported issues"
        flags+=(--homelab)
        [ "$extras" = 1 ] && flags+=(--extras)
    fi
    if [ "$hermes" = 1 ]; then
        pz_info "server: configuring Hermes remote actuation"
        bash "$PZ_SERVER_ROOT/linux/server/hermes-remote.sh" setup || pz_warn "hermes setup reported issues"
        flags+=(--hermes)
    fi

    # Register the reversible headless GRUB entry (self-escalates). Skippable via
    # PZ_SERVER_INSTALL_BOOT=0 for users who only want the components.
    if [ "$install_boot" = 1 ] && [ "${PZ_SERVER_INSTALL_BOOT:-1}" = 1 ]; then
        pz_info "server: registering PhaseZero Homelab GRUB entry (${flags[*]})"
        bash "$PZ_SERVER_ROOT/linux/server/install-homelab-boot.sh" install "${flags[@]}" ||
            pz_warn "GRUB entry not installed (needs root); run: sudo pz server boot install ${flags[*]}"
    else
        pz_info "server: skipped GRUB entry (PZ_SERVER_INSTALL_BOOT=0). Register later: sudo pz server boot install ${flags[*]}"
    fi
    pz_info "server profile applied."
}
