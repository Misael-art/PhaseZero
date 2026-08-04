#!/usr/bin/env bash
# End-to-end offline QGA recovery. Secrets enter only on stdin and never touch
# argv, environment, host state, or the recovery log.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

MODE=auto
LEAVE_RUNNING=0
JSON_OUT=0
PASSWORD_STDIN=0
ALLOW_BASIC_GRAPHICS=0
PASSWORD=""
VM_PID=""
KEEP_VM=0
GUEST_LOGIN="$PZ_ROOT/linux/windows-vm/guest-login.sh"
RECOVERY_LOG="$PZ_STATE/windows-vm/recover.log"
BOOT_TIMEOUT="${PZ_WINDOWS_VM_RECOVER_BOOT_TIMEOUT:-600}"
READY_TIMEOUT="${PZ_WINDOWS_VM_RECOVER_READY_TIMEOUT:-300}"

usage() {
    pz_error "usage: pz windows-vm recover --mode auto|password [--password-stdin] [--leave-running] [--allow-basic-graphics] [--json]"
}

# The VM is started by this script, so this script owns its lifetime. Leaving a
# headless QEMU behind on failure strands the disk lock and the next run refuses
# to start at all.
stop_vm() {
    [ -n "$VM_PID" ] || return 0
    if ! kill -0 "$VM_PID" 2>/dev/null; then
        VM_PID=""
        return 0
    fi
    # Ask the guest first: an ACPI powerdown keeps NTFS and the TPM state clean.
    bash "$GUEST_LOGIN" shutdown --json >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 120))
    while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$VM_PID" 2>/dev/null; do
        sleep 2
    done
    # The launcher runs in its own session, so signalling the group reaches QEMU
    # and swtpm rather than only the wrapper shell.
    local pgid
    pgid="$(ps -o pgid= -p "$VM_PID" 2>/dev/null | tr -d ' ' || true)"
    if kill -0 "$VM_PID" 2>/dev/null; then
        if [ -n "$pgid" ]; then kill -TERM -"$pgid" 2>/dev/null || true; fi
        kill -TERM "$VM_PID" 2>/dev/null || true
        deadline=$((SECONDS + 30))
        while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$VM_PID" 2>/dev/null; do
            sleep 1
        done
    fi
    if kill -0 "$VM_PID" 2>/dev/null; then
        if [ -n "$pgid" ]; then kill -KILL -"$pgid" 2>/dev/null || true; fi
        kill -KILL "$VM_PID" 2>/dev/null || true
    fi
    wait "$VM_PID" 2>/dev/null || true
    VM_PID=""
}

vm_alive() {
    [ -n "$VM_PID" ] || return 1
    kill -0 "$VM_PID" 2>/dev/null
}

cleanup() {
    unset PASSWORD
    [ "$KEEP_VM" = 1 ] || stop_vm
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --mode=*) MODE="${1#*=}"; shift ;;
        --password-stdin) PASSWORD_STDIN=1; shift ;;
        --leave-running) LEAVE_RUNNING=1; shift ;;
        --allow-basic-graphics) ALLOW_BASIC_GRAPHICS=1; shift ;;
        --json) JSON_OUT=1; shift ;;
        *) usage; exit 2 ;;
    esac
done

case "$MODE" in auto|password) ;; *) usage; exit 2 ;; esac
if [ "$MODE" = password ]; then
    [ "$PASSWORD_STDIN" = 1 ] || { pz_error "password mode requires --password-stdin"; exit 2; }
    IFS= read -r PASSWORD
    [ -n "$PASSWORD" ] || { pz_error "empty guest password refused"; exit 2; }
fi

emit() {
    local phase="$1" success="$2" detail="${3:-}"
    if [ "$JSON_OUT" = 1 ]; then
        jq -n --arg phase "$phase" --arg detail "$detail" --argjson success "$success" \
            '{phase:$phase,success:$success,detail:$detail}'
    else
        pz_info "recover phase=$phase${detail:+ ($detail)}"
    fi
}

guest_transport_json() {
    bash "$GUEST_LOGIN" transport-verify --json 2>/dev/null
}

