#!/usr/bin/env bash
# windows-vm.sh - QEMU/KVM Windows VM automation for PhaseZero Linux hosts
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

# virsh output is parsed (domstate, domblklist); force C locale so state
# strings stay "running" instead of localized ("executando", ...).
virsh() { LC_ALL=C command virsh "$@"; }

ACTION="${1:-status}"
[ $# -gt 0 ] && shift || true

TARGET_USER="${PZ_TARGET_USER:-${SUDO_USER:-${USER:-misael}}}"
[ "$TARGET_USER" = "root" ] && TARGET_USER="misael"
if [ "$EUID" -eq 0 ]; then
    target_home_root="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
    [ -n "$target_home_root" ] && export HOME="$target_home_root"
fi

VM_NAME_DEFAULT="PhaseZero-Windows"
VM_DIR_DEFAULT="$HOME/VirtualMachines/PhaseZero-Windows"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero"
CONFIG_FILE="${PZ_WINDOWS_VM_CONFIG:-$CONFIG_DIR/windows-vm.conf}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/phasezero-windows-vm"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

BOOT_HELPER_SOURCE="$PZ_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
SESSION_SOURCE="$PZ_ROOT/linux/windows-vm/windows-vm-session.sh"
DISPLAY_SESSION_SOURCE="$PZ_ROOT/linux/steamdeck/display-session.sh"
BOOT_HELPER_TARGET="/usr/local/lib/phasezero/windows-vm-boot-prepare"
SESSION_TARGET="/usr/local/lib/phasezero/windows-vm-session"
DISPLAY_SESSION_TARGET="/usr/local/lib/phasezero/display-session"
RUNTIME_ROOT="/usr/local/lib/phasezero/windows-vm-runtime"
RUNTIME_LAUNCHER="$RUNTIME_ROOT/linux/windows-vm/windows-vm.sh"
RUNTIME_GRAPHICS="$RUNTIME_ROOT/linux/windows-vm/graphics.sh"
RUNTIME_COMMON="$RUNTIME_ROOT/linux/lib/common.sh"
ROOT_ENV_FILE="/etc/phasezero/windows-vm.env"
SERVICE_FILE="/etc/systemd/system/phasezero-windows-vm-boot-prepare.service"
WAYLAND_SESSION_FILE="/usr/share/wayland-sessions/phasezero-windows-vm.desktop"
XSESSION_FILE="/usr/share/xsessions/phasezero-windows-vm.desktop"
GRUB_SCRIPT="/etc/grub.d/43_phasezero_windows_vm"
GRUB_CFG="/boot/grub/grub.cfg"
SDDM_CONF="/etc/sddm.conf.d/91-phasezero-windows-vm.conf"
BOOT_ENTRY="PhaseZero Windows VM"
BOOT_ID="phasezero-windows-vm"
SAMBA_CONF="${PZ_WINDOWS_VM_SAMBA_CONF:-/etc/samba/smb.conf}"
SAMBA_BEGIN="# BEGIN PHASEZERO WINDOWS VM SHARES"
SAMBA_END="# END PHASEZERO WINDOWS VM SHARES"
USB_UDEV_RULE="${PZ_WINDOWS_VM_USB_UDEV_RULE:-/etc/udev/rules.d/72-phasezero-windows-vm-usb.rules}"
EXCHANGE_DIR="${PZ_WINDOWS_VM_EXCHANGE_DIR:-$HOME/Shared/WindowsVM}"

ISO_PATH=""
ISO_EXPLICIT=0
VIRTIO_ISO=""
VM_DIR=""
DISK_PATH=""
DISK_SIZE="256G"
EXPLICIT_DISK=0
RAM_MB=""
CPUS=""
USB_MODE=""
USB_AUTO_FILTER=""
SMB_HOST=""
FULLSCREEN=0
DRY_RUN="${PZ_DRY_RUN:-0}"
JSON_OUT="${JSON_OUT:-0}"
WITH_BOOT=0
PCI_DEVICES=""
EXTRA_ARGS=""
LIBVIRT_DOMAIN=""
EXPLICIT_DOMAIN=0
RAW_QEMU=0
RAW_DISK_BUS="nvme"
DISPLAY_MODE="gtk"
OPTIMIZE_HOST="${PZ_WINDOWS_VM_OPTIMIZE:-1}"
GRAPHICS_PROFILE=""
GRAPHICS_EXPERIMENTAL=0
EXPLICIT_GRAPHICS=0

usage() {
    cat <<EOF
PhaseZero Windows VM - QEMU/KVM Windows automation

Usage:
  pz windows-vm status
  pz windows-vm discover [--json]
  pz windows-vm adopt [--disk PATH]
  pz windows-vm plan --iso <windows.iso> [--json]
  pz windows-vm install --iso <windows.iso> [--disk-size 256G] [--ram 8192|8G] [--cpus N] [--dry-run]
  pz windows-vm optimize [--dry-run]
  pz windows-vm launch [--domain NAME|--raw-qemu] [--iso <windows.iso>] [--fullscreen|--headless] [--graphics <profile>] [--experimental] [--dry-run]
  pz windows-vm graphics status [--json]
  pz windows-vm graphics doctor [--json]
  pz windows-vm graphics plan --profile <auto|compat|virtio-gl|virtio-venus|rutabaga|vfio-looking-glass> [--json]
  pz windows-vm graphics apply --profile <compat|virtio-gl> [--experimental --yes]
  pz windows-vm graphics remove
  pz windows-vm graphics runtime (status|install|rollback)
  pz windows-vm graphics guest-guide [--save]
  pz windows-vm shares (status|install|remove|dry-run)
  pz windows-vm apps (status|setup|configure|doctor|install-winboat|install-winpodx|launch-winboat|launch-winpodx)
  pz windows-vm boot status
  pz windows-vm boot install
  pz windows-vm boot next
  pz windows-vm boot next-reboot
  pz windows-vm boot remove
  pz windows-vm boot dry-run

Access:
  home, /mnt/sdcard, /run/media/\$USER and /mnt are exposed through SMB and virtiofs when available.
  USB redirection is enabled by default. Raw usb-host passthrough requires --usb-mode all or peripherals.
  PCI/GPU passthrough is opt-in through PZ_WINDOWS_VM_PCI_DEVICES="0000:xx:yy.z ...".
EOF
}

parse_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --iso) ISO_PATH="${2:-}"; ISO_EXPLICIT=1; shift 2 ;;
            --iso=*) ISO_PATH="${1#*=}"; ISO_EXPLICIT=1; shift ;;
            --virtio-iso) VIRTIO_ISO="${2:-}"; shift 2 ;;
            --virtio-iso=*) VIRTIO_ISO="${1#*=}"; shift ;;
            --vm-dir) VM_DIR="${2:-}"; shift 2 ;;
            --vm-dir=*) VM_DIR="${1#*=}"; shift ;;
            --disk) DISK_PATH="${2:-}"; EXPLICIT_DISK=1; shift 2 ;;
            --disk=*) DISK_PATH="${1#*=}"; EXPLICIT_DISK=1; shift ;;
            --disk-size) DISK_SIZE="${2:-}"; shift 2 ;;
            --disk-size=*) DISK_SIZE="${1#*=}"; shift ;;
            --ram) RAM_MB="$(normalize_ram_mb "${2:-}")"; shift 2 ;;
            --ram=*) RAM_MB="$(normalize_ram_mb "${1#*=}")"; shift ;;
            --cpus) CPUS="${2:-}"; shift 2 ;;
            --cpus=*) CPUS="${1#*=}"; shift ;;
            --usb-mode) USB_MODE="${2:-}"; shift 2 ;;
            --usb-mode=*) USB_MODE="${1#*=}"; shift ;;
            --usb-auto-filter) USB_AUTO_FILTER="${2:-}"; shift 2 ;;
            --usb-auto-filter=*) USB_AUTO_FILTER="${1#*=}"; shift ;;
            --pci) PCI_DEVICES="${PCI_DEVICES:+$PCI_DEVICES }${2:-}"; shift 2 ;;
            --pci=*) PCI_DEVICES="${PCI_DEVICES:+$PCI_DEVICES }${1#*=}"; shift ;;
            --extra-qemu) EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }${2:-}"; shift 2 ;;
            --extra-qemu=*) EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }${1#*=}"; shift ;;
            --domain) LIBVIRT_DOMAIN="${2:-}"; EXPLICIT_DOMAIN=1; shift 2 ;;
            --domain=*) LIBVIRT_DOMAIN="${1#*=}"; EXPLICIT_DOMAIN=1; shift ;;
            --raw-qemu) RAW_QEMU=1; shift ;;
            --graphics) GRAPHICS_PROFILE="${2:-}"; EXPLICIT_GRAPHICS=1; shift 2 ;;
            --graphics=*) GRAPHICS_PROFILE="${1#*=}"; EXPLICIT_GRAPHICS=1; shift ;;
            --experimental) GRAPHICS_EXPERIMENTAL=1; shift ;;
            --headless) DISPLAY_MODE="none"; shift ;;
            --optimize) OPTIMIZE_HOST=1; shift ;;
            --no-optimize) OPTIMIZE_HOST=0; shift ;;
            --fullscreen) FULLSCREEN=1; shift ;;
            --with-boot) WITH_BOOT=1; shift ;;
            --json) JSON_OUT=1; shift ;;
            --dry-run|-n) DRY_RUN=1; shift ;;
            --rescue) PZ_WINDOWS_VM_RESCUE=1; shift ;;
            --no-rescue) PZ_WINDOWS_VM_RESCUE=0; shift ;;
            --help|-h) usage; exit 0 ;;
            *) pz_error "unknown windows-vm option: $1"; return 1 ;;
        esac
    done
}

run_privileged_noninteractive() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
        return $?
    fi
    return 1
}

write_root_value() {
    local path="$1" value="$2"
    local label="${3:-$path}"
    [ -e "$path" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would set $label -> $value"
        return 0
    fi
    if [ -w "$path" ]; then
        printf '%s\n' "$value" > "$path" 2>/dev/null || true
        return 0
    fi
    if run_privileged_noninteractive tee "$path" >/dev/null <<< "$value"; then
        return 0
    fi
    pz_warn "$label requires root; skipped non-interactive write"
    return 0
}

sysctl_set_noninteractive() {
    local key="$1" value="$2"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would sysctl $key=$value"
        return 0
    fi
    if [ "$EUID" -eq 0 ]; then
        sysctl -w "$key=$value" >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n sysctl -w "$key=$value" >/dev/null 2>&1 || true
    fi
}

apply_host_optimizations() {
    [ "$OPTIMIZE_HOST" = "1" ] || return 0
    pz_info "applying Windows VM host optimizations"
    command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set performance >/dev/null 2>&1 || true
    sysctl_set_noninteractive vm.swappiness 1
    sysctl_set_noninteractive vm.vfs_cache_pressure 50
    sysctl_set_noninteractive vm.dirty_background_ratio 5
    sysctl_set_noninteractive vm.dirty_ratio 20
    sysctl_set_noninteractive kernel.nmi_watchdog 0
    write_root_value /sys/kernel/mm/transparent_hugepage/enabled madvise "transparent hugepages mode"
    write_root_value /sys/kernel/mm/transparent_hugepage/defrag madvise "transparent hugepages defrag"
    write_root_value /sys/kernel/mm/ksm/run 1 "KSM"
    write_root_value /sys/kernel/mm/ksm/pages_to_scan 1000 "KSM pages_to_scan"
    write_root_value /sys/kernel/mm/ksm/sleep_millisecs 20 "KSM sleep_millisecs"
    local governor
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$governor" ] || continue
        write_root_value "$governor" performance "CPU governor"
    done
}

json_escape() {
    jq -Rs . <<< "${1:-}" | tr -d '\n'
}

normalize_ram_mb() {
    local value="$1"
    [ -n "$value" ] || { echo ""; return 0; }
    case "$value" in
        *G|*g) echo "$(( ${value%[Gg]} * 1024 ))" ;;
        *M|*m) echo "${value%[Mm]}" ;;
        *) echo "$value" ;;
    esac
}

shell_join() {
    local out="" arg
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        out="${out:+$out }$arg"
    done
    printf '%s\n' "$out"
}

command_path() {
    command -v "$1" 2>/dev/null || true
}

virtiofsd_path() {
    command -v virtiofsd 2>/dev/null || {
        [ -x /usr/lib/virtiofsd ] && printf '%s\n' /usr/lib/virtiofsd
    } || true
}

target_home() {
    getent passwd "$TARGET_USER" | cut -d: -f6
}

chown_target_user() {
    [ "$EUID" -eq 0 ] || return 0
    chown "$TARGET_USER:$TARGET_USER" "$@" 2>/dev/null || true
}

