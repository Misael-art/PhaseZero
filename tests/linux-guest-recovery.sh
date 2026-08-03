#!/usr/bin/env bash
# Hermetic contract checks for recovery-account secret handling.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS="$ROOT/linux/windows-vm/guest-login.ps1"
SH="$ROOT/linux/windows-vm/guest-login.sh"

bash -n "$SH"
grep -Fq "\$recoveryUser = 'PZ-Recovery'" "$PS"
grep -Fq "Add-LocalGroupMember -Group 'Administrators'" "$PS"
grep -Fq 'SeDenyNetworkLogonRight' "$PS"
grep -Fq 'SeDenyRemoteInteractiveLogonRight' "$PS"
grep -Fq "Remove-ItemProperty -Path \$winlogon -Name DefaultPassword" "$PS"
grep -Fq 'recovery apply requires --password-stdin' "$SH"
grep -Fq 'QGA unavailable; use repair-qga with VM powered off' "$SH"
grep -Fq 'verified guest backup required before recovery mutation' "$SH"
grep -Fq 'repair-qga requires VM powered off' "$SH"
if grep -Eq -- '--arg (password|secret)|PZ_RECOVERY_PASSWORD|recovery.*password.*=' "$SH"; then
    echo 'recovery secret leaked through shell argv/environment contract' >&2
    exit 1
fi
echo 'guest recovery secret and local-only contracts ok'
