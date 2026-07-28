#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

SWTPM_BIN=""
SWTPM_RUNNING=false
SWTPM_SOCKET=""
SWTPM_PID=""
SWTPM_SERVICE_INSTALLED=false
VIRTIO_PINNED="0.1.285"
VIRTIO_PINNED_SHA="e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331"
VIRTIO_LATEST=""
VIRTIO_LATEST_URL=""
VIRTIO_OUTDATED=false
GRAPHICS_PROFILE=""
GRAPHICS_SUPPORTED=false
GRAPHICS_FALLBACK="compat"
GRAPHICS_FAILURES=()
KVM_ACCESS=false
OVMF_PRESENT=false
RAM_MB=0
CPUS=0
DISK_GB=0

cleanup() { true; }

swtpm_check() {
    SWTPM_BIN="$(command -v swtpm || true)"
    SWTPM_SERVICE_INSTALLED=false
    SWTPM_RUNNING=false

    [ -n "$SWTPM_BIN" ] || return 0

    local service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    [ -f "$service_dir/swtpm.service" ] && SWTPM_SERVICE_INSTALLED=true

    local sock="${XDG_RUNTIME_DIR:-/tmp}/swtpm.sock"
    local pid_file="${XDG_RUNTIME_DIR:-/tmp}/swtpm.pid"

    if [ -S "$sock" ]; then
        SWTPM_SOCKET="$sock"
        SWTPM_RUNNING=true
        [ -f "$pid_file" ] && SWTPM_PID="$(cat "$pid_file" 2>/dev/null || true)"
    elif systemctl --user is-active swtpm.service >/dev/null 2>&1; then
        SWTPM_RUNNING=true
        SWTPM_SOCKET="$sock"
    fi
}

