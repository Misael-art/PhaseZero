#!/usr/bin/env bash
# Hermetic contract for removing a PhaseZero-created VM through the trash.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_STATE_HOME="$TEST_ROOT/state"
export XDG_DATA_HOME="$TEST_ROOT/data"
export PZ_WINDOWS_VM_CONFIG="$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
export TEST_VM_TRASH="$TEST_ROOT/trash"
mkdir -p "$HOME/VirtualMachines/PhaseZero-Windows" "$XDG_CONFIG_HOME/phasezero" \
    "$TEST_ROOT/bin" "$TEST_VM_TRASH"
VM_DIR="$HOME/VirtualMachines/PhaseZero-Windows"
DISK="$VM_DIR/phasezero-windows.qcow2"
touch "$DISK"

cat > "$TEST_ROOT/bin/gio" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "trash" ] && [ "$2" = "--" ]
mv -- "$3" "$TEST_VM_TRASH/"
EOF
chmod +x "$TEST_ROOT/bin/gio"
export PATH="$TEST_ROOT/bin:$PATH"

write_config() {
    local source="$1"
    cat > "$PZ_WINDOWS_VM_CONFIG" <<EOF
PZ_WINDOWS_VM_DIR='$VM_DIR'
PZ_WINDOWS_VM_DISK='$DISK'
PZ_WINDOWS_VM_DISK_SOURCE='$source'
PZ_WINDOWS_VM_LIBVIRT_DOMAIN=''
PZ_WINDOWS_VM_SHARE_POLICY='minimal'
EOF
}

write_config new
plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json)"
jq -e '.ready == true and (.blockers | length == 0)' <<< "$plan" >/dev/null

write_config managed
legacy_plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json)"
jq -e '.ready == true and .vm.diskSource == "managed"' <<< "$legacy_plan" >/dev/null
write_config new

if "$REPO_ROOT/linux/pz" windows-vm remove --json >/dev/null 2>&1; then
    echo "remove without --yes unexpectedly succeeded" >&2
    exit 1
fi
[ -d "$VM_DIR" ]

mkdir -p "$TEST_ROOT/not-managed"
touch "$TEST_ROOT/not-managed/phasezero-windows.qcow2"
VM_DIR="$TEST_ROOT/not-managed"
DISK="$VM_DIR/phasezero-windows.qcow2"
write_config new
if "$REPO_ROOT/linux/pz" windows-vm remove --dry-run --json >/dev/null 2>&1; then
    echo "remove outside managed directory unexpectedly planned as safe" >&2
    exit 1
fi
[ -d "$VM_DIR" ]

VM_DIR="$HOME/VirtualMachines/PhaseZero-Windows"
DISK="$VM_DIR/phasezero-windows.qcow2"
write_config new

result="$("$REPO_ROOT"/linux/pz windows-vm remove --yes --json)"
jq -s -e 'length == 1' <<< "$result" >/dev/null
jq -e '.success == true' <<< "$result" >/dev/null
[ ! -e "$VM_DIR" ]
[ ! -e "$PZ_WINDOWS_VM_CONFIG" ]
[ -e "$TEST_VM_TRASH/PhaseZero-Windows/phasezero-windows.qcow2" ]

mkdir -p "$VM_DIR"
touch "$DISK"
write_config adopted-existing
if "$REPO_ROOT/linux/pz" windows-vm remove --dry-run --json >/dev/null 2>&1; then
    echo "remove adopted VM unexpectedly planned as safe" >&2
    exit 1
fi
[ -d "$VM_DIR" ]

echo "windows-vm remove smoke ok"
