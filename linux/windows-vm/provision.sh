#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

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

PROVISION_DIR="${PZ_STATE}/windows-vm/provision"

PROVISION_DIR="${PZ_STATE}/windows-vm/provision"
OPERATIONS_DIR="${PZ_STATE}/operations"

PLAN_ENDPOINT="${PZ_WINDOWS_VM_PLAN:-$PROVISION_DIR/plans}"
ACTIVE_LOCK="$PROVISION_DIR/active.lock"

PROVISION_CHECKPOINTS=("validate" "assets" "answer-media" "disk" "setup" "drivers" "tweaks" "verify" "snapshot" "relaunch")

provision_plan() {
    local iso="" ram="" cpus="" disk_size="256G" lang="pt-BR" keyboard="pt-BR" timezone="America/Sao_Paulo"
    local user="phasezero" product_key="" tpm_bypass=0 graphics="compat" appx_deny="default"
    local image_index=1
    local JSON_OUT=0 DRY_RUN=0 AUTO_FIX=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --iso) iso="${2:-}"; shift 2 ;; --iso=*) iso="${1#*=}"; shift ;;
            --ram) ram="${2:-}"; shift 2 ;; --ram=*) ram="${1#*=}"; shift ;;
            --cpus) cpus="${2:-}"; shift 2 ;; --cpus=*) cpus="${1#*=}"; shift ;;
            --disk-size) disk_size="${2:-}"; shift 2 ;; --disk-size=*) disk_size="${1#*=}"; shift ;;
            --image-index) image_index="${2:-1}"; shift 2 ;;
            --image-index=*) image_index="${1#*=}"; shift ;;
            --lang) lang="${2:-}"; shift 2 ;; --lang=*) lang="${1#*=}"; shift ;;
            --keyboard) keyboard="${2:-}"; shift 2 ;; --keyboard=*) keyboard="${1#*=}"; shift ;;
            --timezone) timezone="${2:-}"; shift 2 ;; --timezone=*) timezone="${1#*=}"; shift ;;
            --user) user="${2:-}"; shift 2 ;; --user=*) user="${1#*=}"; shift ;;
            --product-key) product_key="${2:-}"; shift 2 ;; --product-key=*) product_key="${1#*=}"; shift ;;
            --tpm-bypass) tpm_bypass=1; shift ;;
            --graphics) graphics="${2:-}"; shift 2 ;; --graphics=*) graphics="${1#*=}"; shift ;;
            --json) JSON_OUT=1; shift ;;
            --auto-fix) AUTO_FIX=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            *) pz_error "unknown plan option: $1"; return 1 ;;
        esac
    done

    [ -n "$iso" ] || { pz_error "--iso required"; return 1; }

    if [ "$AUTO_FIX" = "1" ]; then
        pz_info "running preflight with auto-fix..."
        bash "$PZ_ROOT/linux/windows-vm/preflight.sh" --auto-fix 2>&1 || pz_warn "preflight auto-fix encountered errors"
    fi

    local iso_ok=1 iso_sha="" iso_arch="x64" iso_uefi=1 iso_errors="[]"
    if [ ! -f "$iso" ]; then iso_ok=0; iso_errors="[\"ISO not found\"]"; fi
    if [ "$iso_ok" = "1" ]; then
        iso_sha="$(sha256sum "$iso" | cut -d' ' -f1)"
    fi

    local json_ram json_cpus
    json_ram="${ram:-$(default_ram_mb)}"
    json_cpus="${cpus:-$(default_cpus)}"

    local plan_id confirm_token timestamp
    plan_id="plan-$(date +%Y%m%d-%H%M%S)-${RANDOM}"
    confirm_token="$(openssl rand -hex 32 2>/dev/null || echo "confirm-${RANDOM}-${RANDOM}")"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local virtio_source="auto"
    local virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.262-1/virtio-win-0.1.262.iso"
    local virtio_sha_expected="9cfd0520453b262bb38c2d14bb5f24ccae4bd4e14ef85fc18ef9f1af3c4681a9"

    local preflight_json preflight_status preflight_stderr
    preflight_stderr="$(mktemp)" || true
    preflight_json="$(bash "$PZ_ROOT/linux/windows-vm/preflight.sh" --json 2>"${preflight_stderr:-/dev/null}" || {
        pz_warn "preflight check failed — see diagnostics above"
        echo '{"status":"fail"}'
    })"
    if [ -s "${preflight_stderr:-/dev/null}" ]; then
        pz_warn "preflight diagnostics:"
        sed 's/^/  /' "$preflight_stderr" >&2
    fi
    rm -f "${preflight_stderr:-}"
    preflight_status="$(echo "$preflight_json" | jq -r '.status // "fail"')"

    local blockers="[]"
    if [ "$iso_ok" != "1" ]; then
        blockers="[\"ISO file not found or unreadable\"]"
    fi
    if [ "$preflight_status" = "fail" ]; then
        local swtpm_missing
        swtpm_missing=$(echo "$preflight_json" | jq -r '.swtpm.binary == false' 2>/dev/null)
        if [ "$swtpm_missing" = "true" ]; then
            local fail_msg="swtpm binary not found — TPM 2.0 required for Windows 11"
            blockers="$(echo "$blockers" | jq --arg m "$fail_msg" '. + [$m]')"
        fi
    fi

    local warnings="[]"
    if [ "$preflight_status" = "warn" ]; then
        local swtpm_not_running virtio_outdated
        swtpm_not_running=$(echo "$preflight_json" | jq -r '.swtpm.running == false' 2>/dev/null)
        virtio_outdated=$(echo "$preflight_json" | jq -r '.virtio.outdated' 2>/dev/null)
        [ "$swtpm_not_running" = "true" ] && warnings="$(echo "$warnings" | jq '. + ["swtpm daemon not running — VM may fail to boot with TPM error"]')"
        [ "$virtio_outdated" = "true" ] && warnings="$(echo "$warnings" | jq '. + ["virtio-win outdated — latest may improve driver compatibility"]')"
    fi

    local destructive_ops="[]"
    if [ "$appx_deny" = "default" ]; then
        destructive_ops="[\"remove consumer AppX packages\"]"
    fi

    mkdir -p "$PLAN_ENDPOINT"
    local plan_file="$PLAN_ENDPOINT/$plan_id.json"
    jq -n \
        --arg id "$plan_id" \
        --arg confirmToken "$confirm_token" \
        --arg iso "$iso" \
        --arg isoSha256 "$iso_sha" \
        --arg isoArch "$iso_arch" \
        --argjson isoUefi "$iso_uefi" \
        --argjson isoValid "$iso_ok" \
        --argjson blockers "$blockers" \
        --argjson preflight "$preflight_json" \
        --argjson warnings "$warnings" \
        --arg ram "$json_ram" \
        --arg cpus "$json_cpus" \
        --arg diskSize "$disk_size" \
        --argjson imageIndex "$image_index" \
        --arg lang "$lang" \
        --arg keyboard "$keyboard" \
        --arg timezone "$timezone" \
        --arg user "$user" \
        --arg graphics "$graphics" \
        --arg virtioSource "$virtio_source" \
        --arg virtioUrl "$virtio_url" \
        --arg virtioSha256 "$virtio_sha_expected" \
        --argjson tpmBypass "$tpm_bypass" \
        --argjson destructiveOps "$destructive_ops" \
        --arg createdAt "$timestamp" \
        '{
            id: $id,
            confirmToken: $confirmToken,
            iso: {path: $iso, sha256: $isoSha256, arch: $isoArch, uefi: $isoUefi, valid: $isoValid},
            resources: {
                ramMb: ($ram|tonumber),
                cpus: ($cpus|tonumber),
                diskSize: $diskSize
            },
            imageIndex: $imageIndex,
            locale: {lang: $lang, keyboard: $keyboard, timezone: $timezone},
            user: $user,
            graphics: $graphics,
            virtio: {source: $virtioSource, url: $virtioUrl, sha256: $virtioSha256},
            tpmBypass: $tpmBypass,
            profile: "performance-safe",
            destructiveOps: $destructiveOps,
            preflight: $preflight,
            warnings: $warnings,
            blockers: $blockers,
            createdAt: $createdAt
        }' > "$plan_file"
    chmod 0600 "$plan_file"

    if [ "${JSON_OUT:-0}" = "1" ]; then
        cat "$plan_file"
    else
        pz_info "plan created: $plan_id"
        pz_info "confirm token: ${confirm_token:0:16}... (use --confirm <full-token> to execute)"
        if [ "$(echo "$blockers" | jq '. | length')" -gt 0 ]; then
            pz_warn "plan has blockers:"
            echo "$blockers" | jq -r '.[]' | while IFS= read -r b; do echo "  - $b"; done
        fi
        if [ "$(echo "$warnings" | jq '. | length')" -gt 0 ]; then
            pz_warn "preflight warnings:"
            echo "$warnings" | jq -r '.[]' | while IFS= read -r w; do echo "  - $w"; done
            pz_info "run with --auto-fix to start swtpm and download latest virtio-win"
        fi
    fi
}

