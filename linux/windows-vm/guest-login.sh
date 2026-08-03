#!/usr/bin/env bash
# Manage Windows guest login policy through QEMU Guest Agent without logging secrets.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
# Reuse the framed, request-id-aware QGA transport. provision.sh has no side
# effects when sourced because its dispatcher is guarded by BASH_SOURCE.
source "$PZ_ROOT/linux/windows-vm/provision.sh"

ACTION="${1:-status}"
if [ "$#" -gt 0 ]; then
    shift
fi
RECOVERY_ACTION=""
if [ "$ACTION" = "recovery" ]; then
    RECOVERY_ACTION="${1:-status}"
    [ "$#" -gt 0 ] && shift
fi
CONFIG_FILE="${PZ_WINDOWS_VM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/windows-vm.conf}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
VM_DIR="${PZ_WINDOWS_VM_DIR:-$HOME/VirtualMachines/PhaseZero-Windows}"
DISK_PATH="${PZ_WINDOWS_VM_DISK:-$VM_DIR/phasezero-windows.qcow2}"
OVMF_VARS="${PZ_WINDOWS_VM_OVMF_VARS:-$VM_DIR/OVMF_VARS.fd}"
TPM_DIR="${PZ_WINDOWS_VM_TPM_DIR:-$VM_DIR/tpm}"
RUNTIME_DIR="${PZ_WINDOWS_VM_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/phasezero-windows-vm}"
QGA_SOCKET="${PZ_WINDOWS_VM_QGA_SOCKET:-$RUNTIME_DIR/qga.sock}"
GUEST_USER="${PZ_WINDOWS_VM_GUEST_USER:-phasezero}"
POLICY="${PZ_WINDOWS_VM_GUEST_LOGIN_POLICY:-auto}"
JSON_OUT=0
PASSWORD_STDIN=0
BACKUP_PATH=""
BACKUP_PROOF=""
LOCAL_ONLY=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) POLICY="${2:-}"; shift 2 ;;
        --mode=*) POLICY="${1#*=}"; shift ;;
        --user) GUEST_USER="${2:-}"; shift 2 ;;
        --user=*) GUEST_USER="${1#*=}"; shift ;;
        --socket) QGA_SOCKET="${2:-}"; shift 2 ;;
        --socket=*) QGA_SOCKET="${1#*=}"; shift ;;
        --password-stdin) PASSWORD_STDIN=1; shift ;;
        --backup) BACKUP_PATH="${2:-}"; shift 2 ;;
        --backup=*) BACKUP_PATH="${1#*=}"; shift ;;
        --backup-proof) BACKUP_PROOF="${2:-}"; shift 2 ;;
        --backup-proof=*) BACKUP_PROOF="${1#*=}"; shift ;;
        --local-only) LOCAL_ONLY=1; shift ;;
        --allow-remote) LOCAL_ONLY=0; shift ;;
        --manifest) BACKUP_PATH="${2:-}"; shift 2 ;;
        --manifest=*) BACKUP_PATH="${1#*=}"; shift ;;
        --json) JSON_OUT=1; shift ;;
        *) pz_error "unknown guest-login option: $1"; exit 2 ;;
    esac
done

