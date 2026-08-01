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
CP_WEIGHTS=(5 10 5 30 15 10 5 5 10 5)

checkpoint_progress_start() {
    local current="$1" total=0
    for ((i=0; i<${#PROVISION_CHECKPOINTS[@]}; i++)); do
        [ "${PROVISION_CHECKPOINTS[$i]}" = "$current" ] && break
        total=$((total + CP_WEIGHTS[i]))
    done
    [ "$total" -gt 100 ] && total=100
    echo $total
}

checkpoint_progress_end() {
    local current="$1" total=0
    for ((i=0; i<${#PROVISION_CHECKPOINTS[@]}; i++)); do
        total=$((total + CP_WEIGHTS[i]))
        [ "${PROVISION_CHECKPOINTS[$i]}" = "$current" ] && break
    done
    [ "$total" -gt 100 ] && total=100
    echo $total
}

checkpoint_label() {
    case "$1" in
        validate)    echo "Validando ISO e pré-requisitos" ;;
        assets)      echo "Baixando assets (virtio-win)" ;;
        answer-media) echo "Preparando mídia de resposta" ;;
        disk)        echo "Criando disco virtual (256G)" ;;
        setup)       echo "Instalando Windows" ;;
        drivers)     echo "Instalando drivers virtio" ;;
        tweaks)      echo "Aplicando ajustes pós-instalação" ;;
        verify)      echo "Verificando integridade" ;;
        snapshot)    echo "Criando snapshot de restauração" ;;
        relaunch)    echo "Preparando relaunch com display" ;;
        *)           echo "$1" ;;
    esac
}

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
    local virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"
    local virtio_sha_expected="e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331"

    local preflight_json preflight_status preflight_stderr
    if [ "${PZ_TEST_MODE:-0}" = "1" ] && [ -n "${PZ_PREFLIGHT_JSON:-}" ]; then
        # Hermetic override — honored ONLY with the PZ_TEST_MODE=1 sentinel, so
        # production always runs the real preflight. The fixture must match the
        # schema the plan consumes (status in pass/warn/fail, swtpm and virtio
        # objects); an invalid override is rejected loudly instead of falling
        # back to host probing.
        if preflight_json="$(printf '%s' "$PZ_PREFLIGHT_JSON" | jq -e -c '(.status == "pass" or .status == "warn" or .status == "fail") and (.swtpm | type == "object") and (.virtio | type == "object")' 2>/dev/null)"; then
            preflight_json="$PZ_PREFLIGHT_JSON"
        else
            pz_error "PZ_PREFLIGHT_JSON override rejected: fixture does not match preflight schema (status/swtpm/virtio)"
            return 1
        fi
    else
        # shellcheck disable=SC2119
        preflight_stderr="$(pz_tempfile)" || true
        preflight_json="$(bash "$PZ_ROOT/linux/windows-vm/preflight.sh" --json 2>"${preflight_stderr:-/dev/null}" || {
            pz_warn "preflight check failed — see diagnostics above"
            echo '{"status":"fail"}'
        })"
        if [ -s "${preflight_stderr:-/dev/null}" ]; then
            pz_warn "preflight diagnostics:"
            sed 's/^/  /' "$preflight_stderr" >&2
        fi
        rm -f "${preflight_stderr:-}"
    fi
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
    local operation_id="op-$(date +%Y%m%d-%H%M%S)-${RANDOM}"
    if ! provision_lock_acquire "$operation_id"; then
        return 1
    fi
    local op_dir="$OPERATIONS_DIR/$operation_id"
    mkdir -p "$op_dir"
    chmod 0700 "$op_dir"

    cp "$plan_file" "$op_dir/plan.json"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local initial_label
    initial_label="$(checkpoint_label "validate")"
    jq -n \
        --arg id "$operation_id" \
        --arg planId "$plan_id" \
        --arg state "running" \
        --arg checkpoint "validate" \
        --arg currentLabel "$initial_label" \
        --arg createdAt "$timestamp" \
        '{
            id: $id, planId: $planId, state: $state,
            checkpoint: $checkpoint, currentLabel: $currentLabel,
            progress: 0,
            createdAt: $createdAt, updatedAt: $createdAt,
            checkpoints: {},
            log: []
        }' > "$op_dir/operation.json"
    chmod 0600 "$op_dir/operation.json"

    if [ "$json" = "1" ]; then
        jq -n \
            --arg id "$operation_id" \
            --arg state "running" \
            --arg checkpoint "validate" \
            --arg currentLabel "$initial_label" \
            --arg activeLock "$ACTIVE_LOCK" \
            '{operationId: $id, state: $state, checkpoint: $checkpoint, currentLabel: $currentLabel, progress: 0, activeLockPath: $activeLock}'
    else
        pz_info "provision started: $operation_id"
        echo "$operation_id"
    fi

    nohup bash "$PZ_ROOT/linux/windows-vm/provision.sh" run --operation-id "$operation_id" \
        > "$op_dir/worker.log" 2>&1 &
    disown
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

    # The parent (start/resume) holds the lock only until spawn; the worker
    # re-acquires it for the whole run so a second start/resume is blocked
    # while this operation is live. Retry briefly to bridge the handoff.
    local acquired=0 attempt=0
    while [ "$attempt" -lt 100 ]; do
        if provision_lock_acquire "$operation_id"; then
            acquired=1
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    if [ "$acquired" != "1" ]; then
        pz_error "could not acquire provision lock for $operation_id"
        return 1
    fi
    trap 'provision_lock_release' RETURN

    for cp in "${PROVISION_CHECKPOINTS[@]}"; do
        local current_state
        current_state="$(jq -r '.state // "running"' "$op_dir/operation.json")"
        [ "$current_state" = "running" ] || { pz_info "operation state changed to $current_state; stopping"; return 0; }

        # checkpoint done → skip on resume
        local cp_status
        cp_status="$(jq -r --arg cp "$cp" '.checkpoints[$cp] // ""' "$op_dir/operation.json")"
        [ "$cp_status" = "done" ] && continue

        local start_progress end_progress pre_label
        start_progress="$(checkpoint_progress_start "$cp")"
        end_progress="$(checkpoint_progress_end "$cp")"
        pre_label="$(checkpoint_label "$cp")"
        local pre_ts; pre_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq \
            --arg p "$start_progress" \
            --arg l "$pre_label" \
            --arg cp "$cp" \
            --arg ts "$pre_ts" \
            '.checkpoint = $cp | .currentLabel = $l | .progress = ($p|tonumber) | .updatedAt = $ts' \
            "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"

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

        local post_ts; post_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq \
            --arg p "$end_progress" \
            --arg ts "$post_ts" \
            '.progress = ($p|tonumber) | .updatedAt = $ts' \
            "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    done

    local done_ts; done_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$done_ts" '.state = "completed" | .progress = 100 | .updatedAt = $ts' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    provision_lock_clear "$operation_id"
    pz_info "provision completed: $operation_id"
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
    # A user cancel must never be downgraded to failed by the dying worker.
    local cur
    cur="$(jq -r '.state // "running"' "$op_dir/operation.json" 2>/dev/null || true)"
    [ "$cur" = "cancelled" ] && return 0
    update_checkpoint "$op" "$cp" "failed"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$ts" '.state = "failed" | .updatedAt = $ts' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
}

