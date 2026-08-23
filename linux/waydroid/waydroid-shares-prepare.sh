#!/usr/bin/env bash
# waydroid-shares-prepare.sh - managed host storage and USB access for Waydroid
set -euo pipefail

ACTION="${1:-install}"
# CCS-038: resolução sem nome fixo.
TARGET_USER="${PZ_WAYDROID_BOOT_USER:-${PZ_TARGET_USER:-}}"
case "$TARGET_USER" in ""|"root") TARGET_USER="$(logname 2>/dev/null || true)" ;; esac
case "$TARGET_USER" in ""|"root") TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)" ;; esac
case "$TARGET_USER" in ""|"root") TARGET_USER="${SUDO_USER:-${USER:-}}" ;; esac
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] || {
    printf 'waydroid-shares: unable to resolve target user; set PZ_WAYDROID_BOOT_USER\n' >&2
    exit 1
}
TARGET_HOME="${PZ_WAYDROID_TARGET_HOME:-$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
SHARES_CONFIG="${PZ_WAYDROID_LXC_SHARES_CONFIG:-/etc/phasezero/waydroid-lxc-shares.conf}"
LXC_CONFIG_BASE="${PZ_WAYDROID_LXC_CONFIG_BASE:-/usr/lib/waydroid/data/configs/config_base}"
LXC_CONFIG="${PZ_WAYDROID_LXC_CONFIG:-/var/lib/waydroid/lxc/waydroid/config}"
ANDROID_MEDIA_ROOT="${PZ_WAYDROID_ANDROID_MEDIA_ROOT:-$TARGET_HOME/.local/share/waydroid/data/media/0}"
SDCARD_PATH="${PZ_WAYDROID_SDCARD_PATH:-/mnt/sdcard}"
REMOVABLE_PATH="${PZ_WAYDROID_REMOVABLE_PATH:-/run/media/$TARGET_USER}"
MEDIA_PATH="${PZ_WAYDROID_MEDIA_PATH:-/media/$TARGET_USER}"
MOUNTS_PATH="${PZ_WAYDROID_MOUNTS_PATH:-/mnt}"
USB_BUS_PATH="${PZ_WAYDROID_USB_BUS_PATH:-/dev/bus/usb}"
MEDIA_RW_UID="${PZ_WAYDROID_MEDIA_RW_UID:-1023}"
SHARE_EXTRA="${PZ_WAYDROID_SHARE_EXTRA:-}"
SKIP_ACL="${PZ_WAYDROID_SHARE_SKIP_ACL:-0}"
TEST_MODE="${PZ_WAYDROID_SHARE_TEST_MODE:-0}"
# CCS-015: grupos independentes de compartilhamento. "all" mantém o legado;
# listas ("folders", "usb") tornam host-folders e barramento USB toggles
# separados, sem um derrubar o estado do outro.
SHARE_GROUPS="${PZ_WAYDROID_SHARE_GROUPS:-all}"
INCLUDE_LINE="lxc.include = $SHARES_CONFIG"

_PZ_TMP=()
_pz_cleanup() { rm -f "${_PZ_TMP[@]}" 2>/dev/null || true; }
trap _pz_cleanup EXIT

log() {
    printf 'waydroid-shares: %s\n' "$*"
}

need_root() {
    [ "$EUID" -eq 0 ] || [ "$TEST_MODE" = "1" ] || {
        printf 'waydroid-shares: root required\n' >&2
        return 1
    }
}

lxc_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value// /\\040}"
    printf '%s\n' "$value"
}

xdg_user_dir() {
    local key="$1" value=""
    if command -v xdg-user-dir >/dev/null 2>&1; then
        if [ "$EUID" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
            value="$(runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" XDG_CONFIG_HOME="$TARGET_HOME/.config" xdg-user-dir "$key" 2>/dev/null || true)"
        else
            value="$(HOME="$TARGET_HOME" XDG_CONFIG_HOME="$TARGET_HOME/.config" xdg-user-dir "$key" 2>/dev/null || true)"
        fi
    fi
    printf '%s\n' "$value"
}

grant_media_access() {
    local path="$1"
    [ "$SKIP_ACL" = "1" ] && return 0
    command -v setfacl >/dev/null 2>&1 || return 0
    setfacl -R -m "u:$MEDIA_RW_UID:rwX" "$path" >/dev/null 2>&1 || true
    find "$path" -type d -exec setfacl -m "d:u:$MEDIA_RW_UID:rwx" {} + >/dev/null 2>&1 || true
}

