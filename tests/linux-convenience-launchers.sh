#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export XDG_DATA_HOME="$HOME/.local/share"
export PZ_LOCAL_BIN="$HOME/.local/bin"

"$ROOT/linux/pz" steamdeck conveniences plan | grep -q 'Return, Windows VM and Waydroid'
"$ROOT/linux/pz" steamdeck conveniences install >/dev/null
"$ROOT/linux/pz" steamdeck conveniences status | jq -e '.ready == true' >/dev/null

for id in return windows-vm waydroid; do
    test -x "$PZ_LOCAL_BIN/phasezero-$id"
done
grep -q 'os-session-select.sh.*desktop' "$PZ_LOCAL_BIN/phasezero-return"
grep -q 'windows-vm launch --fullscreen' "$PZ_LOCAL_BIN/phasezero-windows-vm"
grep -q 'waydroid launch' "$PZ_LOCAL_BIN/phasezero-waydroid"
test -f "$XDG_DATA_HOME/applications/phasezero-return-to-gaming-mode.desktop"
test -f "$XDG_DATA_HOME/applications/phasezero-windows-vm.desktop"
test -f "$XDG_DATA_HOME/applications/phasezero-waydroid.desktop"
grep -q '^Exec=.*phasezero-return$' "$XDG_DATA_HOME/applications/phasezero-return-to-gaming-mode.desktop"

echo "linux-convenience-launchers smoke ok"