# ── Provision lock ──
# Single-writer lock across start/resume/cancel. Uses flock(1) when available
# (atomic, auto-released on process death); falls back to mkdir+pidfile with
# staleness check. The lock file content is the authoritative operation id;
# a lock whose recorded operation is completed/failed/cancelled is recoverable,
# a running operation blocks a new one, and inconsistent state (lock references
# a missing/corrupt operation) produces a diagnostic instead of silent overwrite.
LOCK_FD=-1
LOCK_DIR_MODE="mkdir"

provision_lock_init() {
    mkdir -p "$PROVISION_DIR"
    # PZ_LOCK_FORCE_MKDIR=1 selects the mkdir+pidfile fallback even when flock
    # is present, so the fallback path is exercisable in tests and on hosts
    # where flock misbehaves (sandboxes, containers with seccomp filtering).
    if [ "${PZ_LOCK_FORCE_MKDIR:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
        LOCK_DIR_MODE="flock"
    else
        LOCK_DIR_MODE="mkdir"
    fi
}

provision_lock_acquire() {
    local new_op="$1"
    local prev="" prev_state=""
    provision_lock_init
    if [ "$LOCK_DIR_MODE" = "flock" ]; then
        [ "$LOCK_FD" -ge 0 ] 2>/dev/null || LOCK_FD=-1
        if [ "$LOCK_FD" -lt 0 ]; then
            # <> opens read-write without truncating, so the recorded
            # operation id survives across processes.
            exec {LOCK_FD}<>"$ACTIVE_LOCK"
        fi
        if ! flock -n "$LOCK_FD"; then
            prev="$(cat "$ACTIVE_LOCK" 2>/dev/null || true)"
            pz_error "provision lock held by: ${prev:-unknown operation}"
            return 1
        fi
    else
        if ! mkdir "$ACTIVE_LOCK.d" 2>/dev/null; then
            prev="$(cat "$ACTIVE_LOCK" 2>/dev/null || true)"
            local holder_pid=""
            [ -f "$ACTIVE_LOCK.d/pid" ] && holder_pid="$(cat "$ACTIVE_LOCK.d/pid" 2>/dev/null || true)"
            if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
                pz_error "provision lock held by: ${prev:-unknown operation} (pid $holder_pid)"
                return 1
            fi
            pz_warn "stale mkdir lock detected (holder pid ${holder_pid:-unknown} not alive); recovering"
            rm -rf "$ACTIVE_LOCK.d"
            mkdir "$ACTIVE_LOCK.d" 2>/dev/null || { pz_error "provision lock contention"; return 1; }
        fi
        printf '%s\n' "$$" > "$ACTIVE_LOCK.d/pid"
    fi

    prev="$(cat "$ACTIVE_LOCK" 2>/dev/null || true)"
    if [ -n "$prev" ] && [ "$prev" != "$new_op" ]; then
        local prev_op="$OPERATIONS_DIR/$prev"
        if [ -f "$prev_op/operation.json" ]; then
            prev_state="$(jq -r '.state // ""' "$prev_op/operation.json" 2>/dev/null || true)"
            case "$prev_state" in
                running)
                    pz_error "active operation exists: $prev (state: running) — cancel or wait for it"
                    provision_lock_release
                    return 1
                    ;;
                completed|failed|cancelled)
                    pz_warn "recovering provision lock from operation $prev (state: $prev_state)"
                    ;;
                "")
                    pz_error "lock references operation $prev with unreadable/corrupt state — refusing to overwrite"
                    provision_lock_release
                    return 1
                    ;;
                *)
                    pz_error "lock references operation $prev in inconsistent state ($prev_state) — refusing to overwrite"
                    provision_lock_release
                    return 1
                    ;;
            esac
        else
            pz_error "lock references missing operation $prev — refusing to overwrite"
            provision_lock_release
            return 1
        fi
    fi
    printf '%s\n' "$new_op" > "$ACTIVE_LOCK"
    return 0
}

