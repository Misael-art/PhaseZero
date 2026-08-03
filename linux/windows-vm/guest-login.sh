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
OFFLINE_WORK=""
OFFLINE_LOCK_FD=""

cleanup_offline_work() {
    if [ -n "${OFFLINE_WORK:-}" ] && [ -d "$OFFLINE_WORK" ]; then
        rm -rf -- "$OFFLINE_WORK"
    fi
    OFFLINE_WORK=""
}
trap cleanup_offline_work EXIT INT TERM

acquire_guest_lock() {
    [ -z "${OFFLINE_LOCK_FD:-}" ] || return 0
    local lock_file="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/guest-login.lock"
    install -d -m 0700 "$(dirname "$lock_file")" || return 1
    touch "$lock_file" || return 1
    chmod 0600 "$lock_file" || return 1
    exec {OFFLINE_LOCK_FD}<>"$lock_file" || return 1
    flock -n "$OFFLINE_LOCK_FD" || {
        pz_error "another guest-login operation is active"
        return 1
    }
}

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
    local proc cmd disk_real
    disk_real="$(realpath -e "$DISK_PATH" 2>/dev/null || printf '%s' "$DISK_PATH")"
    for proc in /proc/[0-9]*/cmdline; do
        [ -r "$proc" ] || continue
        cmd="$(tr '\0' ' ' < "$proc" 2>/dev/null || true)"
        if [[ "$cmd" == *qemu-system* || "$cmd" == *qemu-kvm* ]] && \
            { [[ "$cmd" == *"$DISK_PATH"* ]] || [[ "$cmd" == *"$disk_real"* ]]; }; then
            return 0
        fi
    done
    return 1
}