swtpm_auto_fix() {
    [ -z "$SWTPM_BIN" ] && { pz_warn "swtpm binary not found — cannot auto-start"; return 1; }
    if $SWTPM_RUNNING; then
        return 0
    fi

    local service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$service_dir"
    if ! $SWTPM_SERVICE_INSTALLED; then
        cp "$PZ_ROOT/linux/windows-vm/swtpm.service" "$service_dir/swtpm.service"
        systemctl --user daemon-reload
        SWTPM_SERVICE_INSTALLED=true
    fi

    local tpm_state_dir="${XDG_DATA_HOME:-$HOME/.local/share}/swtpm"
    mkdir -p "$tpm_state_dir"

    systemctl --user enable --now swtpm.service 2>/dev/null || \
        swtpm socket --tpm2 \
            --tpmstate "dir=$tpm_state_dir" \
            --ctrl "type=unixio,path=${XDG_RUNTIME_DIR:-/tmp}/swtpm.sock,terminate" \
            --pid "file=${XDG_RUNTIME_DIR:-/tmp}/swtpm.pid" \
            --log "file=${XDG_STATE_HOME:-$HOME/.local/state}/swtpm.log,level=20" \
            --daemon

    local i
    for ((i=0; i<50; i++)); do
        [ -S "${XDG_RUNTIME_DIR:-/tmp}/swtpm.sock" ] && { SWTPM_RUNNING=true; SWTPM_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/swtpm.sock"; break; }
        sleep 0.05
    done
    $SWTPM_RUNNING || pz_warn "swtpm socket did not appear after start"
}

virtio_check() {
    local redirect
    redirect="$(curl -sI 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso' 2>/dev/null | grep -i '^location:' | tail -1 | tr -d '\r')" || true
    if [ -n "$redirect" ]; then
        local url="${redirect#*: }"
        VIRTIO_LATEST_URL="$url"
        local version
        version="$(echo "$url" | sed -n 's|.*virtio-win-\([0-9.]*\)-1/virtio-win.*|\1|p')" || true
        [ -z "$version" ] && version="$(echo "$url" | sed -n 's|.*virtio-win-\([0-9.]*\)/virtio-win.*|\1|p')" || true
        if [ -n "$version" ]; then
            VIRTIO_LATEST="$version"
            [ "$VIRTIO_LATEST" != "$VIRTIO_PINNED" ] && VIRTIO_OUTDATED=true
        fi
    fi
}

virtio_auto_fix() {
    $VIRTIO_OUTDATED || return 0
    [ -z "$VIRTIO_LATEST_URL" ] && { pz_warn "cannot resolve latest virtio-win URL"; return 1; }

    local vm_dir="${PZ_STATE}/windows-vm/vm"
    mkdir -p "$vm_dir"

    pz_info "downloading virtio-win $VIRTIO_LATEST → $vm_dir/virtio-win.iso"
    local ok=0
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$vm_dir/virtio-win.iso" "$VIRTIO_LATEST_URL" && ok=1 || true
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$vm_dir/virtio-win.iso" "$VIRTIO_LATEST_URL" && ok=1 || true
    fi

    if [ "$ok" = "1" ]; then
        local actual
        actual="$(sha256sum "$vm_dir/virtio-win.iso" | cut -d' ' -f1)"
        pz_info "virtio-win.iso SHA-256: $actual"
        echo "  url: $VIRTIO_LATEST_URL"
        echo "  sha: $actual"
        echo "  pinned_version: $VIRTIO_LATEST"
    else
        pz_warn "virtio-win download failed"
        rm -f "$vm_dir/virtio-win.iso"
    fi
}

graphics_check() {
    GRAPHICS_FAILURES=()
    local qemu_bin="${PZ_GFX_QEMU_BIN:-qemu-system-x86_64}"

    [ -e /dev/kvm ] || GRAPHICS_FAILURES+=("KVM not accessible")

    local render_node=""
    for node in /dev/dri/renderD*; do
        [ -r "$node" ] && [ -w "$node" ] && { render_node="$node"; break; }
    done
    [ -n "$render_node" ] || GRAPHICS_FAILURES+=("no accessible render node")

    [ -e /dev/kvm ] && KVM_ACCESS=true

    if [ -f /usr/share/edk2-ovmf/OVMF_CODE.fd ] || [ -f /usr/share/OVMF/OVMF_CODE.fd ] || [ -f /usr/share/edk2/x64/OVMF_CODE.4m.fd ]; then
        OVMF_PRESENT=true
    fi

    local has_virtio_vga_gl=false
    if command -v "$qemu_bin" >/dev/null 2>&1; then
        "$qemu_bin" -device help 2>/dev/null | grep -q 'virtio-vga-gl' && has_virtio_vga_gl=true
    fi
    $has_virtio_vga_gl || GRAPHICS_FAILURES+=("QEMU lacks virtio-vga-gl device")

    local virgl_ok=false
    ldconfig -p 2>/dev/null | grep -q 'virglrenderer' && virgl_ok=true
    $virgl_ok || GRAPHICS_FAILURES+=("virglrenderer library not found")

    if [ -e /dev/kvm ] && [ -n "$render_node" ] && $has_virtio_vga_gl && $virgl_ok; then
        GRAPHICS_SUPPORTED=true
    fi
}

resource_check() {
    RAM_MB="$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    CPUS="$(nproc 2>/dev/null || echo 0)"
    local root_avail
    root_avail="$(df -BG / | awk 'NR==2 {print $4}' 2>/dev/null | tr -d 'G' || echo 0)"
    DISK_GB="$root_avail"
}

emit_json() {
    local status="pass"
    [ -z "$SWTPM_BIN" ] && status="fail"
    if ! $SWTPM_RUNNING; then
        [ "$status" = "pass" ] && status="warn"
    fi
    if $VIRTIO_OUTDATED; then
        [ "$status" = "pass" ] && status="warn"
    fi

    jq -n \
        --arg status "$status" \
        --arg swtpmBin "${SWTPM_BIN:-}" \
        --argjson swtpmRunning "$SWTPM_RUNNING" \
        --arg swtpmSocket "${SWTPM_SOCKET:-}" \
        --arg swtpmPid "${SWTPM_PID:-}" \
        --argjson swtpmServiceInstalled "$SWTPM_SERVICE_INSTALLED" \
        --arg virtioPinned "$VIRTIO_PINNED" \
        --arg virtioLatest "${VIRTIO_LATEST:-$VIRTIO_PINNED}" \
        --argjson virtioOutdated "$VIRTIO_OUTDATED" \
        --arg virtioLatestUrl "${VIRTIO_LATEST_URL:-}" \
        --arg graphicsProfile "${GRAPHICS_PROFILE:-virtio-venus}" \
        --argjson graphicsSupported "$GRAPHICS_SUPPORTED" \
        --arg graphicsFallback "$GRAPHICS_FALLBACK" \
        --argjson kvmAccess "$KVM_ACCESS" \
        --argjson ovmfPresent "$OVMF_PRESENT" \
        --argjson ramMb "$RAM_MB" \
        --argjson cpus "$CPUS" \
        --argjson diskGb "$DISK_GB" \
        --argjson graphicsFailures "$(printf '%s\n' "${GRAPHICS_FAILURES[@]}" | jq -R . | jq -s -c . 2>/dev/null || echo '[]')" \
        '{
            status: $status,
            swtpm: {
                binary: ($swtpmBin != ""),
                running: $swtpmRunning,
                socket: $swtpmSocket,
                pid: $swtpmPid,
                serviceInstalled: $swtpmServiceInstalled
            },
            virtio: {
                pinned: $virtioPinned,
                latest: $virtioLatest,
                outdated: $virtioOutdated,
                latestUrl: $virtioLatestUrl
            },
            graphics: {
                profile: $graphicsProfile,
                supported: $graphicsSupported,
                fallback: $graphicsFallback,
                failures: $graphicsFailures
            },
            resources: {
                ramMb: $ramMb,
                cpus: $cpus,
                diskGb: $diskGb,
                kvmAccess: $kvmAccess,
                ovmfPresent: $ovmfPresent
            }
        }'
}

main() {
    local AUTO_FIX=false JSON_OUT=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto-fix) AUTO_FIX=true; shift ;;
            --json) JSON_OUT=true; shift ;;
            *) pz_error "unknown preflight option: $1"; return 1 ;;
        esac
    done

    resource_check
    swtpm_check
    virtio_check
    graphics_check

    if $AUTO_FIX; then
        if ! $SWTPM_RUNNING; then
            swtpm_auto_fix
        fi
        if $VIRTIO_OUTDATED; then
            virtio_auto_fix
        fi
    fi

    if $JSON_OUT; then
        emit_json
    fi
}

main "$@"
