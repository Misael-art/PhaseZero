#!/usr/bin/env bash
# Smoke tests for PhaseZero Steam Deck desktop UX: hotkey OSD, tray,
# shortcut cheat-sheet and voice typing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_LOCAL_BIN="$TMP_ROOT/bin"
mkdir -p "$HOME" "$PZ_LOCAL_BIN"

SD="$REPO_ROOT/linux/steamdeck"

bash -n "$SD/osd.sh"
bash -n "$SD/hotkey-actions.sh"
bash -n "$SD/tray.sh"
bash -n "$SD/voice-typing.sh"
bash -n "$SD/install-hotkeys.sh"

# OSD dry-run never touches the session
PZ_DRY_RUN=1 bash "$SD/osd.sh" "input-keyboard" "smoke" >/dev/null

# tray: status JSON contract + dry-run
bash "$SD/tray.sh" status | jq -e '.tool == "phasezero-tray" and (.running | type == "boolean")' >/dev/null
PZ_DRY_RUN=1 bash "$SD/tray.sh" dry-run >/dev/null

# voice typing: status JSON contract + dry-run setup
bash "$SD/voice-typing.sh" status | jq -e '.tool == "voice-typing" and (.modelPresent | type == "boolean") and (.lang | type == "string")' >/dev/null
bash "$SD/voice-typing.sh" dry-run >/dev/null

# voice stop without recording is a safe no-op
bash "$SD/voice-typing.sh" stop >/dev/null

# hotkey dispatcher rejects unknown actions
if bash "$SD/hotkey-actions.sh" bogus-action 2>/dev/null; then
    echo "hotkey-actions should reject unknown actions" >&2
    exit 1
fi

# full hotkeys install in dry-run mode writes nothing outside HOME
bash "$SD/install-hotkeys.sh" dry-run >/dev/null
[ ! -f "$XDG_CONFIG_HOME/autostart/phasezero-tray.desktop" ]

echo "linux-steamdeck-overlay smoke ok"