case "$POLICY" in auto|password) ;; *) pz_error "guest login mode must be auto or password"; exit 2 ;; esac
[[ "$GUEST_USER" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { pz_error "invalid guest user"; exit 2; }

vm_uses_disk() {
    local proc cmd
    for proc in /proc/[0-9]*/cmdline; do
        [ -r "$proc" ] || continue
        cmd="$(tr '\0' ' ' < "$proc" 2>/dev/null || true)"
        [[ "$cmd" == *qemu-system*"$DISK_PATH"* ]] && return 0
    done
    return 1
}

latest_backup_manifest() {
    find "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/guest-login-backups" \
        -mindepth 2 -maxdepth 2 -type f -name manifest.json -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -1 | cut -d' ' -f2-
}

backup_guest() {
    [ -f "$DISK_PATH" ] || { pz_error "guest disk missing: $DISK_PATH"; return 1; }
    ! vm_uses_disk || { pz_error "guest backup requires VM powered off"; return 1; }
    qemu-img check "$DISK_PATH" >/dev/null
    local root stamp dir disk_backup manifest
    root="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/guest-login-backups"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    dir="$root/$stamp"
    install -d -m 0700 "$dir"
    disk_backup="$dir/$(basename "$DISK_PATH")"
    cp --reflink=auto --sparse=always --preserve=mode,timestamps "$DISK_PATH" "$disk_backup"
    [ -f "$OVMF_VARS" ] && cp -a "$OVMF_VARS" "$dir/OVMF_VARS.fd"
    [ -d "$TPM_DIR" ] && cp -a "$TPM_DIR" "$dir/tpm"
    qemu-img check "$disk_backup" >/dev/null
    manifest="$dir/manifest.json"
    jq -n --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg sourceDisk "$DISK_PATH" --arg backupDisk "$disk_backup" \
        --arg ovmfVars "$OVMF_VARS" --arg tpmDir "$TPM_DIR" \
        --argjson sourceInfo "$(qemu-img info --output=json "$DISK_PATH")" \
        '{schemaVersion:1,createdAt:$createdAt,sourceDisk:$sourceDisk,backupDisk:$backupDisk,
          ovmfVars:$ovmfVars,tpmDir:$tpmDir,qemuImageCheck:true,sourceInfo:$sourceInfo}' > "$manifest"
    chmod 0600 "$manifest"
    jq -n --arg backup "$dir" --arg manifest "$manifest" '{success:true,backup:$backup,manifest:$manifest}'
}

restore_guest() {
    local manifest="${BACKUP_PATH:-$(latest_backup_manifest)}"
    [ -d "$manifest" ] && manifest="$manifest/manifest.json"
    [ -f "$manifest" ] || { pz_error "guest-login backup manifest missing"; return 1; }
    ! vm_uses_disk || { pz_error "guest restore requires VM powered off"; return 1; }
    local source backup dir
    source="$(jq -r '.sourceDisk' "$manifest")"
    backup="$(jq -r '.backupDisk' "$manifest")"
    dir="$(dirname "$manifest")"
    [ "$source" = "$DISK_PATH" ] || { pz_error "backup target mismatch"; return 1; }
    case "$TPM_DIR" in
        "$VM_DIR"/*) ;;
        *) pz_error "unsafe TPM restore target refused: $TPM_DIR"; return 1 ;;
    esac
    if [ "$TPM_DIR" = "$VM_DIR" ] || [ "$TPM_DIR" = "/" ]; then
        pz_error "unsafe TPM restore target refused: $TPM_DIR"
        return 1
    fi
    qemu-img check "$backup" >/dev/null
    cp --reflink=auto --sparse=always --preserve=mode,timestamps "$backup" "$DISK_PATH"
    [ -f "$dir/OVMF_VARS.fd" ] && cp -a "$dir/OVMF_VARS.fd" "$OVMF_VARS"
    [ -d "$dir/tpm" ] && { rm -rf "$TPM_DIR"; cp -a "$dir/tpm" "$TPM_DIR"; }
    qemu-img check "$DISK_PATH" >/dev/null
    jq -n --arg restoredFrom "$dir" '{success:true,restoredFrom:$restoredFrom}'
}

powershell_encoded() {
    iconv -f UTF-8 -t UTF-16LE "$PZ_ROOT/linux/windows-vm/guest-login.ps1" | base64 -w0
}

qga_guest_exec_wait() {
    local mode="${1:-status}" input_json="${2:-}" encoded input_b64 request pid response out_data deadline
    encoded="$(powershell_encoded)"
    input_b64="$(printf '%s' "$input_json" | base64 -w0)"
    request="$(printf '%s\n%s\n%s\n%s\n' "$encoded" "$input_b64" "$mode" "$GUEST_USER" | jq -R -s '
        split("\n") as $v |
        {execute:"guest-exec",arguments:{path:"powershell.exe",
          arg:["-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",$v[0]],
          env:[("PZ_GUEST_LOGIN_MODE="+$v[2]),("PZ_GUEST_LOGIN_USER="+$v[3])],
          "input-data":$v[1],"capture-output":true}}')"
    qga_request "$QGA_SOCKET" "$request" || return 1
    pid="$(printf '%s\n' "$QGA_RESPONSE" | jq -r '.return.pid // 0')"
    [ "$pid" -gt 0 ] 2>/dev/null || return 1
    deadline=$((SECONDS + 90))
    while [ "$SECONDS" -lt "$deadline" ]; do
        qga_request "$QGA_SOCKET" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" || true
        response="$QGA_RESPONSE"
        if printf '%s\n' "$response" | jq -e '.return.exited == true' >/dev/null 2>&1; then
            [ "$(printf '%s\n' "$response" | jq -r '.return.exitcode // 1')" -eq 0 ] || return 1
            out_data="$(printf '%s\n' "$response" | jq -r '.return["out-data"] // ""')"
            printf '%s' "$out_data" | base64 -d 2>/dev/null | tr -d '\r' | tail -n 1
            return 0
        fi
        sleep 1
    done
    return 1
}

guest_status() {
    if ! qga_ping "$QGA_SOCKET"; then
        jq -n --arg policy "$POLICY" --arg user "$GUEST_USER" --arg socket "$QGA_SOCKET" \
            '{success:false,available:false,policy:$policy,user:$user,qgaSocket:$socket,guestLoginVerified:false}'
        return 1
    fi
    local result
    result="$(qga_guest_exec_wait status "")" || return 1
    printf '%s\n' "$result" | jq '. + {available:true,guestLoginVerified:(.configured == true and .registryPasswordStored == false)}'
}

recovery_status() {
    if ! qga_ping "$QGA_SOCKET"; then
        jq -n --arg account 'PZ-Recovery' \
            '{success:false,recoveryAccount:$account,recoveryConfigured:false,recoveryEnabled:false,recoveryAdministrator:false,recoveryLocalOnly:true,qgaAvailable:false,qgaServiceHealthy:false,guestLoginVerified:false,error:"qga-unavailable"}'
        return 1
    fi
    local result
    result="$(qga_guest_exec_wait recovery-status "")" || return 1
    printf '%s\n' "$result" | jq '. + {qgaAvailable:true}'
}

recovery_apply() {
    [ "$PASSWORD_STDIN" = "1" ] || { pz_error "recovery apply requires --password-stdin"; return 2; }
    [ -f "$(latest_backup_manifest)" ] || { pz_error "verified guest backup required before recovery mutation"; return 1; }
    qga_ping "$QGA_SOCKET" || { pz_error "QGA unavailable; use repair-qga with VM powered off"; return 1; }
    local password payload result
    IFS= read -r password
    [ -n "$password" ] || { pz_error "empty recovery password refused"; return 2; }
    payload="$(printf '%s\n%s\n' "$password" "$LOCAL_ONLY" | jq -R -s 'split("\n") | {password:.[0],localOnly:(.[1] == "1")}')"
    result="$(qga_guest_exec_wait recovery-apply "$payload")"
    unset password payload
    printf '%s\n' "$result" | jq '. + {qgaAvailable:true}'
}

recovery_toggle() {
    local mode="$1" result
    qga_ping "$QGA_SOCKET" || { pz_error "QGA unavailable"; return 1; }
    result="$(qga_guest_exec_wait "recovery-$mode" "")" || return 1
    printf '%s\n' "$result" | jq '. + {qgaAvailable:true}'
}

repair_qga() {
    # Offline repair needs a powered-off image and a verified rollback point.
    # Refuse rather than editing SAM/registry hives directly or retaining a
    # password on the host.  The one-shot injector is intentionally available
    # only when libguestfs can guarantee its temporary appliance cleanup.
    ! vm_uses_disk || { pz_error "repair-qga requires VM powered off"; return 1; }
    [ -f "$(latest_backup_manifest)" ] || { pz_error "verified backup required before offline repair"; return 1; }
    qemu-img check "$DISK_PATH" >/dev/null
    command -v guestfish >/dev/null 2>&1 || { pz_error "libguestfs/guestfish unavailable; offline repair refused"; return 1; }
    pz_error "offline one-shot repair requires recovery password input and is not yet authorized by this command"
    return 1
}

guest_power() {
    local mode="$1"
    qga_ping "$QGA_SOCKET" || { pz_error "QGA unavailable: guest power action refused"; return 1; }
    qga_channel_open "$QGA_SOCKET" || return 1
    printf '{"execute":"guest-shutdown","arguments":{"mode":"%s"}}\n' "$mode" >&"$QGA_WRITE_FD"
    jq -n --arg action "$mode" '{success:true,accepted:true,action:$action}'
}

apply_policy() {
    if [ -n "$BACKUP_PROOF" ]; then
        if [ ! -f "$BACKUP_PROOF" ] || ! qemu-img check "$BACKUP_PROOF" >/dev/null; then
            pz_error "verified provision snapshot required before login-policy mutation"
            return 1
        fi
    else
        [ -f "$(latest_backup_manifest)" ] || { pz_error "verified guest backup required before login-policy mutation"; return 1; }
    fi
    qga_ping "$QGA_SOCKET" || { pz_error "QGA unavailable: start the VM first"; return 1; }
    local password payload result
    if [ "$POLICY" = "password" ]; then
        [ "$PASSWORD_STDIN" = "1" ] || { pz_error "password mode requires --password-stdin"; return 2; }
        IFS= read -r password
        [ -n "$password" ] || { pz_error "empty guest password refused"; return 2; }
    else
        password="$(openssl rand -base64 36 | tr -d '\n')"
    fi
    payload="$(printf '%s\n%s\n' "$GUEST_USER" "$password" | jq -R -s 'split("\n") | {username:.[0],password:.[1]}')"
    result="$(qga_guest_exec_wait "$POLICY" "$payload")"
    unset password payload
    printf '%s\n' "$result" | jq --arg requestedPolicy "$POLICY" \
        '. + {requestedPolicy:$requestedPolicy,guestLoginVerified:(.configured == true and .registryPasswordStored == false)}'
}

set +e
case "$ACTION" in
    status) guest_status ;;
    backup) backup_guest ;;
    restore|rollback) restore_guest ;;
    apply) apply_policy ;;
    recovery)
        case "$RECOVERY_ACTION" in
            status) recovery_status ;;
            apply|rotate) recovery_apply ;;
            enable|disable) recovery_toggle "$RECOVERY_ACTION" ;;
            *) pz_error "usage: guest-login recovery (status|apply|rotate|enable|disable)"; exit 2 ;;
        esac ;;
    repair-qga) repair_qga ;;
    rollback) restore_guest ;;
    reboot) guest_power reboot ;;
    shutdown) guest_power powerdown ;;
    *) pz_error "usage: pz windows-vm guest-login (status|backup|apply|recovery|repair-qga|rollback|restore|reboot|shutdown)"; exit 2 ;;
esac
rc=$?
set -e
qga_channel_close
exit "$rc"