validate_managed_vm_paths() {
    local vm_real disk_real ovmf_real tpm_real
    vm_real="$(realpath -e "$VM_DIR" 2>/dev/null)" || { pz_error "managed VM directory missing"; return 1; }
    [ "$vm_real" != "/" ] || { pz_error "unsafe managed VM directory"; return 1; }
    disk_real="$(realpath -e "$DISK_PATH" 2>/dev/null)" || { pz_error "managed guest disk missing"; return 1; }
    case "$disk_real" in "$vm_real"/*) ;; *) pz_error "guest disk outside managed VM directory"; return 1 ;; esac
    if [ -e "$OVMF_VARS" ]; then
        ovmf_real="$(realpath -e "$OVMF_VARS" 2>/dev/null)" || return 1
        case "$ovmf_real" in "$vm_real"/*) ;; *) pz_error "OVMF state outside managed VM directory"; return 1 ;; esac
    fi
    if [ -e "$TPM_DIR" ]; then
        tpm_real="$(realpath -e "$TPM_DIR" 2>/dev/null)" || return 1
        case "$tpm_real" in "$vm_real"/*) ;; *) pz_error "TPM state outside managed VM directory"; return 1 ;; esac
    fi
}

latest_backup_manifest() {
    find "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/guest-login-backups" \
        -mindepth 2 -maxdepth 2 -type f -name manifest.json -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -1 | cut -d' ' -f2-
}

backup_guest() {
    acquire_guest_lock || return 1
    [ -f "$DISK_PATH" ] || { pz_error "guest disk missing: $DISK_PATH"; return 1; }
    validate_managed_vm_paths || return 1
    ! vm_uses_disk || { pz_error "guest backup requires VM powered off"; return 1; }
    qemu-img check "$DISK_PATH" >/dev/null || { pz_error "guest disk integrity check failed"; return 1; }
    local root stamp dir disk_backup manifest manifest_tmp source_info
    root="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/guest-login-backups"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 0700 "$root" || return 1
    dir="$(mktemp -d "$root/${stamp}.XXXXXX")" || return 1
    chmod 0700 "$dir" || { rm -rf -- "$dir"; return 1; }
    disk_backup="$dir/$(basename "$DISK_PATH")"
    cp --reflink=auto --sparse=always --preserve=mode,timestamps "$DISK_PATH" "$disk_backup" || {
        rm -rf -- "$dir"; return 1;
    }
    if [ -f "$OVMF_VARS" ] && ! cp -a "$OVMF_VARS" "$dir/OVMF_VARS.fd"; then
        rm -rf -- "$dir"; return 1
    fi
    if [ -d "$TPM_DIR" ] && ! cp -a "$TPM_DIR" "$dir/tpm"; then
        rm -rf -- "$dir"; return 1
    fi
    qemu-img check "$disk_backup" >/dev/null || { rm -rf -- "$dir"; return 1; }
    source_info="$(qemu-img info --output=json "$DISK_PATH")" || { rm -rf -- "$dir"; return 1; }
    manifest="$dir/manifest.json"
    manifest_tmp="$dir/.manifest.json.tmp"
    jq -n --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg sourceDisk "$DISK_PATH" --arg backupDisk "$disk_backup" \
        --arg ovmfVars "$OVMF_VARS" --arg tpmDir "$TPM_DIR" \
        --argjson sourceInfo "$source_info" \
        '{schemaVersion:1,createdAt:$createdAt,sourceDisk:$sourceDisk,backupDisk:$backupDisk,
          ovmfVars:$ovmfVars,tpmDir:$tpmDir,qemuImageCheck:true,sourceInfo:$sourceInfo}' > "$manifest_tmp" || {
        rm -rf -- "$dir"; return 1;
    }
    if ! chmod 0600 "$manifest_tmp" || ! mv "$manifest_tmp" "$manifest"; then
        rm -rf -- "$dir"; return 1;
    fi
    jq -n --arg backup "$dir" --arg manifest "$manifest" '{success:true,backup:$backup,manifest:$manifest}'
}

restore_guest() {
    acquire_guest_lock || return 1
    local manifest="${BACKUP_PATH:-$(latest_backup_manifest)}"
    [ -d "$manifest" ] && manifest="$manifest/manifest.json"
    [ -f "$manifest" ] || { pz_error "guest-login backup manifest missing"; return 1; }
    validate_managed_vm_paths || return 1
    ! vm_uses_disk || { pz_error "guest restore requires VM powered off"; return 1; }
    local source backup dir backup_root manifest_real backup_real restore_tmp ovmf_tmp tpm_tmp tpm_old
    backup_root="$(realpath -m "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/guest-login-backups")"
    manifest_real="$(realpath -e "$manifest" 2>/dev/null)" || return 1
    case "$manifest_real" in "$backup_root"/*/manifest.json) ;; *) pz_error "unsafe backup manifest refused"; return 1 ;; esac
    source="$(jq -er '.sourceDisk' "$manifest_real")" || return 1
    backup="$(jq -er '.backupDisk' "$manifest_real")" || return 1
    dir="$(dirname "$manifest_real")"
    [ "$source" = "$DISK_PATH" ] || { pz_error "backup target mismatch"; return 1; }
    backup_real="$(realpath -e "$backup" 2>/dev/null)" || return 1
    case "$backup_real" in "$dir"/*) ;; *) pz_error "unsafe backup disk path refused"; return 1 ;; esac
    qemu-img check "$backup_real" >/dev/null || return 1
    restore_tmp="$(mktemp "$VM_DIR/.phasezero-disk-restore.XXXXXX")" || return 1
    cp --reflink=auto --sparse=always --preserve=mode,timestamps "$backup_real" "$restore_tmp" || {
        rm -f -- "$restore_tmp"; return 1;
    }
    qemu-img check "$restore_tmp" >/dev/null || { rm -f -- "$restore_tmp"; return 1; }
    if [ -f "$dir/OVMF_VARS.fd" ]; then
        ovmf_tmp="$(mktemp "$VM_DIR/.phasezero-ovmf-restore.XXXXXX")" || { rm -f -- "$restore_tmp"; return 1; }
        cp -a "$dir/OVMF_VARS.fd" "$ovmf_tmp" || { rm -f -- "$restore_tmp" "$ovmf_tmp"; return 1; }
    fi
    if [ -d "$dir/tpm" ]; then
        tpm_tmp="$(mktemp -d "$VM_DIR/.phasezero-tpm-restore.XXXXXX")" || { rm -f -- "$restore_tmp" "${ovmf_tmp:-}"; return 1; }
        cp -a "$dir/tpm/." "$tpm_tmp/" || { rm -f -- "$restore_tmp" "${ovmf_tmp:-}"; rm -rf -- "$tpm_tmp"; return 1; }
    fi
    mv -f "$restore_tmp" "$DISK_PATH" || return 1
    [ -z "${ovmf_tmp:-}" ] || mv -f "$ovmf_tmp" "$OVMF_VARS" || return 1
    if [ -n "${tpm_tmp:-}" ]; then
        tpm_old="$VM_DIR/.phasezero-tpm-old.$$"
        [ ! -e "$tpm_old" ] || { pz_error "temporary TPM restore path collision"; return 1; }
        [ ! -e "$TPM_DIR" ] || mv "$TPM_DIR" "$tpm_old" || return 1
        if ! mv "$tpm_tmp" "$TPM_DIR"; then
            [ ! -e "$tpm_old" ] || mv "$tpm_old" "$TPM_DIR"
            return 1
        fi
        [ ! -e "$tpm_old" ] || rm -rf -- "$tpm_old"
    fi
    qemu-img check "$DISK_PATH" >/dev/null || return 1
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
        jq -n --arg policy "$POLICY" \
            '{guestLoginPolicy:$policy,guestLoginVerified:false,qgaAvailable:false,
              qgaServiceHealthy:false,lastVerifiedAt:null,error:"qga-unavailable"}'
        return 1
    fi
    local result
    result="$(qga_guest_exec_wait status "")" || return 1
    printf '%s\n' "$result" | jq '{guestLoginPolicy:.policy,
        guestLoginVerified:(.configured == true and .registryPasswordStored == false),
        qgaAvailable:true,qgaServiceHealthy:true,lastVerifiedAt,error:null}'
}

recovery_status() {
    if ! qga_ping "$QGA_SOCKET"; then
        jq -n --arg account 'PZ-Recovery' \
            '{recoveryAccount:$account,recoveryConfigured:false,recoveryEnabled:false,recoveryAdministrator:false,recoveryLocalOnly:true,qgaAvailable:false,qgaServiceHealthy:false,lastVerifiedAt:null,error:"qga-unavailable"}'
        return 1
    fi
    local result
    result="$(qga_guest_exec_wait recovery-status "")" || return 1
    printf '%s\n' "$result" | jq '{recoveryAccount,recoveryConfigured,recoveryEnabled,
        recoveryAdministrator,recoveryLocalOnly,qgaServiceHealthy,lastVerifiedAt,
        qgaAvailable:true,error:null}'
}

verified_backup_required() {
    if [ -n "$BACKUP_PROOF" ]; then
        if [ ! -f "$BACKUP_PROOF" ] || ! qemu-img check "$BACKUP_PROOF" >/dev/null; then
            pz_error "verified provision snapshot required before guest mutation"
            return 1
        fi
        return 0
    fi
    [ -f "$(latest_backup_manifest)" ] || {
        pz_error "verified guest backup required before guest mutation"
        return 1
    }
}

recovery_apply() {
    acquire_guest_lock || return 1
    [ "$PASSWORD_STDIN" = "1" ] || { pz_error "recovery apply requires --password-stdin"; return 2; }
    verified_backup_required || return 1
    qga_ping "$QGA_SOCKET" || { pz_error "QGA unavailable; use repair-qga with VM powered off"; return 1; }
    local password payload result
    IFS= read -r password
    [ -n "$password" ] || { pz_error "empty recovery password refused"; return 2; }
    if [ "${#password}" -lt 14 ] || [[ ! "$password" =~ [A-Z] ]] \
        || [[ ! "$password" =~ [a-z] ]] || [[ ! "$password" =~ [0-9] ]] \
        || [[ ! "$password" =~ [[:punct:]] ]]; then
        unset password
        pz_error "recovery password must have 14+ chars, upper, lower, number and symbol"
        return 2
    fi
    payload="$(printf '%s\n%s\n' "$password" "$LOCAL_ONLY" | jq -R -s 'split("\n") | {password:.[0],localOnly:(.[1] == "1")}')"
    result="$(qga_guest_exec_wait recovery-apply "$payload")"
    unset password payload
    printf '%s\n' "$result" | jq '{recoveryAccount,recoveryConfigured,recoveryEnabled,
        recoveryAdministrator,recoveryLocalOnly,qgaServiceHealthy,lastVerifiedAt,
        qgaAvailable:true,error:null}'
}

recovery_toggle() {
    local mode="$1" result
    acquire_guest_lock || return 1
    qga_ping "$QGA_SOCKET" || { pz_error "QGA unavailable"; return 1; }
    result="$(qga_guest_exec_wait "recovery-$mode" "")" || return 1
    printf '%s\n' "$result" | jq '{recoveryAccount,recoveryConfigured,recoveryEnabled,
        recoveryAdministrator,recoveryLocalOnly,qgaServiceHealthy,lastVerifiedAt,
        qgaAvailable:true,error:null}'
}

repair_qga() {
    # Offline repair needs a powered-off image and a verified rollback point.
    # Refuse rather than editing SAM/registry hives directly or retaining a
    # password on the host.  The one-shot injector is intentionally available
    # only when libguestfs can guarantee its temporary appliance cleanup.
    ! vm_uses_disk || { pz_error "repair-qga requires VM powered off"; return 1; }
    qemu-img check "$DISK_PATH" >/dev/null
    command -v virt-customize >/dev/null 2>&1 || { pz_error "libguestfs/virt-customize unavailable; offline repair refused"; return 1; }
    local virtio_iso="${PZ_WINDOWS_VM_VIRTIO_ISO:-}" virtio_sha_expected virtio_sha_actual
    local backup_json manifest runtime_base guestfs_root guestfs_tmp guestfs_cache
    local guestfs_avail_kb diagnostic_root diagnostic rc
    for candidate in "$virtio_iso" "$VM_DIR/virtio-win.iso" \
        "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/vm/virtio-win.iso"; do
        if [ -n "$candidate" ] && [ -r "$candidate" ]; then virtio_iso="$candidate"; break; fi
    done
    if [ -z "$virtio_iso" ] || [ ! -r "$virtio_iso" ]; then
        pz_error "verified virtio-win.iso required for offline QGA repair"
        return 1
    fi
    virtio_sha_expected="${PZ_WINDOWS_VM_VIRTIO_SHA256:-e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331}"
    [[ "$virtio_sha_expected" =~ ^[a-fA-F0-9]{64}$ ]] || { pz_error "invalid trusted virtio-win SHA-256"; return 1; }
    virtio_sha_actual="$(sha256sum "$virtio_iso" | cut -d' ' -f1)"
    [ "${virtio_sha_actual,,}" = "${virtio_sha_expected,,}" ] || {
        pz_error "virtio-win SHA-256 mismatch; offline repair refused"
        return 1
    }
    runtime_base="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    case "$runtime_base" in "/run/user/$(id -u)"|"/tmp") ;; *) pz_error "unsafe offline repair tmpfs root"; return 1 ;; esac
    if [ ! -d "$runtime_base" ] || [ ! -w "$runtime_base" ]; then
        pz_error "writable tmpfs runtime required"
        return 1
    fi
    OFFLINE_WORK="$(mktemp -d "$runtime_base/phasezero-qga-repair.XXXXXX")"
    chmod 0700 "$OFFLINE_WORK"
    # libguestfs inherits TMPDIR.  Desktop launchers often point it at the
    # per-user runtime tmpfs, which is too small for supermin's appliance.
    # Keep its large, non-secret work/cache on the user's persistent state
    # volume instead; never fall back to a shared directory.
    guestfs_root="$PZ_STATE/windows-vm/libguestfs"
    guestfs_tmp="$guestfs_root/tmp"
    guestfs_cache="$guestfs_root/cache"
    install -d -m 0700 "$guestfs_tmp" "$guestfs_cache" || {
        pz_error "private libguestfs workspace unavailable"
        return 1
    }
    guestfs_avail_kb="$(df -Pk "$guestfs_root" | awk 'NR == 2 { print $4 }')"
    [[ "$guestfs_avail_kb" =~ ^[0-9]+$ ]] && [ "$guestfs_avail_kb" -ge 3145728 ] || {
        pz_error "at least 3 GiB free space required for offline QGA repair"
        return 1
    }
    acquire_guest_lock || return 1
    backup_json="$(backup_guest)" || return 1
    manifest="$(printf '%s\n' "$backup_json" | jq -er '.manifest')" || return 1
    cp "$PZ_ROOT/linux/windows-vm/qga-offline-repair.ps1" "$OFFLINE_WORK/qga-offline-repair.ps1"
    chmod 0600 "$OFFLINE_WORK/qga-offline-repair.ps1"
    set +e
    TMPDIR="$guestfs_tmp" LIBGUESTFS_CACHEDIR="$guestfs_cache" \
        timeout --signal=TERM --kill-after=20s 10m virt-customize -a "$DISK_PATH" \
        --mkdir /ProgramData/PhaseZeroOffline \
        --upload "$virtio_iso:/ProgramData/PhaseZeroOffline/virtio-win.iso" \
        --firstboot "$OFFLINE_WORK/qga-offline-repair.ps1" >/dev/null 2>"$OFFLINE_WORK/virt-customize.err"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        diagnostic_root="$PZ_STATE/windows-vm/guest-login-diagnostics"
        install -d -m 0700 "$diagnostic_root" || diagnostic_root=""
        diagnostic=""
        if [ -n "$diagnostic_root" ]; then
            diagnostic="$(mktemp "$diagnostic_root/qga-offline-repair.XXXXXX.log")"
            chmod 0600 "$diagnostic"
            tail -n 80 "$OFFLINE_WORK/virt-customize.err" > "$diagnostic" || true
        fi
        BACKUP_PATH="$manifest"
        restore_guest >/dev/null || pz_error "automatic rollback failed; use --manifest $manifest"
        pz_error "offline QGA repair failed; disk rollback attempted${diagnostic:+; diagnostic: $diagnostic}"
        return 1
    fi
    cleanup_offline_work
    jq -n --arg manifest "$manifest" \
        '{success:true,state:"pending-guest-boot",qgaAvailable:false,qgaServiceHealthy:false,rollbackManifest:$manifest,nextAction:"boot guest once, then run guest-login recovery apply --password-stdin"}'
}

guest_power() {
    local mode="$1"
    acquire_guest_lock || return 1
    qga_ping "$QGA_SOCKET" || { pz_error "QGA unavailable: guest power action refused"; return 1; }
    qga_channel_open "$QGA_SOCKET" || return 1
    printf '{"execute":"guest-shutdown","arguments":{"mode":"%s"}}\n' "$mode" >&"$QGA_WRITE_FD"
    jq -n --arg action "$mode" '{success:true,accepted:true,action:$action}'
}

apply_policy() {
    acquire_guest_lock || return 1
    verified_backup_required || return 1
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
    printf '%s\n' "$result" | jq '{guestLoginPolicy:.policy,
        guestLoginVerified:(.configured == true and .registryPasswordStored == false),
        qgaAvailable:true,qgaServiceHealthy:true,lastVerifiedAt,error:null}'
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
    reboot) guest_power reboot ;;
    shutdown) guest_power powerdown ;;
    *) pz_error "usage: pz windows-vm guest-login (status|backup|apply|recovery|repair-qga|rollback|restore|reboot|shutdown)"; exit 2 ;;
esac
rc=$?
set -e
qga_channel_close
exit "$rc"