target_user_can_rw() {
    local path="$1"
    if [ "$EUID" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- sh -c 'test -r "$1" && test -w "$1"' sh "$path" 2>/dev/null
        return $?
    fi
    [ -r "$path" ] && [ -w "$path" ]
}

default_ram_mb() {
    local total reserve ram
    total="$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 8192)"
    reserve=2048
    ram=$(( total * 70 / 100 ))
    [ "$ram" -gt $(( total - reserve )) ] && ram=$(( total - reserve ))
    [ "$ram" -lt 4096 ] && ram=$(( total / 2 ))
    [ "$ram" -lt 2048 ] && ram=2048
    echo "$ram"
}

default_cpus() {
    local total cpus
    total="$(nproc 2>/dev/null || echo 2)"
    cpus="$total"
    [ "$total" -gt 4 ] && cpus=$(( total - 1 ))
    [ "$total" -gt 8 ] && cpus=$(( total - 2 ))
    [ "$cpus" -lt 2 ] && cpus=2
    echo "$cpus"
}

disk_actual_bytes() {
    local path="$1" info value
    [ -f "$path" ] || { echo 0; return 0; }
    if command -v qemu-img >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        info="$(qemu-img info --output=json "$path" 2>/dev/null || true)"
        if [ -n "$info" ]; then
            value="$(jq -r '."actual-size" // 0' <<< "$info" 2>/dev/null || true)"
            echo "${value:-0}"
            return 0
        fi
        stat -c %s "$path" 2>/dev/null || echo 0
    else
        stat -c %s "$path" 2>/dev/null || echo 0
    fi
}

disk_virtual_bytes() {
    local path="$1" info value
    [ -f "$path" ] || { echo 0; return 0; }
    if command -v qemu-img >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        info="$(qemu-img info --output=json "$path" 2>/dev/null || true)"
        if [ -n "$info" ]; then
            value="$(jq -r '."virtual-size" // 0' <<< "$info" 2>/dev/null || true)"
            echo "${value:-0}"
            return 0
        fi
        echo 0
    else
        echo 0
    fi
}

disk_looks_installed() {
    local path="$1" actual virtual min_actual=$((5 * 1024 * 1024 * 1024)) min_virtual=$((32 * 1024 * 1024 * 1024))
    actual="$(disk_actual_bytes "$path")"
    virtual="$(disk_virtual_bytes "$path")"
    [ "${actual:-0}" -ge "$min_actual" ] && return 0
    [ "${virtual:-0}" -ge "$min_virtual" ] && [ "${actual:-0}" -ge $((1024 * 1024 * 1024)) ] && return 0
    return 1
}

find_existing_windows_disk() {
    local base path
    for path in \
        "$VM_DIR_DEFAULT/phasezero-windows.qcow2" \
        "$HOME/VirtualMachines/PhaseZero-Windows/phasezero-windows.qcow2" \
        "$HOME/VirtualMachines/Windows/Windows.qcow2" \
        "$HOME/VirtualMachines/Windows11/Windows11.qcow2" \
        "$HOME/.local/share/libvirt/images/windows.qcow2" \
        "$HOME/.local/share/libvirt/images/win11.qcow2" \
        "/var/lib/libvirt/images/windows.qcow2" \
        "/var/lib/libvirt/images/win11.qcow2"; do
        [ -f "$path" ] && disk_looks_installed "$path" && { printf '%s\n' "$path"; return 0; }
    done
    for base in "$HOME/VirtualMachines" "$HOME/.local/share/libvirt/images" "/var/lib/libvirt/images" "$HOME" "/mnt/sdcard"; do
        [ -d "$base" ] || continue
        path="$(find "$base" -maxdepth 4 -type f \( -iname '*win*.qcow2' -o -iname '*windows*.qcow2' -o -iname '*win*.img' -o -iname '*windows*.img' -o -iname '*win*.raw' -o -iname '*windows*.raw' -o -iname '*win*.vmdk' -o -iname '*windows*.vmdk' \) 2>/dev/null | sort | while IFS= read -r candidate; do disk_looks_installed "$candidate" && { printf '%s\n' "$candidate"; break; }; done | sed -n '1p' || true)"
        [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

find_usable_existing_windows_disk() {
    local candidate
    candidate="$(find_existing_windows_disk | sed -n '1p')"
    [ -n "$candidate" ] && [ -r "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    return 0
}

find_existing_windows_disk_any() {
    local base path
    for path in \
        "$VM_DIR_DEFAULT/phasezero-windows.qcow2" \
        "$HOME/VirtualMachines/PhaseZero-Windows/phasezero-windows.qcow2"; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    for base in "$HOME/VirtualMachines" "$HOME/.local/share/libvirt/images" "/var/lib/libvirt/images" "$HOME" "/mnt/sdcard"; do
        [ -d "$base" ] || continue
        path="$(find "$base" -maxdepth 4 -type f \( -iname '*win*.qcow2' -o -iname '*windows*.qcow2' -o -iname '*win*.img' -o -iname '*windows*.img' -o -iname '*win*.raw' -o -iname '*windows*.raw' -o -iname '*win*.vmdk' -o -iname '*windows*.vmdk' \) 2>/dev/null | sort | sed -n '1p' || true)"
        [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

libvirt_uri() {
    printf '%s\n' "${PZ_WINDOWS_VM_LIBVIRT_URI:-qemu:///system}"
}

find_existing_windows_domain() {
    type -P virsh >/dev/null 2>&1 || return 0
    local uri domain source
    uri="$(libvirt_uri)"
    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        if windows_name_hint "$domain"; then
            printf '%s\n' "$domain"
            return 0
        fi
        while IFS= read -r source; do
            if windows_name_hint "$source"; then
                printf '%s\n' "$domain"
                return 0
            fi
        done < <(virsh -c "$uri" domblklist "$domain" --details 2>/dev/null | awk '$2 == "disk" {print $4}')
    done < <(virsh -c "$uri" list --all --name 2>/dev/null)
    return 0
}

windows_name_hint() {
    local value="${1,,}"
    [[ "$value" =~ windows|win(vm|xp|vista|[0-9]+) ]] ||
        [[ "$value" =~ (^|[^[:alnum:]])win([^[:alnum:]]|$) ]]
}

libvirt_domain_disk() {
    local domain="$1"
    [ -n "$domain" ] || return 0
    virsh -c "$(libvirt_uri)" domblklist "$domain" --details 2>/dev/null |
        awk '$2 == "disk" && !seen++ {print $4}'
}

libvirt_domain_xml_value() {
    local domain="$1" xpath="$2"
    [ -n "$domain" ] && command -v xmllint >/dev/null 2>&1 || return 0
    virsh -c "$(libvirt_uri)" dumpxml "$domain" 2>/dev/null |
        xmllint --xpath "string($xpath)" - 2>/dev/null || true
}

libvirt_domain_nvram() {
    libvirt_domain_xml_value "$1" "/domain/os/nvram"
}

libvirt_domain_disk_bus() {
    libvirt_domain_xml_value "$1" "/domain/devices/disk[@device='disk'][1]/target/@bus"
}

discovered_windows_disk() {
    find_usable_existing_windows_disk | sed -n '1p'
}

disk_format() {
    local path="$1" info fmt
    if [ -f "$path" ] && command -v qemu-img >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        info="$(qemu-img info --output=json "$path" 2>/dev/null || true)"
        fmt="$(jq -r '.format // empty' <<< "$info" 2>/dev/null || true)"
        [ -n "$fmt" ] && { printf '%s\n' "$fmt"; return 0; }
    fi
    case "$path" in
        *.qcow2) echo qcow2 ;;
        *.vmdk) echo vmdk ;;
        *.raw) echo raw ;;
        *.img) echo raw ;;
        *) echo qcow2 ;;
    esac
}

discovery_json() {
    local installed usable any configured installed_like="no" usable_like="no" any_like="no" configured_like="no" installed_readable="no" usable_readable="no" any_readable="no" configured_readable="no"
    installed="$(find_existing_windows_disk | sed -n '1p')"
    usable="$(find_usable_existing_windows_disk | sed -n '1p')"
    any="$(find_existing_windows_disk_any | sed -n '1p')"
    configured="${PZ_WINDOWS_VM_DISK:-}"
    [ -z "$configured" ] && [ -f "$CONFIG_FILE" ] && configured="$(bash -c '. "$0"; printf "%s\n" "${PZ_WINDOWS_VM_DISK:-}"' "$CONFIG_FILE" 2>/dev/null || true)"
    if [ -n "$installed" ]; then
        installed_like="yes"
        [ -r "$installed" ] && installed_readable="yes"
    fi
    if [ -n "$usable" ]; then
        usable_like="yes"
        [ -r "$usable" ] && usable_readable="yes"
    fi
    if [ -n "$any" ] && disk_looks_installed "$any"; then
        any_like="yes"
    fi
    if [ -n "$any" ] && [ -r "$any" ]; then
        any_readable="yes"
    fi
    if [ -n "$configured" ] && [ -f "$configured" ] && disk_looks_installed "$configured"; then
        configured_like="yes"
    fi
    if [ -n "$configured" ] && [ -r "$configured" ]; then
        configured_readable="yes"
    fi
    jq -n \
        --arg installed "$installed" \
        --arg usable "$usable" \
        --arg any "$any" \
        --arg configured "$configured" \
        --arg installedLike "$installed_like" \
        --arg usableLike "$usable_like" \
        --arg anyLike "$any_like" \
        --arg configuredLike "$configured_like" \
        --arg installedReadable "$installed_readable" \
        --arg usableReadable "$usable_readable" \
        --arg anyReadable "$any_readable" \
        --arg configuredReadable "$configured_readable" \
        '{
            configuredDisk: {path: $configured, installedLike: ($configuredLike == "yes"), readable: ($configuredReadable == "yes")},
            discoveredInstalledDisk: {path: $installed, installedLike: ($installedLike == "yes"), readable: ($installedReadable == "yes"), usable: (($installedLike == "yes") and ($installedReadable == "yes"))},
            discoveredUsableDisk: {path: $usable, installedLike: ($usableLike == "yes"), readable: ($usableReadable == "yes"), usable: (($usableLike == "yes") and ($usableReadable == "yes"))},
            discoveredAnyDisk: {path: $any, installedLike: ($anyLike == "yes"), readable: ($anyReadable == "yes")}
        }'
}

