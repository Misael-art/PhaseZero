#!/usr/bin/env bash
# Hermetic contract checks for recovery-account secret handling.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS="$ROOT/linux/windows-vm/guest-login.ps1"
SH="$ROOT/linux/windows-vm/guest-login.sh"
RECOVER="$ROOT/linux/windows-vm/recover.sh"

bash -n "$SH" "$RECOVER"
grep -Fq "\$recoveryUser = 'PZ-Recovery'" "$PS"
grep -Fq "Get-LocalGroup -SID 'S-1-5-32-544'" "$PS"
# Literal PowerShell contract.
# shellcheck disable=SC2016
grep -Fq 'Add-LocalGroupMember -Group $adminGroup' "$PS"
grep -Fq 'SeDenyNetworkLogonRight' "$PS"
grep -Fq 'SeDenyRemoteInteractiveLogonRight' "$PS"
grep -Fq "Remove-ItemProperty -Path \$winlogon -Name DefaultPassword" "$PS"
grep -Fq 'recovery apply requires --password-stdin' "$SH"
grep -Fq 'QGA unavailable; use repair-qga with VM powered off' "$SH"
grep -Fq 'verified guest backup required before guest mutation' "$SH"
grep -Fq 'repair-qga requires VM powered off' "$SH"
# Literal shell source contract.
# shellcheck disable=SC2016
grep -Fq 'virt-customize -a "$DISK_PATH"' "$SH"
# Literal shell source contract.
# shellcheck disable=SC2016
grep -Fq -- '--firstboot "$OFFLINE_WORK/qga-offline-repair.bat"' "$SH"
grep -Fq -- 'qga-offline-repair.ps1:/ProgramData/PhaseZeroOffline/qga-offline-repair.ps1' "$SH"
grep -Fq 'automatic rollback failed' "$SH"
grep -Fq 'LIBGUESTFS_CACHEDIR="$guestfs_cache"' "$SH"
grep -Fq 'at least 3 GiB free space required for offline QGA repair' "$SH"
grep -Fq 'guest-login-diagnostics' "$SH"
# Literal PowerShell contract.
# shellcheck disable=SC2016
grep -Fq 'Remove-Item -LiteralPath $payloadDir' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Join-Path \$env:SystemRoot 'System32'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Join-Path \$env:SystemRoot 'Sysnative'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'Test-Path -LiteralPath $sysnative' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq '& $pnputil /add-driver' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "\$trustedVirtioSha256 = '__PZ_VIRTIO_SHA256__'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'virtio media payload hash mismatch' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'QGA MSI signature hash mismatch' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Write-RepairStatus \$true 'driver-installed'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Write-RepairStatus \$true 'qga-installed'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Write-RepairStatus \$true 'reboot-scheduled'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'QGA transport unavailable after guest reboot' "$SH"
grep -Fq 'transport-verified' "$SH"
grep -Fq 'transport:"qmp"' "$SH"
grep -Fq 'Set-ExchangeMappingTask' "$PS"
grep -Fq "PhaseZero-MapExchange" "$PS"
grep -Fq '\\10.0.2.4\qemu' "$PS"
grep -Fq 'install -d -m 0700 "$RUNTIME_DIR" "$STATE_DIR"' "$ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq 'wait_for_transport_cycle' "$RECOVER"
grep -Fq 'transport-verify --json' "$RECOVER"
grep -Fq 'guest-login.sh" apply' "$RECOVER"
grep -Fq -- '--leave-running' "$RECOVER"
if grep -Eq -- 'PASSWORD=.*(echo|log|arg)' "$RECOVER"; then
    echo 'recovery orchestration may leak password' >&2
    exit 1
fi
grep -Fq 's/__PZ_VIRTIO_SHA256__/${virtio_sha_expected,,}/g' "$SH"
if grep -Eq -- '--arg (password|secret)|PZ_RECOVERY_PASSWORD|recovery.*password.*=' "$SH"; then
    echo 'recovery secret leaked through shell argv/environment contract' >&2
    exit 1
fi