provision_start() {
    local plan_id="" confirm_token="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --plan-id) plan_id="${2:-}"; shift 2 ;;
            --plan-id=*) plan_id="${1#*=}"; shift ;;
            --confirm) confirm_token="${2:-}"; shift 2 ;;
            --confirm=*) confirm_token="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown start option: $1"; return 1 ;;
        esac
    done

    [ -n "$plan_id" ] || { pz_error "--plan-id required"; return 1; }
    [ -n "$confirm_token" ] || { pz_error "--confirm required"; return 1; }

    local plan_file="$PLAN_ENDPOINT/$plan_id.json"
    [ -f "$plan_file" ] || { pz_error "plan not found: $plan_id"; return 1; }

    local expected_token
    expected_token="$(jq -r '.confirmToken' "$plan_file")"
    [ "$confirm_token" = "$expected_token" ] || { pz_error "confirm token mismatch"; return 1; }

    local blockers
    blockers="$(jq -r '.blockers | length' "$plan_file")"
    [ "$blockers" = "0" ] || { pz_error "plan has unresolved blockers"; return 1; }

    mkdir -p "$OPERATIONS_DIR"
    if [ -f "$ACTIVE_LOCK" ]; then
        local active_op
        active_op="$(cat "$ACTIVE_LOCK")"
        if [ -f "$OPERATIONS_DIR/$active_op/operation.json" ]; then
            local op_state
            op_state="$(jq -r '.state' "$OPERATIONS_DIR/$active_op/operation.json")"
            if [ "$op_state" != "cancelled" ] && [ "$op_state" != "failed" ]; then
                pz_error "active operation exists: $active_op (state: $op_state)"
                return 1
            fi
        fi
    fi

    local operation_id="op-$(date +%Y%m%d-%H%M%S)-${RANDOM}"
    local op_dir="$OPERATIONS_DIR/$operation_id"
    mkdir -p "$op_dir"
    chmod 0700 "$op_dir"

    echo "$operation_id" > "$ACTIVE_LOCK"
    cp "$plan_file" "$op_dir/plan.json"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg id "$operation_id" \
        --arg planId "$plan_id" \
        --arg state "running" \
        --arg checkpoint "validate" \
        --arg createdAt "$timestamp" \
        '{
            id: $id, planId: $planId, state: $state,
            checkpoint: $checkpoint, progress: 0,
            createdAt: $createdAt, updatedAt: $createdAt,
            checkpoints: {},
            log: []
        }' > "$op_dir/operation.json"
    chmod 0600 "$op_dir/operation.json"

    pz_info "provision started: $operation_id"
    echo "$operation_id"

    nohup bash "$PZ_ROOT/linux/windows-vm/provision.sh" run --operation-id "$operation_id" \
        > "$op_dir/worker.log" 2>&1 &
    disown

    if [ "$json" = "1" ]; then
        jq -n --arg id "$operation_id" --arg state "running" '{operationId: $id, state: $state}'
    fi
}

