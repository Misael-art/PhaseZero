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
export PZ_EMULATION_DMI_DIR="$TMP_ROOT/dmi-generic"
export PZ_EMULATION_FORCE_APPLY=1

mkdir -p "$HOME" "$PZ_EMULATION_DMI_DIR"
printf 'Generic PC\n' > "$PZ_EMULATION_DMI_DIR/product_name"
printf 'GenericVendor\n' > "$PZ_EMULATION_DMI_DIR/sys_vendor"
printf 'GenericBoard\n' > "$PZ_EMULATION_DMI_DIR/board_name"
printf 'GenericVendor\n' > "$PZ_EMULATION_DMI_DIR/board_vendor"

"$REPO_ROOT/linux/pz" emulation layout >/dev/null
test -d "$PZ_EMULATION_ROOT/bios"
test -d "$PZ_EMULATION_ROOT/firmware/switch/keys"
test -d "$PZ_EMULATION_ROOT/roms/switch"
test -d "$PZ_EMULATION_ROOT/roms/ps4"

"$REPO_ROOT/linux/pz" emulation status | jq -e '.userContent.policy == "local-user-owned-import-only"' >/dev/null
"$REPO_ROOT/linux/pz" emulation emudeck dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation emudeck status | jq -e '.host.class == "linux-pc" and .launcher.kind == "appimage"' >/dev/null
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
"$REPO_ROOT/linux/pz" emulation nsz status | jq -e '.source.count == 0 and .policy == "local-user-owned-content-only"' >/dev/null
"$REPO_ROOT/linux/pz" emulation nsz plan "$PZ_EMULATION_ROOT/roms/switch" | jq -e '.execution == "sequential" and .sourcePolicy == "preserve-by-default"' >/dev/null
"$REPO_ROOT/linux/pz" emulation srm dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation srm status | jq -e '.configured | type == "boolean"' >/dev/null
"$REPO_ROOT/linux/pz" emulation ps3 dry-run >/dev/null
"$REPO_ROOT/linux/pz" emulation ps3 status | jq -e '.policy == "local-user-owned-import-only"' >/dev/null
"$REPO_ROOT/linux/pz" emulation performance apply >/dev/null
"$REPO_ROOT/linux/pz" emulation performance status | jq -e '.configValid == true and .runtimeInstalled == true' >/dev/null
"$REPO_ROOT/linux/pz" emulation fixes list | jq -e 'length >= 11' >/dev/null
"$REPO_ROOT/linux/pz" install emulation-linux --dry-run >/dev/null

DECK_DMI="$TMP_ROOT/dmi-steamdeck"
DECK_HOME="$TMP_ROOT/deck-home"
DECK_ROOT="$TMP_ROOT/deck-Emulation"
DECK_APPS="$TMP_ROOT/deck-Applications"
DECK_BIN="$TMP_ROOT/deck-bin"
DECK_DESKTOP_SOURCE="$TMP_ROOT/official/EmuDeck.desktop"
mkdir -p "$DECK_DMI" "$DECK_HOME" "$(dirname "$DECK_DESKTOP_SOURCE")"
printf 'Jupiter\n' > "$DECK_DMI/product_name"
printf '1\n' > "$DECK_DMI/product_version"
printf 'Valve\n' > "$DECK_DMI/sys_vendor"
printf 'Jupiter\n' > "$DECK_DMI/board_name"
printf 'Valve\n' > "$DECK_DMI/board_vendor"
printf '8\n' > "$DECK_DMI/chassis_type"
cat > "$DECK_DESKTOP_SOURCE" <<'EOF'
	[Desktop Entry]
	Name=Install EmuDeck
	Exec=sh -c 'curl -L https://raw.githubusercontent.com/dragoonDorise/EmuDeck/main/install.sh | bash'
	Terminal=true
	Type=Application
EOF
HOME="$DECK_HOME" \
XDG_CONFIG_HOME="$DECK_HOME/.config" \
XDG_DATA_HOME="$DECK_HOME/.local/share" \
PZ_EMULATION_ROOT="$DECK_ROOT" \
PZ_APPLICATIONS_DIR="$DECK_APPS" \
PZ_LOCAL_BIN="$DECK_BIN" \
PZ_EMULATION_DMI_DIR="$DECK_DMI" \
PZ_EMUDECK_STEAMDECK_DESKTOP_URL="file://$DECK_DESKTOP_SOURCE" \
    "$REPO_ROOT/linux/pz" emulation emudeck install >/dev/null
