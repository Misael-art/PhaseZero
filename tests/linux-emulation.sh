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
export PZ_RPCS3_APP=""

mkdir -p "$HOME"

"$REPO_ROOT/linux/pz" emulation layout >/dev/null
test -d "$PZ_EMULATION_ROOT/bios"
test -d "$PZ_EMULATION_ROOT/firmware/switch/keys"
test -d "$PZ_EMULATION_ROOT/roms/switch"
test -d "$PZ_EMULATION_ROOT/roms/ps4"

"$REPO_ROOT/linux/pz" emulation status | jq -e '.userContent.policy == "local-user-owned-import-only"' >/dev/null
"$REPO_ROOT/linux/pz" emulation emudeck dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation eden dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation eden integrate >/dev/null
"$REPO_ROOT/linux/pz" emulation eden status | jq -e '.emudeckInstalled == false' >/dev/null
"$REPO_ROOT/linux/pz" emulation citron dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation citron integrate >/dev/null
"$REPO_ROOT/linux/pz" emulation citron status | jq -e '.emudeckInstalled == false' >/dev/null
"$REPO_ROOT/linux/pz" emulation hydra dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation hydra status | jq -e '.policyInstalled == false' >/dev/null
"$REPO_ROOT/linux/pz" emulation lua status | jq -e '.ready | type == "boolean"' >/dev/null
"$REPO_ROOT/linux/pz" emulation lua dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation steam-tools status | jq -e '.tools | has("protontricks") and has("steamRomManager")' >/dev/null
"$REPO_ROOT/linux/pz" emulation steam-tools dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation srm dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation srm status | jq -e '.configured | type == "boolean"' >/dev/null
"$REPO_ROOT/linux/pz" emulation ps3 dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation ps3 status | jq -e '.policy == "local-user-owned-import-only"' >/dev/null
"$REPO_ROOT/linux/pz" emulation performance apply >/dev/null
"$REPO_ROOT/linux/pz" emulation performance status | jq -e '.configValid == true and .runtimeInstalled == true' >/dev/null
"$REPO_ROOT/linux/pz" emulation fixes list | jq -e 'length >= 11' >/dev/null
"$REPO_ROOT/linux/pz" install emulation-linux --dry-run >/dev/null

touch "$PZ_APPLICATIONS_DIR/DuckStation.AppImage" "$PZ_APPLICATIONS_DIR/pcsx2-Qt.AppImage" "$PZ_APPLICATIONS_DIR/rpcs3.AppImage"
chmod +x "$PZ_APPLICATIONS_DIR/DuckStation.AppImage" "$PZ_APPLICATIONS_DIR/pcsx2-Qt.AppImage" "$PZ_APPLICATIONS_DIR/rpcs3.AppImage"
"$REPO_ROOT/linux/pz" emulation hydra force-classic-config >/dev/null
jq -e '.displayClassicContent == true and .enableRetroUIFeatures == true' "$XDG_CONFIG_HOME/hydralauncher/config.json" >/dev/null
jq -e 'length == 3' "$XDG_CONFIG_HOME/hydralauncher/emulators_config.json" >/dev/null
"$REPO_ROOT/linux/pz" emulation hydra status | jq -e '.classicConfigInstalled == true and .emulatorsConfigured == 3' >/dev/null