provision_run() {
    local operation_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    local plan_file="$op_dir/plan.json"
    [ -f "$plan_file" ] || { pz_error "plan not found for operation $operation_id"; return 1; }

    for cp in "${PROVISION_CHECKPOINTS[@]}"; do
        local current_state
        current_state="$(jq -r '.state // "running"' "$op_dir/operation.json")"
        [ "$current_state" = "running" ] || { pz_info "operation state changed to $current_state; stopping"; return 0; }

        update_checkpoint "$operation_id" "$cp" "running"

        case "$cp" in
            validate)    run_validate "$operation_id" || { fail_operation "$operation_id" "validate"; return 1; } ;;
            assets)      run_assets "$operation_id" || { fail_operation "$operation_id" "assets"; return 1; } ;;
            answer-media) run_answer_media "$operation_id" || { fail_operation "$operation_id" "answer-media"; return 1; } ;;
            disk)        run_disk "$operation_id" || { fail_operation "$operation_id" "disk"; return 1; } ;;
            setup)       run_setup "$operation_id" || { fail_operation "$operation_id" "setup"; return 1; } ;;
            drivers)     run_drivers "$operation_id" || { fail_operation "$operation_id" "drivers"; return 1; } ;;
            tweaks)      run_tweaks "$operation_id" || { fail_operation "$operation_id" "tweaks"; return 1; } ;;
            verify)      run_verify "$operation_id" || { fail_operation "$operation_id" "verify"; return 1; } ;;
            snapshot)    run_snapshot "$operation_id" || { fail_operation "$operation_id" "snapshot"; return 1; } ;;
            relaunch)    run_relaunch "$operation_id" || { fail_operation "$operation_id" "relaunch"; return 1; } ;;
        esac

        update_checkpoint "$operation_id" "$cp" "done"
        local progress
        progress="$(checkpoint_progress "$cp")"
        jq --arg p "$progress" '.progress = ($p|tonumber) | .updatedAt = now' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    done

    jq '.state = "completed" | .updatedAt = now' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    rm -f "$ACTIVE_LOCK"
    pz_info "provision completed: $operation_id"
}

checkpoint_progress() {
    local current="$1" idx=0 total=${#PROVISION_CHECKPOINTS[@]}
    for ((i=0; i<total; i++)); do
        [ "${PROVISION_CHECKPOINTS[$i]}" = "$current" ] && idx=$((i + 1))
    done
    echo $((idx * 100 / total))
}

update_checkpoint() {
    local op="$1" cp="$2" status="$3"
    local op_dir="$OPERATIONS_DIR/$op"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg cp "$cp" --arg status "$status" --arg ts "$ts" \
        '.checkpoints[$cp] = $status | .updatedAt = $ts' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
}

fail_operation() {
    local op="$1" cp="$2"
    local op_dir="$OPERATIONS_DIR/$op"
    update_checkpoint "$op" "$cp" "failed"
    jq '.state = "failed" | .updatedAt = now' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
}

HAVE_SOCAT=0
command -v socat >/dev/null 2>&1 && HAVE_SOCAT=1

qga_ping() {
    local sock="$1"
    [ "$HAVE_SOCAT" != "1" ] && return 1
    echo '{"execute":"guest-ping"}' | socat - UNIX-CONNECT:"$sock" 2>/dev/null | jq -e '.return' >/dev/null 2>&1
}

qga_exec() {
    local sock="$1" cmd="$2"
    [ "$HAVE_SOCAT" != "1" ] && { echo '{"return":{"pid":0}}'; return 1; }
    echo "$cmd" | socat - UNIX-CONNECT:"$sock" 2>/dev/null || echo '{"return":{"pid":0}}'
}

qga_shutdown() {
    local sock="$1"
    [ "$HAVE_SOCAT" != "1" ] && return 1
    echo '{"execute":"guest-shutdown"}' | socat - UNIX-CONNECT:"$sock" 2>/dev/null || true
}

graphics_preflight() {
    local op="$1" graphics="$2"
    local kvm_path="${PZ_GFX_KVM_PATH:-/dev/kvm}"
    local qemu_bin="${PZ_GFX_QEMU_BIN:-qemu-system-x86_64}"
    case "$graphics" in
        compat) return 0 ;;
        virtio-gl)
            local failures=()
            [ -e "$kvm_path" ] || failures+=("$kvm_path not accessible")
            local render_node="${PZ_GFX_RENDER_NODE:-}"
            if [ -z "$render_node" ]; then
                for node in /dev/dri/renderD*; do [ -r "$node" ] && [ -w "$node" ] && { render_node="$node"; break; }; done
            fi
            [ -n "$render_node" ] || failures+=("no accessible render node (need mesa/virgl)")
            local has_virtio_vga_gl=0
            if command -v "$qemu_bin" >/dev/null 2>&1; then
                "$qemu_bin" -device help 2>/dev/null | grep -q 'virtio-vga-gl' && has_virtio_vga_gl=1
            fi
            local qemu_has_virtio_vga_gl="${PZ_GFX_QEMU_VIRTIO_VGA_GL:-}"
            if [ -n "$qemu_has_virtio_vga_gl" ]; then
                [ "$qemu_has_virtio_vga_gl" = "1" ] && has_virtio_vga_gl=1 || has_virtio_vga_gl=0
            fi
            [ "$has_virtio_vga_gl" = "1" ] || failures+=("QEMU lacks virtio-vga-gl device")
            local has_virgl=0
            if [ -n "${PZ_GFX_VIRGL_PRESENT:-}" ]; then
                [ "$PZ_GFX_VIRGL_PRESENT" = "1" ] && has_virgl=1
            else
                ldconfig -p 2>/dev/null | grep -q 'virglrenderer' && has_virgl=1
            fi
            [ "$has_virgl" = "1" ] || failures+=("virglrenderer library not found")
            if [ -z "${PZ_GFX_AMDGPU_BOUND:-}" ]; then
                local has_amdgpu=0
                for card in /sys/class/drm/card*/device/driver; do
                    [ -L "$card" ] && [ "$(readlink "$card")" = "amdgpu" ] && has_amdgpu=1
                done
                [ "$has_amdgpu" = "0" ] && log_operation "$op" "WARN: no AMDGPU driver bound (VM may lack device memory for virgl)"
            fi
            if [ "${#failures[@]}" -gt 0 ]; then
                for f in "${failures[@]}"; do log_operation "$op" "virtio-gl preflight FAIL: $f"; done
                log_operation "$op" "fallback: --graphics compat (non-accelerated QXL)"
                return 1
            fi
            log_operation "$op" "virtio-gl preflight: KVM OK, render node OK, QEMU OK, virgl OK"
            return 0
            ;;
        *)
            log_operation "$op" "FAIL: unknown graphics profile: $graphics (valid: compat, virtio-gl)"
            return 1
            ;;
    esac
}

resolve_graphics_qemu_args() {
    local op="$1" graphics="$2"
    GRAPHICS_VGA="" GRAPHICS_DISPLAY="" GRAPHICS_ACCEL_LOG=""
    case "$graphics" in
        compat)
            GRAPHICS_VGA="-vga qxl"
            GRAPHICS_DISPLAY="-display gtk"
            GRAPHICS_ACCEL_LOG="GPU acceleration: NONE (QXL)"
            ;;
        virtio-gl)
            GRAPHICS_VGA="-device virtio-vga-gl"
            GRAPHICS_DISPLAY="-display gtk,gl=on"
            GRAPHICS_ACCEL_LOG="GPU acceleration: virgl (OpenGL only; no Vulkan/D3D)"
            ;;
        *)
            log_operation "$op" "FAIL: unknown graphics profile: $graphics"
            return 1
            ;;
    esac
    local op_dir="$OPERATIONS_DIR/$op"
    jq --arg resolved "$graphics" --arg vga "$GRAPHICS_VGA" --arg display "$GRAPHICS_DISPLAY" --arg accelLog "$GRAPHICS_ACCEL_LOG" \
        '.graphicsResolved = {profile: $resolved, vgaDevice: $vga, displayArg: $display, accelLog: $accelLog}' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    return 0
}