test -x "$DECK_HOME/Desktop/EmuDeck.desktop"
grep -q $'^\t' "$DECK_HOME/Desktop/EmuDeck.desktop" && exit 1
test -x "$DECK_BIN/phasezero-emudeck"
HOME="$DECK_HOME" \
XDG_CONFIG_HOME="$DECK_HOME/.config" \
XDG_DATA_HOME="$DECK_HOME/.local/share" \
PZ_EMULATION_ROOT="$DECK_ROOT" \
PZ_APPLICATIONS_DIR="$DECK_APPS" \
PZ_LOCAL_BIN="$DECK_BIN" \
PZ_EMULATION_DMI_DIR="$DECK_DMI" \
    "$REPO_ROOT/linux/pz" emulation emudeck status | jq -e '.host.class == "steam-deck" and .launcher.kind == "steamdeck-desktop" and .steamDeckDesktop.installed == true and .appImageInstalled == false' >/dev/null

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
  {"configTitle":"","parserType":"Manual","romDirectory":"","executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":false},
  {"configTitle":"Nintendo Switch - Eden","parserInputs":{"glob":"**/${title}@(.nsp|.NSP)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Nintendo Switch - Citron","parserInputs":{"glob":"**/${title}@(.nsp|.NSP)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Nintendo Switch - Ryujinx","parserInputs":{"glob":"**/${title}@(.nsp|.NSP)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Microsoft Xbox 360 - Xenia","parserInputs":{"glob":"**/${title}@(.iso|.xex)"},"executable":{"path":""},"userAccounts":{"specifiedAccounts":[]},"disabled":true},
  {"configTitle":"Atari 2600 - RetroArch","parserType":"Glob","romDirectory":"/home/olduser/Emulation/roms/atari2600","parserInputs":{"glob":"${title}@(.a26|.bin)"},"executable":{"path":"/usr/bin/retroarch"},"userAccounts":{"specifiedAccounts":["Global"]},"disabled":false},
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
"$REPO_ROOT/linux/pz" emulation srm status | jq -e '.configured == true and .managedParsers >= 5 and .invalidParsers == 0' >/dev/null
jq -e --arg steam "$HOME/.local/share/Steam" --arg roms "$PZ_EMULATION_ROOT/roms" '.environmentVariables.steamDirectory == $steam and .environmentVariables.romsDirectory == $roms and .autoKillSteam == true' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userSettings.json" >/dev/null
jq -e '[.[] | select((.configTitle // "") == "" or (.parserType // "") == "")] | length == 0' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null
jq -e --arg runtime "$PZ_LOCAL_BIN/phasezero-eden" '
    .[] | select(.configTitle == "Nintendo Switch - Eden")
    | .executable.path == $runtime
    and .parserType == "Glob"
    and (.executableArgs | contains("%command%") | not)
' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null
jq -e '
  .[] | select(.configTitle == "Atari 2600 - RetroArch")
  | .romDirectory == "${romsdirglobal}/atari2600"
' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null

mkdir -p "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (Update)" \
  "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (DLC)" \
  "$PZ_EMULATION_ROOT/roms/switch/Mods" "$PZ_EMULATION_ROOT/roms/switch/Firmware" \
  "$PZ_EMULATION_ROOT/roms/switch/_backup" "$PZ_EMULATION_ROOT/roms/switch/Torrent"
mkdir -p "$XDG_CONFIG_HOME/Ryujinx"
jq -n --arg root "$PZ_EMULATION_ROOT/roms/switch" \
  '{game_dirs:[$root,($root+"/Nintendo Switch (Update)"),($root+"/Nintendo Switch (DLC)"),($root+"/Mods"),($root+"/Firmware"),($root+"/_backup"),($root+"/Torrent"),"/games/external"]}' \
  > "$XDG_CONFIG_HOME/Ryujinx/Config.json"
"$REPO_ROOT/linux/pz" emulation media prepare-scan >/dev/null
jq -e --arg view "$PZ_EMULATION_ROOT/.phasezero/scan-safe/roms/switch" \
  '.game_dirs == ["/games/external",$view]' "$XDG_CONFIG_HOME/Ryujinx/Config.json" >/dev/null
jq -e --arg view "$PZ_EMULATION_ROOT/.phasezero/scan-safe/roms/switch" '
  ([.[] | select(.configTitle | test("Nintendo Switch - (Eden|Citron|Ryujinx)"))] | all(.romDirectory == $view and (.parserInputs.glob | startswith("${title}@")))) and
  (.[] | select(.configTitle == "Microsoft Xbox 360 - Xenia") | .romDirectory == "${romsdirglobal}/xbox360/roms" and (.parserInputs.glob | contains("default.xex"))) and
  (.[] | select(.configTitle == "Sony PlayStation 3 - RPCS3 (Extracted ISO/PSN)") | (.parserInputs.glob | startswith("{${title}@(.iso"))) and
  (.[] | select(.configTitle == "Sony PlayStation 4 - ShadPS4 (Shortcut)") | .parserInputs.glob == "${title}@(.desktop)")
' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null

mkdir -p "$PZ_EMULATION_ROOT/roms/steam/GOG Game" "$PZ_EMULATION_ROOT/roms/steam/Native Game"
mkdir -p "$PZ_EMULATION_ROOT/tools/downloaded_media/steam/covers" "$PZ_EMULATION_ROOT/tools/downloaded_media/steam/fanart"
printf 'cover\n' > "$PZ_EMULATION_ROOT/tools/downloaded_media/steam/covers/GOG Game.png"
printf 'fanart\n' > "$PZ_EMULATION_ROOT/tools/downloaded_media/steam/fanart/GOG Game.jpg"
cat > "$PZ_EMULATION_ROOT/roms/steam/GOG Game/goggame-1.info" <<'JSON'
{
  "name": "GOG Game",
  "playTasks": [
    {"category": "game", "isPrimary": true, "name": "GOG Game", "path": "GOGGame.exe", "arguments": "-safe", "type": "FileTask"},
    {"category": "game", "name": "GOG Game Launcher", "path": "Launcher.exe", "type": "FileTask"}
  ]
}
JSON
echo "exe" > "$PZ_EMULATION_ROOT/roms/steam/GOG Game/GOGGame.exe"
echo "launcher" > "$PZ_EMULATION_ROOT/roms/steam/GOG Game/Launcher.exe"
echo "uninstall" > "$PZ_EMULATION_ROOT/roms/steam/GOG Game/unins000.exe"
cat > "$PZ_EMULATION_ROOT/roms/steam/Native Game/Native Game.sh" <<'SH'
#!/usr/bin/env bash
echo native
SH
chmod +x "$PZ_EMULATION_ROOT/roms/steam/Native Game/Native Game.sh"
cat > "$PZ_EMULATION_ROOT/roms/steam/Standalone.sh" <<'SH'
#!/usr/bin/env bash
echo standalone
SH
chmod +x "$PZ_EMULATION_ROOT/roms/steam/Standalone.sh"
PZ_EMULATION_FORCE_APPLY=1 "$REPO_ROOT/linux/pz" emulation pc-games repair >/dev/null
"$REPO_ROOT/linux/pz" emulation pc-games status --json | jq -e '.discovered == 3 and .heroicManagedGames == 3 and .hydraConfigured == true and .esdeGamelistInstalled == true' >/dev/null
jq -e '
  (.games | length == 3) and
  (.games[] | select(.slug == "gog-game") | .target | endswith("GOGGame.exe")) and
  (.games[] | select(.slug == "gog-game") | .runner == "wine")
' "$PZ_EMULATION_ROOT/metadata/pc-games/catalog.json" >/dev/null
test -x "$PZ_EMULATION_ROOT/tools/pc-games/launchers/gog-game.sh"
test -f "$XDG_DATA_HOME/applications/phasezero-pc-gog-game.desktop"
jq -e '[.games[] | select(.app_name | startswith("phasezero-pc-"))] | length == 3 and all(.install.platform == "Linux")' "$XDG_CONFIG_HOME/heroic/sideload_apps/library.json" >/dev/null
jq -e '.games[] | select(.app_name == "phasezero-pc-gog-game") | (.art_square | startswith("file://")) and (.art_cover | startswith("file://"))' "$XDG_CONFIG_HOME/heroic/sideload_apps/library.json" >/dev/null
jq -e '.pcgames.enabled == true and .pcgames.roms_directory == "'"$PZ_EMULATION_ROOT/tools/pc-games/launchers"'"' "$XDG_CONFIG_HOME/hydralauncher/emulators_config.json" >/dev/null
grep -q '<name>steam</name>' "$HOME/ES-DE/custom_systems/es_systems.xml"
grep -q "$PZ_EMULATION_ROOT/tools/pc-games/launchers" "$HOME/ES-DE/custom_systems/es_systems.xml"
grep -q '<path>./gog-game.sh</path>' "$PZ_EMULATION_ROOT/metadata/gamelists/steam/gamelist.xml"
jq -e '.[] | select(.configTitle == "PC Games - PhaseZero") | .romDirectory == "'"$PZ_EMULATION_ROOT/tools/pc-games/launchers"'" and .executable.path == "/bin/bash"' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null
jq -e '.[] | select(.configTitle == "PC Games - PhaseZero") | .version == 25 and .presetVersion == 19 and .executable.appendArgsToExecutable == true and (.imageProviders | index("sgdb")) != null and .titleModifier == "${fuzzyTitle}"' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null
python3 "$REPO_ROOT/linux/emulation/pc-games.py" --dry-run launch gog-game | jq -e '.runner == "wine" and (.command | any(test("wine$")))' >/dev/null

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
PZ_EMULATION_FORCE_APPLY=1 "$REPO_ROOT/linux/pz" emulation ps3 configure >/dev/null
"$REPO_ROOT/linux/pz" emulation ps3 status | jq -e '.wrapperInstalled == true and .esdeConfigured == true and .retrodeckConfigured == true' >/dev/null
test -x "$PZ_LOCAL_BIN/phasezero-rpcs3"
grep -q 'phasezero-rpcs3 --no-gui %ROM%' "$HOME/ES-DE/custom_systems/es_systems.xml"
grep -q 'flatpak-spawn --host .*phasezero-rpcs3 --no-gui %ROM%' "$HOME/retrodeck/ES-DE/custom_systems/es_systems.xml"

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

FAKE_NSZ_BIN="$TMP_ROOT/fake-nsz"
cat > "$FAKE_NSZ_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
source=""
decompress=0
verify=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -D) decompress=1; shift ;;
        -V|--verify) verify=1; shift ;;
        --output) output="$2"; shift 2 ;;
        --threads) shift 2 ;;
        *) source="$1"; shift ;;
    esac
