#!/usr/bin/env bash
# homelab-boot-prepare.sh - brings up the enabled home-server components when the
# host was booted via the PhaseZero Homelab GRUB entry. Installed to
# /usr/local/lib/phasezero/homelab-boot-prepare and driven by the
# phasezero-homelab-boot-prepare.service oneshot. Reads /etc/phasezero/server-mode.env.
set -euo pipefail

# EnvironmentFile provides these; fall back to the mode env directly if run by hand.
[ -n "${PZ_ROOT:-}" ] || { [ -f /etc/phasezero/server-mode.env ] && . /etc/phasezero/server-mode.env; }
PZ_ROOT="${PZ_ROOT:-/mnt/sdcard/Projects/PhaseZero}"
PZ_SERVER_USER="${PZ_SERVER_USER:-misael}"

log() { printf '[homelab-boot-prepare] %s\n' "$*"; }

# Only act on an actual homelab boot (belt-and-suspenders vs. the unit Condition).
if ! grep -qw 'phasezero.homelab=1' /proc/cmdline 2>/dev/null; then
    log "not a homelab boot (marker absent); nothing to do"
    exit 0
fi

if [ "${PZ_SERVER_LLM:-0}" = "1" ]; then
    log "ensuring Ollama service"
    systemctl start ollama >/dev/null 2>&1 || log "ollama start skipped"
fi

if [ "${PZ_SERVER_HOMELAB:-0}" = "1" ]; then
    log "bringing up homelab docker stack (extras=${PZ_SERVER_EXTRAS:-0})"
    systemctl start docker >/dev/null 2>&1 || true
    extra_flag=""; [ "${PZ_SERVER_EXTRAS:-0}" = "1" ] && extra_flag="--extras"
    bash "$PZ_ROOT/linux/server/homelab-stack.sh" up $extra_flag || log "homelab stack bring-up reported issues"
fi

if [ "${PZ_SERVER_HERMES:-0}" = "1" ]; then
    log "starting Hermes remote agent for $PZ_SERVER_USER"
    bash "$PZ_ROOT/linux/server/hermes-remote.sh" start || log "hermes start skipped"
fi

log "homelab boot bring-up complete"