log_operation() {
    local op="$1" msg="$2"
    local op_dir="$OPERATIONS_DIR/$op"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg msg "$msg" --arg ts "$ts" \
        '.log += [$ts + " " + $msg]' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    pz_info "[$op] $msg"
}

run_validate() {
    local op="$1"
    log_operation "$op" "validating ISO and host requirements"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local iso
    iso="$(jq -r '.iso.path' "$plan_file")"
    [ -f "$iso" ] || { log_operation "$op" "FAIL: ISO not found"; return 1; }
    [ -e /dev/kvm ] || { log_operation "$op" "FAIL: KVM not available"; return 1; }
    command -v qemu-system-x86_64 >/dev/null 2>&1 || { log_operation "$op" "FAIL: qemu-system-x86_64 missing"; return 1; }
    command -v qemu-img >/dev/null 2>&1 || { log_operation "$op" "FAIL: qemu-img missing"; return 1; }
    local ovmf
    ovmf="$(jq -r '.iso.arch' "$plan_file")"
    [ "$ovmf" = "x64" ] || { log_operation "$op" "FAIL: unsupported architecture"; return 1; }

    local graphics
    graphics="$(jq -r '.graphics // "compat"' "$plan_file")"
    graphics_preflight "$op" "$graphics" || { log_operation "$op" "FAIL: graphics preflight"; return 1; }
    resolve_graphics_qemu_args "$op" "$graphics" || { log_operation "$op" "FAIL: graphics resolution"; return 1; }

    log_operation "$op" "$GRAPHICS_ACCEL_LOG"
    log_operation "$op" "validation passed"
    return 0
}

run_assets() {
    local op="$1"
    log_operation "$op" "preparing assets"

    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir="${PZ_STATE}/windows-vm/vms/${op}"
    local disk_path="$vm_dir/disk.qcow2"
    local disk_size
    disk_size="$(jq -r '.resources.diskSize // "256G"' "$plan_file")"

    mkdir -p "$vm_dir"
    echo "$vm_dir" > "$OPERATIONS_DIR/$op/vm_dir"

    log_operation "$op" "VM directory: $vm_dir"

    local virtio_url virtio_expected
    virtio_url="$(jq -r '.virtio.url // ""' "$plan_file")"
    virtio_expected="$(jq -r '.virtio.sha256 // ""' "$plan_file")"

    if [ -n "$virtio_url" ] && [ ! -f "$vm_dir/virtio-win.iso" ]; then
        local preflight_cache="${PZ_STATE}/windows-vm/vm/virtio-win.iso"
        if [ -f "$preflight_cache" ]; then
            local cache_sha
            cache_sha="$(sha256sum "$preflight_cache" 2>/dev/null | cut -d' ' -f1 || true)"
            if [ -z "$virtio_expected" ] || [ "$cache_sha" = "$virtio_expected" ]; then
                log_operation "$op" "reusing preflight-cached virtio-win.iso"
                ln -f "$preflight_cache" "$vm_dir/virtio-win.iso"
            else
                log_operation "$op" "preflight cache SHA mismatch (expected=$virtio_expected cached=$cache_sha) — downloading fresh"
            fi
        fi
        if [ ! -f "$vm_dir/virtio-win.iso" ]; then
            log_operation "$op" "downloading VirtIO drivers from $virtio_url"
            local download_ok=0
            if command -v curl >/dev/null 2>&1; then
                curl -L -o "$vm_dir/virtio-win.iso" "$virtio_url" && download_ok=1 || true
            elif command -v wget >/dev/null 2>&1; then
                wget -O "$vm_dir/virtio-win.iso" "$virtio_url" && download_ok=1 || true
            fi
            if [ "$download_ok" = "1" ] && [ -n "$virtio_expected" ]; then
                local actual
                actual="$(sha256sum "$vm_dir/virtio-win.iso" | cut -d' ' -f1)"
                if [ "$actual" != "$virtio_expected" ]; then
                    log_operation "$op" "FAIL: VirtIO SHA-256 mismatch (expected=$virtio_expected actual=$actual)"
                    return 1
                fi
            elif [ "$download_ok" != "1" ]; then
                log_operation "$op" "FAIL: VirtIO download failed"
                return 1
            fi
        fi
    fi

    log_operation "$op" "assets ready"
    return 0
}

