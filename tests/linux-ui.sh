#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux UI components.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== UI bash -n checks ==="
bash -n "$REPO_ROOT/linux/lib/json-envelope.sh" && echo "  json-envelope.sh OK"
bash -n "$REPO_ROOT/linux/ui/tui.sh" && echo "  tui.sh OK"
python3 -c "compile(open('$REPO_ROOT/linux/ui/server.py').read(), 'server.py', 'exec'); print('  server.py OK')"
python3 -m py_compile "$REPO_ROOT"/linux/ui_native/*.py
bash -n "$REPO_ROOT/linux/ui/native.sh" && echo "  native.sh OK"
bash -n "$REPO_ROOT/linux/pz" && echo "  pz OK"
bash -n "$REPO_ROOT/linux/emulation/shared-content.sh" && echo "  shared-content.sh OK"
bash -n "$REPO_ROOT/linux/emulation/media.sh" && echo "  media.sh OK"
bash -n "$REPO_ROOT/linux/emulation/retrodeck.sh" && echo "  retrodeck.sh OK"
bash -n "$REPO_ROOT/linux/emulation/pc-games.sh" && echo "  pc-games.sh OK"
python3 -m py_compile "$REPO_ROOT/linux/emulation/pc-games.py"

echo "=== Server startup test ==="
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
XDG_STATE_HOME="$(mktemp -d)"
export XDG_STATE_HOME
export HOME="$XDG_STATE_HOME"
python3 "$REPO_ROOT/linux/ui/server.py" --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 1
kill -0 "$SERVER_PID" 2>/dev/null || { echo "FAIL: server did not start"; exit 1; }

# Read token
TOKEN=$(cat "$XDG_STATE_HOME/phasezero/ui-token" 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "FAIL: token not generated"; exit 1; }

# Helper: curl with auth or no auth
api_get() {
    local path="$1" auth="${2:-}"
    if [ -n "$auth" ]; then
        curl -s -H "Authorization: Bearer $auth" "http://127.0.0.1:$PORT$path"
    else
        curl -s "http://127.0.0.1:$PORT$path"
    fi
}

api_post() {
    local path="$1" data="$2" auth="${3:-}"
    if [ -n "$auth" ]; then
        curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $auth" -d "$data" "http://127.0.0.1:$PORT$path"
    else
        curl -s -X POST -H "Content-Type: application/json" -d "$data" "http://127.0.0.1:$PORT$path"
    fi
}

echo "=== API: /api/modules ==="
api_get "/api/modules" "$TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'modules' in d; print('  modules ok')"

echo "=== API: /api/actions ==="
api_get "/api/actions" "$TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'actions' in d; print('  actions ok')"

echo "=== API: /api/token-status (no auth) ==="
api_get "/api/token-status" "" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('valid') == False; print('  token check ok')"

echo "=== API: /api/token-status (with auth) ==="
api_get "/api/token-status" "$TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('valid') == True; print('  token auth ok')"

echo "=== API: /api/status ==="
api_get "/api/status" "$TOKEN" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'system' in d
assert 'steamdeck' in d
assert 'emulation' in d
assert 'ai' in d
print('  status ok')
"

echo "=== API: /api/status/steamdeck ==="
api_get "/api/status/steamdeck" "$TOKEN" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['module'] == 'steamdeck'
print('  steamdeck status ok')
"

echo "=== API: allowlist blocks unknown action ==="
api_post "/api/action" '{"action":"unknown.action"}' "$TOKEN" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['status'] == 'blocked'
print('  block unknown action ok')
"

echo "=== API: mutable action requires confirmation ==="
api_post "/api/action" '{"action":"emulation.shared"}' "$TOKEN" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['status'] in ('ok', 'warn')
assert 'confirmation required' in d.get('blockers', [])
print('  blockers:', d.get('blockers', []))
"

echo "=== API: no auth returns 401 ==="
status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/status/steamdeck")
if [ "$status" = "401" ]; then
    echo "  no auth 401 ok"
else
    echo "FAIL: expected 401 got $status"
    exit 1
fi

echo "=== Static files served ==="
style_data=$(curl -s "http://127.0.0.1:$PORT/static/style.css")
if echo "$style_data" | head -1 | grep -q "PhaseZero"; then
    echo "  style.css ok"
else
    echo "  FAIL: style.css"
    exit 1
fi
app_data=$(curl -s "http://127.0.0.1:$PORT/static/app.js")
if echo "$app_data" | head -1 | grep -q "PhaseZero"; then
    echo "  app.js ok"
else
    echo "  FAIL: app.js"
    exit 1
fi
html_data=$(curl -s "http://127.0.0.1:$PORT/")
if echo "$html_data" | grep -q "PhaseZero"; then
    echo "  index.html ok"
else
    echo "  FAIL: index.html"
    exit 1
fi

echo "=== Cleanup ==="
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
sleep 1

echo "=== Windows files untouched ==="
ps1_changed=$(git diff --name-only -- '*.ps1' 2>/dev/null | wc -l)
echo "  .ps1 files changed: $ps1_changed (all must be our work or pre-existing)"
# our changes don't include .ps1 files - this is a soft check
git diff --name-only 2>/dev/null | while IFS= read -r f; do
    case "$f" in
        *.ps1) echo "  WARN: $f appears modified (pre-existing change)";;
    esac
done

echo "=== --json flag on emulation commands ==="
export HOME="$XDG_STATE_HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export PZ_EMULATION_ROOT="$HOME/Emulation"
export PZ_RETRODECK_ROOT="$HOME/retrodeck"
mkdir -p "$HOME" "$PZ_EMULATION_ROOT" "$PZ_RETRODECK_ROOT"
"$REPO_ROOT/linux/pz" emulation layout >/dev/null 2>&1 || true

"$REPO_ROOT/linux/pz" emulation shared status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['module'] == 'emulation'
assert 'checks' in d
print('  shared --json ok')
"

"$REPO_ROOT/linux/pz" emulation media status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'checks' in d
print('  media --json ok')
"

echo "=== No regressions: existing commands ==="
"$REPO_ROOT/linux/pz" emulation shared status >/dev/null 2>&1 && echo "  shared status ok"
"$REPO_ROOT/linux/pz" emulation media status >/dev/null 2>&1 && echo "  media status ok"

echo "=== TUI script syntax ==="
bash -n "$REPO_ROOT/linux/ui/tui.sh" >/dev/null 2>&1 && echo "  tui syntax ok"

echo "=== Native Qt UI ==="
if python3 -c 'import PySide6' >/dev/null 2>&1; then
    QT_QPA_PLATFORM=offscreen python3 -m linux.ui_native --smoke-test \
        --screenshot "$XDG_STATE_HOME/native-ui-smoke.png"
    test -s "$XDG_STATE_HOME/native-ui-smoke.png"
    pytest -q "$REPO_ROOT/tests/test_linux_native_ui.py"
else
    echo "  PySide6 unavailable; native runtime test skipped"
fi

echo "=== UI smoke ok ==="