mkdir -p "$HOME/.config/EmuDeck/backend/configs/steam-rom-manager/userData"
cat > "$HOME/.config/EmuDeck/backend/configs/steam-rom-manager/userData/userSettings.json" <<'JSON'
{"environmentVariables":{"steamDirectory":"","romsDirectory":"","retroarchPath":"","userAccounts":[]},"autoKillSteam":false,"autoRestartSteam":false}
JSON
cat > "$HOME/.config/EmuDeck/backend/configs/steam-rom-manager/userData/userConfigurations.json" <<'JSON'
[
  {"configTitle":"Nintendo Switch - Eden","parserInputs":{"glob":"**/${title}@(.nsp|.NSP)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Nintendo Switch - Citron","parserInputs":{"glob":"**/${title}@(.nsp|.NSP)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Nintendo Switch - Ryujinx","parserInputs":{"glob":"**/${title}@(.nsp|.NSP)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Microsoft Xbox 360 - Xenia","parserInputs":{"glob":"**/${title}@(.iso|.xex)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Sony PlayStation - DuckStation","executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Sony PlayStation 2 - PCSX2","executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Sony PlayStation 3 - RPCS3 (Extracted ISO/PSN)","parserInputs":{"glob":"**/${title}/PS3_GAME/USRDIR/EBOOT.BIN"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Sony PlayStation 4 - ShadPS4 (Shortcut)","parserInputs":{"glob":"**/${title}@(.desktop)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true}
]
JSON
mkdir -p "$PZ_EMULATION_ROOT/tools/launchers/srm" "$PZ_EMULATION_ROOT/tools/launchers"
touch "$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage" "$PZ_EMULATION_ROOT/tools/launchers/srm/steamrommanager.sh" "$PZ_EMULATION_ROOT/tools/launchers/retroarch.sh"
chmod +x "$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage" "$PZ_EMULATION_ROOT/tools/launchers/srm/steamrommanager.sh" "$PZ_EMULATION_ROOT/tools/launchers/retroarch.sh"
"$REPO_ROOT/linux/pz" emulation srm configure >/dev/null
"$REPO_ROOT/linux/pz" emulation srm status | jq -e '.configured == true and .managedParsers >= 5' >/dev/null
jq -e --arg steam "$HOME/.local/share/Steam" --arg roms "$PZ_EMULATION_ROOT/roms" '.environmentVariables.steamDirectory == $steam and .environmentVariables.romsDirectory == $roms and .autoKillSteam == true' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userSettings.json" >/dev/null
jq -e --arg runtime "$PZ_LOCAL_BIN/phasezero-eden" '
    .[] | select(.configTitle == "Nintendo Switch - Eden")
    | .executable.path == $runtime
    and (.executableArgs | contains("%command%") | not)
' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null
jq -e --arg view "$PZ_EMULATION_ROOT/.phasezero/scan-safe/roms/switch" '
  ([.[] | select(.configTitle | test("Nintendo Switch - (Eden|Citron|Ryujinx)"))] | all(.romDirectory == $view and (.parserInputs.glob | startswith("${title}@")))) and
  (.[] | select(.configTitle == "Microsoft Xbox 360 - Xenia") | .romDirectory == "${romsdirglobal}/xbox360/roms" and (.parserInputs.glob | contains("default.xex"))) and
  (.[] | select(.configTitle == "Sony PlayStation 3 - RPCS3 (Extracted ISO/PSN)") | (.parserInputs.glob | startswith("{${title}@(.iso"))) and
  (.[] | select(.configTitle == "Sony PlayStation 4 - ShadPS4 (Shortcut)") | .parserInputs.glob == "${title}@(.desktop)")
' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null

mkdir -p "$TMP_ROOT/ps3-game/PS3_GAME"
printf 'fake-param\n' > "$TMP_ROOT/ps3-game/PS3_GAME/PARAM.SFO"
"$REPO_ROOT/linux/pz" emulation ps3 import-game "$TMP_ROOT/ps3-game" >/dev/null
test -d "$PZ_EMULATION_ROOT/roms/ps3/ps3-game/PS3_GAME"
printf 'fake-rap\n' > "$TMP_ROOT/license.rap"
"$REPO_ROOT/linux/pz" emulation ps3 import-rap "$TMP_ROOT/license.rap" >/dev/null
test -f "$PZ_EMULATION_ROOT/storage/rpcs3/dev_hdd0/home/00000001/exdata/license.rap"
printf 'fake-pup\n' > "$TMP_ROOT/PS3UPDAT.PUP"
"$REPO_ROOT/linux/pz" emulation ps3 import-firmware "$TMP_ROOT/PS3UPDAT.PUP" >/dev/null
test -f "$PZ_EMULATION_ROOT/firmware/ps3/PS3UPDAT.PUP"
"$REPO_ROOT/linux/pz" emulation ps3 status | jq -e '.vfsConfigured == true and .rapFiles == 1 and .firmwareFiles == 1' >/dev/null

mkdir -p "$TMP_ROOT/source-bios"
printf 'fake-bios\n' > "$TMP_ROOT/source-bios/scph5501.bin"
"$REPO_ROOT/linux/pz" emulation bios import "$TMP_ROOT/source-bios" >/dev/null
test -f "$PZ_EMULATION_ROOT/bios/scph5501.bin"

mkdir -p "$TMP_ROOT/source-keys"
printf 'fake-prod-keys\n' > "$TMP_ROOT/source-keys/prod.keys"
"$REPO_ROOT/linux/pz" emulation switch import-keys "$TMP_ROOT/source-keys" >/dev/null
test -f "$PZ_EMULATION_ROOT/firmware/switch/keys/prod.keys"
test -f "$XDG_DATA_HOME/eden/keys/prod.keys"
test -f "$XDG_DATA_HOME/citron/keys/prod.keys"

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

if "$REPO_ROOT/linux/pz" emulation ps3 import-game https://example.com/ps3.iso >/tmp/pz-emulation-blocked.log 2>&1; then
    echo "expected PS3 remote source to be blocked" >&2
    exit 1
fi
grep -qi 'blocked' /tmp/pz-emulation-blocked.log

echo "linux-emulation smoke ok"