done
if [ "$decompress" -eq 1 ]; then
    case "$(basename "$source")" in
        Broken*) exit 9 ;;
    esac
    mkdir -p "$output"
    base="$(basename "${source%.*}")"
    printf 'PFS0phasezero-test-payload\n' > "$output/$base.nsp"
elif [ "$verify" -eq 1 ]; then
    [ "$(head -c 4 "$source")" = "PFS0" ]
fi
EOF
chmod +x "$FAKE_NSZ_BIN"

printf 'fake-prod-keys\n' > "$PZ_EMULATION_ROOT/firmware/switch/keys/prod.keys"
printf 'compressed-one\n' > "$PZ_EMULATION_ROOT/roms/switch/one.nsz"
PZ_NSZ_BIN="$FAKE_NSZ_BIN" PZ_NSZ_RESERVE_BYTES=0 PZ_NSZ_EXPANSION_RATIO=1 \
    "$REPO_ROOT/linux/pz" emulation nsz convert "$PZ_EMULATION_ROOT/roms/switch/one.nsz" >/dev/null
test -f "$PZ_EMULATION_ROOT/roms/switch/one.nsz"
test -f "$PZ_EMULATION_ROOT/roms/switch/nsp/one.nsp"
test "$(head -c 4 "$PZ_EMULATION_ROOT/roms/switch/nsp/one.nsp")" = "PFS0"