# Boot identity, not transport gaps. Watching QGA disappear and come back is a
# race against the poll interval: a reboot faster than one poll is invisible and
# a guest that never drops the socket hangs until the deadline. The guest
# reports which boot the offline repair ran on, so "did it reboot" is an exact
# comparison instead of an inference.
wait_for_repair_reboot() {
    local deadline status
    deadline=$((SECONDS + BOOT_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        vm_alive || { pz_error "QEMU exited before the guest completed the repair reboot"; return 1; }
        status="$(guest_transport_json || true)"
        if printf '%s\n' "$status" | jq -e \
            '.success == true and .offlineRepairRebootProven == true' >/dev/null 2>&1; then
            printf '%s\n' "$status"
            return 0
        fi
        sleep 3
    done
    pz_error "guest did not return from the scheduled offline-repair reboot"
    return 1
}

wait_for_boot_change() {
    local previous="$1" deadline status boot
    [ -n "$previous" ] || { pz_error "guest boot identity unavailable; cannot prove a reboot"; return 1; }
    deadline=$((SECONDS + BOOT_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        vm_alive || { pz_error "QEMU exited before the guest completed the login reboot"; return 1; }
        status="$(guest_transport_json || true)"
        boot="$(printf '%s\n' "$status" | jq -r '.lastBootUpTime // ""' 2>/dev/null || true)"
        if [ -n "$boot" ] && [ "$boot" != "$previous" ]; then
            printf '%s\n' "$status"
            return 0
        fi
        sleep 3
    done
    pz_error "guest did not return from the login-verification reboot"
    return 1
}

# Readiness is only claimed for facts that were actually proven. Public DNS
# resolution is not one of them: an offline or filtered network is a legitimate
# guest state, so configured resolvers gate and resolution is reported.
wait_for_guest_ready() {
    local deadline status filter
    filter='.guestLoginVerified == true and .explorerReady == true and .networkReady == true and
            .dnsServersConfigured == true and .exchangeMapped == true and .audioReady == true'
    if [ "$ALLOW_BASIC_GRAPHICS" = 1 ]; then
        filter="$filter and .displayAdapterPresent == true"
    else
        filter="$filter and .graphicsAccelerationVerified == true"
    fi
    deadline=$((SECONDS + READY_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        vm_alive || { pz_error "QEMU exited during guest readiness validation"; return 1; }
        status="$(bash "$GUEST_LOGIN" status --json 2>/dev/null || true)"
        if printf '%s\n' "$status" | jq -e "$filter" >/dev/null 2>&1; then
            printf '%s\n' "$status"
            return 0
        fi
        sleep 3
    done
    pz_error "guest readiness validation timed out"
    return 1
}

install -d -m 0700 "$(dirname "$RECOVERY_LOG")"
: > "$RECOVERY_LOG"
chmod 0600 "$RECOVERY_LOG"

# Prerequisites are proven before anything is copied or written, so a missing
# libguestfs helper costs an error message instead of a backup and a rollback.
bash "$GUEST_LOGIN" repair-preflight --json >/dev/null || {
    bash "$GUEST_LOGIN" repair-preflight >/dev/null 2>&1 || true
    emit preflight false "offline repair prerequisites missing"
    exit 1
}
emit preflight true

repair="$(bash "$GUEST_LOGIN" repair-qga --json)" || exit $?
manifest="$(printf '%s\n' "$repair" | jq -er '.rollbackManifest')" || exit 1
emit backup true "offline backup and QGA repair"
emit reboot-scheduled true

# Headless direct QEMU keeps recovery deterministic and allows this command to
# observe the private QGA/QMP sockets. setsid gives it its own process group so
# cleanup can reach QEMU and swtpm, not just the launcher shell. The normal
# graphical session can attach after --leave-running completes.
setsid bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" launch --raw-qemu --headless \
    >>"$RECOVERY_LOG" 2>&1 &
VM_PID=$!
emit boot true

if ! transport="$(wait_for_repair_reboot)"; then
    emit transport-verified false "rollback manifest: $manifest"
    exit 1
fi
emit transport-verified true

if [ "$MODE" = password ]; then
    printf '%s\n' "$PASSWORD" | bash "$GUEST_LOGIN" apply \
        --mode password --password-stdin --backup-proof "$(jq -r '.backupDisk' "$manifest")" --json >/dev/null
else
    bash "$GUEST_LOGIN" apply \
        --mode auto --backup-proof "$(jq -r '.backupDisk' "$manifest")" --json >/dev/null
fi
unset PASSWORD
emit login-applied true

# A second controlled reboot proves AutoAdminLogon, not merely registry state.
# The pre-reboot boot identity is captured first so the return is provable.
boot_before_login="$(printf '%s\n' "$transport" | jq -r '.lastBootUpTime // ""')"
if [ -z "$boot_before_login" ]; then
    boot_before_login="$(guest_transport_json | jq -r '.lastBootUpTime // ""' 2>/dev/null || true)"
fi
bash "$GUEST_LOGIN" reboot --json >/dev/null
if ! wait_for_boot_change "$boot_before_login" >/dev/null; then
    emit login-reboot false "QGA transport did not return on a new boot"
    exit 1
fi
emit login-reboot true
status="$(wait_for_guest_ready)" || exit $?
emit ready true

disk_check=false
if [ "$LEAVE_RUNNING" = 1 ]; then
    KEEP_VM=1
else
    # Shut the guest down and wait for QEMU and swtpm to actually exit before
    # touching the image; qemu-img check on a live disk proves nothing.
    stop_vm
    if bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" disk-check --json >>"$RECOVERY_LOG" 2>&1; then
        disk_check=true
    else
        emit disk-check false "qemu-img check reported errors after shutdown"
        exit 1
    fi
    emit disk-check true
fi

if [ "$JSON_OUT" = 1 ]; then
    printf '%s\n' "$status" | jq --arg manifest "$manifest" \
        --argjson leaveRunning "$([ "$LEAVE_RUNNING" = 1 ] && echo true || echo false)" \
        --argjson diskCheck "$disk_check" \
        '{success:true,phase:"ready",rollbackManifest:$manifest,leaveRunning:$leaveRunning,
          diskCheckPassed:$diskCheck,
          loggedOnUser,explorerReady,networkReady,dnsReady,dnsServersConfigured,exchangeMapped,
          audioReady,graphicsAdapters,displayAdapterPresent,graphicsDriver,graphicsDriverVersion,
          wddmVersion,basicDisplayAdapterOnly,direct3DReady,graphicsAccelerationVerified,
          lastBootUpTime}'
else
    pz_info "recover complete; guest validated"
fi
