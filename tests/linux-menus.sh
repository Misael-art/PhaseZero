#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export XDG_DATA_HOME="$TMP_ROOT/data"
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_STATE_HOME="$TMP_ROOT/state"
export XDG_DATA_DIRS="$TMP_ROOT/share"
mkdir -p "$HOME" "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
done
[ -n "$output" ]
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h1v1z"/></svg>' > "$output"
EOF
cat > "$TMP_ROOT/bin/steam" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP_ROOT/bin/curl" "$TMP_ROOT/bin/steam"
export PATH="$TMP_ROOT/bin:$PATH"

"$REPO_ROOT/linux/ui/webapp.sh" install whatsapp
test -s "$XDG_DATA_HOME/icons/hicolor/scalable/apps/phz-whatsapp.svg"
grep -Fxq 'Exec=xdg-open https://web.whatsapp.com' "$XDG_DATA_HOME/applications/phz-whatsapp.desktop"

"$REPO_ROOT/linux/ui/webapp.sh" install slack
test -s "$XDG_DATA_HOME/icons/hicolor/256x256/apps/phz-slack.png"
"$REPO_ROOT/linux/ui/webapp.sh" menu
python3 - "$XDG_CONFIG_HOME/menus/applications-merged/phasezero.menu" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.findtext("Name") == "Applications"
assert any(menu.findtext("Name") == "PhaseZero" for menu in root.findall("Menu"))
PY

"$REPO_ROOT/linux/ui/games.sh" install steam
grep -Fxq 'Exec=steam %f' "$XDG_DATA_HOME/applications/phz-game-steam.desktop"
"$REPO_ROOT/linux/ui/games.sh" menu
python3 - "$XDG_CONFIG_HOME/menus/applications-merged/phasezero.menu" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
files = [node.text for node in root.findall(".//Filename")]
assert "phz-whatsapp.desktop" in files
assert "phz-game-steam.desktop" in files
PY

test ! -e "$XDG_CONFIG_HOME/menus/applications-merged/phz-games.menu"
test ! -e "$XDG_CONFIG_HOME/menus/applications-merged/phz-webapps.menu"
menu_status="$($REPO_ROOT/linux/pz ui menu scan --json)"
jq -e '.schema == "pz.desktop-menu/v1" and .readOnly == true and .summary.managedVisible == 3' <<< "$menu_status" >/dev/null

"$REPO_ROOT/linux/pz" ui menu rollback --json | jq -e '.status == "ok"' >/dev/null

echo "linux menu tests passed"