provision_lock_release() {
    if [ "$LOCK_DIR_MODE" = "flock" ]; then
        if [ "$LOCK_FD" -ge 0 ] 2>/dev/null; then
            flock -u "$LOCK_FD" 2>/dev/null || true
            exec {LOCK_FD}>&- 2>/dev/null || true
            LOCK_FD=-1
        fi
    else
        rm -rf "$ACTIVE_LOCK.d"
    fi
}

# Remove ACTIVE_LOCK only if it still names the given operation (the worker
# finishing must never clear a lock that a newer operation already took over).
# Always returns 0: a mismatch is a no-op, never a failure under set -e.
provision_lock_clear() {
    local op="$1"
    local current=""
    current="$(cat "$ACTIVE_LOCK" 2>/dev/null || true)"
    [ "$current" = "$op" ] && rm -f "$ACTIVE_LOCK"
    return 0
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
                "$qemu_bin" -device help 2>/dev/null | grep 'virtio-vga-gl' >/dev/null && has_virtio_vga_gl=1
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
                ldconfig -p 2>/dev/null | grep 'virglrenderer' >/dev/null && has_virgl=1
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
                if curl -L -o "$vm_dir/virtio-win.iso" "$virtio_url"; then
                    download_ok=1
                fi
            elif command -v wget >/dev/null 2>&1; then
                if wget -O "$vm_dir/virtio-win.iso" "$virtio_url"; then
                    download_ok=1
                fi
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

    local autounattend_args=(
        --wim-index "$image_index"
        --lang "$lang"
        --keyboard "$keyboard"
        --timezone "$tz"
        --user "$user"
        --password "$password_xml"
        --disk-serial "$disk_serial"
        --output-dir "$answer_dir"
    )
    [ -n "$product_key" ] && autounattend_args+=(--product-key "$product_key")
    [ "$tpm_bypass" = "true" ] && autounattend_args+=(--tpm-bypass)
    bash "$PZ_ROOT/linux/windows-vm/autounattend.sh" generate \
        "${autounattend_args[@]}" >/dev/null

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
    ovmf_code="${PZ_WINDOWS_VM_OVMF_CODE:-$(pz_path_resolve ovmf_code \
        /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd \
        /usr/share/OVMF/OVMF_CODE.fd || true)}"
    ovmf_vars="$vm_dir/OVMF_VARS.fd"
    if [ ! -f "$ovmf_vars" ]; then
        local vars_template
        vars_template="$(pz_path_resolve ovmf_vars_template \
            /usr/share/edk2/x64/OVMF_VARS.4m.fd \
            /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null || true)"
        [ -n "$vars_template" ] && cp "$vars_template" "$ovmf_vars"
    fi

    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }
    [ -f "$oemdrv_iso" ] || { log_operation "$op" "OEMDRV ISO not found"; return 1; }

    # shellcheck disable=SC2054
    local qemu_args=(
        -machine q35,accel=kvm
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
        # shellcheck disable=SC2054
        qemu_args+=(-drive file="$vm_dir/virtio-win.iso",format=raw,if=none,id=virtio)
        # shellcheck disable=SC2054
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
    local ovmf_code="${PZ_WINDOWS_VM_OVMF_CODE:-$(pz_path_resolve ovmf_code \
        /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd \
        /usr/share/OVMF/OVMF_CODE.fd || true)}"
    local ovmf_vars="$vm_dir/OVMF_VARS.fd"
    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }

    rm -f "$qga_sock"

    # shellcheck disable=SC2054
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
        local ps_script
        ps_script=$(cat << 'PSEOF'
$d = (Get-Volume -FileSystemLabel VIRTIO).DriveLetter + ':' 2>$null;
if (-not $d) { $d = 'D:' };
if (Test-Path "$d\setup.exe") {
    Write-Host Installing VirtIO drivers from $d;
    Start-Process "$d\setup.exe" -ArgumentList '/S /NoRestart' -NoNewWindow -Wait
} elseif (Test-Path "$d\virtio-win-gt-x64.msi") {
    Write-Host Installing VirtIO MSI from $d;
    Start-Process msiexec.exe -ArgumentList "/i ""$d\virtio-win-gt-x64.msi"" /qn /norestart" -NoNewWindow -Wait
} else {
    Write-Host Searching for .inf drivers in $d;
    Get-ChildItem "$d" -Filter *.inf -Recurse | ForEach-Object {
        & pnputil /add-driver $_.FullName /install 2>&1 | Write-Host
    }
};
Write-Host VirtIO driver installation complete
PSEOF
)
        local qga_json
        qga_json=$(jq -n --arg ps "$ps_script" '{
            "execute": "guest-exec",
            "arguments": {
                "path": "powershell.exe",
                "arg": ["-Command", $ps],
                "capture-output": true
            }
        }')
        local exec_result
        exec_result="$(qga_exec "$qga_sock" "$qga_json")"
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
        local check_qga
        check_qga=$(jq -n '{
            "execute": "guest-exec",
            "arguments": {
                "path": "powershell.exe",
                "arg": ["-Command", "(Get-PnpDevice -Class Display).Name"],
                "capture-output": true
            }
        }')
        local check_result
        check_result="$(qga_exec "$qga_sock" "$check_qga")"
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
                if echo "$check_stdout" | grep -i "Microsoft Basic Display" >/dev/null; then
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
    local ovmf_code="${PZ_WINDOWS_VM_OVMF_CODE:-$(pz_path_resolve ovmf_code \
        /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd \
        /usr/share/OVMF/OVMF_CODE.fd || true)}"
    local ovmf_vars="$vm_dir/OVMF_VARS.fd"
    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }

    rm -f "$qga_sock"

    # shellcheck disable=SC2054
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

        local tweaks_script
        tweaks_script=$(cat << 'PSEOF'
Remove-AppxPackage -Package "*xbox*" -AllUsers -ErrorAction SilentlyContinue
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /h off
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name EnableLUA -Value 0 -Type DWord
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
PSEOF
)

        local tweaks_qga
        tweaks_qga=$(jq -n --arg ps "$tweaks_script" '{
            "execute": "guest-exec",
            "arguments": {
                "path": "powershell.exe",
                "arg": ["-Command", $ps],
                "capture-output": true
            }
        }')
        local exec_result
        exec_result="$(qga_exec "$qga_sock" "$tweaks_qga")"
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

    log_operation "$op" "disk verified: $(numfmt --to=iec "$disk_size" 2>/dev/null || echo "${disk_size}B")"
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
    ovmf_code="${PZ_WINDOWS_VM_OVMF_CODE:-$(pz_path_resolve ovmf_code \
        /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd \
        /usr/share/OVMF/OVMF_CODE.fd || true)}"
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

    # shellcheck disable=SC2054
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
        -spice port=5930,addr=127.0.0.1,disable-ticketing=on
        -device ich9-usb-ehci1
        -device ich9-usb-uhci1
        -device usb-tablet
        -device usb-kbd
    )

    qemu_args+=("$GRAPHICS_VGA")
    qemu_args+=("$GRAPHICS_DISPLAY")
    # shellcheck disable=SC2054
    qemu_args+=(-chardev socket,path="$vm_dir/qga.sock",server=on,id=qga0)
    # shellcheck disable=SC2054
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

    local vm_dir="" snapshot_path="" qemu_pid_raw="" qemu_pid_num=0
    local vm_dir_file="$OPERATIONS_DIR/$operation_id/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local snap_path_file="$OPERATIONS_DIR/$operation_id/snapshot_path"
    [ -f "$snap_path_file" ] && snapshot_path="$(cat "$snap_path_file")"
    if [ -n "$vm_dir" ] && [ -f "$vm_dir/qemu-pid" ]; then
        # Only trust qemu-pid from a vm_dir that resolves to canonical staging;
        # a corrupt/hostile vm_dir record must never drive a read from an
        # arbitrary path.
        if resolve_vm_staging_dir "$operation_id" >/dev/null 2>&1; then
            qemu_pid_raw="$(cat "$vm_dir/qemu-pid")"
        else
            pz_warn "vm_dir fails staging validation; qemu-pid not read: $vm_dir"
            vm_dir=""
        fi
    fi
    [[ "$qemu_pid_raw" =~ ^[0-9]+$ ]] && qemu_pid_num="$qemu_pid_raw"
    local qemu_running="false"
    if [ "$qemu_pid_num" -gt 0 ]; then
        if kill -0 "$qemu_pid_num" 2>/dev/null; then
            local cmdline=""
            [ -r "/proc/${qemu_pid_num}/cmdline" ] && cmdline="$(tr '\0' ' ' < "/proc/${qemu_pid_num}/cmdline")"
            case "$cmdline" in
                *qemu-system*|*qemu-kvm*) qemu_running="true" ;;
            esac
        fi
    fi
    local snapshot_exists="false"
    [ -n "$snapshot_path" ] && [ -f "$snapshot_path" ] && snapshot_exists="true"
    local libvirt_running="false"
    if command -v virsh >/dev/null 2>&1; then
        local dom_state
        dom_state="$(virsh domstate phasezero-windows-vm 2>/dev/null || true)"
        case "$dom_state" in
            running|paused|idle) libvirt_running="true" ;;
        esac
    fi

    if [ "$json" = "1" ]; then
        jq -n \
            --argjson op "$(cat "$op_dir/operation.json")" \
            --arg vmDir "$vm_dir" \
            --arg snapshotPath "$snapshot_path" \
            --argjson snapshotExists "$snapshot_exists" \
            --argjson qemuPid "$qemu_pid_num" \
            --argjson qemuRunning "$qemu_running" \
            --argjson libvirtRunning "$libvirt_running" \
            '$op + {vmDir: $vmDir, snapshotPath: $snapshotPath, snapshotExists: $snapshotExists, qemuPid: $qemuPid, qemuRunning: $qemuRunning, libvirtRunning: $libvirtRunning}'
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

    if ! provision_lock_acquire "$operation_id"; then
        return 1
    fi

    local resume_ts; resume_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$resume_ts" '.state = "running" | .updatedAt = $ts' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"

    nohup bash "$PZ_ROOT/linux/windows-vm/provision.sh" run --operation-id "$operation_id" \
        > "$op_dir/worker.log" 2>&1 &
    disown

    pz_info "operation resumed: $operation_id (from checkpoint: $checkpoint)"
}

