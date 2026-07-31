#!/usr/bin/env bash
# Support bundle must remain private, clean staging, and redact user secrets.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$TMP_ROOT/state"
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/phasezero" "$XDG_STATE_HOME/phasezero/windows-vm" "$TMPDIR"

fake_secret='sk-phasezero-support-bundle-test-secret-1234567890'
printf 'export OPENAI_API_KEY=%s\n' "$fake_secret" > "$HOME/.bashrc"
printf 'PZ_WINDOWS_VM_PASSWORD=%s\n' "$fake_secret" > "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
printf 'Authorization: Bearer %s\n' "$fake_secret" > "$XDG_STATE_HOME/phasezero/windows-vm/session.log"

output="$(timeout 180 bash "$REPO_ROOT/linux/audit/support-bundle.sh")"
bundle="$(sed -n 's/^Support bundle: //p' <<< "$output")"
test -f "$bundle"
test "$(stat -c '%a' "$bundle")" = "600"
test -z "$(find "$TMPDIR" -maxdepth 1 -type d -name 'phasezero-support-stage.*' -print -quit)"

extract="$TMP_ROOT/extract"
mkdir -p "$extract"
tar -xzf "$bundle" -C "$extract"
if rg -F "$fake_secret" "$extract"; then
    echo "FAIL: support bundle leaked synthetic secret"
    exit 1
fi
rg -q '<redacted>' "$extract"

rm -f "$bundle"
echo "linux-support-bundle smoke ok"
