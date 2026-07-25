#!/usr/bin/env bash
# Smoke tests for adaptive Switch/PS3/PS4 performance launch profiles.
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
export PATH="$TMP_ROOT/test-bin:$PATH"

mkdir -p "$HOME" "$TMP_ROOT/test-bin"
cat > "$TMP_ROOT/test-bin/gamemoderun" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$TMP_ROOT/test-bin/gamemoderun"

"$REPO_ROOT/linux/pz" emulation performance apply >/dev/null
test -x "$PZ_LOCAL_BIN/phasezero-emulation-launch"
jq -e '
    .profiles.switch.lsfg == "auto"
    and .profiles.ps3.lsfg == "auto"
    and .profiles.ps4.lsfg == "auto"
    and .applyTdp == false
' "$XDG_CONFIG_HOME/phasezero/emulation-performance.json" >/dev/null

cat > "$TMP_ROOT/emulator" <<'EOF'
#!/usr/bin/env bash
printf 'vblank=%s lsfg=%s args=%s\n' "${vblank_mode:-}" "${LSFG_PROCESS:-}" "$*" > "$PZ_TEST_LOG"
EOF
chmod +x "$TMP_ROOT/emulator"
touch "$TMP_ROOT/Game.nsp"

export PZ_TEST_LOG="$TMP_ROOT/launch.log"
"$PZ_LOCAL_BIN/phasezero-emulation-launch" switch -- "$TMP_ROOT/emulator" "$TMP_ROOT/Game.nsp"
grep -q 'vblank=0 lsfg=' "$PZ_TEST_LOG"

mkdir -p "$HOME/.local/lib" "$XDG_DATA_HOME/vulkan/implicit_layer.d" "$XDG_CONFIG_HOME/lsfg-vk"
touch "$HOME/.local/lib/liblsfg-vk.so"
printf '{}\n' > "$XDG_DATA_HOME/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json"
printf 'version = 1\n' > "$XDG_CONFIG_HOME/lsfg-vk/conf.toml"
cat > "$HOME/lsfg" <<'EOF'
#!/usr/bin/env bash
export LSFG_PROCESS=phasezero
exec "$@"
EOF
chmod +x "$HOME/lsfg"

"$PZ_LOCAL_BIN/phasezero-emulation-launch" switch -- "$TMP_ROOT/emulator" "$TMP_ROOT/Game.nsp"
grep -q 'vblank=0 lsfg=phasezero' "$PZ_TEST_LOG"

"$REPO_ROOT/linux/pz" emulation performance set-game switch Game off >/dev/null
"$PZ_LOCAL_BIN/phasezero-emulation-launch" switch -- "$TMP_ROOT/emulator" "$TMP_ROOT/Game.nsp"
grep -q 'vblank=0 lsfg=' "$PZ_TEST_LOG"
! grep -q 'lsfg=phasezero' "$PZ_TEST_LOG"

"$REPO_ROOT/linux/pz" emulation performance set-profile ps3 off >/dev/null
jq -e '.profiles.ps3.lsfg == "off" and .games.switch.Game.lsfg == "off"' \
    "$XDG_CONFIG_HOME/phasezero/emulation-performance.json" >/dev/null
"$REPO_ROOT/linux/pz" emulation performance status |
    jq -e '.configValid == true and .runtimeInstalled == true and .lsfg.ready == true' >/dev/null

echo "linux-emulation-performance smoke ok"