ensure_android_dir() {
    if [ "$EUID" -eq 0 ] && [ "$TEST_MODE" != "1" ]; then
        install -d -m 0770 -o "$MEDIA_RW_UID" -g "$MEDIA_RW_UID" "$@"
    else
        install -d -m 0770 "$@"
    fi
}

add_mount() {
    local output="$1" source="$2" target="$3" options="${4:-rbind,create=dir,optional}"
    [ -e "$source" ] || return 0
    printf 'lxc.mount.entry = %s %s none %s 0 0\n' \
        "$(lxc_escape "$source")" \
        "$(lxc_escape "$target")" \
        "$options" >> "$output"
}

ensure_include() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -Fqx "$INCLUDE_LINE" "$file" || printf '\n%s\n' "$INCLUDE_LINE" >> "$file"
}

remove_include() {
    local file="$1" tmp
    [ -f "$file" ] || return 0
    tmp="$(mktemp)" && _PZ_TMP+=("$tmp")
    grep -Fvx "$INCLUDE_LINE" "$file" > "$tmp" || true
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

# Grupos presentes no config gerenciado atual (folders = tudo sob Host/,
# usb = barramento /dev/bus/usb).
config_targets() {
    sed -n 's/^lxc\.mount\.entry = \([^ ]*\) \([^ ]*\) .*/\2/p' "$SHARES_CONFIG" 2>/dev/null || true
}

current_groups() {
    local out=""
    if config_targets | grep -q '^data/media/0/Host/'; then
        out="folders"
    fi
    if config_targets | grep -q '^dev/bus/usb'; then
        out="${out:+$out,}usb"
    fi
    printf '%s\n' "${out:-none}"
}

list_has() {
    case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

# Conjunto efetivo de grupos para a escrita do config.
effective_groups() {
    local current
    current="$(current_groups)"
    if [ "$SHARE_GROUPS" = "all" ]; then
        printf '%s\n' "folders,usb"
        return 0
    fi
    if [ "$ACTION" = "remove" ]; then
        # remove: subtrai os grupos pedidos do estado atual.
        local out="" group
        IFS=',' read -r -a group <<< "$current"
        local g
        for g in "${group[@]:-}"; do
            [ -n "$g" ] || continue
            list_has "$SHARE_GROUPS" "$g" || out="${out:+$out,}$g"
        done
        printf '%s\n' "${out:-none}"
        return 0
    fi
    # install com lista: união do estado atual com o pedido.
    local out="$current" group g
    IFS=',' read -r -a group <<< "$SHARE_GROUPS"
    for g in "${group[@]:-}"; do
        [ -n "$g" ] || continue
        list_has "$out" "$g" || out="${out:+$out,}$g"
    done
    printf '%s\n' "$out"
}

write_config() {
    local tmp key label path extra groups
    groups="$(effective_groups)"
    [ -n "$TARGET_HOME" ] || {
        printf 'waydroid-shares: target home unresolved for %s\n' "$TARGET_USER" >&2
        return 1
    }
    tmp="$(mktemp)" && _PZ_TMP+=("$tmp")
    printf '%s\n' '# PhaseZero managed Waydroid host storage and USB access.' > "$tmp"
    printf '%s\n' "# groups: $groups" >> "$tmp"
    printf '%s\n' '# Hidden credential directories are intentionally excluded.' >> "$tmp"

    if list_has "$groups" folders; then
        while read -r key label; do
            [ -n "$key" ] || continue
            path="$(xdg_user_dir "$key")"
            [ -d "$path" ] || continue
            ensure_android_dir "$ANDROID_MEDIA_ROOT/Host/Home/$label"
            grant_media_access "$path"
            add_mount "$tmp" "$path" "data/media/0/Host/Home/$label"
        done <<'EOF'
DESKTOP Desktop
DOWNLOAD Downloads
DOCUMENTS Documents
MUSIC Music
PICTURES Pictures
VIDEOS Videos
PUBLICSHARE Public
TEMPLATES Templates
EOF

        # Opt-in: expose the whole home (incl. dotfiles) instead of just XDG folders.
        # Default stays XDG-only so Android apps never see ~/.ssh, keys, tokens, etc.
        if [ "${PZ_WAYDROID_SHARE_FULL_HOME:-0}" = "1" ] && [ -d "$TARGET_HOME" ]; then
            ensure_android_dir "$ANDROID_MEDIA_ROOT/Host/Home/All"
            grant_media_access "$TARGET_HOME"
            add_mount "$tmp" "$TARGET_HOME" "data/media/0/Host/Home/All"
        fi

        install -d -o "$TARGET_USER" -g "$TARGET_USER" "$REMOVABLE_PATH" "$MEDIA_PATH"
        ensure_android_dir "$ANDROID_MEDIA_ROOT/Host/SDCard" "$ANDROID_MEDIA_ROOT/Host/Removable" \
            "$ANDROID_MEDIA_ROOT/Host/Media" "$ANDROID_MEDIA_ROOT/Host/Mounts" "$ANDROID_MEDIA_ROOT/Host/Extra"

        add_mount "$tmp" "$SDCARD_PATH" data/media/0/Host/SDCard
        add_mount "$tmp" "$REMOVABLE_PATH" data/media/0/Host/Removable
        add_mount "$tmp" "$MEDIA_PATH" data/media/0/Host/Media
        add_mount "$tmp" "$MOUNTS_PATH" data/media/0/Host/Mounts
    fi

    if list_has "$groups" usb; then
        add_mount "$tmp" "$USB_BUS_PATH" dev/bus/usb
    fi

    if list_has "$groups" folders; then
        IFS=: read -r -a extras <<< "$SHARE_EXTRA"
        for extra in "${extras[@]:-}"; do
            [ -d "$extra" ] || continue
            label="$(basename "$extra" | tr -c '[:alnum:]_.-' '_')"
            ensure_android_dir "$ANDROID_MEDIA_ROOT/Host/Extra/$label"
            grant_media_access "$extra"
            add_mount "$tmp" "$extra" "data/media/0/Host/Extra/$label"
        done
    fi

    install -d "$(dirname "$SHARES_CONFIG")"
    install -m 0644 "$tmp" "$SHARES_CONFIG"
    rm -f "$tmp"
    ensure_include "$LXC_CONFIG_BASE"
    ensure_include "$LXC_CONFIG"
}

status() {
    local mounts=0 ready=no
    [ -r "$SHARES_CONFIG" ] && mounts="$(grep -c '^lxc.mount.entry = ' "$SHARES_CONFIG" || true)"
    if [ "$mounts" -gt 0 ] &&
        grep -Fqx "$INCLUDE_LINE" "$LXC_CONFIG_BASE" 2>/dev/null &&
        grep -Fqx "$INCLUDE_LINE" "$LXC_CONFIG" 2>/dev/null; then
        ready=yes
    fi
    echo "shares_config: $SHARES_CONFIG"
    echo "shares_ready: $ready"
    echo "mount_count: $mounts"
    echo "android_host_root: $ANDROID_MEDIA_ROOT/Host"
    echo "usb_bus_shared: $(grep -Fq ' dev/bus/usb ' "$SHARES_CONFIG" 2>/dev/null && echo yes || echo no)"
}

case "$ACTION" in
    install|repair)
        need_root
        write_config
        status
        ;;
    remove)
        need_root
        if [ "$SHARE_GROUPS" != "all" ] && [ "$(effective_groups)" != "none" ]; then
            # Remoção por grupo: reescreve o config sem o grupo pedido.
            write_config
            log "managed Waydroid share groups removed: $SHARE_GROUPS"
        else
            remove_include "$LXC_CONFIG_BASE"
            remove_include "$LXC_CONFIG"
            rm -f "$SHARES_CONFIG"
            log "managed Waydroid shares removed"
        fi
        status
        ;;
    status|--status)
        status
        ;;
    dry-run|plan)
        echo "Waydroid shared access plan (groups: $(effective_groups))"
        echo "  personal folders: $TARGET_HOME (XDG directories only)"
        echo "  SD card: $SDCARD_PATH"
        echo "  removable: $REMOVABLE_PATH and $MEDIA_PATH"
        echo "  mounts: $MOUNTS_PATH"
        echo "  USB bus: $USB_BUS_PATH"
        echo "  Android path: Internal storage/Host"
        ;;
    *)
        printf 'usage: waydroid-shares-prepare.sh (install|repair|remove|status|dry-run)\n' >&2
        exit 2
        ;;
esac
