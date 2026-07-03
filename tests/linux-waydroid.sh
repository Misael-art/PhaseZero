#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux Waydroid automation.
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

bash -n "$REPO_ROOT/linux/pz"
bash -n "$REPO_ROOT/linux/waydroid/waydroid.sh"
bash -n "$REPO_ROOT/linux/waydroid/waydroid-boot-prepare.sh"
bash -n "$REPO_ROOT/linux/waydroid/waydroid-session.sh"
jq empty "$REPO_ROOT/profiles/waydroid-linux.json"

"$REPO_ROOT/linux/pz" waydroid status | jq -e '.host | has("binderFilesystem") and has("kwinWayland")' >/dev/null
plan_output="$("$REPO_ROOT/linux/pz" waydroid plan)"
grep -q 'PhaseZero Waydroid plan' <<< "$plan_output"
boot_output="$("$REPO_ROOT/linux/pz" waydroid boot dry-run)"
grep -q 'one-shot boot' <<< "$boot_output"
PZ_DRY_RUN=1 "$REPO_ROOT/linux/pz" waydroid optimize >/dev/null
launch_output="$("$REPO_ROOT/linux/pz" waydroid launch --dry-run)"
grep -q 'Waydroid launcher dry-run' <<< "$launch_output"
"$REPO_ROOT/linux/pz" waydroid install >/dev/null
test -f "$XDG_CONFIG_HOME/phasezero/waydroid.conf"
test -f "$XDG_DATA_HOME/applications/phasezero-waydroid.desktop"
test -f "$XDG_CONFIG_HOME/systemd/user/phasezero-waydroid.service"
"$REPO_ROOT/linux/pz" waydroid status | jq -e '.config.installed == true and (.android | has("serviceActive")) and (.boot | has("grubCfgEntry"))' >/dev/null
"$REPO_ROOT/linux/pz" waydroid status | jq -e '.android.resumablePrefetch == true' >/dev/null
grep -q 'PZ_WAYDROID_SOURCEFORGE_MIRRORS' "$REPO_ROOT/linux/waydroid/waydroid.sh"
"$REPO_ROOT/linux/pz" install waydroid-linux --dry-run >/dev/null

echo "linux-waydroid smoke ok"
