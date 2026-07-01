#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux emulation helpers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_EMULATION_ROOT="$TMP_ROOT/Emulation"
export PZ_APPLICATIONS_DIR="$TMP_ROOT/Applications"
export PZ_LOCAL_BIN="$TMP_ROOT/bin"

mkdir -p "$HOME"

"$REPO_ROOT/linux/pz" emulation layout >/dev/null
test -d "$PZ_EMULATION_ROOT/bios"
test -d "$PZ_EMULATION_ROOT/firmware/switch/keys"
test -d "$PZ_EMULATION_ROOT/roms/switch"

"$REPO_ROOT/linux/pz" emulation status | jq -e '.userContent.policy == "local-user-owned-import-only"' >/dev/null
"$REPO_ROOT/linux/pz" emulation emudeck dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation eden dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation eden integrate >/dev/null
"$REPO_ROOT/linux/pz" emulation eden status | jq -e '.emudeckInstalled == false' >/dev/null
"$REPO_ROOT/linux/pz" emulation hydra dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation hydra status | jq -e '.policyInstalled == false' >/dev/null
"$REPO_ROOT/linux/pz" install emulation-linux --dry-run >/dev/null

mkdir -p "$TMP_ROOT/source-bios"
printf 'fake-bios\n' > "$TMP_ROOT/source-bios/scph5501.bin"
"$REPO_ROOT/linux/pz" emulation bios import "$TMP_ROOT/source-bios" >/dev/null
test -f "$PZ_EMULATION_ROOT/bios/scph5501.bin"

mkdir -p "$TMP_ROOT/source-keys"
printf 'fake-prod-keys\n' > "$TMP_ROOT/source-keys/prod.keys"
"$REPO_ROOT/linux/pz" emulation switch import-keys "$TMP_ROOT/source-keys" >/dev/null
test -f "$PZ_EMULATION_ROOT/firmware/switch/keys/prod.keys"
test -f "$XDG_DATA_HOME/eden/keys/prod.keys"

mkdir -p "$TMP_ROOT/source-fw"
printf 'fake-fw\n' > "$TMP_ROOT/source-fw/firmware.nca"
"$REPO_ROOT/linux/pz" emulation switch import-firmware "$TMP_ROOT/source-fw" >/dev/null
test -f "$PZ_EMULATION_ROOT/firmware/switch/firmware/firmware.nca"
test -f "$XDG_DATA_HOME/eden/nand/system/Contents/registered/firmware.nca"

if "$REPO_ROOT/linux/pz" emulation bios import https://github.com/Abdess/retrobios.git >/tmp/pz-emulation-blocked.log 2>&1; then
    echo "expected retrobios remote source to be blocked" >&2
    exit 1
fi
grep -qi 'blocked' /tmp/pz-emulation-blocked.log

if "$REPO_ROOT/linux/pz" emulation switch import-firmware https://github.com/THZoria/NX_Firmware.git >/tmp/pz-emulation-blocked.log 2>&1; then
    echo "expected NX firmware remote source to be blocked" >&2
    exit 1
fi
grep -qi 'blocked' /tmp/pz-emulation-blocked.log

if "$REPO_ROOT/linux/pz" emulation switch import-keys https://edenemulators.com/eden-prod-keys/ >/tmp/pz-emulation-blocked.log 2>&1; then
    echo "expected Eden prod keys remote source to be blocked" >&2
    exit 1
fi
grep -qi 'blocked' /tmp/pz-emulation-blocked.log

echo "linux-emulation smoke ok"
