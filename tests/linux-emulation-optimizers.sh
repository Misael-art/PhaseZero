#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export PZ_EMULATION_ROOT="$HOME/Emulation"
mkdir -p "$HOME"

json="$("$ROOT/linux/pz" emulation optimizer status)"
[ "$(jq 'length' <<< "$json")" -eq 14 ]
"$ROOT/linux/pz" emulation optimizer apply-all >/dev/null
test -f "$XDG_CONFIG_HOME/duckstation/GameSettings/SLUS-00594.ini"
test -f "$XDG_CONFIG_HOME/PCSX2/inis/GameSettings/SLUS-20946.ini"
test -f "$XDG_CONFIG_HOME/dolphin-emu/GameSettings/RMGE01.ini"
grep -q 'CpuOverclockPercent = 200' "$XDG_CONFIG_HOME/duckstation/GameSettings/SLUS-00594.ini"
grep -q 'UpscaleMultiplier = 4' "$XDG_CONFIG_HOME/PCSX2/inis/GameSettings/SLUS-20946.ini"
grep -q 'InternalResolution = 3' "$XDG_CONFIG_HOME/dolphin-emu/GameSettings/RMGE01.ini"
echo "linux-emulation-optimizers smoke ok"