run_answer_media() {
    local op="$1"
    log_operation "$op" "generating answer file"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_serial="PZ-${op:0:12}"

    local answer_dir="$vm_dir/oemdrv"
    mkdir -p "$answer_dir"

    local image_index lang keyboard tz user password_xml product_key tpm_bypass
    image_index="$(jq -r '.imageIndex // 1' "$plan_file")"
    lang="$(jq -r '.locale.lang // "pt-BR"' "$plan_file")"
    keyboard="$(jq -r '.locale.keyboard // "pt-BR"' "$plan_file")"
    tz="$(jq -r '.locale.timezone // "America/Sao_Paulo"' "$plan_file")"
    user="$(jq -r '.user // "phasezero"' "$plan_file")"
    password_xml="$(openssl rand -base64 24 2>/dev/null || echo "PhaseZero.Install.$(date +%s)")"
    product_key="$(jq -r '.productKey // ""' "$plan_file")"
    tpm_bypass="$(jq -r '.tpmBypass // false' "$plan_file")"

    echo "$password_xml" > "$OPERATIONS_DIR/$op/bootstrap_secret"
    chmod 0600 "$OPERATIONS_DIR/$op/bootstrap_secret"

    bash "$PZ_ROOT/linux/windows-vm/autounattend.sh" generate \
        --wim-index "$image_index" \
        --lang "$lang" \
        --keyboard "$keyboard" \
        --timezone "$tz" \
        --user "$user" \
        --password "$password_xml" \
        --disk-serial "$disk_serial" \
        $( [ -n "$product_key" ] && echo "--product-key $product_key" ) \
        $( [ "$tpm_bypass" = "true" ] && echo "--tpm-bypass" ) \
        --output-dir "$answer_dir" >/dev/null

    local iso_file="$answer_dir/autounattend.xml"
    [ -f "$iso_file" ] || { log_operation "$op" "FAIL: autounattend.xml not generated"; return 1; }

    local inject_script="$answer_dir/setup.ps1"
    cat > "$inject_script" << 'PSEOF'
# PhaseZero post-install setup script
Start-Transcript -Path "$env:SystemRoot\Temp\phasezero-setup.log"
$ErrorActionPreference = "Stop"

Write-Host "PhaseZero: post-install setup starting"

# Remove bootstrap password
$user = [ADSI]"WinNT://./phasezero,user"
$user.SetPassword("")
$user.SetInfo()
Write-Host "PhaseZero: bootstrap password cleared"

Write-Host "PhaseZero: post-install setup complete"
Stop-Transcript
PSEOF
    chmod 0600 "$inject_script"

    local oemdrv_iso="$vm_dir/oemdrv.iso"
    if command -v genisoimage >/dev/null 2>&1; then
        genisoimage -J -R -V OEMDRV -o "$oemdrv_iso" "$answer_dir" 2>/dev/null || \
            { log_operation "$op" "FAIL: genisoimage failed to create OEMDRV ISO"; return 1; }
    elif command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -J -R -V OEMDRV -o "$oemdrv_iso" "$answer_dir" 2>/dev/null || \
            { log_operation "$op" "FAIL: xorriso failed to create OEMDRV ISO"; return 1; }
    else
        log_operation "$op" "FAIL: no ISO creation tool (genisoimage or xorriso)"
        return 1
    fi
    [ -f "$oemdrv_iso" ] || { log_operation "$op" "FAIL: OEMDRV ISO not created"; return 1; }

    log_operation "$op" "answer file generated, OEMDRV ISO created"
    return 0
}

run_disk() {
    local op="$1"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    if [ -f "$disk_path" ]; then
        log_operation "$op" "disk already exists; skipping creation"
        return 0
    fi
    local disk_size
    disk_size="$(jq -r '.resources.diskSize // "256G"' "$plan_file")"
    log_operation "$op" "creating disk: $disk_path ($disk_size)"
    qemu-img create -f qcow2 "$disk_path" "$disk_size"
    log_operation "$op" "disk created"
    return 0
}

run_setup() {
    local op="$1"
    log_operation "$op" "starting Windows setup"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    local oemdrv_iso="$vm_dir/oemdrv.iso"
    local iso
    iso="$(jq -r '.iso.path' "$plan_file")"
    local ram cpus
    ram="$(jq -r '.resources.ramMb // 8192' "$plan_file")"
    cpus="$(jq -r '.resources.cpus // 4' "$plan_file")"

    local ovmf_code ovmf_vars
    ovmf_code="${PZ_WINDOWS_VM_OVMF_CODE:-$(find /usr -name 'OVMF_CODE.fd' 2>/dev/null | head -1)}"
    ovmf_vars="$vm_dir/OVMF_VARS.fd"
    if [ ! -f "$ovmf_vars" ]; then
        local vars_template="${ovmf_code%CODE.fd}VARS.fd"
        [ -f "$vars_template" ] && cp "$vars_template" "$ovmf_vars"
    fi

    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }
    [ -f "$oemdrv_iso" ] || { log_operation "$op" "OEMDRV ISO not found"; return 1; }

    local qemu_args=(
        -machine q35,accel=kvm
        -cpu host
        -smp "$cpus"
        -m "$ram"
        -drive file="$ovmf_code",if=pflash,format=raw,readonly=on
        -drive file="$ovmf_vars",if=pflash,format=raw
        -drive file="$disk_path",format=qcow2,if=none,id=drive0
        -device nvme,serial=pzvm,drive=drive0,bootindex=1
        -drive file="$iso",format=raw,if=none,id=isoboot,readonly=on
        -device ide-hd,drive=isoboot,bootindex=2
        -drive file="$oemdrv_iso",format=raw,if=none,id=oemdrv,readonly=on
        -device ide-cd,drive=oemdrv
        -netdev user,id=net0
        -device e1000e,netdev=net0
        -vga qxl
        -display none
        -nographic
        -serial file:"$vm_dir/setup-serial.log"
        -chardev socket,path="$vm_dir/qga.sock",server=on,id=qga0
        -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
    )

    if [ -f "$vm_dir/virtio-win.iso" ]; then
        qemu_args+=(-drive file="$vm_dir/virtio-win.iso",format=raw,if=none,id=virtio)
        qemu_args+=(-device ide-cd,drive=virtio)
    fi

    log_operation "$op" "launching QEMU for Windows setup"
    mkdir -p "$vm_dir"
    qemu-system-x86_64 "${qemu_args[@]}" &
    local qemu_pid=$!
    echo "$qemu_pid" > "$vm_dir/qemu-pid"

    local timeout=7200 interval=30 elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        kill -0 "$qemu_pid" 2>/dev/null || { log_operation "$op" "QEMU exited after ${elapsed}s"; break; }
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [ $((elapsed % 300)) -eq 0 ]; then
            log_operation "$op" "setup running for ${elapsed}s ($((elapsed / 60))min)"
        fi
    done

    if kill -0 "$qemu_pid" 2>/dev/null; then
        log_operation "$op" "setup timeout reached (${timeout}s); killing QEMU"
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi

    rm -f "$vm_dir/qemu-pid"
    log_operation "$op" "Windows setup phase complete"
    return 0
}

