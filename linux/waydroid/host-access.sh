#!/usr/bin/env bash
# host-access.sh - let the Linux host browse Waydroid's internal Android storage.
#
# Guest->host sharing is handled by waydroid-shares-prepare.sh (LXC binds). This
# is the reverse: Waydroid keeps its Android userdata on the host filesystem, so
# we expose a friendly symlink (~/Waydroid) to the guest's internal storage and
# report where app data lives. No mounting/root needed for the media tree.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
# CCS-038: usuário alvo resolvido, nunca fixo no código.
TARGET_USER="${PZ_WAYDROID_BOOT_USER:-$(pz_resolve_target_user)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
DATA_ROOT="${PZ_WAYDROID_DATA_ROOT:-$TARGET_HOME/.local/share/waydroid/data}"
MEDIA_ROOT="$DATA_ROOT/media/0"
SYSTEM_DATA="/var/lib/waydroid/data"      # app-private data (root-owned)
LINK="${PZ_WAYDROID_HOST_LINK:-$TARGET_HOME/Waydroid}"

cmd_link() {
    if [ ! -d "$MEDIA_ROOT" ]; then
        pz_warn "Waydroid internal storage not found at $MEDIA_ROOT (start Waydroid once first)"
        return 0
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would symlink $LINK -> $MEDIA_ROOT"
        return 0
    fi
    ln -sfn "$MEDIA_ROOT" "$LINK"
    pz_info "Waydroid internal storage browsable at: $LINK -> $MEDIA_ROOT"
    pz_info "app-private data (root): $SYSTEM_DATA"
}

cmd_unlink() {
    if [ -L "$LINK" ] && rm -f "$LINK"; then pz_info "removed $LINK"; else pz_info "no managed link at $LINK"; fi
}

cmd_status() {
    jq -n \
        --arg media "$MEDIA_ROOT" --arg link "$LINK" --arg sys "$SYSTEM_DATA" \
        --argjson mediaExists "$([ -d "$MEDIA_ROOT" ] && echo true || echo false)" \
        --argjson linked "$([ -L "$LINK" ] && echo true || echo false)" \
        '{tool:"waydroid-host-access", internalStorage:$media, exists:$mediaExists,
          hostLink:$link, linked:$linked, appPrivateData:$sys}'
}

case "$ACTION" in
    link|install|mount) cmd_link ;;
    unlink|remove) cmd_unlink ;;
    status) cmd_status ;;
    dry-run|plan) PZ_DRY_RUN=1 cmd_link ;;
    *) pz_error "usage: host-access.sh (link|unlink|status|dry-run)"; exit 2 ;;
esac
