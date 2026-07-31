#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export XDG_STATE_HOME="$TMP_ROOT/state"
export PZ_EMUDECK_CONFIG_ROOT="$TMP_ROOT/emudeck"
export PZ_CONTROLLERS_FORCE=1

mkdir -p \
    "$PZ_EMUDECK_CONFIG_ROOT/Ryujinx" \
    "$PZ_EMUDECK_CONFIG_ROOT/rpcs3/input_configs/global" \
    "$HOME/.config/Ryujinx" \
    "$HOME/.config/rpcs3/input_configs/global"

cat > "$PZ_EMUDECK_CONFIG_ROOT/Ryujinx/Config.json" <<'EOF'
{"input_config":[{"id":"reference-sdl-guid","name":"Reference Deck Pad","backend":"GamepadSDL3","player_index":"Player2"}]}
EOF
cat > "$HOME/.config/Ryujinx/Config.json" <<'EOF'
{"input_config":[{"id":"old-p1","player_index":"Player1"},{"id":"keep-p2","player_index":"Player2"}],"custom":true}
EOF
printf '%s\n' 'Player 1 Input:' '  Handler: SDL' > "$PZ_EMUDECK_CONFIG_ROOT/rpcs3/input_configs/global/Default.yml"
cat > "$HOME/.config/rpcs3/input_configs/active_profiles.yml" <<'EOF'
Active Profiles:
  custom-game: MyCustomProfile
Other Setting: keep-me
EOF

"$REPO_ROOT/linux/emulation/controllers.sh" apply >/dev/null
jq -e '
  .custom == true and
  .input_config[0].id == "reference-sdl-guid" and
  .input_config[0].player_index == "Player1" and
  .input_config[1].id == "keep-p2"
' "$HOME/.config/Ryujinx/Config.json" >/dev/null
grep -Fxq '  custom-game: MyCustomProfile' "$HOME/.config/rpcs3/input_configs/active_profiles.yml"
grep -Fxq '  global: Default' "$HOME/.config/rpcs3/input_configs/active_profiles.yml"
grep -Fxq 'Other Setting: keep-me' "$HOME/.config/rpcs3/input_configs/active_profiles.yml"

before="$(sha256sum "$HOME/.config/rpcs3/input_configs/active_profiles.yml")"
"$REPO_ROOT/linux/emulation/controllers.sh" dry-run >/dev/null
after="$(sha256sum "$HOME/.config/rpcs3/input_configs/active_profiles.yml")"
test "$before" = "$after"

echo "linux controller tests passed"
