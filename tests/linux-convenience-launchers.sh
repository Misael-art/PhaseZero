#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export XDG_DATA_HOME="$HOME/.local/share"
export PZ_LOCAL_BIN="$HOME/.local/bin"

"$ROOT/linux/pz" steamdeck conveniences plan | grep -q 'Return, Boot Selector, Windows VM and Waydroid'
mkdir -p "$XDG_DATA_HOME/applications"
printf 'X-PhaseZero-Managed=true\n' > "$XDG_DATA_HOME/applications/phasezero-phasezero-boot-selector.desktop"
"$ROOT/linux/pz" steamdeck conveniences install >/dev/null
"$ROOT/linux/pz" steamdeck conveniences status | jq -e '.ready == true and has("bootSelector")' >/dev/null

for id in return boot-selector windows-vm waydroid; do
    test -x "$PZ_LOCAL_BIN/phasezero-$id"
done
grep -q 'os-session-select.sh.*desktop' "$PZ_LOCAL_BIN/phasezero-return"
grep -q 'boot selector' "$PZ_LOCAL_BIN/phasezero-boot-selector"
grep -q 'windows-vm launch --fullscreen' "$PZ_LOCAL_BIN/phasezero-windows-vm"
grep -q 'waydroid launch' "$PZ_LOCAL_BIN/phasezero-waydroid"
test -f "$XDG_DATA_HOME/applications/phasezero-return-to-gaming-mode.desktop"
test -f "$XDG_DATA_HOME/applications/phasezero-boot-selector.desktop"
test ! -e "$XDG_DATA_HOME/applications/phasezero-phasezero-boot-selector.desktop"
test -f "$XDG_DATA_HOME/applications/phasezero-windows-vm.desktop"
test -f "$XDG_DATA_HOME/applications/phasezero-waydroid.desktop"
grep -q '^Exec=.*phasezero-return$' "$XDG_DATA_HOME/applications/phasezero-return-to-gaming-mode.desktop"

echo "linux-convenience-launchers smoke ok"
