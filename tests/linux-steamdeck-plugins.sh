#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CACHE_HOME="$TMP_ROOT/cache"
export XDG_STATE_HOME="$TMP_ROOT/state"
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export PZ_DECKY_HOME="$HOME/homebrew"
export PZ_DECKY_PLUGINS_DIR="$PZ_DECKY_HOME/plugins"
export PZ_DECKY_THEMES_DIR="$PZ_DECKY_HOME/themes"
export PZ_DECKY_LIB_ONLY=1
export PZ_DECKY_RUNTIME_PROBE=0
mkdir -p "$HOME" "$PZ_DECKY_PLUGINS_DIR" "$PZ_DECKY_THEMES_DIR"

# shellcheck disable=SC1091  # Runtime repository path is intentional.
source "$REPO_ROOT/linux/steamdeck/plugins.sh"

echo "=== health requires a valid frontend bundle ==="
mkdir -p "$PZ_DECKY_PLUGINS_DIR/healthy/dist"
printf '%s\n' '{"name":"healthy","version":"1.0.0"}' > "$PZ_DECKY_PLUGINS_DIR/healthy/plugin.json"
printf '%s\n' 'export default function Plugin() {}' > "$PZ_DECKY_PLUGINS_DIR/healthy/dist/index.js"
plugin_health_json healthy "$PZ_DECKY_PLUGINS_DIR/healthy" | jq -e '.ok == true' >/dev/null
test "$(plugin_frontend_reachable_json "$PZ_DECKY_PLUGINS_DIR/healthy")" = null

mkdir -p "$PZ_DECKY_PLUGINS_DIR/missing"
printf '%s\n' '{"name":"missing"}' > "$PZ_DECKY_PLUGINS_DIR/missing/plugin.json"
printf '%s\n' 'print("backend exists")' > "$PZ_DECKY_PLUGINS_DIR/missing/main.py"
plugin_health_json missing "$PZ_DECKY_PLUGINS_DIR/missing" |
    jq -e '.ok == false and (.issue | contains("frontend bundle"))' >/dev/null

mkdir -p "$PZ_DECKY_PLUGINS_DIR/invalid/dist"
printf '%s\n' '{}' > "$PZ_DECKY_PLUGINS_DIR/invalid/plugin.json"
printf '%s\n' 'bundle' > "$PZ_DECKY_PLUGINS_DIR/invalid/dist/index.js"
plugin_health_json invalid "$PZ_DECKY_PLUGINS_DIR/invalid" |
    jq -e '.ok == false and .issue == "plugin.json invalid"' >/dev/null

echo "=== complete package replaces only after validation ==="
PACKAGE_ROOT="$TMP_ROOT/package/demo"
mkdir -p "$PACKAGE_ROOT/dist"
printf '%s\n' '{"name":"demo","version":"2.0.0"}' > "$PACKAGE_ROOT/plugin.json"
printf '%s\n' 'export default function Demo() {}' > "$PACKAGE_ROOT/dist/index.js"
python3 - "$TMP_ROOT/package" "$TMP_ROOT/demo.zip" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as archive:
    for path in root.rglob("*"):
        if path.is_file():
            archive.write(path, path.relative_to(root))
PY
mkdir -p "$PZ_DECKY_PLUGINS_DIR/demo"
printf '%s\n' old > "$PZ_DECKY_PLUGINS_DIR/demo/sentinel"
install_zip_plugin demo "$TMP_ROOT/demo.zip" demo
test -s "$PZ_DECKY_PLUGINS_DIR/demo/dist/index.js"
test ! -e "$PZ_DECKY_PLUGINS_DIR/demo/sentinel"
find "$PZ_DECKY_HOME/plugin-backups" -type f -name sentinel -exec grep -qx old {} \;
test -z "$(find "$PZ_DECKY_PLUGINS_DIR" -maxdepth 1 -type d -name '*.bak.*' -print -quit)"

echo "=== incomplete and malicious packages preserve installed plugin ==="
mkdir -p "$TMP_ROOT/raw/raw"
printf '%s\n' '{"name":"raw"}' > "$TMP_ROOT/raw/raw/plugin.json"
python3 - "$TMP_ROOT/raw" "$TMP_ROOT/raw.zip" "$TMP_ROOT/traversal.zip" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w") as archive:
    archive.write(root / "raw" / "plugin.json", "raw/plugin.json")
with zipfile.ZipFile(sys.argv[3], "w") as archive:
    archive.writestr("../escaped", "unsafe")
    archive.writestr("bad/plugin.json", '{"name":"bad"}')
    archive.writestr("bad/dist/index.js", "bundle")
PY
mkdir -p "$PZ_DECKY_PLUGINS_DIR/raw"
printf '%s\n' keep > "$PZ_DECKY_PLUGINS_DIR/raw/sentinel"
if install_zip_plugin raw "$TMP_ROOT/raw.zip" raw >/dev/null 2>&1; then
    echo "FAIL: raw source package accepted" >&2
    exit 1
fi
grep -qx keep "$PZ_DECKY_PLUGINS_DIR/raw/sentinel"
if install_zip_plugin bad "$TMP_ROOT/traversal.zip" bad >/dev/null 2>&1; then
    echo "FAIL: path traversal package accepted" >&2
    exit 1
fi
test ! -e "$TMP_ROOT/escaped"

echo "=== unsupported incomplete plugin is quarantined ==="
mkdir -p "$PZ_DECKY_PLUGINS_DIR/NonSteamLaunchers"
printf '%s\n' '{"name":"NonSteamLaunchers"}' > "$PZ_DECKY_PLUGINS_DIR/NonSteamLaunchers/plugin.json"
quarantine_broken_plugin NonSteamLaunchers 'NonSteamLaunchers,NonSteamLaunchersDecky'
test ! -e "$PZ_DECKY_PLUGINS_DIR/NonSteamLaunchers"
find "$PZ_DECKY_HOME/disabled-plugins" -maxdepth 1 -type d -name 'NonSteamLaunchers.disabled.*' -print -quit | grep -q .
plugin_catalog | awk -F'|' '$1 == "NonSteamLaunchers" { found = ($4 == "unsupported") } END { exit !found }'

echo "=== non-theme resource folder leaves CSS Loader scan path ==="
mkdir -p "$PZ_DECKY_THEMES_DIR/resources/images"
printf '%s\n' docs > "$PZ_DECKY_THEMES_DIR/resources/images/readme.txt"
migrate_legacy_theme_resources
test ! -e "$PZ_DECKY_THEMES_DIR/resources"
find "$PZ_DECKY_HOME/theme-resources-backups" -type f -name readme.txt -exec grep -qx docs {} \;

echo "linux SteamOS plugin tests passed"