offline_fixture() {
    local dir="$1" mode="$2"
    local trusted_sha
    mkdir -p "$dir/bin" "$dir/vm/tpm" "$dir/state" "$dir/config"
    printf 'original-qcow2\n' > "$dir/vm/phasezero-windows.qcow2"
    printf 'ovmf\n' > "$dir/vm/OVMF_VARS.fd"
    printf 'tpm\n' > "$dir/vm/tpm/state"
    printf 'virtio\n' > "$dir/virtio-win.iso"
    # Writing a fake executable verbatim.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$1" in' \
        '  check) [ -f "$2" ] ;;' \
        '  info) printf '\''{"format":"qcow2","virtual-size":4096}\n'\'' ;;' \
        '  *) exit 2 ;;' \
        'esac' > "$dir/bin/qemu-img"
    # Writing a fake executable verbatim.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf '\''%s\n'\'' "$@" > "$PZ_TEST_VIRT_ARGS"' \
        'if [ "$PZ_TEST_VIRT_MODE" = fail ]; then' \
        '  printf '\''mutated-before-failure\n'\'' > "$PZ_TEST_DISK"' \
        '  exit 42' \
        'fi' > "$dir/bin/virt-customize"
    chmod 0755 "$dir/bin/qemu-img" "$dir/bin/virt-customize"
    trusted_sha="$(sha256sum "$dir/virtio-win.iso" | cut -d' ' -f1)"
    [ "$mode" != hash-fail ] || trusted_sha="$(printf '0%.0s' {1..64})"
    PZ_TEST_VIRT_MODE="$mode" PZ_TEST_VIRT_ARGS="$dir/virt.args" \
    PZ_TEST_DISK="$dir/vm/phasezero-windows.qcow2" \
    PZ_WINDOWS_VM_DIR="$dir/vm" PZ_WINDOWS_VM_DISK="$dir/vm/phasezero-windows.qcow2" \
    PZ_WINDOWS_VM_OVMF_VARS="$dir/vm/OVMF_VARS.fd" PZ_WINDOWS_VM_TPM_DIR="$dir/vm/tpm" \
    PZ_WINDOWS_VM_VIRTIO_ISO="$dir/virtio-win.iso" \
    PZ_WINDOWS_VM_VIRTIO_SHA256="$trusted_sha" \
    XDG_STATE_HOME="$dir/state" XDG_CONFIG_HOME="$dir/config" XDG_RUNTIME_DIR=/tmp \
    HOME="$dir/home" PATH="$dir/bin:$PATH" \
        bash "$SH" repair-qga --json
}

# Use persistent /tmp, not Codex's per-user runtime tmpfs: repair-qga
# deliberately requires 3 GiB for the libguestfs appliance.
tmp_success="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
success_json="$(offline_fixture "$tmp_success" success)"
printf '%s\n' "$success_json" | jq -e \
    '.success == true and .state == "pending-guest-boot" and .phase == "reboot-scheduled" and
     .guestRebootRequired == true and
     .qgaAvailable == false and (.rollbackManifest | type == "string")' >/dev/null
grep -Fxq -- '--firstboot' "$tmp_success/virt.args"
grep -Fq -- 'qga-offline-repair.bat' "$tmp_success/virt.args"
grep -Fq -- 'qga-offline-repair.ps1' "$tmp_success/virt.args"
manifest="$(printf '%s\n' "$success_json" | jq -r '.rollbackManifest')"
[ -f "$manifest" ]
jq -e '.qemuImageCheck == true and .sourceDisk and .backupDisk' "$manifest" >/dev/null
rm -rf -- "$tmp_success"

tmp_failure="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
set +e
failure_output="$(offline_fixture "$tmp_failure" fail 2>&1)"
failure_rc=$?
set -e
[ "$failure_rc" -ne 0 ]
grep -Fxq 'original-qcow2' "$tmp_failure/vm/phasezero-windows.qcow2"
if grep -Fq 'mutated-before-failure' "$tmp_failure/vm/phasezero-windows.qcow2"; then
    exit 1
fi
grep -Fq 'disk rollback attempted' <<<"$failure_output"
rm -rf -- "$tmp_failure"

tmp_hash="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
set +e
hash_output="$(offline_fixture "$tmp_hash" hash-fail 2>&1)"
hash_rc=$?
set -e
[ "$hash_rc" -ne 0 ]
grep -Fq 'SHA-256 mismatch' <<<"$hash_output"
[ ! -e "$tmp_hash/virt.args" ]
[ ! -d "$tmp_hash/state/phasezero/windows-vm/guest-login-backups" ]
rm -rf -- "$tmp_hash"

echo 'guest recovery secret and local-only contracts ok'