printf 'compressed-two\n' > "$PZ_EMULATION_ROOT/roms/switch/two.nsz"
PZ_NSZ_BIN="$FAKE_NSZ_BIN" PZ_NSZ_RESERVE_BYTES=0 PZ_NSZ_EXPANSION_RATIO=1 \
    "$REPO_ROOT/linux/pz" emulation nsz convert "$PZ_EMULATION_ROOT/roms/switch/two.nsz" --delete-source --yes >/dev/null
test ! -e "$PZ_EMULATION_ROOT/roms/switch/two.nsz"
test -f "$PZ_EMULATION_ROOT/roms/switch/nsp/two.nsp"
jq -e 'select(.status == "completed" and .sourceRemoved == true)' "$PZ_EMULATION_ROOT"/metadata/switch/nsz-conversions/*.json >/dev/null

mkdir -p "$PZ_EMULATION_ROOT/roms/switch/dedupe"
printf 'same-compressed-data\n' > "$PZ_EMULATION_ROOT/roms/switch/dedupe/Game.nsz"
cp "$PZ_EMULATION_ROOT/roms/switch/dedupe/Game.nsz" \
   "$PZ_EMULATION_ROOT/roms/switch/dedupe/Game (1.00 GB).nsz"
PZ_NSZ_BIN="$FAKE_NSZ_BIN" PZ_NSZ_RESERVE_BYTES=0 PZ_NSZ_EXPANSION_RATIO=1 \
    "$REPO_ROOT/linux/pz" emulation nsz plan "$PZ_EMULATION_ROOT/roms/switch/dedupe" |
    jq -e '.confirmedDuplicates == 1 and .duplicateConflicts == 0' >/dev/null
PZ_NSZ_BIN="$FAKE_NSZ_BIN" PZ_NSZ_RESERVE_BYTES=0 PZ_NSZ_EXPANSION_RATIO=1 \
    "$REPO_ROOT/linux/pz" emulation nsz apply "$PZ_EMULATION_ROOT/roms/switch/dedupe" --yes >/dev/null
test ! -e "$PZ_EMULATION_ROOT/roms/switch/dedupe/Game.nsz"
test ! -e "$PZ_EMULATION_ROOT/roms/switch/dedupe/Game (1.00 GB).nsz"
test -f "$PZ_EMULATION_ROOT/roms/switch/nsp/Game.nsp"

mkdir -p "$PZ_EMULATION_ROOT/roms/switch/conflict"
printf 'first\n' > "$PZ_EMULATION_ROOT/roms/switch/conflict/Conflict.nsz"
printf 'second\n' > "$PZ_EMULATION_ROOT/roms/switch/conflict/Conflict (2.00 GB).nsz"
if PZ_NSZ_BIN="$FAKE_NSZ_BIN" PZ_NSZ_RESERVE_BYTES=0 PZ_NSZ_EXPANSION_RATIO=1 \
    "$REPO_ROOT/linux/pz" emulation nsz apply "$PZ_EMULATION_ROOT/roms/switch/conflict" --yes >/dev/null 2>&1; then
    echo "expected normalized-name conflict to block apply" >&2
    exit 1
fi
test -f "$PZ_EMULATION_ROOT/roms/switch/conflict/Conflict.nsz"
test -f "$PZ_EMULATION_ROOT/roms/switch/conflict/Conflict (2.00 GB).nsz"

mkdir -p "$PZ_EMULATION_ROOT/roms/switch/broken"
printf 'broken-data\n' > "$PZ_EMULATION_ROOT/roms/switch/broken/Broken Game.nsz"
if PZ_NSZ_BIN="$FAKE_NSZ_BIN" PZ_NSZ_RESERVE_BYTES=0 PZ_NSZ_EXPANSION_RATIO=1 \
    "$REPO_ROOT/linux/pz" emulation nsz apply "$PZ_EMULATION_ROOT/roms/switch/broken" --yes >/dev/null 2>&1; then
    echo "expected broken NSZ apply to report failure" >&2
    exit 1
fi
test ! -e "$PZ_EMULATION_ROOT/roms/switch/broken/Broken Game.nsz"
test -f "$PZ_EMULATION_ROOT/.phasezero/quarantine/nsz/Broken Game.nsz"
find "$PZ_EMULATION_ROOT/roms/switch/nsp/.phasezero-staging/nsz-to-nsp" \
    -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q . && exit 1
jq -e 'select(.status == "failed-verification" and .sourcePreserved == true and .quarantine != null)' \
    "$PZ_EMULATION_ROOT"/metadata/switch/nsz-conversions/failed-*.json >/dev/null

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
