#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux AppImage desktop shortcut repair.
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
export PZ_APPIMAGE_DIR="$HOME/Appimage"
export PZ_SHORTCUTS_DISABLE_RENDER_MENU=0

apps_dir="$XDG_DATA_HOME/applications"
mkdir -p "$HOME" "$apps_dir" "$PZ_APPLICATIONS_DIR" "$PZ_APPIMAGE_DIR" "$PZ_EMULATION_ROOT/tools"

touch "$PZ_APPLICATIONS_DIR/EmuDeck.AppImage"
touch "$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage"
touch "$PZ_APPLICATIONS_DIR/DuckStation.AppImage"
chmod +x "$PZ_APPLICATIONS_DIR/EmuDeck.AppImage" "$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage" "$PZ_APPLICATIONS_DIR/DuckStation.AppImage"

cat > "$apps_dir/EmuDeck.desktop" <<EOF
#!/usr/bin/env xdg-open
[Desktop Entry]
Name=EmuDeck
Exec=$PZ_APPLICATIONS_DIR/EmuDeck.AppImage --no-sandbox
Icon=emudeck
Terminal=false
Type=Application
Categories=Game;
Actions=SoftwareRender;

[Desktop Action SoftwareRender]
Name=Software Render
Exec=SoftwareRender $PZ_APPLICATIONS_DIR/EmuDeck.AppImage --no-sandbox
EOF

cat > "$apps_dir/appimagekit_hash-EmuDeck.desktop" <<EOF
[Desktop Entry]
Name=EmuDeck (2.5.0)
Exec=$PZ_APPIMAGE_DIR/EmuDeck_old.AppImage --no-sandbox %U
Terminal=false
Type=Application
Icon=appimagekit_hash_emudeck
X-AppImage-Version=2.5.0
Categories=Development;
EOF

cat > "$apps_dir/Steam ROM Manager.desktop" <<EOF
#!/usr/bin/env xdg-open
[Desktop Entry]
Name=Steam-ROM-Manager AppImage
Exec=$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage
Icon=steam-rom-manager
Terminal=false
Type=Application
Categories=Game;
Actions=SoftwareRender;

[Desktop Action SoftwareRender]
Name=Software Render
Exec=SoftwareRender $PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage
EOF

cat > "$apps_dir/DuckStation.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DuckStation (1)
Exec=$PZ_APPLICATIONS_DIR/DuckStation.AppImage %f
Icon=duckstation
Categories=Game;Emulator;
EOF

"$REPO_ROOT/linux/pz" emulation shortcuts status --json | jq -e '.status == "warn"' >/dev/null || {
    echo "FAIL: shortcut status should warn before repair"
    exit 1
}

plan_output="$("$REPO_ROOT/linux/pz" emulation shortcuts plan)"
grep -q 'hide duplicate' <<< "$plan_output" || {
    echo "FAIL: shortcut plan did not mention duplicate hiding"
    printf '%s\n' "$plan_output"
    exit 1
}

"$REPO_ROOT/linux/pz" emulation shortcuts repair >/dev/null

test -x "$PZ_LOCAL_BIN/phasezero-emudeck" || { echo "FAIL: EmuDeck wrapper missing"; exit 1; }
test -x "$PZ_LOCAL_BIN/phasezero-srm" || { echo "FAIL: SRM wrapper missing"; exit 1; }
test -x "$PZ_LOCAL_BIN/phasezero-duckstation" || { echo "FAIL: DuckStation wrapper missing"; exit 1; }

grep -q '^Exec='"$PZ_LOCAL_BIN"'/phasezero-emudeck$' "$apps_dir/phasezero-emudeck.desktop" || {
    echo "FAIL: EmuDeck canonical desktop wrong"
    cat "$apps_dir/phasezero-emudeck.desktop"
    exit 1
}
grep -q '^Exec='"$PZ_LOCAL_BIN"'/phasezero-srm$' "$apps_dir/phasezero-steam-rom-manager.desktop" || {
    echo "FAIL: SRM canonical desktop wrong"
    cat "$apps_dir/phasezero-steam-rom-manager.desktop"
    exit 1
}
grep -q '^Exec='"$PZ_LOCAL_BIN"'/phasezero-duckstation %f$' "$apps_dir/phasezero-duckstation.desktop" || {
    echo "FAIL: DuckStation canonical desktop wrong"
    cat "$apps_dir/phasezero-duckstation.desktop"
    exit 1
}

! grep -qi 'SoftwareRender' "$apps_dir/phasezero-emudeck.desktop" || { echo "FAIL: SoftwareRender leaked into canonical EmuDeck desktop"; exit 1; }

for dup in "$apps_dir/EmuDeck.desktop" "$apps_dir/appimagekit_hash-EmuDeck.desktop" "$apps_dir/Steam ROM Manager.desktop" "$apps_dir/DuckStation.desktop"; do
    grep -q '^NoDisplay=true$' "$dup" || { echo "FAIL: duplicate missing NoDisplay: $dup"; cat "$dup"; exit 1; }
    grep -q '^Hidden=true$' "$dup" || { echo "FAIL: duplicate missing Hidden: $dup"; cat "$dup"; exit 1; }
done

"$REPO_ROOT/linux/pz" emulation shortcuts status --json | jq -e '.status == "ok"' >/dev/null || {
    echo "FAIL: shortcut status should be ok after repair"
    "$REPO_ROOT/linux/pz" emulation shortcuts status --json
    exit 1
}

echo "linux-shortcuts smoke ok"
