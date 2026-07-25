#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_STATE_HOME="$TMP_ROOT/state"
export PZ_DUALSCREEN_LIB_ONLY=1
export PZ_DUALSCREEN_SKIP_RECONFIGURE=1
mkdir -p "$XDG_CONFIG_HOME"

cat > "$XDG_CONFIG_HOME/kwinrulesrc" <<'EOF'
[keep-id]
Description=User rule
wmclass=user-app

[old-managed]
Description=PhaseZero dualscreen: cemu-main
pb_dualscreen_managed=true
wmclass=Cemu

[General]
activity=true
count=2
rules=keep-id,old-managed
EOF

# shellcheck disable=SC1091
source "$REPO_ROOT/linux/emulation/dualscreen.sh"

dualscreen_kwin_rule_block \
    "new-managed" "PhaseZero dualscreen: cemu-pad" "Cemu" "1" "0,0" "false" |
    dualscreen_kwin_write_rules cemu

config="$(<"$KWINRULES")"
grep -q '^\[keep-id\]$' <<< "$config"
grep -q '^\[new-managed\]$' <<< "$config"
if grep -q '^\[old-managed\]$' <<< "$config"; then exit 1; fi
grep -q '^activity=true$' <<< "$config"
grep -q '^count=2$' <<< "$config"
grep -q '^rules=keep-id,new-managed$' <<< "$config"

dualscreen_kwin_remove_all
config="$(<"$KWINRULES")"
grep -q '^\[keep-id\]$' <<< "$config"
if grep -q 'PhaseZero dualscreen:' <<< "$config"; then exit 1; fi
grep -q '^count=1$' <<< "$config"
grep -q '^rules=keep-id$' <<< "$config"
find "$XDG_CONFIG_HOME" -maxdepth 1 -type f -name 'kwinrulesrc.phasezero.bak.*' -print -quit | grep -q .

echo "linux dualscreen tests passed"