run_drivers() {
    local op="$1"
    log_operation "$op" "installing VirtIO drivers via QEMU Guest Agent"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    local qga_sock="$vm_dir/qga.sock"

    if [ ! -f "$vm_dir/virtio-win.iso" ]; then
        log_operation "$op" "no VirtIO ISO; skipping driver injection"
        return 0
    fi

    local ram cpus
    ram="$(jq -r '.resources.ramMb // 8192' "$plan_file")"
    cpus="$(jq -r '.resources.cpus // 4' "$plan_file")"
    local ovmf_code="${PZ_WINDOWS_VM_OVMF_CODE:-$(find /usr -name 'OVMF_CODE.fd' 2>/dev/null | head -1)}"
    local ovmf_vars="$vm_dir/OVMF_VARS.fd"
    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }

    rm -f "$qga_sock"

    local qemu_args=(
        -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$ram"
        -drive file="$ovmf_code",if=pflash,format=raw,readonly=on
        -drive file="$ovmf_vars",if=pflash,format=raw
        -drive file="$disk_path",format=qcow2,if=none,id=drive0
        -device nvme,serial=pzvm,drive=drive0
        -drive file="$vm_dir/virtio-win.iso",format=raw,if=none,id=virtio,readonly=on
        -device ide-cd,drive=virtio
        -netdev user,id=net0 -device e1000e,netdev=net0
        -vga qxl -display none -nographic
        -serial file:"$vm_dir/drivers-serial.log"
        -chardev socket,path="$qga_sock",server=on,id=qga0
        -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
    )

    log_operation "$op" "launching QEMU for driver installation"
    qemu-system-x86_64 "${qemu_args[@]}" &
    local qemu_pid=$!
    echo "$qemu_pid" > "$vm_dir/drivers-qemu-pid"

    local qga_ok=0
    local timeout=300 interval=5 elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        kill -0 "$qemu_pid" 2>/dev/null || break
        if [ -S "$qga_sock" ] && qga_ping "$qga_sock"; then
            qga_ok=1
            log_operation "$op" "QEMU Guest Agent ready after ${elapsed}s"
            break
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if [ "$qga_ok" = "1" ]; then
        local ps_cmd='powershell -Command "
            $d = (Get-Volume -FileSystemLabel VIRTIO).DriveLetter + ':' 2>$null;
            if (-not $d) { $d = 'D:' };
            if (Test-Path \"$d\setup.exe\") {
                Write-Host Installing VirtIO drivers from $d;
                Start-Process \"$d\setup.exe\" -ArgumentList '/S /NoRestart' -NoNewWindow -Wait
            } elseif (Test-Path \"$d\virtio-win-gt-x64.msi\") {
                Write-Host Installing VirtIO MSI from $d;
                Start-Process msiexec.exe -ArgumentList \"/i \\\"$d\virtio-win-gt-x64.msi\\\" /qn /norestart\" -NoNewWindow -Wait
            } else {
                Write-Host Searching for .inf drivers in $d;
                Get-ChildItem \"$d\" -Filter *.inf -Recurse | ForEach-Object {
                    & pnputil /add-driver $_.FullName /install 2>&1 | Write-Host
                }
            };
            Write-Host VirtIO driver installation complete
        "'
        local exec_result
        exec_result="$(qga_exec "$qga_sock" '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-Command","'"$ps_cmd"'"],"capture-output":true}}')"
        local pid
        pid="$(echo "$exec_result" | jq -r '.return.pid // 0')"
        if [ "$pid" -gt 0 ]; then
            log_operation "$op" "driver install guest-exec PID: $pid"
            local wait_timeout=120 wait_elapsed=0
            while [ "$wait_elapsed" -lt "$wait_timeout" ]; do
                local status_result
                status_result="$(qga_exec "$qga_sock" '{"execute":"guest-exec-status","arguments":{"pid":'"$pid"'}}')"
                local exited
                exited="$(echo "$status_result" | jq -r '.return.exited // false')"
                if [ "$exited" = "true" ]; then
                    local exitcode
                    exitcode="$(echo "$status_result" | jq -r '.return.exitcode // -1')"
                    log_operation "$op" "driver install exit code: $exitcode"
                    break
                fi
                sleep 5
                wait_elapsed=$((wait_elapsed + 5))
            done
        fi

        # Post-driver display adapter check
        local check_result
        check_result="$(qga_exec "$qga_sock" '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-Command","(Get-PnpDevice -Class Display).Name"],"capture-output":true}}')"
        local check_pid
        check_pid="$(echo "$check_result" | jq -r '.return.pid // 0')"
        if [ "$check_pid" -gt 0 ]; then
            sleep 5
            local check_status
            check_status="$(qga_exec "$qga_sock" '{"execute":"guest-exec-status","arguments":{"pid":'"$check_pid"'}}')"
            local check_exited
            check_exited="$(echo "$check_status" | jq -r '.return.exited // false')"
            if [ "$check_exited" = "true" ]; then
                local check_stdout
                check_stdout="$(echo "$check_status" | jq -r '.["return"]["out-data"] // ""' | base64 -d 2>/dev/null || true)"
                if echo "$check_stdout" | grep -qi "Microsoft Basic Display"; then
                    log_operation "$op" "WARN: guest still on Microsoft Basic Display Adapter after driver install"
                else
                    log_operation "$op" "guest display adapter: $(echo "$check_stdout" | tr -d '\n\r')"
                fi
            fi
        fi

        qga_shutdown "$qga_sock"
        sleep 10
    else
        local reason="QGA not available after ${timeout}s"
        [ "$HAVE_SOCAT" != "1" ] && reason="socat not installed (needed for QGA communication)"
        log_operation "$op" "$reason; driver install deferred"
    fi

    wait "$qemu_pid" 2>/dev/null || true
    rm -f "$vm_dir/drivers-qemu-pid"
    log_operation "$op" "driver installation phase complete"
    return 0
}