detect_windows_iso() {
    local base found
    for base in /mnt/sdcard/Steam "$HOME/Downloads" "$HOME" /mnt/sdcard; do
        [ -d "$base" ] || continue
        found="$(find "$base" -maxdepth 4 -type f \( -iname '*win*.iso' -o -iname '*windows*.iso' \) 2>/dev/null | sort | sed -n '1p' || true)"
        [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
    done
    return 0
}

detect_virtio_iso() {
    local path
    for path in \
        "$HOME/Downloads/virtio-win.iso" \
        "/usr/share/virtio/virtio-win.iso" \
        "/var/lib/libvirt/images/virtio-win.iso" \
        "/mnt/sdcard/Steam/virtio-win.iso"; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

ovmf_code_path() {
    local path
    for path in \
        /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd \
        /usr/share/OVMF/OVMF_CODE.fd; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

ovmf_vars_template() {
    local path
    for path in \
        /usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/OVMF/OVMF_VARS.fd; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    # PhaseZero writes this file as shell-escaped KEY=VALUE pairs.
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
}

effective_config() {
    load_config
    local discovered_disk="${PZ_WINDOWS_VM_DISCOVERED_DISK:-$(discovered_windows_disk)}"
    VM_NAME="${PZ_WINDOWS_VM_NAME:-$VM_NAME_DEFAULT}"
    VM_DIR="${VM_DIR:-${PZ_WINDOWS_VM_DIR:-$VM_DIR_DEFAULT}}"
    local configured_disk="${PZ_WINDOWS_VM_DISK:-}"
    if [ "$EXPLICIT_DISK" -eq 0 ] && [ -n "$configured_disk" ] && [ -n "$discovered_disk" ] && ! disk_looks_installed "$configured_disk"; then
        configured_disk=""
    fi
    DISK_PATH="${DISK_PATH:-${configured_disk:-${discovered_disk:-$VM_DIR/phasezero-windows.qcow2}}}"
    if [ "$EXPLICIT_DOMAIN" -eq 0 ]; then
        LIBVIRT_DOMAIN="${LIBVIRT_DOMAIN:-${PZ_WINDOWS_VM_LIBVIRT_DOMAIN:-$(find_existing_windows_domain)}}"
    fi
    if [ -n "$LIBVIRT_DOMAIN" ]; then
        local domain_disk domain_bus
        domain_disk="$(libvirt_domain_disk "$LIBVIRT_DOMAIN")"
        [ -n "$domain_disk" ] && [ "$EXPLICIT_DISK" -eq 0 ] && DISK_PATH="$domain_disk"
        domain_bus="$(libvirt_domain_disk_bus "$LIBVIRT_DOMAIN")"
        [ -n "$domain_bus" ] && RAW_DISK_BUS="$domain_bus"
    fi
    ISO_PATH="${ISO_PATH:-${PZ_WINDOWS_VM_ISO:-$(detect_windows_iso)}}"
    VIRTIO_ISO="${VIRTIO_ISO:-${PZ_WINDOWS_VM_VIRTIO_ISO:-$(detect_virtio_iso)}}"
    RAM_MB="${RAM_MB:-${PZ_WINDOWS_VM_RAM_MB:-$(default_ram_mb)}}"
    CPUS="${CPUS:-${PZ_WINDOWS_VM_CPUS:-$(default_cpus)}}"
    USB_MODE="${USB_MODE:-${PZ_WINDOWS_VM_USB_MODE:-redir}}"
    USB_AUTO_FILTER="${USB_AUTO_FILTER:-${PZ_WINDOWS_VM_USB_AUTO_FILTER:-0x08,-1,-1,-1,1}}"
    SMB_HOST="${PZ_WINDOWS_VM_SMB_HOST:-$(libvirt_gateway)}"
    PCI_DEVICES="${PCI_DEVICES:-${PZ_WINDOWS_VM_PCI_DEVICES:-}}"
    EXTRA_ARGS="${EXTRA_ARGS:-${PZ_WINDOWS_VM_EXTRA_ARGS:-}}"
    GRAPHICS_PROFILE="${GRAPHICS_PROFILE:-${PZ_WINDOWS_VM_GRAPHICS_PROFILE:-compat}}"
    [ "$GRAPHICS_PROFILE" = "auto" ] && GRAPHICS_PROFILE=compat
    OVMF_CODE="${PZ_WINDOWS_VM_OVMF_CODE:-$(ovmf_code_path)}"
    OVMF_VARS="${PZ_WINDOWS_VM_OVMF_VARS:-$VM_DIR/OVMF_VARS.fd}"
    if [ -n "$LIBVIRT_DOMAIN" ]; then
        local domain_nvram
        domain_nvram="$(libvirt_domain_nvram "$LIBVIRT_DOMAIN")"
        [ -f "$domain_nvram" ] && OVMF_VARS="$domain_nvram"
    fi
    SHARE_ROOT="${PZ_WINDOWS_VM_SHARE_ROOT:-$VM_DIR/shares}"
    TPM_DIR="${PZ_WINDOWS_VM_TPM_DIR:-$VM_DIR/tpm}"
    local configured_source="${PZ_WINDOWS_VM_DISK_SOURCE:-new}"
    DISK_SOURCE="$configured_source"
    if [ "$EXPLICIT_DISK" -eq 1 ]; then
        DISK_SOURCE="explicit"
    elif [ -n "${PZ_WINDOWS_VM_DISK:-}" ] && [ "$DISK_PATH" = "${PZ_WINDOWS_VM_DISK:-}" ]; then
        if [ "$configured_source" = "new" ]; then
            DISK_SOURCE="config"
        fi
    elif [ -n "$discovered_disk" ] && [ "$DISK_PATH" = "$discovered_disk" ]; then
        DISK_SOURCE="discovered-installed"
    fi
}

write_config() {
    install -d "$CONFIG_DIR"
    {
        printf '# PhaseZero managed Windows VM config\n'
        printf 'PZ_WINDOWS_VM_NAME=%q\n' "$VM_NAME"
        printf 'PZ_WINDOWS_VM_DIR=%q\n' "$VM_DIR"
        printf 'PZ_WINDOWS_VM_DISK=%q\n' "$DISK_PATH"
        printf 'PZ_WINDOWS_VM_LIBVIRT_DOMAIN=%q\n' "$LIBVIRT_DOMAIN"
        printf 'PZ_WINDOWS_VM_LIBVIRT_URI=%q\n' "$(libvirt_uri)"
        printf 'PZ_WINDOWS_VM_ISO=%q\n' "$ISO_PATH"
        printf 'PZ_WINDOWS_VM_VIRTIO_ISO=%q\n' "$VIRTIO_ISO"
        printf 'PZ_WINDOWS_VM_RAM_MB=%q\n' "$RAM_MB"
        printf 'PZ_WINDOWS_VM_CPUS=%q\n' "$CPUS"
        printf 'PZ_WINDOWS_VM_USB_MODE=%q\n' "$USB_MODE"
        printf 'PZ_WINDOWS_VM_USB_AUTO_FILTER=%q\n' "$USB_AUTO_FILTER"
        printf 'PZ_WINDOWS_VM_SMB_HOST=%q\n' "$SMB_HOST"
        printf 'PZ_WINDOWS_VM_OVMF_CODE=%q\n' "$OVMF_CODE"
        printf 'PZ_WINDOWS_VM_OVMF_VARS=%q\n' "$OVMF_VARS"
        printf 'PZ_WINDOWS_VM_SHARE_ROOT=%q\n' "$SHARE_ROOT"
        printf 'PZ_WINDOWS_VM_TPM_DIR=%q\n' "$TPM_DIR"
        printf 'PZ_WINDOWS_VM_PCI_DEVICES=%q\n' "$PCI_DEVICES"
        printf 'PZ_WINDOWS_VM_EXTRA_ARGS=%q\n' "$EXTRA_ARGS"
        printf 'PZ_WINDOWS_VM_DISK_SOURCE=%q\n' "$DISK_SOURCE"
        printf 'PZ_WINDOWS_VM_OPTIMIZE=%q\n' "$OPTIMIZE_HOST"
        printf 'PZ_WINDOWS_VM_GRAPHICS_PROFILE=%q\n' "${PZ_WINDOWS_VM_GRAPHICS_PROFILE:-compat}"
    } > "$CONFIG_FILE"
    chown_target_user "$CONFIG_DIR" "$CONFIG_FILE"
    pz_info "wrote $CONFIG_FILE"
}

ensure_vm_storage() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would create VM directories under $VM_DIR"
    else
        install -d "$VM_DIR" "$STATE_DIR" "$RUNTIME_DIR"
    fi
    if [ ! -f "$DISK_PATH" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            pz_info "dry-run: would create qcow2 disk: $DISK_PATH ($DISK_SIZE)"
        else
            qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
            pz_info "created qcow2 disk: $DISK_PATH"
        fi
    fi
    if [ ! -f "$OVMF_VARS" ]; then
        local vars_template
        vars_template="$(ovmf_vars_template)"
        [ -n "$vars_template" ] || { pz_error "OVMF_VARS template missing"; return 1; }
        if [ "$DRY_RUN" = "1" ]; then
            pz_info "dry-run: would copy OVMF vars: $vars_template -> $OVMF_VARS"
        else
            cp "$vars_template" "$OVMF_VARS"
            chown_target_user "$OVMF_VARS"
            pz_info "created OVMF vars: $OVMF_VARS"
        fi
    fi
}

desktop_entry_content() {
    cat <<EOF
[Desktop Entry]
Type=Application
Name=PhaseZero Windows VM
Comment=Launch PhaseZero Windows VM
Exec=$PZ_ROOT/linux/pz windows-vm launch --fullscreen
Terminal=false
Categories=System;Utility;
EOF
}

boot_reboot_desktop_content() {
    local exec_line terminal
    if command -v pkexec >/dev/null 2>&1; then
        exec_line="pkexec bash $PZ_ROOT/linux/windows-vm/windows-vm.sh boot next-reboot"
        terminal=false
    else
        exec_line="$PZ_ROOT/linux/pz windows-vm boot next-reboot"
        terminal=true
    fi
    cat <<EOF
[Desktop Entry]
Type=Application
Name=PhaseZero Reboot to Windows VM
Comment=Set one-shot GRUB boot to PhaseZero Windows VM and reboot
Exec=$exec_line
Terminal=$terminal
Categories=System;Utility;
EOF
}

user_service_content() {
    cat <<EOF
[Unit]
Description=PhaseZero Windows VM
After=graphical-session.target

[Service]
Type=simple
ExecStart=$PZ_ROOT/linux/pz windows-vm launch --fullscreen
Restart=no

[Install]
WantedBy=default.target
EOF
}

install_user_files() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $APPLICATIONS_DIR/phasezero-windows-vm.desktop"
        pz_info "dry-run: would write $APPLICATIONS_DIR/phasezero-reboot-windows-vm.desktop"
        pz_info "dry-run: would write $SYSTEMD_USER_DIR/phasezero-windows-vm.service"
        return 0
    fi
    install -d "$APPLICATIONS_DIR" "$SYSTEMD_USER_DIR"
    desktop_entry_content | pz_desktop_write_entry "$APPLICATIONS_DIR/phasezero-windows-vm.desktop" system.machines
    boot_reboot_desktop_content | pz_desktop_write_entry "$APPLICATIONS_DIR/phasezero-reboot-windows-vm.desktop" system.boot
    user_service_content > "$SYSTEMD_USER_DIR/phasezero-windows-vm.service"
    chown_target_user "$APPLICATIONS_DIR" "$APPLICATIONS_DIR/phasezero-windows-vm.desktop" "$APPLICATIONS_DIR/phasezero-reboot-windows-vm.desktop" "$SYSTEMD_USER_DIR" "$SYSTEMD_USER_DIR/phasezero-windows-vm.service"
    pz_info "installed user launcher and service"
}

require_iso_for_install() {
    if [ -f "$DISK_PATH" ] && disk_looks_installed "$DISK_PATH"; then
        return 0
    fi
    [ -n "$ISO_PATH" ] || { pz_error "Windows ISO missing. Use --iso /path/to/Windows.iso"; return 1; }
    [ -f "$ISO_PATH" ] || { pz_error "Windows ISO not found: $ISO_PATH"; return 1; }
}

install_vm() {
    parse_options "$@"
    effective_config
    require_iso_for_install
    [ -n "$OVMF_CODE" ] || { pz_error "OVMF code firmware missing. Install edk2-ovmf."; return 1; }
    command -v qemu-img >/dev/null 2>&1 || { pz_error "qemu-img missing. Install qemu-base/qemu-desktop."; return 1; }
    ensure_vm_storage
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $CONFIG_FILE"
        install_user_files
        pz_info "dry-run: Windows VM user-space install planned"
        return 0
    fi
    write_config
    install_user_files
    if [ "$WITH_BOOT" = "1" ]; then
        install_boot
    else
        pz_info "Windows VM user-space install complete"
        pz_info "direct GRUB boot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot install"
    fi
}

vm_admin_run() {
    if pz_can_sudo_noninteractive; then sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then phasezero-admin "$@"
    else return 127; fi
}

# QEMU's built-in SMB (\\10.0.2.4\qemu) serves ONE directory and does NOT follow
# symlinks that point outside it, so the old symlink share root left the guest with
# empty home/ and sdcard/ folders. Bind mounts are real directories smbd traverses
# fine. We populate a share root under RUNTIME_DIR (outside $HOME, so bind-mounting
# $HOME cannot recurse) and expose that; sets the global EFFECTIVE_SMB_DIR.
SHARE_BIND_ROOT="$RUNTIME_DIR/shares"
ensure_share_links() {
    local hard_fail="${1:-0}"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would bind-mount host home + /mnt/sdcard into $SHARE_BIND_ROOT for SMB"
        EFFECTIVE_SMB_DIR="$SHARE_BIND_ROOT"
        return 0
    fi
    local ok=1 pair name target attempt=0
    while [ "$attempt" -le 1 ]; do
        ok=1
        install -d "$SHARE_BIND_ROOT" 2>/dev/null || ok=0
        if [ "$ok" = "1" ]; then
            mkdir -p "$EXCHANGE_DIR"
            for pair in "exchange:$EXCHANGE_DIR" "home:$HOME" "sdcard:/mnt/sdcard" "removable:/run/media/$USER" "media:/media/$USER" "mnt:/mnt"; do
                name="${pair%%:*}"; target="${pair#*:}"
                [ -d "$target" ] || continue
                install -d "$SHARE_BIND_ROOT/$name"
                mountpoint -q "$SHARE_BIND_ROOT/$name" && continue
                vm_admin_run mount --bind "$target" "$SHARE_BIND_ROOT/$name" 2>/dev/null || { ok=0; break; }
            done
        fi
        [ "$ok" = "1" ] && break
        [ "$attempt" -ge 1 ] && break
        attempt=$((attempt + 1))
        pz_warn "bind mount attempt $attempt failed; retrying once"
    done
    if [ "$ok" = "1" ] && mountpoint -q "$SHARE_BIND_ROOT/home"; then
        EFFECTIVE_SMB_DIR="$SHARE_BIND_ROOT"
        pz_info "host folders bind-mounted for SMB: \\\\10.0.2.4\\qemu -> exchange, home, sdcard, removable, media, mnt"
        return 0
    fi
    if [ "$hard_fail" = "1" ]; then
        pz_error "bind mounts failed and virtiofs unavailable; SMB shares will be empty in guest. Aborting boot install."
        return 1
    fi
    install -d "$SHARE_ROOT"
    mkdir -p "$EXCHANGE_DIR"
    ln -sfn "$EXCHANGE_DIR" "$SHARE_ROOT/exchange"
    ln -sfn "$HOME" "$SHARE_ROOT/home"
    [ -d /mnt/sdcard ] && ln -sfn /mnt/sdcard "$SHARE_ROOT/sdcard"
    [ -d "/run/media/$USER" ] && ln -sfn "/run/media/$USER" "$SHARE_ROOT/removable"
    [ -d "/media/$USER" ] && ln -sfn "/media/$USER" "$SHARE_ROOT/media"
    [ -d /mnt ] && ln -sfn /mnt "$SHARE_ROOT/mnt"
    EFFECTIVE_SMB_DIR="$SHARE_ROOT"
    pz_warn "no root for bind mounts; SMB share uses symlinks (guest home/sdcard may be empty). Run: sudo pz windows-vm shares install, or use virtiofs."
}

verify_share() {
    local name="$1" expected_target="$2" result="fail" detail=""
    if mountpoint -q "$SHARE_BIND_ROOT/$name" 2>/dev/null; then
        local actual
        actual="$(findmnt -no TARGET "$SHARE_BIND_ROOT/$name" 2>/dev/null || echo "")"
        if [ "$actual" = "$expected_target" ] || [ -z "$expected_target" ]; then
            result="pass"
            detail="bind-mounted"
        else
            detail="bind-mounted (expected=$expected_target actual=$actual)"
        fi
    elif [ -L "$SHARE_ROOT/$name" ]; then
        result="degraded"
        detail="symlink (guest may not follow)"
    elif [ -d "$SHARE_BIND_ROOT/$name" ]; then
        detail="directory exists, not mounted"
    else
        detail="not found"
    fi
    if [ "${JSON_OUT:-0}" = "1" ]; then
        jq -nc \
            --arg name "$name" \
            --arg result "$result" \
            --arg detail "$detail" \
            '{name:$name,result:$result,detail:$detail}'
    else
        printf 'share_%s: %s (%s)\n' "$name" "$result" "$detail"
    fi
}

cmd_shares_verify() {
    local fail=0 json_output="" line result_field failures=0
    for pair in "exchange:$EXCHANGE_DIR" "home:$HOME" "sdcard:/mnt/sdcard" "removable:/run/media/$USER" "media:/media/$USER" "mnt:/mnt"; do
        local name="${pair%%:*}" target="${pair#*:}"
        [ -d "$target" ] || continue
        if [ "${JSON_OUT:-0}" = "1" ]; then
            line="$(verify_share "$name" "$target")"
            result_field="$(jq -r '.result' <<< "$line" 2>/dev/null || echo "fail")"
            [ "$result_field" = "pass" ] || { fail=1; failures=$((failures + 1)); }
            json_output="$json_output$line,"
        else
            local capture
            capture="$(verify_share "$name" "$target")"
            printf '%s\n' "$capture"
            # Match "share_<name>: pass" at end of token; \b makes it tolerant
            # of the parenthesised detail suffix ("pass (bind-mounted)").
            if ! grep -Eq "share_[^:]+: pass( |\$)" <<< "$capture" 2>/dev/null; then
                fail=1
            fi
        fi
    done
    if [ "${JSON_OUT:-0}" = "1" ]; then
        json_output="${json_output%,}"
        printf '{"ok":%s,"failures":%d,"shares":[%s]}\n' \
            "$([ "$fail" = "0" ] && echo true || echo false)" \
            "$failures" "$json_output"
    fi
    local samba_reachable=""
    if command -v smbclient >/dev/null 2>&1; then
        if smbclient -N -L "//127.0.0.1/PZHome" -I 127.0.0.1 -p 445 2>&1 | grep -q 'PZHome'; then
            samba_reachable="yes"
        else
            samba_reachable="no"
            fail=1
        fi
    fi
    if [ "${JSON_OUT:-0}" != "1" ]; then
        [ -n "$samba_reachable" ] && echo "samba_home_reachable: $samba_reachable"
        printf 'shares_ok: %s\n' "$([ "$fail" = "0" ] && echo yes || echo no)"
    fi
    return $fail
}

# Unmount the bind-mount share root (called on teardown / shares clean).
clean_share_binds() {
    local name
    for name in exchange home sdcard removable media mnt; do
        mountpoint -q "$SHARE_BIND_ROOT/$name" 2>/dev/null &&
            vm_admin_run umount "$SHARE_BIND_ROOT/$name" 2>/dev/null || true
    done
}

libvirt_gateway() {
    local gateway=""
    if type -P virsh >/dev/null 2>&1; then
        gateway="$(virsh -c "$(libvirt_uri)" net-dumpxml default 2>/dev/null |
            awk -F"'" '/<ip address=/{if (!seen++) print $2}')"
    fi
    printf '%s\n' "${gateway:-192.168.122.1}"
}

samba_block_content() {
    local home removable media
    home="$(target_home)"
    removable="/run/media/$TARGET_USER"
    media="/media/$TARGET_USER"
    cat <<EOF
$SAMBA_BEGIN
[PZExchange]
    comment = PhaseZero Windows exchange
    path = $EXCHANGE_DIR
    browseable = yes
    read only = no
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
    smb encrypt = desired
    follow symlinks = no
    wide links = no
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0

[PZHome]
    comment = PhaseZero host home
    path = $home
    browseable = yes
    read only = no
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
    force create mode = 0600
    force directory mode = 0700
    veto files = /.ssh/.gnupg/.aws/.kube/
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0

[PZSDCard]
    comment = PhaseZero SD card
    path = /mnt/sdcard
    browseable = yes
    read only = no
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0

[PZRemovable]
    comment = PhaseZero removable media
    path = $removable
    browseable = yes
    read only = no
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0

[PZMedia]
    comment = PhaseZero media mounts
    path = $media
    browseable = yes
    read only = no
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0

[PZMounts]
    comment = PhaseZero host mounts
    path = /mnt
    browseable = yes
    read only = no
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0
$SAMBA_END
EOF
}

strip_managed_samba_block() {
    local input="$1" output="$2"
    awk -v begin="$SAMBA_BEGIN" -v end="$SAMBA_END" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "$input" > "$output"
}

samba_shares_managed() {
    [ -r "$SAMBA_CONF" ] &&
        grep -Fqx "$SAMBA_BEGIN" "$SAMBA_CONF" &&
        grep -Fqx "$SAMBA_END" "$SAMBA_CONF" &&
        command -v testparm >/dev/null 2>&1 &&
        testparm -s "$SAMBA_CONF" >/dev/null 2>&1
}

samba_shares_reachable() {
    command -v smbclient >/dev/null 2>&1 &&
        smbclient -N //127.0.0.1/PZExchange -c 'ls' >/dev/null 2>&1 &&
        smbclient -N //127.0.0.1/PZHome -c 'ls' >/dev/null 2>&1 &&
        smbclient -N //127.0.0.1/PZSDCard -c 'ls' >/dev/null 2>&1
}

windows_usb_udev_content() {
    cat <<'EOF'
# PhaseZero: active-seat access for external USB passthrough.
# SPICE auto-redirection remains restricted to mass-storage interfaces.
ACTION!="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_INTEGRATION}=="external", MODE="0660", TAG+="uaccess"
ACTION!="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_USB_INTERFACES}=="*:08????:*", MODE="0660", TAG+="uaccess"
EOF
}

windows_usb_udev_managed() {
    [ -r "$USB_UDEV_RULE" ] && cmp -s <(windows_usb_udev_content) "$USB_UDEV_RULE"
}

configure_windows_usb_access() {
    [ "$EUID" -eq 0 ] || {
        pz_error "root required to configure Windows VM USB access"
        return 1
    }
    install -d "$(dirname "$USB_UDEV_RULE")"
    windows_usb_udev_content > "$USB_UDEV_RULE"
    chmod 0644 "$USB_UDEV_RULE"
    command -v udevadm >/dev/null 2>&1 || return 0
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb --action=change
    udevadm settle --timeout=10 || true
}

configure_windows_samba_shares() {
    [ "$EUID" -eq 0 ] || {
        pz_error "root required to configure Windows VM host shares"
        return 1
    }
    command -v testparm >/dev/null 2>&1 || {
        pz_error "testparm missing; install Samba"
        return 1
    }
    [ -f "$SAMBA_CONF" ] || {
        pz_error "Samba config missing: $SAMBA_CONF"
        return 1
    }
    local tmp backup_dir fw_zone exchange_parent target_home_dir
    tmp="$(mktemp)"
    strip_managed_samba_block "$SAMBA_CONF" "$tmp"
    printf '\n' >> "$tmp"
    samba_block_content >> "$tmp"
    testparm -s "$tmp" >/dev/null
    backup_dir="/var/lib/phasezero/windows-vm/samba-backups"
    install -d -m 0700 "$backup_dir"
    cp -a "$SAMBA_CONF" "$backup_dir/smb.conf.$(date +%Y%m%d-%H%M%S)"
    install -m 0644 "$tmp" "$SAMBA_CONF"
    rm -f "$tmp"
    # Repair the canonical parent created by older root runs, then create every
    # missing descendant as the desktop user.  Do not chown arbitrary override
    # parents outside the target home.
    exchange_parent="$(dirname "$EXCHANGE_DIR")"
    target_home_dir="$(target_home)"
    if [ "$exchange_parent" = "$target_home_dir/Shared" ]; then
        install -d -m 0750 -o "$TARGET_USER" -g "$TARGET_USER" "$exchange_parent"
    fi
    # A root-owned 0700
    # $HOME/Shared made smbd authenticate successfully but fail the first chdir.
    runuser -u "$TARGET_USER" -- mkdir -p "$EXCHANGE_DIR" || {
        pz_error "target user cannot create exchange directory: $EXCHANGE_DIR"
        return 1
    }
    chown "$TARGET_USER:$TARGET_USER" "$EXCHANGE_DIR"
    chmod 0770 "$EXCHANGE_DIR"
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "/run/media/$TARGET_USER" "/media/$TARGET_USER"
    systemctl enable --now smb.service >/dev/null 2>&1 || systemctl restart smbd.service >/dev/null 2>&1 || true
    systemctl restart smb.service >/dev/null 2>&1 || systemctl restart smbd.service >/dev/null 2>&1 || true
    if command -v ufw >/dev/null 2>&1; then
        ufw allow in on virbr0 to any port 445 proto tcp comment 'PhaseZero Windows VM SMB' >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        fw_zone="$(firewall-cmd --get-zone-of-interface=virbr0 2>/dev/null || true)"
        firewall-cmd --permanent --zone="${fw_zone:-libvirt}" --add-service=samba >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    samba_shares_reachable || {
        pz_error "managed Samba shares failed local reachability test"
        return 1
    }
    configure_windows_usb_access
    pz_info "Windows shares ready: \\\\$(libvirt_gateway)\\PZExchange, PZHome, PZSDCard, PZRemovable, PZMedia, PZMounts"
}

remove_windows_samba_shares() {
    [ "$EUID" -eq 0 ] || {
        pz_error "root required to remove Windows VM host shares"
        return 1
    }
    [ -f "$SAMBA_CONF" ] || return 0
    local tmp
    tmp="$(mktemp)"
    strip_managed_samba_block "$SAMBA_CONF" "$tmp"
    testparm -s "$tmp" >/dev/null
    install -m 0644 "$tmp" "$SAMBA_CONF"
    rm -f "$tmp"
    rm -f "$USB_UDEV_RULE"
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules
        udevadm trigger --subsystem-match=usb --action=change
    fi
    systemctl restart smb.service >/dev/null 2>&1 || systemctl restart smbd.service >/dev/null 2>&1 || true
    pz_info "PhaseZero Windows Samba shares removed"
}

libvirt_usb_redir_count() {
    [ -n "$LIBVIRT_DOMAIN" ] || { echo 0; return 0; }
    virsh -c "$(libvirt_uri)" dumpxml "$LIBVIRT_DOMAIN" 2>/dev/null |
        awk '/<redirdev /{count++} END{print count+0}'
}

usb_accessible_device_count() {
    local count=0 device
    for device in /dev/bus/usb/*/*; do
        [ -c "$device" ] || continue
        [ -r "$device" ] && [ -w "$device" ] && count=$((count + 1))
    done
    echo "$count"
}

share_links_ready() {
    local root
    for root in "$SHARE_BIND_ROOT" /tmp/phasezero-windows-vm/shares; do
        if mountpoint -q "$root/exchange" 2>/dev/null &&
            mountpoint -q "$root/home" 2>/dev/null &&
            mountpoint -q "$root/sdcard" 2>/dev/null &&
            mountpoint -q "$root/mnt" 2>/dev/null; then
            return 0
        fi
    done
    [ -L "$SHARE_ROOT/exchange" ] && [ -L "$SHARE_ROOT/home" ] &&
        [ -L "$SHARE_ROOT/sdcard" ] && [ -L "$SHARE_ROOT/mnt" ]
}

libvirt_webdav_channel_count() {
    [ -n "$LIBVIRT_DOMAIN" ] || { echo 0; return 0; }
    virsh -c "$(libvirt_uri)" dumpxml "$LIBVIRT_DOMAIN" 2>/dev/null |
        awk '/<channel type=/{channel=1} channel && /org.spice-space.webdav.0/{count++; channel=0} /<\/channel>/{channel=0} END{print count+0}'
}

libvirt_network_state() {
    type -P virsh >/dev/null 2>&1 || { printf missing; return; }
    virsh -c "$(libvirt_uri)" net-info default 2>/dev/null |
        awk -F: '/^Active:/{gsub(/^[[:space:]]+/,"",$2); print $2; found=1} END{if(!found) print "missing"}'
}

libvirt_interface_model() {
    [ -n "$LIBVIRT_DOMAIN" ] || { printf missing; return; }
    virsh -c "$(libvirt_uri)" dumpxml "$LIBVIRT_DOMAIN" 2>/dev/null |
        awk -F"'" '/<model type=/{print $2; found=1; exit} END{if(!found) print "unknown"}'
}

grant_raw_qemu_disk_access() {
    local disk="${1:-$DISK_PATH}" chain_json path
    [ "$EUID" -eq 0 ] || return 0
    [ -f "$disk" ] || return 0
    command -v setfacl >/dev/null 2>&1 || {
        pz_warn "setfacl missing; raw QEMU fallback cannot access libvirt-owned disks"
        return 0
    }
    chain_json="$(qemu-img info --backing-chain --output=json "$disk" 2>/dev/null || true)"
    if [ -n "$chain_json" ] && command -v jq >/dev/null 2>&1; then
        while IFS= read -r path; do
            [ -f "$path" ] || continue
            setfacl -m "u:$TARGET_USER:rw-" "$path"
        done < <(jq -r 'if type == "array" then .[].filename else .filename end // empty' <<< "$chain_json")
    else
        setfacl -m "u:$TARGET_USER:rw-" "$disk"
    fi
    [ -f "$OVMF_VARS" ] && setfacl -m "u:$TARGET_USER:rw-" "$OVMF_VARS"
}

cmd_shares() {
    local sub="${1:-status}"
    [ $# -gt 0 ] && shift || true
    parse_options "$@"
    effective_config
    case "$sub" in
        install|repair)
            need_root
            ensure_share_links
            configure_windows_samba_shares
            optimize_libvirt_domain
            ;;
        remove)
            need_root
            clean_share_binds
            remove_windows_samba_shares
            ;;
        clean)
            clean_share_binds
            pz_info "Windows VM share bind mounts removed"
            return 0
            ;;
        verify)
            cmd_shares_verify
            return $?
            ;;
        dry-run|plan)
            echo "Windows VM shared access plan"
            echo "  built-in SMB (SLIRP): \\\\10.0.2.4\\qemu  -> home/ and sdcard/ (bind-mounted)"
            echo "  libvirt SMB host: \\\\$(libvirt_gateway)\\PZExchange, PZHome, PZSDCard"
            echo "  SPICE WebDAV: $EXCHANGE_DIR (requires spice-webdavd in Windows guest)"
            echo "  bind-mount root: $SHARE_BIND_ROOT"
            echo "  USB auto filter: $USB_AUTO_FILTER"
            echo "  USB permissions: active-seat udev access for external devices"
            return 0
            ;;
        status) ;;
        *)
            pz_error "usage: windows-vm shares (status|install|repair|remove|clean|verify|dry-run)"
            return 1
            ;;
    esac
    echo "builtin_smb_unc: \\\\10.0.2.4\\qemu (home/, sdcard/)"
    echo "bind_root: $SHARE_BIND_ROOT"
    echo "home_bound: $(mountpoint -q "$SHARE_BIND_ROOT/home" 2>/dev/null && echo yes || echo no)"
    echo "sdcard_bound: $(mountpoint -q "$SHARE_BIND_ROOT/sdcard" 2>/dev/null && echo yes || echo no)"
    echo "samba_managed: $(samba_shares_managed && echo yes || echo no)"
    echo "samba_reachable: $(samba_shares_reachable && echo yes || echo no)"
    echo "smb_host: $(libvirt_gateway)"
    echo "exchange_dir: $EXCHANGE_DIR"
    echo "webdav_channels: $(libvirt_webdav_channel_count)"
    echo "libvirt_network: $(libvirt_network_state)"
    echo "libvirt_nic_model: $(libvirt_interface_model)"
    echo "share_links: $(share_links_ready && echo yes || echo no)"
    echo "usb_redir_channels: $(libvirt_usb_redir_count)"
    echo "usb_auto_filter: ${USB_AUTO_FILTER:-disabled}"
}

audio_driver() {
    local help
    help="$(qemu-system-x86_64 -audiodev help 2>&1 || true)"
    grep -qx 'pipewire' <<< "$help" && { echo pipewire; return 0; }
    grep -qx 'pa' <<< "$help" && { echo pa; return 0; }
    echo none
}

QEMU_ARGS=()
CLEANUP_PIDS=()
TPM_PID_FILE=""
VIRTIOFS_COUNT=0

cleanup_runtime() {
    local pid
    for pid in "${CLEANUP_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done
    if [ -n "${TPM_PID_FILE:-}" ] && [ -f "$TPM_PID_FILE" ]; then
        kill "$(cat "$TPM_PID_FILE" 2>/dev/null)" >/dev/null 2>&1 || true
    fi
}

start_virtiofs_share() {
    local tag="$1" path="$2" daemon sock pid
    [ -d "$path" ] || return 0
    daemon="$(virtiofsd_path)"
    [ -n "$daemon" ] || return 0
    sock="$RUNTIME_DIR/virtiofs-$tag.sock"
    rm -f "$sock"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would start virtiofsd tag=$tag path=$path socket=$sock"
    else
        "$daemon" --shared-dir "$path" --socket-path "$sock" --cache auto --sandbox none --inode-file-handles=never --log-level warn &
        pid=$!
        CLEANUP_PIDS+=("$pid")
        local i
        for ((i = 0; i < 50; i++)); do
            [ -S "$sock" ] && break
            sleep 0.05
        done
        if [ ! -S "$sock" ]; then
            pz_warn "virtiofsd socket did not become ready for $tag; share skipped"
            return 0
        fi
    fi
    QEMU_ARGS+=("-chardev" "socket,id=charfs_$tag,path=$sock")
    QEMU_ARGS+=("-device" "vhost-user-fs-pci,chardev=charfs_$tag,tag=$tag")
    VIRTIOFS_COUNT=$((VIRTIOFS_COUNT + 1))
}

start_tpm() {
    command -v swtpm >/dev/null 2>&1 || return 0
    install -d "$TPM_DIR" "$RUNTIME_DIR"
    local sock="$RUNTIME_DIR/swtpm.sock"
    TPM_PID_FILE="$RUNTIME_DIR/swtpm.pid"
    rm -f "$sock" "$TPM_PID_FILE"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would start swtpm socket: $sock"
    else
        swtpm socket --tpm2 \
            --tpmstate "dir=$TPM_DIR" \
            --ctrl "type=unixio,path=$sock,terminate" \
            --pid "file=$TPM_PID_FILE" \
            --log "file=$STATE_DIR/swtpm.log,level=20" \
            --daemon
        local i
        for ((i = 0; i < 50; i++)); do
            [ -S "$sock" ] && break
            sleep 0.05
        done
    fi
    QEMU_ARGS+=("-chardev" "socket,id=chrtpm,path=$sock")
    QEMU_ARGS+=("-tpmdev" "emulator,id=tpm0,chardev=chrtpm")
    QEMU_ARGS+=("-device" "tpm-tis,tpmdev=tpm0")
}

add_usb_redirection() {
    local idx
    QEMU_ARGS+=("-device" "qemu-xhci,id=xhci,p2=8,p3=8")
    QEMU_ARGS+=("-device" "usb-kbd,bus=xhci.0")
    QEMU_ARGS+=("-device" "usb-tablet,bus=xhci.0")
    case "$USB_MODE" in
        redir|peripherals|all)
            for idx in 0 1 2 3; do
                QEMU_ARGS+=("-chardev" "spicevmc,id=usbredir$idx,name=usbredir")
                QEMU_ARGS+=("-device" "usb-redir,chardev=usbredir$idx,id=usbredir$idx")
            done
            ;;
    esac
}

add_raw_usb_devices() {
    local mode="$1" dev vendor product bus addr class
    [ "$mode" = "all" ] || [ "$mode" = "peripherals" ] || return 0
    for dev in /sys/bus/usb/devices/*; do
        [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ] || continue
        vendor="$(cat "$dev/idVendor" 2>/dev/null || true)"
        product="$(cat "$dev/idProduct" 2>/dev/null || true)"
        bus="$(cat "$dev/busnum" 2>/dev/null || true)"
        addr="$(cat "$dev/devnum" 2>/dev/null || true)"
        class="$(cat "$dev/bDeviceClass" 2>/dev/null || true)"
        [ "$class" = "09" ] && continue
        if [ "$mode" = "peripherals" ] && [ "$class" = "08" ]; then
            continue
        fi
        [ -n "$vendor" ] && [ -n "$product" ] && [ -n "$bus" ] && [ -n "$addr" ] || continue
        QEMU_ARGS+=("-device" "usb-host,hostbus=$((10#$bus)),hostaddr=$((10#$addr))")
    done
}

add_pci_devices() {
    local dev
    for dev in $PCI_DEVICES; do
        [[ "$dev" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || {
            pz_warn "invalid PCI id skipped: $dev"
            continue
        }
        QEMU_ARGS+=("-device" "vfio-pci,host=$dev")
    done
}

build_qemu_args() {
    local audio netdev accel_cpu accel_machine
    QEMU_ARGS=()
    VIRTIOFS_COUNT=0
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would prepare runtime dir: $RUNTIME_DIR"
    else
        install -d "$RUNTIME_DIR" "$STATE_DIR"
    fi
    ensure_share_links
    start_virtiofs_share hosthome "$HOME"
    start_virtiofs_share exchange "$EXCHANGE_DIR"
    [ -d /mnt/sdcard ] && start_virtiofs_share sdcard /mnt/sdcard
    [ -d "/run/media/$USER" ] && start_virtiofs_share removable "/run/media/$USER"
    [ -d "/media/$USER" ] && start_virtiofs_share media "/media/$USER"
    [ -d /mnt ] && start_virtiofs_share mnt /mnt
    start_tpm

    QEMU_ARGS+=("-name" "$VM_NAME")
    if [ -e /dev/kvm ]; then
        accel_machine="q35,accel=kvm,kernel_irqchip=split"
        accel_cpu="host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_time,hv_vpindex,hv_runtime,hv_synic,hv_stimer,hv_reset,hv_frequencies"
        QEMU_ARGS+=("-enable-kvm")
    else
        accel_machine="q35,accel=tcg"
        accel_cpu="max"
    fi
    QEMU_ARGS+=("-machine" "$accel_machine")
    QEMU_ARGS+=("-cpu" "$accel_cpu")
    QEMU_ARGS+=("-smp" "$CPUS,sockets=1,cores=$CPUS,threads=1")
    QEMU_ARGS+=("-m" "${RAM_MB}M")
    if [ "$VIRTIOFS_COUNT" -gt 0 ]; then
        QEMU_ARGS+=("-object" "memory-backend-memfd,id=mem,size=${RAM_MB}M,share=on")
        QEMU_ARGS+=("-numa" "node,memdev=mem")
    fi
    QEMU_ARGS+=("-drive" "if=pflash,format=raw,readonly=on,file=$OVMF_CODE")
    QEMU_ARGS+=("-drive" "if=pflash,format=raw,file=$OVMF_VARS")
    QEMU_ARGS+=("-drive" "if=none,id=system,file=$DISK_PATH,format=$(disk_format "$DISK_PATH"),cache=none,discard=unmap,aio=io_uring")
    case "$RAW_DISK_BUS" in
        sata|ide) QEMU_ARGS+=("-device" "ide-hd,drive=system,bus=ide.0,bootindex=1") ;;
        virtio) QEMU_ARGS+=("-device" "virtio-blk-pci,drive=system,bootindex=1") ;;
        *) QEMU_ARGS+=("-device" "nvme,drive=system,serial=PZWINVM0,bootindex=1") ;;
    esac
    if [ -n "$PCI_DEVICES" ]; then
        QEMU_ARGS+=("-device" "intel-iommu,intremap=on,caching-mode=on")
    fi
    if [ "$ISO_EXPLICIT" = "1" ] && [ -n "$ISO_PATH" ] && [ -f "$ISO_PATH" ]; then
        QEMU_ARGS+=("-cdrom" "$ISO_PATH")
        QEMU_ARGS+=("-boot" "order=d,menu=on")
    else
        QEMU_ARGS+=("-boot" "menu=on")
    fi
    if [ -n "$VIRTIO_ISO" ] && [ -f "$VIRTIO_ISO" ]; then
        QEMU_ARGS+=("-drive" "file=$VIRTIO_ISO,media=cdrom,readonly=on,index=3")
    fi
    if [ "$GRAPHICS_PROFILE" = "virtio-gl" ]; then
        QEMU_ARGS+=("-device" "virtio-vga-gl")
    else
        QEMU_ARGS+=("-device" "virtio-vga")
    fi
    QEMU_ARGS+=("-device" "virtio-rng-pci")
    QEMU_ARGS+=("-device" "virtio-balloon-pci")
    add_usb_redirection
    add_raw_usb_devices "$USB_MODE"
    audio="$(audio_driver)"
    if [ "$audio" != "none" ]; then
        QEMU_ARGS+=("-audiodev" "$audio,id=audio0")
        QEMU_ARGS+=("-device" "ich9-intel-hda")
        QEMU_ARGS+=("-device" "hda-duplex,audiodev=audio0")
    fi
    netdev="user,id=net0,hostname=pz-winvm,hostfwd=tcp:127.0.0.1:33890-:3389,hostfwd=tcp:127.0.0.1:59850-:5985"
    if command -v smbd >/dev/null 2>&1; then
        netdev="$netdev,smb=${EFFECTIVE_SMB_DIR:-$SHARE_ROOT}"
    fi
    QEMU_ARGS+=("-netdev" "$netdev")
    QEMU_ARGS+=("-device" "e1000e,netdev=net0,mac=52:54:00:50:5a:00")
    QEMU_ARGS+=("-spice" "port=5930,disable-ticketing=on")
    QEMU_ARGS+=("-device" "virtio-serial-pci")
    QEMU_ARGS+=("-chardev" "spicevmc,id=vdagent,name=vdagent")
    QEMU_ARGS+=("-device" "virtserialport,chardev=vdagent,name=com.redhat.spice.0")
    if [ "$DISPLAY_MODE" = "none" ]; then
        QEMU_ARGS+=("-display" "none")
    elif [ "$GRAPHICS_PROFILE" = "virtio-gl" ]; then
        QEMU_ARGS+=("-display" "gtk,gl=on,show-cursor=on")
        [ "$FULLSCREEN" = "1" ] && QEMU_ARGS+=("-full-screen")
    else
        QEMU_ARGS+=("-display" "gtk,show-cursor=on")
        [ "$FULLSCREEN" = "1" ] && QEMU_ARGS+=("-full-screen")
    fi
    add_pci_devices
    if [ -n "$EXTRA_ARGS" ]; then
        # Intentional shell split for expert-only extra QEMU args.
        # shellcheck disable=SC2206
        local extra=( $EXTRA_ARGS )
        QEMU_ARGS+=("${extra[@]}")
    fi
}

launch_libvirt_domain() {
    local uri state display viewer_args=()
    uri="$(libvirt_uri)"
    type -P virsh >/dev/null 2>&1 || {
        pz_error "virsh missing for discovered domain: $LIBVIRT_DOMAIN"
        return 1
    }
    if [ "$DRY_RUN" = "1" ]; then
        echo "virsh -c $uri start $LIBVIRT_DOMAIN"
        if [ "$DISPLAY_MODE" != "none" ]; then
            echo "virt-viewer/spicy fullscreen domain=$LIBVIRT_DOMAIN"
        fi
        return 0
    fi
    ensure_share_links
    state="$(virsh -c "$uri" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
    if [ "$state" != "running" ]; then
        if ! virsh -c "$uri" start "$LIBVIRT_DOMAIN"; then
            # "start" fails when the domain is already active; re-check before
            # declaring failure so we still attach the viewer to a live VM.
            state="$(virsh -c "$uri" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
            [ "$state" = "running" ] || {
                pz_error "failed to start libvirt domain: $LIBVIRT_DOMAIN"
                return 1
            }
        fi
        local wait_attempt
        for ((wait_attempt = 0; wait_attempt < 30; wait_attempt++)); do
            state="$(virsh -c "$uri" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
            [ "$state" = "running" ] && break
            sleep 1
        done
        [ "$state" = "running" ] || {
            pz_error "libvirt domain did not reach running state: $LIBVIRT_DOMAIN ($state)"
            return 1
        }
    fi
    if [ "$DISPLAY_MODE" = "none" ]; then
        pz_info "Windows libvirt domain running headless: $LIBVIRT_DOMAIN"
        return 0
    fi
    if command -v spicy >/dev/null 2>&1; then
        local attempt
        for ((attempt = 0; attempt < 100; attempt++)); do
            display="$(virsh -c "$uri" domdisplay "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
            [ -n "$display" ] && break
            sleep 0.1
        done
        [ -n "${display:-}" ] || {
            pz_error "SPICE display unavailable for domain: $LIBVIRT_DOMAIN"
            return 1
        }
        if [ -n "$USB_AUTO_FILTER" ] && [ "$USB_MODE" != "none" ]; then
            viewer_args+=("--spice-usbredir-auto-redirect-filter=$USB_AUTO_FILTER")
            viewer_args+=("--spice-usbredir-redirect-on-connect=$USB_AUTO_FILTER")
        fi
        [ "$FULLSCREEN" = "1" ] && viewer_args+=(-f)
        exec spicy --uri "$display" --spice-shared-dir="$SHARE_ROOT" --spice-smartcard "${viewer_args[@]}"
    fi
    if command -v virt-viewer >/dev/null 2>&1; then
        [ "$FULLSCREEN" = "1" ] && viewer_args+=(--full-screen)
        exec virt-viewer --connect "$uri" --wait --reconnect "${viewer_args[@]}" "$LIBVIRT_DOMAIN"
    fi
    pz_error "install virt-viewer or spice-gtk to display domain: $LIBVIRT_DOMAIN"
    return 1
}

attach_libvirt_device_config() {
    local domain="$1" xml="$2" tmp
    tmp="$(mktemp)"
    printf '%s\n' "$xml" > "$tmp"
    if ! virsh -c "$(libvirt_uri)" attach-device "$domain" "$tmp" --config >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

optimize_libvirt_domain() {
    [ -n "$LIBVIRT_DOMAIN" ] || return 0
    type -P virsh >/dev/null 2>&1 || return 0
    local uri state xml redir_count cdrom_target
    uri="$(libvirt_uri)"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would tune libvirt domain=$LIBVIRT_DOMAIN ram=${RAM_MB}M cpus=$CPUS"
        pz_info "dry-run: would eject install ISO and ensure four SPICE USB channels, WebDAV plus smartcard"
        return 0
    fi
    grant_raw_qemu_disk_access "$DISK_PATH"
    state="$(virsh -c "$uri" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
    if [ "$state" = "running" ]; then
        pz_warn "domain running; persistent libvirt tuning deferred"
        return 0
    fi
    virsh -c "$uri" setmaxmem "$LIBVIRT_DOMAIN" "${RAM_MB}M" --config >/dev/null || true
    virsh -c "$uri" setmem "$LIBVIRT_DOMAIN" "${RAM_MB}M" --config >/dev/null || true
    virsh -c "$uri" setvcpus "$LIBVIRT_DOMAIN" "$CPUS" --maximum --config >/dev/null || true
    virsh -c "$uri" setvcpus "$LIBVIRT_DOMAIN" "$CPUS" --config >/dev/null || true
    cdrom_target="$(virsh -c "$uri" domblklist "$LIBVIRT_DOMAIN" --details 2>/dev/null | awk '$2 == "cdrom" && $4 != "-" && !seen++ {print $3}')"
    if [ -n "$cdrom_target" ]; then
        virsh -c "$uri" change-media "$LIBVIRT_DOMAIN" "$cdrom_target" --eject --config >/dev/null || true
    fi
    xml="$(virsh -c "$uri" dumpxml "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
    redir_count="$(grep -c "<redirdev " <<< "$xml" || true)"
    while [ "$redir_count" -lt 4 ]; do
        attach_libvirt_device_config "$LIBVIRT_DOMAIN" "<redirdev bus='usb' type='spicevmc'/>" || break
        redir_count=$((redir_count + 1))
    done
    if ! grep -q "<smartcard " <<< "$xml"; then
        attach_libvirt_device_config "$LIBVIRT_DOMAIN" "<smartcard mode='host'/>" ||
            pz_warn "libvirt smartcard passthrough unavailable; SPICE client support remains enabled"
    fi
    if ! grep -q "org.spice-space.webdav.0" <<< "$xml"; then
        attach_libvirt_device_config "$LIBVIRT_DOMAIN" \
            "<channel type='spiceport'><source channel='org.spice-space.webdav.0'/><target type='virtio' name='org.spice-space.webdav.0'/></channel>" ||
            pz_warn "SPICE WebDAV channel unavailable; Samba exchange remains active"
    fi
    pz_info "libvirt domain tuned: $LIBVIRT_DOMAIN ram=${RAM_MB}M cpus=$CPUS usbredir=$redir_count webdav=$(libvirt_webdav_channel_count)"
}

# v1 graphics contract: compat is the only profile allowed everywhere.
# virtio-gl is raw-QEMU-only and experimental; venus/rutabaga/VFIO are
# plan-only (see linux/windows-vm/graphics.sh). Never mutates a domain.
guard_graphics_profile() {
    case "$GRAPHICS_PROFILE" in
        compat|"")
            GRAPHICS_PROFILE=compat
            return 0
            ;;
        virtio-gl)
            if [ -n "$LIBVIRT_DOMAIN" ] && [ "$RAW_QEMU" != "1" ]; then
                if [ "$EXPLICIT_GRAPHICS" != "1" ]; then
                    pz_warn "perfil configurado virtio-gl requer QEMU direto; dominio libvirt $LIBVIRT_DOMAIN usara compat QXL/SPICE"
                    GRAPHICS_PROFILE=compat
                    return 0
                fi
                pz_error "graphics virtio-gl exige --raw-qemu na v1; dominio libvirt permanece QXL/SPICE"
                return 1
            fi
            if [ "$EXPLICIT_GRAPHICS" = "1" ] && [ "$GRAPHICS_EXPERIMENTAL" != "1" ]; then
                pz_error "graphics virtio-gl e experimental; adicione --experimental"
                return 1
            fi
            local blockers=()
            local gfx_kvm_path="${PZ_GFX_KVM_PATH:-/dev/kvm}"
            local gfx_dri_dir="${PZ_GFX_DRI_DIR:-/dev/dri}"
            local gfx_qemu_bin="${PZ_GFX_QEMU_BIN:-qemu-system-x86_64}"
            local -a render_nodes=("$gfx_dri_dir"/renderD*)
            [ -r "$gfx_kvm_path" ] && [ -w "$gfx_kvm_path" ] || blockers+=("KVM sem acesso read/write: $gfx_kvm_path")
            if [ ! -e "${render_nodes[0]}" ]; then
                blockers+=("render node ausente em $gfx_dri_dir")
            elif [ ! -r "${render_nodes[0]}" ] || [ ! -w "${render_nodes[0]}" ]; then
                blockers+=("render node sem acesso read/write: ${render_nodes[0]}")
            fi
            if ! command -v "$gfx_qemu_bin" >/dev/null 2>&1; then
                blockers+=("QEMU ausente: $gfx_qemu_bin")
            elif ! "$gfx_qemu_bin" -device help 2>/dev/null | grep -q 'virtio-vga-gl'; then
                blockers+=("QEMU sem device virtio-vga-gl")
            elif ! "$gfx_qemu_bin" -display help 2>/dev/null | grep -qw gtk; then
                blockers+=("QEMU sem display GTK necessario para gtk,gl=on")
            fi
            if [ "${#blockers[@]}" -gt 0 ]; then
                local blocker
                if [ "$DRY_RUN" = "1" ]; then
                    for blocker in "${blockers[@]}"; do
                        pz_warn "virtio-gl blocker (dry-run continua): $blocker"
                    done
                else
                    pz_error "graphics virtio-gl bloqueado neste host:"
                    for blocker in "${blockers[@]}"; do
                        pz_error "  - $blocker"
                    done
                    pz_error "fallback: linux/pz windows-vm launch --graphics compat"
                    return 1
                fi
            fi
            return 0
            ;;
        virtio-venus|rutabaga)
            pz_error "graphics $GRAPHICS_PROFILE bloqueado para Windows na v1 (driver guest nao validado). Veja: linux/pz windows-vm graphics plan --profile $GRAPHICS_PROFILE"
            return 1
            ;;
        vfio-looking-glass)
            pz_error "graphics vfio-looking-glass e plan-only na v1 (sem bind VFIO nem GRUB). Veja: linux/pz windows-vm graphics plan --profile vfio-looking-glass"
            return 1
            ;;
        *)
            pz_error "unknown graphics profile: $GRAPHICS_PROFILE (auto|compat|virtio-gl|virtio-venus|rutabaga|vfio-looking-glass)"
            return 1
            ;;
    esac
}

launch_vm() {
    parse_options "$@"
    [ "${PZ_WINDOWS_VM_FULLSCREEN:-0}" = "1" ] && FULLSCREEN=1
    effective_config
    local RESCUE_SOURCED=0
    RESCUE_SOURCED=0
    guard_graphics_profile || return 1
    trap cleanup_runtime EXIT INT TERM
    apply_host_optimizations
    if [ -n "$LIBVIRT_DOMAIN" ] && [ "$RAW_QEMU" != "1" ]; then
        if launch_libvirt_domain; then
            return 0
        fi
        local fallback_state
        fallback_state="$(virsh -c "$(libvirt_uri)" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
        case "$fallback_state" in
            running|paused|"pmsuspended")
                # Domain holds the disk write lock; direct QEMU would just
                # loop on lock errors. Let the caller retry the viewer.
                pz_error "libvirt domain is $fallback_state; not falling back to direct QEMU: $LIBVIRT_DOMAIN"
                return 1
                ;;
        esac
        pz_warn "libvirt domain start failed; falling back to direct QEMU/KVM"
        LIBVIRT_DOMAIN=""
        RAW_QEMU=1
    fi
    [ -n "$OVMF_CODE" ] || { pz_error "OVMF code firmware missing. Install edk2-ovmf."; return 1; }
    [ -f "$DISK_PATH" ] || {
        if [ "$RESCUE_SOURCED" = "0" ] && [ -f "$PZ_ROOT/linux/windows-vm/rescue.sh" ]; then
            source "$PZ_ROOT/linux/windows-vm/rescue.sh"
            RESCUE_SOURCED=1
        fi
        if [ "${PZ_WINDOWS_VM_RESCUE:-1}" != "0" ] && [ "${PZ_WINDOWS_VM_BOOT_SESSION:-0}" = "1" ] && type vm_rescue_run >/dev/null 2>&1; then
            if vm_rescue_run; then
                effective_config
                [ -f "$DISK_PATH" ] || { pz_error "VM disk still missing after rescue"; return 1; }
            else
                pz_error "VM disk missing: $DISK_PATH. Run: $PZ_ROOT/linux/pz windows-vm install --iso <windows.iso>"
                return 1
            fi
        else
            pz_error "VM disk missing: $DISK_PATH. Run: $PZ_ROOT/linux/pz windows-vm install --iso <windows.iso>"
            return 1
        fi
    }
    [ -f "$OVMF_VARS" ] || { pz_error "OVMF vars missing: $OVMF_VARS. Run install again."; return 1; }
    command -v qemu-system-x86_64 >/dev/null 2>&1 || { pz_error "qemu-system-x86_64 missing"; return 1; }
    build_qemu_args
    if [ "$DRY_RUN" = "1" ]; then
        shell_join qemu-system-x86_64 "${QEMU_ARGS[@]}"
        return 0
    fi
    pz_info "Windows VM shares: \\\\10.0.2.4\\qemu"
    pz_info "SPICE USB redirection: spice://127.0.0.1:5930"
    if command -v ionice >/dev/null 2>&1; then
        exec ionice -c 2 -n 0 qemu-system-x86_64 "${QEMU_ARGS[@]}"
    fi
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
}

status_json() {
    effective_config
    local kvm="no" config="no" disk="no" iso="no" ovmf="no" vars="no" qemu="" qemu_img="" virtiofs="" smbd="" swtpm_bin="" boot_helper="no" boot_service="no" boot_grub="unknown" current_marker="no" installed_like="no" boot_current="no" samba_managed="no" samba_reachable="no" share_links="no" usb_udev_managed="no" discovery
    local domain_state="missing" domain_disk=""
    [ -e /dev/kvm ] && kvm="yes"
    [ -f "$CONFIG_FILE" ] && config="yes"
    [ -f "$DISK_PATH" ] && disk="yes"
    if [ -f "$DISK_PATH" ] && disk_looks_installed "$DISK_PATH"; then
        installed_like="yes"
    fi
    [ -n "$ISO_PATH" ] && [ -f "$ISO_PATH" ] && iso="yes"
    [ -n "$OVMF_CODE" ] && [ -f "$OVMF_CODE" ] && ovmf="yes"
    [ -f "$OVMF_VARS" ] && vars="yes"
    qemu="$(command_path qemu-system-x86_64)"
    qemu_img="$(command_path qemu-img)"
    virtiofs="$(virtiofsd_path)"
    smbd="$(command_path smbd)"
    swtpm_bin="$(command_path swtpm)"
    if [ -n "$LIBVIRT_DOMAIN" ]; then
        domain_state="$(virsh -c "$(libvirt_uri)" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || echo unavailable)"
        domain_disk="$(libvirt_domain_disk "$LIBVIRT_DOMAIN")"
    fi
    [ -x "$BOOT_HELPER_TARGET" ] && boot_helper="yes"
    [ -f "$SERVICE_FILE" ] && boot_service="yes"
    samba_shares_managed && samba_managed="yes"
    samba_shares_reachable && samba_reachable="yes"
    share_links_ready && share_links="yes"
    windows_usb_udev_managed && usb_udev_managed="yes"
    boot_artifacts_current && boot_current="yes"
    boot_grub="$(grub_cfg_entry_state)"
    grep -qw 'phasezero.windowsvm=1' /proc/cmdline 2>/dev/null && current_marker="yes"
    discovery="$(discovery_json)"
    jq -n \
        --arg configFile "$CONFIG_FILE" \
        --arg configInstalled "$config" \
        --arg vmDir "$VM_DIR" \
        --arg disk "$DISK_PATH" \
        --arg diskExists "$disk" \
        --arg iso "$ISO_PATH" \
        --arg isoExists "$iso" \
        --arg ramMb "$RAM_MB" \
        --arg cpus "$CPUS" \
        --arg usbMode "$USB_MODE" \
        --arg graphicsProfile "$GRAPHICS_PROFILE" \
        --arg usbAutoFilter "$USB_AUTO_FILTER" \
        --arg usbUdevManaged "$usb_udev_managed" \
        --arg usbRedirChannels "$(libvirt_usb_redir_count)" \
        --arg usbAccessibleDevices "$(usb_accessible_device_count)" \
        --arg shareRoot "$SHARE_ROOT" \
        --arg shareLinks "$share_links" \
        --arg sambaManaged "$samba_managed" \
        --arg sambaReachable "$samba_reachable" \
        --arg smbHost "$SMB_HOST" \
        --arg exchangeDir "$EXCHANGE_DIR" \
        --arg webdavChannels "$(libvirt_webdav_channel_count)" \
        --arg networkState "$(libvirt_network_state)" \
        --arg nicModel "$(libvirt_interface_model)" \
        --arg spicy "$(command_path spicy)" \
        --arg diskSource "$DISK_SOURCE" \
        --arg libvirtDomain "$LIBVIRT_DOMAIN" \
        --arg libvirtUri "$(libvirt_uri)" \
        --arg libvirtState "$domain_state" \
        --arg libvirtDisk "$domain_disk" \
        --arg diskInstalledLike "$installed_like" \
        --arg kvm "$kvm" \
        --arg qemu "$qemu" \
        --arg qemuImg "$qemu_img" \
        --arg ovmfCode "$OVMF_CODE" \
        --arg ovmfCodeExists "$ovmf" \
        --arg ovmfVars "$OVMF_VARS" \
        --arg ovmfVarsExists "$vars" \
        --arg virtiofsd "$virtiofs" \
        --arg smbd "$smbd" \
        --arg swtpm "$swtpm_bin" \
        --arg bootHelper "$boot_helper" \
        --arg bootService "$boot_service" \
        --arg bootArtifactsCurrent "$boot_current" \
        --arg bootConfiguredRepo "$(root_env_value PZ_WINDOWS_VM_REPO)" \
        --arg bootConfiguredUser "$(root_env_value PZ_WINDOWS_VM_BOOT_USER)" \
        --arg grubEntry "$boot_grub" \
        --arg currentMarker "$current_marker" \
        --argjson discovery "$discovery" \
        '{
            config: {path: $configFile, installed: ($configInstalled == "yes")},
            vm: {dir: $vmDir, disk: $disk, diskExists: ($diskExists == "yes"), diskSource: $diskSource, installedLike: ($diskInstalledLike == "yes"), iso: $iso, isoExists: ($isoExists == "yes"), ramMb: ($ramMb|tonumber), cpus: ($cpus|tonumber), usbMode: $usbMode, graphicsProfile: $graphicsProfile},
            libvirt: {domain: $libvirtDomain, uri: $libvirtUri, state: $libvirtState, disk: $libvirtDisk, preferred: ($libvirtDomain != ""), network:"default", networkState:$networkState, nicModel:$nicModel},
            host: {kvm: ($kvm == "yes"), qemu: $qemu, qemuImg: $qemuImg, ovmfCode: $ovmfCode, ovmfCodeExists: ($ovmfCodeExists == "yes"), ovmfVars: $ovmfVars, ovmfVarsExists: ($ovmfVarsExists == "yes"), virtiofsd: $virtiofsd, smbd: $smbd, swtpm: $swtpm},
            access: {
                shareRoot: $shareRoot,
                shareLinksReady: ($shareLinks == "yes"),
                sambaManaged: ($sambaManaged == "yes"),
                sambaReachable: ($sambaReachable == "yes"),
                smbHost: $smbHost,
                exchangeDir: $exchangeDir,
                shares: ["PZExchange", "PZHome", "PZSDCard", "PZRemovable", "PZMedia", "PZMounts"],
                spiceClient: $spicy,
                spiceWebdavChannels: ($webdavChannels|tonumber),
                usbMode: $usbMode,
                usbAutoFilter: $usbAutoFilter,
                usbUdevManaged: ($usbUdevManaged == "yes"),
                usbRedirChannels: ($usbRedirChannels|tonumber),
                usbAccessibleDevices: ($usbAccessibleDevices|tonumber)
            },
            discovery: $discovery,
            boot: {helperInstalled: ($bootHelper == "yes"), serviceInstalled: ($bootService == "yes"), artifactsCurrent: ($bootArtifactsCurrent == "yes"), configuredRepo: $bootConfiguredRepo, configuredUser: $bootConfiguredUser, grubCfgEntry: $grubEntry, currentBootWindowsVm: ($currentMarker == "yes")}
        }'
}

print_status() {
    status_json
}

print_discover() {
    parse_options "$@"
    if [ "$JSON_OUT" = "1" ]; then
        discovery_json
        return 0
    fi
    local discovery
    discovery="$(discovery_json)"
    echo "PhaseZero Windows VM discovery"
    echo "  configured_disk: $(jq -r '.configuredDisk.path // ""' <<< "$discovery")"
    echo "  discovered_installed_disk: $(jq -r '.discoveredInstalledDisk.path // ""' <<< "$discovery")"
    echo "  discovered_installed_usable: $(jq -r '.discoveredInstalledDisk.usable // false' <<< "$discovery")"
    echo "  discovered_usable_disk: $(jq -r '.discoveredUsableDisk.path // ""' <<< "$discovery")"
    echo "  discovered_any_disk: $(jq -r '.discoveredAnyDisk.path // ""' <<< "$discovery")"
}

cmd_optimize() {
    parse_options "$@"
    effective_config
    apply_host_optimizations
    optimize_libvirt_domain
}

cmd_adopt() {
    parse_options "$@"
    local target="${DISK_PATH:-$(find_existing_windows_disk | sed -n '1p')}"
    [ -n "$target" ] || { pz_error "no existing Windows VM disk found"; return 1; }
    [ -f "$target" ] || { pz_error "existing disk not found: $target"; return 1; }
    disk_looks_installed "$target" || { pz_error "disk does not look like an installed Windows VM: $target"; return 1; }
    if ! target_user_can_rw "$target"; then
        if [ "$EUID" -ne 0 ]; then
            pz_error "existing disk is not readable. run: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh adopt --disk '$target'"
            return 1
        fi
        if command -v setfacl >/dev/null 2>&1; then
            setfacl -m "u:$TARGET_USER:rw" "$target" || true
        else
            chmod g+rw "$target" || true
        fi
    fi
    target_user_can_rw "$target" || { pz_error "could not grant $TARGET_USER read/write access to existing disk: $target"; return 1; }
    DISK_PATH="$target"
    EXPLICIT_DISK=1
    effective_config
    DISK_PATH="$target"
    DISK_SOURCE="adopted-existing"
    ensure_vm_storage
    write_config
    install_user_files
    pz_info "adopted existing Windows VM disk: $target"
}

print_plan() {
    parse_options "$@"
    effective_config
    if [ "$JSON_OUT" = "1" ]; then
        status_json
        return 0
    fi
    echo "PhaseZero Windows VM plan"
    echo "  iso: ${ISO_PATH:-missing}"
    echo "  disk: $DISK_PATH ($DISK_SIZE)"
    echo "  disk_source: $DISK_SOURCE"
    echo "  disk_installed_like: $([ -f "$DISK_PATH" ] && disk_looks_installed "$DISK_PATH" && echo yes || echo no)"
    echo "  ram_mb: $RAM_MB"
    echo "  cpus: $CPUS"
    echo "  kvm: $([ -e /dev/kvm ] && echo yes || echo no)"
    echo "  ovmf: ${OVMF_CODE:-missing}"
    echo "  tpm: $(command_path swtpm || echo missing)"
    echo "  home_share: $HOME"
    echo "  sdcard_share: $([ -d /mnt/sdcard ] && echo /mnt/sdcard || echo missing)"
    echo "  removable_share: $([ -d "/run/media/$USER" ] && echo "/run/media/$USER" || echo missing)"
    echo "  smb_unc: \\\\10.0.2.4\\qemu"
    echo "  spice_usb: spice://127.0.0.1:5930"
    echo "  direct_boot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot install"
}

need_root() {
    [ "$EUID" -eq 0 ] && return 0
    pz_error "root required. run: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot install"
    return 1
}

parse_boot_common_args() {
    local parsed=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target-root)
                [ -n "${2:-}" ] || { pz_error "--target-root requires a path"; return 1; }
                export PZ_BOOT_TARGET_ROOT="$2"
                shift 2
                ;;
            --target-root=*)
                export PZ_BOOT_TARGET_ROOT="${1#*=}"
                shift
                ;;
            --loader)
                [ -n "${2:-}" ] || { pz_error "--loader requires auto|grub|systemd-boot|refind|efi-stub"; return 1; }
                export PZ_BOOT_LOADER="$2"
                shift 2
                ;;
            --loader=*)
                export PZ_BOOT_LOADER="${1#*=}"
                shift
                ;;
            *)
                parsed+=("$1")
                shift
                ;;
        esac
    done
    PZ_BOOT_PARSED_ARGS=("${parsed[@]}")
}

detected_loader() {
    local loader="${PZ_BOOT_LOADER:-auto}"
    if [ "$loader" = "auto" ]; then
        loader="$(pz_boot_detect_loader)"
    fi
    echo "$loader"
}

loader_install_entry() {
    local loader="$1" uuid version kernel initrd cmdline
    uuid="$(root_uuid)"
    version="$(latest_kernel_version)"
    [ -n "$uuid" ] || { pz_error "could not resolve root UUID"; return 1; }
    [ -n "$version" ] || { pz_error "could not resolve /boot/vmlinuz-*"; return 1; }
    kernel="/boot/vmlinuz-$version"
    initrd="/boot/initramfs-$version.img"
    [ -f "$kernel" ] || { pz_error "missing kernel: $kernel"; return 1; }
    [ -f "$initrd" ] || { pz_error "missing initrd: $initrd"; return 1; }
    cmdline="root=UUID=$uuid rw quiet splash"
    subvol="$(root_subvol || true)"
    [ -n "$subvol" ] && cmdline="$cmdline rootflags=subvol=$subvol"

    case "$loader" in
        systemd-boot)
            pz_boot_systemd_boot_oneshot_entry "$BOOT_ID" "$kernel" "$initrd" "$cmdline"
            pz_boot_systemd_boot_set_oneshot "$BOOT_ID"
            ;;
        refind)
            pz_boot_refind_install_stanza "$BOOT_ID" "$kernel" "$initrd" "$cmdline"
            ;;
        efi-stub)
            pz_boot_efi_stub_entry "$BOOT_ID" "$kernel" "$initrd" "$cmdline"
            ;;
        grub-efi|grub-bios)
            return 0
            ;;
        *)
            pz_error "unsupported loader: $loader"
            return 1
            ;;
    esac
}

loader_remove_entry() {
    local loader="$1"
    case "$loader" in
        systemd-boot)
            pz_boot_systemd_boot_remove_entry "$BOOT_ID"
            ;;
        refind)
            pz_boot_refind_remove_stanza "$BOOT_ID"
            ;;
        efi-stub)
            pz_boot_efi_stub_remove "$BOOT_ID"
            ;;
        grub-efi|grub-bios)
            return 0
            ;;
        *)
            pz_error "unsupported loader: $loader"
            return 1
            ;;
    esac
}

loader_entry_state() {
    local loader="$1"
    case "$loader" in
        systemd-boot)
            local esp; esp="$(pz_boot_esp_dir)"
            [ -f "$esp/loader/entries/$BOOT_ID.conf" ] && echo present || echo missing
            ;;
        refind)
            local esp; esp="$(pz_boot_esp_dir)"
            [ -f "$esp/EFI/refind/entries/$BOOT_ID.conf" ] && echo present || echo missing
            ;;
        grub-efi|grub-bios)
            grub_cfg_entry_state
            ;;
        *)
            echo unknown
            ;;
    esac
}

need_root_action() {
    local action="$1"
    shift || true
    [ "$EUID" -eq 0 ] && return 0
    if command -v pkexec >/dev/null 2>&1 && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }; then
        exec pkexec bash "$0" boot "$action" "$@"
    fi
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash "$0" boot "$action" "$@"
    fi
    pz_error "root required for boot $action"
    return 1
}

latest_kernel_version() {
    pz_boot_latest_kernel_version
}

root_uuid() {
    pz_boot_root_uuid
}

root_subvol() {
    pz_boot_root_subvol
}

session_desktop_content() {
    cat <<EOF
[Desktop Entry]
Name=PhaseZero Windows VM
Comment=Start PhaseZero Windows VM without desktop login
Exec=$SESSION_TARGET
Type=Application
DesktopNames=PhaseZeroWindowsVM
EOF
}

root_env_content() {
    printf '%s\n' '# PhaseZero managed Windows VM boot environment'
    printf 'PZ_WINDOWS_VM_REPO=%q\n' "$PZ_ROOT"
    printf 'PZ_WINDOWS_VM_BOOT_USER=%q\n' "$TARGET_USER"
    printf 'PZ_WINDOWS_VM_RUNTIME_LAUNCHER=%q\n' "$RUNTIME_LAUNCHER"
    printf 'PZ_DISPLAY_SESSION_HELPER=%q\n' "$DISPLAY_SESSION_TARGET"
    printf 'PZ_WINDOWS_VM_SESSION_RETRY_SECONDS=%q\n' "${PZ_WINDOWS_VM_SESSION_RETRY_SECONDS:-5}"
    printf 'PZ_WINDOWS_VM_DESKTOP_FALLBACK=%q\n' "${PZ_WINDOWS_VM_DESKTOP_FALLBACK:-0}"
}

root_env_value() {
    local name="$1"
    [ -r "$ROOT_ENV_FILE" ] || return 0
    (
        set +u
        # Managed root-owned environment generated by root_env_content.
        # shellcheck disable=SC1090
        . "$ROOT_ENV_FILE"
        printf '%s\n' "${!name:-}"
    )
}

boot_artifacts_current() {
    local loader
    loader="$(detected_loader)"
        [ -x "$BOOT_HELPER_TARGET" ] &&
        [ -x "$SESSION_TARGET" ] &&
        [ -r "$DISPLAY_SESSION_TARGET" ] &&
        [ -x "$RUNTIME_LAUNCHER" ] &&
        [ -x "$RUNTIME_GRAPHICS" ] &&
        [ -r "$RUNTIME_COMMON" ] &&
        [ -f "$SERVICE_FILE" ] &&
        [ -f "$WAYLAND_SESSION_FILE" ] &&
        [ -f "$XSESSION_FILE" ] &&
        [ -f "$ROOT_ENV_FILE" ] || return 1
    case "$loader" in
        grub-efi|grub-bios)
            [ -x "$GRUB_SCRIPT" ] || return 1
            grep -Fq "phasezero.windowsvm=1" "$GRUB_SCRIPT" || return 1
            grep -Fq -- "--id='$BOOT_ID'" "$GRUB_SCRIPT" || return 1
            ;;
    esac
    cmp -s "$BOOT_HELPER_SOURCE" "$BOOT_HELPER_TARGET" || return 1
    cmp -s "$SESSION_SOURCE" "$SESSION_TARGET" || return 1
    cmp -s "$DISPLAY_SESSION_SOURCE" "$DISPLAY_SESSION_TARGET" || return 1
    cmp -s "$PZ_ROOT/linux/windows-vm/windows-vm.sh" "$RUNTIME_LAUNCHER" || return 1
    cmp -s "$PZ_ROOT/linux/windows-vm/graphics.sh" "$RUNTIME_GRAPHICS" || return 1
    cmp -s "$PZ_ROOT/linux/lib/common.sh" "$RUNTIME_COMMON" || return 1
    [ "$(root_env_value PZ_WINDOWS_VM_REPO)" = "$PZ_ROOT" ] || return 1
    [ "$(root_env_value PZ_WINDOWS_VM_BOOT_USER)" = "$TARGET_USER" ] || return 1
    grep -Fqx "Exec=$SESSION_TARGET" "$WAYLAND_SESSION_FILE" || return 1
    grep -Fqx "Exec=$SESSION_TARGET" "$XSESSION_FILE" || return 1
    grep -Fqx "ExecStart=$BOOT_HELPER_TARGET" "$SERVICE_FILE" || return 1
}

boot_service_content() {
    cat <<EOF
[Unit]
Description=PhaseZero Windows VM GRUB boot session switch
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service

[Service]
Type=oneshot
Environment=PZ_WINDOWS_VM_BOOT_USER=$TARGET_USER
ExecStart=$BOOT_HELPER_TARGET

[Install]
WantedBy=graphical.target
EOF
}

grub_script_content() {
    local uuid version kernel initrd kernel_rel initrd_rel amd_ucode_rel intel_ucode_rel subvol rootflags=""
    uuid="$(root_uuid)"
    version="$(latest_kernel_version)"
    [ -n "$uuid" ] || { pz_error "could not resolve root UUID"; return 1; }
    [ -n "$version" ] || { pz_error "could not resolve /boot/vmlinuz-*"; return 1; }
    kernel="/boot/vmlinuz-$version"
    initrd="/boot/initramfs-$version.img"
    [ -f "$kernel" ] || { pz_error "missing kernel: $kernel"; return 1; }
    [ -f "$initrd" ] || { pz_error "missing initrd: $initrd"; return 1; }
    kernel_rel="$(grub-mkrelpath "$kernel")"
    initrd_rel="$(grub-mkrelpath "$initrd")"
    amd_ucode_rel="$([ -f /boot/amd-ucode.img ] && grub-mkrelpath /boot/amd-ucode.img || true)"
    intel_ucode_rel="$([ -f /boot/intel-ucode.img ] && grub-mkrelpath /boot/intel-ucode.img || true)"
    subvol="$(root_subvol || true)"
    [ -n "$subvol" ] && rootflags=" rootflags=subvol=$subvol"

    cat <<EOF
#!/usr/bin/env bash
exec tail -n +3 "\$0"
# PhaseZero managed GRUB entry. Re-run linux/pz windows-vm boot install after kernel changes.
menuentry '$BOOT_ENTRY' --id='$BOOT_ID' --hotkey=w --class windows --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod btrfs
    search --no-floppy --fs-uuid --set=root $uuid
    echo 'Booting PhaseZero Windows VM...'
    linux $kernel_rel root=UUID=$uuid rw$rootflags quiet splash phasezero.windowsvm=1
    initrd $amd_ucode_rel $intel_ucode_rel $initrd_rel
}
EOF
}

refresh_grub_config() {
    pz_boot_refresh_grub_config "$GRUB_CFG"
}

grub_cfg_entry_state() {
    if [ -r "$GRUB_CFG" ]; then
        grep -Fq "menuentry '$BOOT_ENTRY'" "$GRUB_CFG" && echo present || echo missing
    elif [ "$EUID" -eq 0 ] && [ -f "$GRUB_CFG" ]; then
        grep -Fq "menuentry '$BOOT_ENTRY'" "$GRUB_CFG" && echo present || echo missing
    else
        echo unknown-permission
    fi
}

install_boot() {
    local loader
    need_root
    pz_boot_require_current_root_target
    loader="$(detected_loader)"
    pz_boot_backup_bundle "windows-vm-boot-install-${loader}"
    effective_config
    ensure_share_links 1
    configure_windows_samba_shares
    optimize_libvirt_domain
    install -d /usr/local/lib/phasezero "$RUNTIME_ROOT/linux/windows-vm" "$RUNTIME_ROOT/linux/lib" /etc/phasezero /usr/share/wayland-sessions /usr/share/xsessions
    install -m 0755 "$BOOT_HELPER_SOURCE" "$BOOT_HELPER_TARGET"
    install -m 0755 "$SESSION_SOURCE" "$SESSION_TARGET"
    install -m 0644 "$DISPLAY_SESSION_SOURCE" "$DISPLAY_SESSION_TARGET"
    install -m 0755 "$PZ_ROOT/linux/windows-vm/windows-vm.sh" "$RUNTIME_LAUNCHER"
    install -m 0755 "$PZ_ROOT/linux/windows-vm/graphics.sh" "$RUNTIME_GRAPHICS"
    install -m 0644 "$PZ_ROOT/linux/lib/common.sh" "$RUNTIME_COMMON"
    root_env_content > "$ROOT_ENV_FILE"
    chmod 0644 "$ROOT_ENV_FILE"
    session_desktop_content > "$WAYLAND_SESSION_FILE"
    session_desktop_content > "$XSESSION_FILE"
    chmod 0644 "$WAYLAND_SESSION_FILE" "$XSESSION_FILE"
    boot_service_content > "$SERVICE_FILE"
    chmod 0644 "$SERVICE_FILE"
    case "$loader" in
        grub-efi|grub-bios)
            pz_boot_preflight_grub
            pz_boot_validate_active_efi_safe
            grub_script_content > "$GRUB_SCRIPT"
            chmod 0755 "$GRUB_SCRIPT"
            systemctl daemon-reload
            systemctl enable phasezero-windows-vm-boot-prepare.service >/dev/null
            refresh_grub_config
            pz_boot_validate_grub_cfg_safe "$GRUB_CFG"
            pz_boot_validate_active_efi_safe
            pz_info "PhaseZero Windows VM GRUB boot entry installed (loader=$loader)"
            ;;
        systemd-boot)
            pz_boot_validate_active_efi_safe
            rm -f "$GRUB_SCRIPT" 2>/dev/null || true
            systemctl daemon-reload
            systemctl enable phasezero-windows-vm-boot-prepare.service >/dev/null
            loader_install_entry "$loader"
            ;;
        refind)
            pz_boot_validate_active_efi_safe
            rm -f "$GRUB_SCRIPT" 2>/dev/null || true
            systemctl daemon-reload
            systemctl enable phasezero-windows-vm-boot-prepare.service >/dev/null
            loader_install_entry "$loader"
            ;;
        efi-stub)
            pz_boot_validate_active_efi_safe
            rm -f "$GRUB_SCRIPT" 2>/dev/null || true
            systemctl daemon-reload
            systemctl enable phasezero-windows-vm-boot-prepare.service >/dev/null
            loader_install_entry "$loader"
            ;;
        *)
            pz_error "unsupported bootloader: $loader"
            return 1
            ;;
    esac
    boot_artifacts_current || {
        pz_error "Windows VM boot artifact validation failed after install (loader=$loader)"
        return 1
    }
    pz_info "PhaseZero Windows VM boot entry installed (loader=$loader)"
}

remove_boot() {
    local loader
    need_root
    pz_boot_require_current_root_target
    loader="$(detected_loader)"
    pz_boot_backup_bundle "windows-vm-boot-remove-${loader}"
    systemctl disable phasezero-windows-vm-boot-prepare.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$GRUB_SCRIPT" "$WAYLAND_SESSION_FILE" "$XSESSION_FILE" "$BOOT_HELPER_TARGET" "$SESSION_TARGET" "$ROOT_ENV_FILE"
    rm -rf "$RUNTIME_ROOT"
    if [ -f "$SDDM_CONF" ] && grep -q 'PhaseZero managed' "$SDDM_CONF" 2>/dev/null; then
        rm -f "$SDDM_CONF"
    fi
    loader_remove_entry "$loader"
    systemctl daemon-reload
    case "$loader" in
        grub-efi|grub-bios)
            pz_boot_preflight_grub
            refresh_grub_config
            pz_boot_validate_grub_cfg_safe "$GRUB_CFG"
            pz_boot_validate_active_efi_safe
            ;;
        *)
            pz_boot_validate_active_efi_safe
            ;;
    esac
    pz_info "PhaseZero Windows VM boot entry removed (loader=$loader)"
}

ensure_boot_entry_ready() {
    local loader state
    if ! boot_artifacts_current; then
        pz_warn "Windows VM boot files missing or stale; reinstalling"
        install_boot
        return 0
    fi
    loader="$(detected_loader)"
    state="$(loader_entry_state "$loader")"
    if [ "$state" = "missing" ]; then
        pz_warn "Windows VM loader entry missing for $loader; reinstalling"
        loader_install_entry "$loader"
        state="$(loader_entry_state "$loader")"
    fi
    if [ "$state" != "present" ]; then
        pz_error "Windows VM loader entry not confirmed: $state (loader=$loader)"
        return 1
    fi
}

set_next_boot_root() {
    local loader
    pz_boot_require_current_root_target
    loader="$(detected_loader)"
    case "$loader" in
        systemd-boot)
            ensure_boot_entry_ready
            pz_boot_systemd_boot_set_oneshot "$BOOT_ID"
            ;;
        refind)
            ensure_boot_entry_ready
            pz_info "rEFInd: select PhaseZero Windows VM from boot menu manually"
            ;;
        efi-stub)
            ensure_boot_entry_ready
            pz_info "EFI stub: entry should appear in UEFI boot menu as PhaseZero Windows VM"
            ;;
        *)
            command -v grub-reboot >/dev/null 2>&1 || { pz_error "grub-reboot missing"; return 1; }
            ensure_boot_entry_ready
            grub-reboot "$BOOT_ID"
            ;;
    esac
    pz_info "next boot set to: $BOOT_ENTRY ($BOOT_ID, loader=$loader)"
    pz_info "run: systemctl reboot"
}

set_next_boot() {
    need_root_action next
    set_next_boot_root
}

next_reboot() {
    need_root_action next-reboot
    set_next_boot_root
    pz_info "rebooting into Windows VM"
    systemctl reboot
}

set_default_boot() {
    local loader
    loader="$(detected_loader 2>/dev/null || echo grub-bios)"
    case "$loader" in
        systemd-boot)
            ensure_boot_entry_ready
            if command -v bootctl >/dev/null 2>&1; then
                bootctl set-default "$BOOT_ID" 2>/dev/null || bootctl set-default "$BOOT_ID.conf" 2>/dev/null || true
                pz_warn "permanent systemd-boot default set to: $BOOT_ENTRY"
            else
                pz_error "bootctl missing; cannot set systemd-boot default"
                return 1
            fi
            ;;
        refind)
            local esp
            esp="$(pz_boot_esp_dir 2>/dev/null || true)"
            if [ -n "$esp" ]; then
                pz_warn "rEFInd: set default selection in $esp/EFI/refind/refind.conf (default_selection)"
            else
                pz_warn "rEFInd: set default selection manually (ESP not detected)"
            fi
            ;;
        *)
            need_root_action set-default
            command -v grub-set-default >/dev/null 2>&1 || { pz_error "grub-set-default missing"; return 1; }
            ensure_boot_entry_ready
            grub-set-default "$BOOT_ID"
            pz_warn "permanent GRUB default set to: $BOOT_ENTRY ($BOOT_ID)"
            ;;
    esac
}

clear_next_boot() {
    local loader
    need_root_action clear-next
    loader="$(detected_loader)"
    case "$loader" in
        systemd-boot)
            command -v bootctl >/dev/null 2>&1 && bootctl set-default "" 2>/dev/null || true
            ;;
        *)
            command -v grub-editenv >/dev/null 2>&1 || { pz_error "grub-editenv missing"; return 1; }
            grub-editenv - unset next_entry >/dev/null 2>&1 || true
            ;;
    esac
    pz_info "cleared one-shot next_entry (loader=$loader)"
}

status_boot() {
    local loader="" grub_next_entry="" grub_saved_entry="" cmdline_marker="no" artifacts_current="no"
    loader="$(detected_loader)"
    grep -qw 'phasezero.windowsvm=1' /proc/cmdline 2>/dev/null && cmdline_marker="yes"
    boot_artifacts_current && artifacts_current="yes"
    if command -v grub-editenv >/dev/null 2>&1; then
        grub_next_entry="$(grub-editenv list 2>/dev/null | awk -F= '$1 == "next_entry" {print $2; exit}')"
        grub_saved_entry="$(grub-editenv list 2>/dev/null | awk -F= '$1 == "saved_entry" {print $2; exit}')"
    fi
    echo "helper: $BOOT_HELPER_TARGET"
    [ -x "$BOOT_HELPER_TARGET" ] && echo "helper_installed: yes" || echo "helper_installed: no"
    [ -x "$SESSION_TARGET" ] && echo "session_launcher_installed: yes" || echo "session_launcher_installed: no"
    [ -x "$RUNTIME_LAUNCHER" ] && echo "runtime_launcher_installed: yes" || echo "runtime_launcher_installed: no"
    [ -x "$RUNTIME_GRAPHICS" ] && echo "runtime_graphics_installed: yes" || echo "runtime_graphics_installed: no"
    [ -f "$SERVICE_FILE" ] && echo "service_installed: yes" || echo "service_installed: no"
    systemctl is-enabled phasezero-windows-vm-boot-prepare.service 2>/dev/null || true
    [ -x "$GRUB_SCRIPT" ] && echo "grub_script: yes" || echo "grub_script: no"
    echo "loader: $loader"
    echo "loader_entry: $(loader_entry_state "$loader")"
    echo "artifacts_current: $artifacts_current"
    echo "configured_repo: $(root_env_value PZ_WINDOWS_VM_REPO)"
    echo "configured_boot_user: $(root_env_value PZ_WINDOWS_VM_BOOT_USER)"
    [ "$loader" = "grub-efi" ] || [ "$loader" = "grub-bios" ] && echo "grub_cfg_entry: $(grub_cfg_entry_state)" || echo "grub_cfg_entry: n/a"
    echo "grub_next_entry: ${grub_next_entry:-none}"
    echo "grub_saved_entry: ${grub_saved_entry:-none}"
    [ -f "$SDDM_CONF" ] && echo "active_sddm_windows_vm_conf: yes" || echo "active_sddm_windows_vm_conf: no"
    echo "current_boot_windows_vm: $cmdline_marker"
    echo "target_user: $TARGET_USER"
    echo "target_root: $(pz_boot_target_root)"
    echo "session: phasezero-windows-vm.desktop"
    echo "grub_entry_id: $BOOT_ID"
    echo "recommended_direct_boot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot next-reboot"
}

dry_run_boot() {
    local loader
    loader="$(detected_loader)"
    echo "PhaseZero Windows VM boot dry-run"
    echo "  loader: $loader"
    echo "  helper: $BOOT_HELPER_TARGET"
    echo "  session_launcher: $SESSION_TARGET"
    echo "  runtime_launcher: $RUNTIME_LAUNCHER"
    echo "  runtime_graphics: $RUNTIME_GRAPHICS"
    echo "  service: $SERVICE_FILE"
    echo "  grub: $GRUB_SCRIPT"
    echo "  target_user: $TARGET_USER"
    echo "  root_uuid: $(root_uuid || true)"
    echo "  kernel: $(latest_kernel_version || true)"
    echo "  session: phasezero-windows-vm.desktop"
    echo "  grub entry id: $BOOT_ID"
    [ "$loader" = "grub-efi" ] || [ "$loader" = "grub-bios" ] && echo "  grub hotkey: w"
    echo "  one-shot boot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot next"
    echo "  one-shot reboot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot next-reboot"
    echo "  loader override: --loader auto|grub|systemd-boot|refind|efi-stub"
}

cmd_boot() {
    parse_boot_common_args "$@"
    set -- "${PZ_BOOT_PARSED_ARGS[@]}"
    local sub="${1:-status}"
    [ $# -gt 0 ] && shift || true
    case "$sub" in
        install) install_boot "$@" ;;
        remove) remove_boot "$@" ;;
        status) status_boot "$@" ;;
        next|set-next) set_next_boot "$@" ;;
        next-reboot|reboot-windows-vm|reboot) next_reboot "$@" ;;
        set-default) set_default_boot "$@" ;;
        clear-next) clear_next_boot "$@" ;;
        dry-run|plan) dry_run_boot "$@" ;;
        *) pz_error "usage: windows-vm boot (install|remove|status|next|next-reboot|set-default|clear-next|dry-run) [--loader auto|grub|systemd-boot|refind|efi-stub] [--target-root /]"; exit 1 ;;
    esac
}

case "$ACTION" in
    status) parse_options "$@"; print_status ;;
    discover|detect) print_discover "$@" ;;
    adopt|use-existing) cmd_adopt "$@" ;;
    plan|dry-run) print_plan "$@" ;;
    install|setup) install_vm "$@" ;;
    optimize|tune) cmd_optimize "$@" ;;
    shares|access) cmd_shares "$@" ;;
    host-access|guest-disk|browse-guest) bash "$PZ_ROOT/linux/windows-vm/host-access.sh" "$@" ;;
    graphics|gpu) bash "$PZ_ROOT/linux/windows-vm/graphics.sh" "$@" ;;
    apps|frontends|containers) bash "$PZ_ROOT/linux/windows-vm/container-frontends.sh" "$@" ;;
    launch|start|run) launch_vm "$@" ;;
    boot) cmd_boot "$@" ;;
    help|--help|-h|"") usage ;;
    *) pz_error "usage: windows-vm (status|discover|adopt|plan|install|optimize|shares|host-access|graphics|apps|launch|boot)"; exit 1 ;;
esac