# ── Safe staging removal ──
# Cancel --remove-staging deletes the VM staging directory. The path comes
# from mutable operation state, so it must be validated before any recursive
# deletion: canonical path, exact containment under the official staging
# layout, operation-id agreement, no symlink escapes, no external roots.
pz_staging_base() {
    printf '%s\n' "${PZ_STATE}/windows-vm/vms"
}

resolve_vm_staging_dir() {
    local op="$1" vm_dir="" canonical="" base="" canonical_base=""
    local op_dir="$OPERATIONS_DIR/$op"
    local vm_dir_file="$op_dir/vm_dir"

    [ -n "$op" ] || { pz_error "resolve_vm_staging_dir: empty operation id"; return 1; }
    case "$op" in
        */*|*..*) pz_error "resolve_vm_staging_dir: invalid operation id: $op"; return 1 ;;
    esac
    [ -d "$op_dir" ] || { pz_error "operation not found: $op"; return 1; }
    [ -f "$op_dir/operation.json" ] || { pz_error "operation metadata missing: $op"; return 1; }
    if ! jq -e '.id and .state' "$op_dir/operation.json" >/dev/null 2>&1; then
        pz_error "operation metadata corrupt for $op; refusing to remove staging"
        return 1
    fi
    local op_id_in_meta
    op_id_in_meta="$(jq -r '.id // ""' "$op_dir/operation.json" 2>/dev/null || true)"
    [ "$op_id_in_meta" = "$op" ] || {
        pz_error "operation metadata id ($op_id_in_meta) does not match $op; refusing to remove staging"
        return 1
    }

    [ -f "$vm_dir_file" ] || { pz_error "no staging record for operation $op"; return 1; }
    vm_dir="$(cat "$vm_dir_file" 2>/dev/null || true)"
    [ -n "$vm_dir" ] || { pz_error "empty staging path for operation $op"; return 1; }

    case "$vm_dir" in
        *..*)
            pz_error "refusing staging path containing '..': $vm_dir"
            return 1
            ;;
    esac
    [ "$vm_dir" = "/" ] && { pz_error "refusing to remove root"; return 1; }
    [ "$vm_dir" = "$HOME" ] && { pz_error "refusing to remove HOME"; return 1; }
    [ "$vm_dir" = "$PZ_STATE" ] && { pz_error "refusing to remove PZ_STATE"; return 1; }

    base="$(pz_staging_base)"
    [ -n "$base" ] || { pz_error "staging base undefined"; return 1; }
    canonical_base="$(cd -P "$base" 2>/dev/null && pwd -P || echo "")"
    [ -n "$canonical_base" ] || { pz_error "staging base does not exist: $base"; return 1; }

    if [ -L "$vm_dir" ] || [ -L "$vm_dir_file" ]; then
        pz_error "refusing to follow symlink in staging path: $vm_dir"
        return 1
    fi

    # Resolve the deepest existing ancestor so containment is checked on real
    # paths even when the leaf does not exist yet (or was partially removed).
    local probe="$vm_dir" ancestor=""
    while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
        probe="$(dirname "$probe")"
    done
    if [ -L "$probe" ] || [ -L "$(dirname "$probe" 2>/dev/null)" ]; then
        pz_error "refusing to follow symlink on path to staging: $vm_dir"
        return 1
    fi
    canonical="$(cd -P "$probe" 2>/dev/null && pwd -P || echo "")"
    [ -n "$canonical" ] || { pz_error "cannot resolve staging path: $vm_dir"; return 1; }

    case "$canonical/" in
        "$canonical_base/"*)
            ;;
        *)
            pz_error "staging path escapes official layout: $vm_dir (resolved $canonical, base $canonical_base)"
            return 1
            ;;
    esac

    local expected="$canonical_base/$op"
    [ "$canonical" = "$expected" ] || [ "$canonical/" = "$expected/" ] || {
        pz_error "staging path does not match operation $op: $vm_dir (expected under $expected)"
        return 1
    }
    printf '%s\n' "$vm_dir"
    return 0
}

# Validate a QEMU pid before killing: numeric, alive, and its cmdline must
# reference the operation's staging dir or disk (which embeds the operation
# id). Guards against pid reuse.
validate_qemu_pid() {
    local pid="$1" vm_dir="$2" op="$3"
    case "$pid" in
        ''|*[!0-9]*) pz_error "invalid qemu pid: ${pid:-empty}"; return 1 ;;
    esac
    [ "$pid" -gt 1 ] 2>/dev/null || { pz_error "invalid qemu pid: $pid"; return 1; }
    [ -d "/proc/$pid" ] || { pz_error "qemu pid $pid is not alive; refusing kill"; return 1; }
    local cmdline=""
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$cmdline" in
        *qemu-system*)
            ;;
        *)
            pz_error "pid $pid is not a qemu process; refusing kill"
            return 1
            ;;
    esac
    [ -n "$op" ] || { pz_error "validate_qemu_pid: empty operation id"; return 1; }
    case "$cmdline" in
        *"$op"*)
            ;;
        *)
            pz_error "pid $pid cmdline does not reference operation $op; refusing kill"
            return 1
            ;;
    esac
    if [ -n "$vm_dir" ]; then
        case "$cmdline" in
            *"$vm_dir"*)
                ;;
            *)
                pz_error "pid $pid cmdline does not reference staging $vm_dir; refusing kill"
                return 1
                ;;
        esac
    fi
    return 0
}

provision_cancel() {
    local operation_id="" remove_staging=0 json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --remove-staging) remove_staging=1; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown cancel option: $1"; return 1 ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    if [ ! -d "$op_dir" ] || [ ! -f "$op_dir/operation.json" ]; then
        if [ "$json" = "1" ]; then
            jq -n --arg operationId "$operation_id" \
                '{success: false, cancelled: false, removalRequested: false, removalSucceeded: false, preservedPath: "", error: "operation not found", operationId: $operationId}'
        fi
        pz_error "operation not found: $operation_id"
        return 1
    fi

    # Cancel intentionally does NOT take the provision lock: it is the one
    # supervisory action that must be able to interrupt a running worker that
    # holds the lock. The worker notices the state change at the next
    # checkpoint and exits, releasing the lock on process death.

    local state
    state="$(jq -r '.state' "$op_dir/operation.json")"

    # The vm_dir record is only trusted after canonical-staging validation; a
    # corrupt/hostile record must never drive a qemu-pid read or a removal, and
    # a validation failure is reported (never silently treated as success).
    local vm_dir="" raw_vm_dir="" vm_dir_file="$OPERATIONS_DIR/$operation_id/vm_dir"
    local staging_valid=0
    [ -f "$vm_dir_file" ] && raw_vm_dir="$(cat "$vm_dir_file")"
    if [ -n "$raw_vm_dir" ]; then
        if resolve_vm_staging_dir "$operation_id" >/dev/null 2>&1; then
            staging_valid=1
            vm_dir="$raw_vm_dir"
        else
            pz_warn "staging validation failed for $operation_id; refusing to touch $raw_vm_dir"
        fi
    fi

    if [ "$staging_valid" = "1" ] && [ -f "$vm_dir/qemu-pid" ]; then
        local qemu_pid
        qemu_pid="$(cat "$vm_dir/qemu-pid")"
        if validate_qemu_pid "$qemu_pid" "$vm_dir" "$operation_id"; then
            kill "$qemu_pid" 2>/dev/null || true
            rm -f "$vm_dir/qemu-pid"
        else
            pz_warn "qemu pid validation failed ($qemu_pid); leaving qemu-pid record"
        fi
    fi

    local cancel_ts; cancel_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$cancel_ts" '.state = "cancelled" | .updatedAt = $ts' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"

    local removal_requested=0 removal_succeeded=0 preserved_path=""
    local op_state
    op_state="$(jq -r '.checkpoint' "$op_dir/operation.json")"
    if [ "$remove_staging" = "1" ] || [ "$op_state" = "validate" ] || [ "$op_state" = "assets" ]; then
        removal_requested=1
        if [ "$staging_valid" = "1" ] && [ -d "$vm_dir" ]; then
            if resolve_vm_staging_dir "$operation_id" >/dev/null 2>&1; then
                rm -rf -- "$vm_dir"
                [ "$json" = "1" ] && echo >&2 "INFO:  removed staging directory: $vm_dir" || pz_info "removed staging directory: $vm_dir"
                removal_succeeded=1
            else
                pz_error "staging validation refused; preserving $vm_dir"
                preserved_path="$vm_dir"
            fi
        elif [ "$staging_valid" = "1" ]; then
            # Nothing left to remove (already gone or never created).
            removal_succeeded=1
        else
            pz_error "staging validation failed; preserving ${raw_vm_dir:-unknown}"
            preserved_path="$raw_vm_dir"
        fi
    else
        [ "$json" = "1" ] && echo >&2 "INFO:  disk preserved for resume/diagnosis: ${vm_dir:-$raw_vm_dir}" || pz_info "disk preserved for resume/diagnosis: ${vm_dir:-$raw_vm_dir}"
        [ -n "$raw_vm_dir" ] && preserved_path="$raw_vm_dir"
    fi

    local success=1 error=""
    if [ -n "$raw_vm_dir" ] && [ "$staging_valid" = "0" ]; then
        success=0
        error="staging validation failed; operation untouched: $raw_vm_dir"
    elif [ "$removal_requested" = "1" ] && [ "$removal_succeeded" = "0" ]; then
        success=0
        error="staging removal failed; preserved: $preserved_path"
    fi

    if [ "$json" = "1" ]; then
        jq -n \
            --arg operationId "$operation_id" \
            --argjson success "$([ "$success" = "1" ] && echo true || echo false)" \
            --argjson cancelled true \
            --argjson removalRequested "$([ "$removal_requested" = "1" ] && echo true || echo false)" \
            --argjson removalSucceeded "$([ "$removal_succeeded" = "1" ] && echo true || echo false)" \
            --arg preservedPath "$preserved_path" \
            --arg error "$error" \
            '{success: $success, cancelled: $cancelled, removalRequested: $removalRequested, removalSucceeded: $removalSucceeded, preservedPath: $preservedPath, error: $error, operationId: $operationId}'
    fi
    [ "$json" = "1" ] && echo >&2 "INFO:  operation cancelled: $operation_id" || pz_info "operation cancelled: $operation_id"
    [ "$success" = "1" ]
}

provision_shutdown() {
    local operation_id="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown shutdown option: $1"; return 1 ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local vm_dir vm_dir_file="$OPERATIONS_DIR/$operation_id/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    if [ -z "$vm_dir" ] || [ ! -d "$vm_dir" ]; then
        if [ "$json" = "1" ]; then
            jq -n --arg operation_id "$operation_id" '{success: false, error: "vm_dir not found", operationId: $operation_id}'
        else
            pz_error "vm_dir not found"
        fi
        return 1
    fi

    local qga_sock="$vm_dir/qga.sock"
    if [ ! -S "$qga_sock" ]; then
        if [ "$json" = "1" ]; then
            jq -n --arg operation_id "$operation_id" '{success: false, error: "QGA socket not found", operationId: $operation_id}'
        else
            pz_error "QGA socket not found"
        fi
        return 1
    fi

    local have_socat=0
    command -v socat >/dev/null 2>&1 && have_socat=1
    if [ "$have_socat" != "1" ]; then
        if [ "$json" = "1" ]; then
            jq -n --arg operation_id "$operation_id" '{success: false, error: "socat required for QGA shutdown", operationId: $operation_id}'
        else
            pz_error "socat required"
        fi
        return 1
    fi

    local qemu_pid=""
    local qemu_pid_file="$vm_dir/qemu-pid"
    [ -f "$qemu_pid_file" ] && qemu_pid="$(cat "$qemu_pid_file")"

    echo '{"execute":"guest-shutdown"}' | socat - UNIX-CONNECT:"$qga_sock" 2>/dev/null || true

    local timeout=60 waited=0 shutdown_ok=0
    while [ "$waited" -lt "$timeout" ]; do
        # Check QEMU PID disappeared
        local pid_alive=0
        if [ -n "$qemu_pid" ]; then
            [[ "$qemu_pid" =~ ^[0-9]+$ ]] && kill -0 "$qemu_pid" 2>/dev/null && pid_alive=1
        fi

        # Check libvirt domstate
        local libvirt_alive=0
        if command -v virsh >/dev/null 2>&1; then
            local dom_state
            dom_state="$(virsh domstate phasezero-windows-vm 2>/dev/null || true)"
            case "$dom_state" in
                running|paused|idle) libvirt_alive=1 ;;
            esac
        fi

        if [ "$pid_alive" = "0" ] && [ "$libvirt_alive" = "0" ]; then
            shutdown_ok=1
            break
        fi

        if [ "$libvirt_alive" = "1" ] && [ "$pid_alive" = "1" ]; then
            sleep 2
            waited=$((waited + 2))
            continue
        fi

        sleep 2
        waited=$((waited + 2))
    done

    if [ "$shutdown_ok" != "1" ] && [ -n "$qemu_pid" ]; then
        if [[ "$qemu_pid" =~ ^[0-9]+$ ]]; then
            kill "$qemu_pid" 2>/dev/null || true
        fi
    fi

    if [ "$json" = "1" ]; then
        jq -n \
            --argjson success "$([ "$shutdown_ok" = "1" ] && echo true || echo false)" \
            --arg operation_id "$operation_id" \
            --argjson waited "$waited" \
            '{success: $success, operationId: $operation_id, waitedSeconds: $waited}'
    else
        if [ "$shutdown_ok" = "1" ]; then
            pz_info "VM shutdown confirmed after ${waited}s"
        else
            pz_warn "VM did not shut down within ${timeout}s"
        fi
    fi
    return $((1 - shutdown_ok))
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
  provision shutdown --operation-id <id> [--json]

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
if [ $# -gt 0 ]; then
    shift
fi

case "$ACTION" in
    plan|dry-run) provision_plan "$@" ;;
    start|begin) provision_start "$@" ;;
    run) provision_run "$@" ;;
    status) provision_status "$@" ;;
    watch|follow) provision_watch "$@" ;;
    resume|recover) provision_resume "$@" ;;
    cancel|stop) provision_cancel "$@" ;;
    shutdown) provision_shutdown "$@" ;;
    help|--help|-h|"") usage ;;
    *) pz_error "unknown provision action: $ACTION"; usage; exit 1 ;;
esac