run_tweaks() {
    local op="$1"
    log_operation "$op" "applying performance-safe tweaks via QEMU Guest Agent"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    local qga_sock="$vm_dir/qga.sock"

    local ram cpus
    ram="$(jq -r '.resources.ramMb // 8192' "$plan_file")"
    cpus="$(jq -r '.resources.cpus // 4' "$plan_file")"
    local ovmf_code="${PZ_WINDOWS_VM_OVMF_CODE:-$(find /usr -name 'OVMF_CODE.fd' 2>/dev/null | head -1)}"
    local ovmf_vars="$vm_dir/OVMF_VARS.fd"
    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }

    rm -f "$qga_sock"

    local qemu_args=(
        -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$ram"
        -drive file="$ovmf_code",if=pflash,format=raw,readonly=on
        -drive file="$ovmf_vars",if=pflash,format=raw
        -drive file="$disk_path",format=qcow2,if=none,id=drive0
        -device nvme,serial=pzvm,drive=drive0
        -netdev user,id=net0 -device e1000e,netdev=net0
        -vga qxl -display none -nographic
        -serial file:"$vm_dir/tweaks-serial.log"
        -chardev socket,path="$qga_sock",server=on,id=qga0
        -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
    )

    log_operation "$op" "launching QEMU for tweaks"
    qemu-system-x86_64 "${qemu_args[@]}" &
    local qemu_pid=$!
    echo "$qemu_pid" > "$vm_dir/tweaks-qemu-pid"

    local qga_ok=0
    local timeout=300 interval=5 elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        kill -0 "$qemu_pid" 2>/dev/null || break
        if [ -S "$qga_sock" ] && qga_ping "$qga_sock"; then
            qga_ok=1
            log_operation "$op" "QEMU Guest Agent ready after ${elapsed}s"
            break
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if [ "$qga_ok" = "1" ]; then
        local tweaks_json
        tweaks_json="$(bash "$PZ_ROOT/linux/windows-vm/tweaks.sh" apply 2>/dev/null || echo '[]')"
        echo "$tweaks_json" > "$vm_dir/tweaks-manifest.json"

        local ps_cmds=()
        ps_cmds+=('Remove-AppxPackage -Package "*xbox*" -AllUsers -ErrorAction SilentlyContinue')
        ps_cmds+=('powercfg /change standby-timeout-ac 0')
        ps_cmds+=('powercfg /change hibernate-timeout-ac 0')
        ps_cmds+=('powercfg /h off')
        ps_cmds+=('Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name EnableLUA -Value 0 -Type DWord')
        ps_cmds+=('Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue')
        local combined
        combined="$(
            IFS=';'
            echo "${ps_cmds[*]}"
        )"

        local exec_result
        exec_result="$(qga_exec "$qga_sock" '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-Command","'"$combined"'"],"capture-output":true}}')"
        local pid
        pid="$(echo "$exec_result" | jq -r '.return.pid // 0')"
        if [ "$pid" -gt 0 ]; then
            log_operation "$op" "tweaks guest-exec PID: $pid"
            local wait_timeout=120 wait_elapsed=0
            while [ "$wait_elapsed" -lt "$wait_timeout" ]; do
                local status_result
                status_result="$(qga_exec "$qga_sock" '{"execute":"guest-exec-status","arguments":{"pid":'"$pid"'}}')"
                local exited
                exited="$(echo "$status_result" | jq -r '.return.exited // false')"
                if [ "$exited" = "true" ]; then
                    local exitcode
                    exitcode="$(echo "$status_result" | jq -r '.return.exitcode // -1')"
                    log_operation "$op" "tweaks exit code: $exitcode"
                    break
                fi
                sleep 5
                wait_elapsed=$((wait_elapsed + 5))
            done
        fi
        qga_shutdown "$qga_sock"
        sleep 10
    else
        local reason="QGA not available after ${timeout}s"
        [ "$HAVE_SOCAT" != "1" ] && reason="socat not installed (needed for QGA communication)"
        log_operation "$op" "$reason; tweaks deferred"
    fi

    wait "$qemu_pid" 2>/dev/null || true
    rm -f "$vm_dir/tweaks-qemu-pid"
    log_operation "$op" "tweaks phase complete"
    return 0
}

run_verify() {
    local op="$1"
    log_operation "$op" "verifying installation"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"

    if [ ! -f "$disk_path" ]; then
        log_operation "$op" "FAIL: disk not found at $disk_path"
        return 1
    fi

    local disk_size
    disk_size="$(stat -c%s "$disk_path" 2>/dev/null || echo 0)"
    if [ "$disk_size" -lt 104857600 ]; then
        log_operation "$op" "FAIL: disk too small (${disk_size}B), likely empty"
        return 1
    fi

    log_operation "$op" "disk verified: $(numfmt --to=iec $disk_size 2>/dev/null || echo "${disk_size}B")"
    return 0
}

run_snapshot() {
    local op="$1"
    log_operation "$op" "creating golden-clean snapshot (backing-chain)"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    local snapshot_path="$vm_dir/golden-clean.qcow2"

    [ -f "$disk_path" ] || { log_operation "$op" "FAIL: installed disk not found"; return 1; }

    rm -f "$snapshot_path"
    qemu-img create -f qcow2 -b "$disk_path" -F qcow2 "$snapshot_path"
    [ -f "$snapshot_path" ] || { log_operation "$op" "FAIL: snapshot not created"; return 1; }

    qemu-img check "$snapshot_path" >/dev/null 2>&1 || \
        { log_operation "$op" "FAIL: snapshot verification failed"; return 1; }

    echo "$snapshot_path" > "$OPERATIONS_DIR/$op/snapshot_path"
    log_operation "$op" "golden-clean snapshot: $snapshot_path (backed by installed disk)"
    return 0
}

run_relaunch() {
    local op="$1"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local snapshot_path="$vm_dir/golden-clean.qcow2"
    local disk_path="$vm_dir/disk.qcow2"
    local boot_disk="$disk_path"
    [ -f "$snapshot_path" ] && boot_disk="$snapshot_path"

    local ram cpus
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    ram="$(jq -r '.resources.ramMb // 8192' "$plan_file")"
    cpus="$(jq -r '.resources.cpus // 4' "$plan_file")"
    local graphics
    graphics="$(jq -r '.graphics // "compat"' "$plan_file")"

    local ovmf_code ovmf_vars
    ovmf_code="${PZ_WINDOWS_VM_OVMF_CODE:-$(find /usr -name 'OVMF_CODE.fd' 2>/dev/null | head -1)}"
    ovmf_vars="$vm_dir/OVMF_VARS.fd"

    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found for relaunch"; return 1; }
    [ -f "$boot_disk" ] || { log_operation "$op" "boot disk not found for relaunch"; return 1; }

    GRAPHICS_VGA=""; GRAPHICS_DISPLAY=""; GRAPHICS_ACCEL_LOG=""
    case "$graphics" in
        compat)
            GRAPHICS_VGA="-vga qxl"
            GRAPHICS_DISPLAY="-display gtk"
            GRAPHICS_ACCEL_LOG="GPU acceleration: NONE (QXL)"
            ;;
        virtio-gl)
            GRAPHICS_VGA="-device virtio-vga-gl"
            GRAPHICS_DISPLAY="-display gtk,gl=on"
            GRAPHICS_ACCEL_LOG="GPU acceleration: virgl (OpenGL only; no Vulkan/D3D)"
            ;;
        *)
            log_operation "$op" "FAIL: unknown graphics profile: $graphics"
            return 1
            ;;
    esac

    local qemu_args=(
        -machine q35,accel=kvm
        -cpu host
        -smp "$cpus"
        -m "$ram"
        -drive file="$ovmf_code",if=pflash,format=raw,readonly=on
        -drive file="$ovmf_vars",if=pflash,format=raw
        -drive file="$boot_disk",format=qcow2,if=none,id=drive0
        -device nvme,serial=pzvm,drive=drive0
        -netdev user,id=net0
        -device virtio-net-pci,netdev=net0
        -device virtio-serial-pci
        -chardev spicevmc,id=vdagent,name=vdagent
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
        -spice port=5930,disable-ticketing=on
        -device ich9-usb-ehci1
        -device ich9-usb-uhci1
        -device usb-tablet
        -device usb-kbd
    )

    qemu_args+=($GRAPHICS_VGA)
    qemu_args+=($GRAPHICS_DISPLAY)
    qemu_args+=(-chardev socket,path="$vm_dir/qga.sock",server=on,id=qga0)
    qemu_args+=(-device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0)

    log_operation "$op" "$GRAPHICS_ACCEL_LOG"
    log_operation "$op" "relaunching with display (disk=$boot_disk, graphics=$graphics)"
    qemu-system-x86_64 "${qemu_args[@]}" &
    local qemu_pid=$!
    echo "$qemu_pid" > "$vm_dir/qemu-pid"
    echo "$qemu_pid"
}

