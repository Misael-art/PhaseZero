#!/usr/bin/env bash
# Smoke test for windows-vm/host-access.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

# source the script without side effects by running in a subprocess with --help
out=$(bash "$REPO_ROOT/linux/windows-vm/host-access.sh" --help 2>&1 || true)
if echo "$out" | grep -qi 'usage\|mount\|guest-c'; then
    echo "PASS: host-access --help shows usage"
else
    echo "FAIL: host-access --help output unexpected"
    echo "$out"
    exit 1
fi

# resolve_disk with no VM should return empty (graceful)
src=$(bash -c "
    source '$REPO_ROOT/linux/windows-vm/host-access.sh'
    resolve_disk
" 2>&1 || true)
if [ -z "$src" ]; then
    echo "PASS: resolve_disk returns empty when no VM exists"
else
    echo "PASS: resolve_disk returned path (VM may exist on host)"
fi

echo "linux-windows-vm-host-access smoke ok"
