#!/usr/bin/env bash
# install-removable-mount.sh - auto-mount USB removable filesystems via udisks2,
# coordinated with Waydroid and the Windows VM. Devices mount under the standard
# /run/media/$USER tree that both consumers already bind into.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ARGS=()
ESCALATION_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target-user)
            [ -n "${2:-}" ] || { pz_error "--target-user requires a user"; exit 2; }
            export PZ_TARGET_USER="$2"
            ESCALATION_ARGS+=("--target-user" "$2")
            shift 2
            ;;
        --target-user=*)
            export PZ_TARGET_USER="${1#*=}"
            ESCALATION_ARGS+=("$1")
            shift
            ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

ACTION="${1:-status}"
TARGET_USER="${PZ_TARGET_USER:-${SUDO_USER:-${USER:-}}}"
if [ "$TARGET_USER" = "root" ] && [ -n "${PKEXEC_UID:-}" ]; then
    TARGET_USER="$(getent passwd "$PKEXEC_UID" 2>/dev/null | cut -d: -f1 || true)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
fi
getent passwd "$TARGET_USER" >/dev/null 2>&1 || {
    pz_error "invalid non-root target user; pass --target-user USER"
    exit 2
}
[ "$TARGET_USER" != "root" ] || { pz_error "target user cannot be root"; exit 2; }

UDEV_RULE="/etc/udev/rules.d/73-phasezero-removable-mount.rules"
SERVICE_UNIT="/etc/systemd/system/phasezero-removable-mount@.service"
HELPER_TARGET="/usr/local/lib/phasezero/removable-mount-helper"
HELPER_SOURCE="$PZ_ROOT/linux/steamdeck/removable-mount-helper.sh"
need_root_action() {
    local action="$1"; shift || true
    [ "$EUID" -eq 0 ] && return 0
    if command -v pkexec >/dev/null 2>&1 && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }; then
        exec pkexec bash "$0" "${ESCALATION_ARGS[@]}" "$action" "$@"
    fi
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash "$0" "${ESCALATION_ARGS[@]}" "$action" "$@"
    fi
    pz_error "root required for $action. install pkexec or run: sudo $0 $action"
    return 1
}

vm_is_running() {
    if command -v virsh >/dev/null 2>&1; then
        [ "$(LC_ALL=C virsh domstate phasezero-windows 2>/dev/null || true)" = "running" ] && return 0
    fi
    pgrep -af 'qemu.*phasezero-windows' >/dev/null 2>&1
}

vm_session_active() {
    # A dedicated Windows-VM boot session (kernel cmdline marker) means the host
    # is acting as a VM host only; let the VM own the USB devices.
    grep -qw 'phasezero.windowsvm=1' /proc/cmdline 2>/dev/null
}

udev_rule_content() {
    cat <<'EOF'
# PhaseZero managed: auto-mount USB removable filesystems via udisks2.
# Only block devices with a recognized filesystem on the USB bus; the helper
# gates on a running Windows VM to avoid claiming a device it is passing through.
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_USAGE}=="filesystem", ENV{ID_BUS}=="usb", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="phasezero-removable-mount@%k.service"
EOF
}

service_content() {
    cat <<EOF
# PhaseZero managed: per-device auto-mount helper (instantiated by the udev rule).
[Unit]
Description=PhaseZero auto-mount for %i
BindsTo=dev-%i.device
After=dev-%i.device

[Service]
Type=oneshot
Environment=PZ_TARGET_USER=$TARGET_USER
ExecStart=$HELPER_TARGET %i
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes
ReadWritePaths=/run/media /var/log/phasezero
EOF
}