provision_status() {
    local operation_id="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown status option: $1"; return 1 ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    [ -d "$op_dir" ] || { pz_error "operation not found: $operation_id"; return 1; }
    [ -f "$op_dir/operation.json" ] || { pz_error "operation metadata missing"; return 1; }

    if [ "$json" = "1" ]; then
        cat "$op_dir/operation.json"
    else
        local state checkpoint progress
        state="$(jq -r '.state' "$op_dir/operation.json")"
        checkpoint="$(jq -r '.checkpoint' "$op_dir/operation.json")"
        progress="$(jq -r '.progress' "$op_dir/operation.json")"
        echo "Operation: $operation_id"
        echo "State: $state"
        echo "Checkpoint: $checkpoint"
        echo "Progress: ${progress}%"
        jq -r '.log[]' "$op_dir/operation.json" 2>/dev/null || true
    fi
}

provision_watch() {
    local operation_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    [ -d "$op_dir" ] || { pz_error "operation not found: $operation_id"; return 1; }

    local last_log_lines=0
    while true; do
        [ -f "$op_dir/operation.json" ] || break
        local state
        state="$(jq -r '.state // "unknown"' "$op_dir/operation.json")"
        local checkpoint progress
        checkpoint="$(jq -r '.checkpoint // ""' "$op_dir/operation.json")"
        progress="$(jq -r '.progress // 0' "$op_dir/operation.json")"

        printf "\r[%-20s] %3d%% | %s" \
            "$(printf '%0.s#' $(seq 1 $((progress / 5))))" \
            "$progress" "$checkpoint"
        if [ "$state" != "running" ]; then
            printf " [%s]\n" "$state"
            if [ -f "$op_dir/worker.log" ]; then
                echo "--- worker log ---"
                tail -20 "$op_dir/worker.log" 2>/dev/null || true
            fi
            break
        fi
        sleep 2
    done
}

provision_resume() {
    local operation_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    [ -d "$op_dir" ] || { pz_error "operation not found: $operation_id"; return 1; }

    local state checkpoint
    state="$(jq -r '.state' "$op_dir/operation.json")"
    checkpoint="$(jq -r '.checkpoint' "$op_dir/operation.json")"

    if [ "$state" = "running" ]; then
        pz_error "operation is already running"
        return 1
    fi

    jq '.state = "running" | .updatedAt = now' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    echo "$operation_id" > "$ACTIVE_LOCK"

    nohup bash "$PZ_ROOT/linux/windows-vm/provision.sh" run --operation-id "$operation_id" \
        > "$op_dir/worker.log" 2>&1 &
    disown

    pz_info "operation resumed: $operation_id (from checkpoint: $checkpoint)"
}

provision_cancel() {
    local operation_id="" remove_staging=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --remove-staging) remove_staging=1; shift ;;
            *) pz_error "unknown cancel option: $1"; return 1 ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    [ -d "$op_dir" ] || { pz_error "operation not found: $operation_id"; return 1; }

    local state
    state="$(jq -r '.state' "$op_dir/operation.json")"

    local vm_dir vm_dir_file="$OPERATIONS_DIR/$operation_id/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"

    if [ -f "$vm_dir/qemu-pid" ]; then
        local qemu_pid
        qemu_pid="$(cat "$vm_dir/qemu-pid")"
        kill "$qemu_pid" 2>/dev/null || true
        rm -f "$vm_dir/qemu-pid"
    fi

    jq '.state = "cancelled" | .updatedAt = now' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"

    local op_state
    op_state="$(jq -r '.checkpoint' "$op_dir/operation.json")"
    if [ "$remove_staging" = "1" ] || [ "$op_state" = "validate" ] || [ "$op_state" = "assets" ]; then
        if [ -n "$vm_dir" ] && [ -d "$vm_dir" ]; then
            rm -rf "$vm_dir"
            pz_info "removed staging directory: $vm_dir"
        fi
    else
        pz_info "disk preserved for resume/diagnosis: $vm_dir"
    fi

    rm -f "$ACTIVE_LOCK"
    pz_info "operation cancelled: $operation_id"
}

usage() {
    cat <<EOF
PhaseZero Windows VM Provisioning

Usage:
  provision plan --iso <windows.iso> [options] [--json]
  provision start --plan-id <id> --confirm <token> [--json]
  provision status --operation-id <id> [--json]
  provision watch --operation-id <id>
  provision resume --operation-id <id>
  provision cancel --operation-id <id> [--remove-staging]

Options:
  --iso PATH       Windows installation ISO
  --ram MB         RAM in MB (default: auto)
  --cpus N         CPU cores (default: auto)
  --disk-size SIZE Disk size (default: 256G)
  --image-index N  Windows image/index (default: 1)
  --lang CODE      Language (default: pt-BR)
  --keyboard CODE  Keyboard layout (default: pt-BR)
  --timezone TZ    Timezone (default: America/Sao_Paulo)
  --user NAME      Local username (default: phasezero)
  --product-key KEY Optional Windows product key
  --tpm-bypass     Bypass TPM/Secure Boot requirements
  --graphics PROFILE Graphics profile (default: compat)
  --json           JSON output
  -n, --dry-run    Dry run (plan only)
EOF
}

ACTION="${1:-help}"
[ $# -gt 0 ] && shift || true

case "$ACTION" in
    plan|dry-run) provision_plan "$@" ;;
    start|begin) provision_start "$@" ;;
    run) provision_run "$@" ;;
    status) provision_status "$@" ;;
    watch|follow) provision_watch "$@" ;;
    resume|recover) provision_resume "$@" ;;
    cancel|stop) provision_cancel "$@" ;;
    help|--help|-h|"") usage ;;
    *) pz_error "unknown provision action: $ACTION"; usage; exit 1 ;;
esac
