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
PASSWORD=""
VM_PID=""
RECOVERY_LOG="$PZ_STATE/windows-vm/recover.log"

usage() {
    pz_error "usage: pz windows-vm recover --mode auto|password [--password-stdin] [--leave-running] [--json]"
}

cleanup() {
    unset PASSWORD
}
trap cleanup EXIT INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --mode=*) MODE="${1#*=}"; shift ;;
        --password-stdin) PASSWORD_STDIN=1; shift ;;
        --leave-running) LEAVE_RUNNING=1; shift ;;
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

wait_for_transport_cycle() {
    local deadline first_seen=0 lost_after_seen=0
    deadline=$((SECONDS + 360))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if bash "$PZ_ROOT/linux/windows-vm/guest-login.sh" transport-verify --json >/dev/null 2>&1; then
            if [ "$first_seen" = 1 ] && [ "$lost_after_seen" = 1 ]; then
                return 0
            fi
            first_seen=1
        elif [ "$first_seen" = 1 ]; then
            lost_after_seen=1
        fi
        sleep 2
    done
    pz_error "QGA transport was not proven across the scheduled guest reboot"
    return 1
}

wait_for_guest_ready() {
    local deadline status
    deadline=$((SECONDS + 180))
    while [ "$SECONDS" -lt "$deadline" ]; do
        status="$(bash "$PZ_ROOT/linux/windows-vm/guest-login.sh" status --json 2>/dev/null || true)"
        if printf '%s\n' "$status" | jq -e \
            '.guestLoginVerified == true and .explorerReady == true and .networkReady == true and
             .dnsReady == true and .exchangeMapped == true and .audioReady == true and .graphicsReady == true' \
            >/dev/null 2>&1; then
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

emit backup true "offline backup and QGA repair"
repair="$(bash "$PZ_ROOT/linux/windows-vm/guest-login.sh" repair-qga --json)" || exit $?
manifest="$(printf '%s\n' "$repair" | jq -er '.rollbackManifest')" || exit 1
emit reboot-scheduled true

# Headless direct QEMU keeps recovery deterministic and allows this command to
# observe the private QGA/QMP sockets. The normal graphical session can attach
# after --leave-running completes.
bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" launch --raw-qemu --headless >>"$RECOVERY_LOG" 2>&1 &
VM_PID=$!
emit boot true

if ! wait_for_transport_cycle; then
    emit transport-verified false "rollback manifest: $manifest"
    exit 1
fi
emit transport-verified true

if [ "$MODE" = password ]; then
    printf '%s\n' "$PASSWORD" | bash "$PZ_ROOT/linux/windows-vm/guest-login.sh" apply \
        --mode password --password-stdin --backup-proof "$(jq -r '.backupDisk' "$manifest")" --json >/dev/null
else
    bash "$PZ_ROOT/linux/windows-vm/guest-login.sh" apply \
        --mode auto --backup-proof "$(jq -r '.backupDisk' "$manifest")" --json >/dev/null
fi
unset PASSWORD
emit login-applied true

# A second controlled reboot proves AutoAdminLogon, not merely registry state.
bash "$PZ_ROOT/linux/windows-vm/guest-login.sh" reboot --json >/dev/null
if ! wait_for_transport_cycle; then
    emit login-reboot false "QGA transport did not return"
    exit 1
fi
status="$(wait_for_guest_ready)" || exit $?

if [ "$LEAVE_RUNNING" != 1 ]; then
    bash "$PZ_ROOT/linux/windows-vm/guest-login.sh" shutdown --json >/dev/null || true
fi
if [ "$JSON_OUT" = 1 ]; then
    printf '%s\n' "$status" | jq --arg manifest "$manifest" --argjson leaveRunning "$([ "$LEAVE_RUNNING" = 1 ] && echo true || echo false)" \
        '{success:true,phase:"ready",rollbackManifest:$manifest,leaveRunning:$leaveRunning,
          loggedOnUser,explorerReady,networkReady,dnsReady,exchangeMapped,audioReady,graphicsAdapters,graphicsReady}'
else
    pz_info "recover complete; guest validated"
fi
