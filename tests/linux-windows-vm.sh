#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux Windows VM automation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$TMP_ROOT/state"
export XDG_RUNTIME_DIR="$TMP_ROOT/run"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

iso="$TMP_ROOT/Win11_test.iso"
printf 'fake iso for dry-run tests\n' > "$iso"

bash -n "$REPO_ROOT/linux/pz"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
jq empty "$REPO_ROOT/profiles/windows-vm-linux.json"

"$REPO_ROOT/linux/pz" windows-vm status | jq -e '(.host | has("qemu") and has("kvm")) and (.libvirt | has("domain") and has("preferred"))' >/dev/null
"$REPO_ROOT/linux/pz" windows-vm discover --json | jq -e 'has("configuredDisk") and has("discoveredAnyDisk")' >/dev/null
plan_output="$("$REPO_ROOT/linux/pz" windows-vm plan --iso "$iso")"
grep -q 'PhaseZero Windows VM plan' <<< "$plan_output"
grep -q 'smb_unc' <<< "$plan_output"
grep -q 'disk_source' <<< "$plan_output"
boot_output="$("$REPO_ROOT/linux/pz" windows-vm boot dry-run)"
grep -q 'one-shot boot' <<< "$boot_output"
PZ_DRY_RUN=1 "$REPO_ROOT/linux/pz" windows-vm install --iso "$iso" --disk-size 64M --ram 2048 --cpus 2 >/dev/null
test ! -f "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
"$REPO_ROOT/linux/pz" windows-vm install --iso "$iso" --disk-size 64M --ram 2048 --cpus 2 >/dev/null
test -f "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
grep -q 'PZ_WINDOWS_VM_ISO=' "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
PZ_DRY_RUN=1 "$REPO_ROOT/linux/pz" windows-vm optimize >/dev/null
launch_output="$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu)"
grep -q 'qemu-system-x86_64' <<< "$launch_output"
domain_launch_output="$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run)"
grep -Eq 'virsh -c .* start|qemu-system-x86_64' <<< "$domain_launch_output"
grep -q 'session.log' "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
"$REPO_ROOT/linux/pz" windows-vm status | jq -e '.config.installed == true and .vm.isoExists == true and (.vm.diskSource == "config" or .vm.diskSource == "discovered-installed" or .vm.diskSource == "adopted-existing") and (.vm | has("installedLike"))' >/dev/null
"$REPO_ROOT/linux/pz" install windows-vm-linux --dry-run >/dev/null

echo "linux-windows-vm smoke ok"