install_unit() {
    need_root_action install
    if ! command -v udisksctl >/dev/null 2>&1; then
        pz_error "udisks2 missing; install with: sudo pacman -S udisks2"
        return 1
    fi
    install -d /usr/local/lib/phasezero
    install -m 0755 "$HELPER_SOURCE" "$HELPER_TARGET"
    install -d "$(dirname "$UDEV_RULE")"
    udev_rule_content > "$UDEV_RULE"
    chmod 0644 "$UDEV_RULE"
    install -d "$(dirname "$SERVICE_UNIT")"
    service_content > "$SERVICE_UNIT"
    chmod 0644 "$SERVICE_UNIT"
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=add 2>/dev/null || true
    pz_info "removable auto-mount installed (udev rule + systemd template)"
    pz_info "devices mount under /run/media/$TARGET_USER; Waydroid/Windows-VM already bind this tree"
    mount_present_usb
}

remove_unit() {
    need_root_action remove
    rm -f "$UDEV_RULE" "$SERVICE_UNIT" "$HELPER_TARGET"
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    pz_info "removable auto-mount removed"
}

# Best-effort initial mount of USB filesystems already present at install time.
mount_present_usb() {
    [ "$EUID" -eq 0 ] || return 0
    if vm_is_running; then
        pz_warn "Windows VM is running; skipping initial mount of present USB devices"
        return 0
    fi
    local dev
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        PZ_TARGET_USER="$TARGET_USER" "$HELPER_TARGET" "$dev" || true
    done < <(enumerate_usb_filesystem_devnodes)
}

enumerate_usb_filesystem_devnodes() {
    # Yield kernel device names (e.g. sde1) for USB block devices that carry a
    # filesystem, using udev properties. Empty if udevadm is unavailable.
    command -v udevadm >/dev/null 2>&1 || return 0
    local line name
    while IFS= read -r line; do
        name="$(printf '%s' "$line" | awk -F= '{print $1}')"
        [ -n "$name" ] || continue
        printf '%s\n' "$name"
    done < <(udevadm info --export-db 2>/dev/null | awk '
        /^P:/ { name=""; usage=""; bus="" }
        /^N:/ { name=$2 }
        /ID_FS_USAGE=/ { usage=$0; sub(/.*ID_FS_USAGE=/,"",usage) }
        /ID_BUS=/ { bus=$0; sub(/.*ID_BUS=/,"",bus) }
        /^E:/ && usage=="filesystem" && bus=="usb" && name!="" { print name; name="" }
    ')
}

status_unit() {
    local mounted=0
    echo "helper: $HELPER_TARGET"
    [ -x "$HELPER_TARGET" ] && echo "helper_installed: yes" || echo "helper_installed: no"
    [ -f "$UDEV_RULE" ] && echo "udev_rule: yes" || echo "udev_rule: no"
    [ -f "$SERVICE_UNIT" ] && echo "systemd_template: yes" || echo "systemd_template: no"
    command -v udisksctl >/dev/null 2>&1 && echo "udisks2: yes" || echo "udisks2: no"
    if vm_is_running; then echo "windows_vm_running: yes"; else echo "windows_vm_running: no"; fi
    if vm_session_active; then echo "vm_dedicated_session: yes"; else echo "vm_dedicated_session: no"; fi
    echo "mount_root: /run/media/$TARGET_USER"
    echo "mounted_phasezero_managed:"
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        echo "  - $m"
        mounted=$((mounted + 1))
    done < <(lsblk -npo NAME,MOUNTPOINT 2>/dev/null | awk -v u="$TARGET_USER" '$2 ~ "/run/media/"u {print $0}')
    echo "mounted_count: $mounted"
}

case "$ACTION" in
    install) install_unit ;;
    remove) remove_unit ;;
    status) status_unit ;;
    dry-run|plan)
        echo "PhaseZero removable auto-mount dry-run"
        echo "  udev rule: $UDEV_RULE"
        echo "  service: $SERVICE_UNIT"
        echo "  helper: $HELPER_TARGET"
        echo "  mount root: /run/media/$TARGET_USER"
        echo "  vm gate: skip when Windows VM running or phasezero.windowsvm=1 boot session"
        echo "  present USB filesystems:"
        enumerate_usb_filesystem_devnodes | sed 's/^/    /' || echo "    (none / udevadm unavailable)"
        ;;
    *)
        pz_error "usage: install-removable-mount.sh (install|remove|status|dry-run)"
        exit 1
        ;;
esac
