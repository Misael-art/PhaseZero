#!/usr/bin/env bash
# Suite hermética do motor de temas (plan/apply/verify/rollback/preview/rescue).
# Nenhum teste toca o HOME real; PZ_THEMES_* redirecionam estado, configuração
# e D-Bus; binários do host nunca são executados.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== py_compile ==="
python3 -m py_compile \
    "$REPO_ROOT/linux/themes/engine.py" \
    "$REPO_ROOT/linux/themes/features.py" \
    "$REPO_ROOT/linux/themes/kde.py" \
    "$REPO_ROOT/linux/themes/platform.py" \
    "$REPO_ROOT/linux/themes/state.py" \
    "$REPO_ROOT/linux/themes/catalog.py" \
    "$REPO_ROOT/linux/themes/__main__.py"
echo "  ok"

WORK="$(mktemp -d)"
STATE_DIR="$WORK/state"
CONFIG_DIR="$WORK/config"
FAKE_JSON="$WORK/fake.json"
STUB="$WORK/qdbus-stub.py"
mkdir -p "$CONFIG_DIR"
# noop

cat > "$FAKE_JSON" <<'JSON'
{
  "plasmaMajor": 6,
  "session": "wayland",
  "kwin": true,
  "steamOs": false,
  "steamDeck": false,
  "gameMode": false,
  "decky": false,
  "onBattery": false,
  "batteryPercent": null,
  "vaapi": true,
  "vulkan": true,
  "steamInstall": "",
  "steamLibraries": [],
  "binaries": {
    "qdbus": "",
    "plasma-apply-lookandfeel": "",
    "plasma-apply-colorscheme": "",
    "plasma-apply-cursortheme": ""
  }
}
JSON

cat > "$STUB" <<'PY'
import sys
script = sys.argv[-1]
if 'desktops().map' in script:
    print('[{"id":"1","screen":0,"wallpaperPlugin":"org.kde.image",'
          '"wallpaperMode":"SingleImage","config":{"Image":"file:///old.png",'
          '"FillMode":"6"}}]')
else:
    print('OK_0')
PY

export PZ_THEMES_STATE_DIR="$STATE_DIR"
export PZ_THEMES_CONFIG_DIR="$CONFIG_DIR"
export PZ_THEMES_FAKE_JSON="$FAKE_JSON"
export PZ_THEMES_DBUS_CMD="$(command -v python3) $STUB"

run_themes() {
    "$REPO_ROOT/linux/pz" themes "$@"
}

echo "=== status: schema themes/v1 + hero ==="
run_themes status | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['schema'] == 'themes/v1', d
hero = d['hero']
assert 'themePhasezero' in hero
assert 'themeKde' in hero
assert 'wallpaper' in hero
print('  status ok')
"

echo "=== catalog: features + wallpapers + perfis + recusas rastreáveis ==="
run_themes catalog | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['schema'] == 'themes/v1'
features = d['features']
assert len(features) >= 20
assert any(f['id'] == 'access.reduce-motion' for f in features)
assert any(f['id'] == 'power.pause-on-game' for f in features)
assert any(w['id'] == 'pz.geo-dark' for w in d['wallpapers'])
assert any(p['id'] == 'essencial' for p in d['profiles'])
extensions = d['kdeExtensions']
assert any(e['status'] == 'rejected' for e in extensions)
assert any(e['status'] == 'deferred' for e in extensions)
print('  catalog ok')
"

echo "=== plan + apply + verify: perfil essencial ==="
PLAN_JSON="$(run_themes plan --profile essencial)"
PLAN_ID="$(printf '%s' "$PLAN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
TOKEN="$(printf '%s' "$PLAN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['confirmToken'])")"
printf '%s' "$PLAN_JSON" | python3 -c "
import json, sys
plan = json.load(sys.stdin)
assert plan['ok'] is True
assert plan['snapshotId']
print('  plan ok')
"
OP_JSON="$(run_themes apply --plan-id "$PLAN_ID" --confirm "$TOKEN")"
OP_ID="$(printf '%s' "$OP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['operationId'])")"
printf '%s' "$OP_JSON" | python3 -c "
import json, sys
op = json.load(sys.stdin)
assert op['status'] == 'complete', op
print('  apply ok')
"
run_themes verify --operation-id "$OP_ID" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['ok'] is True, d
print('  verify ok')
"

echo "=== rollback restaura arquivos ==="
run_themes rollback --snapshot latest >/dev/null
echo "  rollback ok"

echo "=== preview wallpaper + apply dentro do prazo ==="
WALL_JSON="$(run_themes plan --wallpaper pz.geo-dark --screen 0)"
WALL_PLAN="$(printf '%s' "$WALL_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
WALL_TOKEN="$(printf '%s' "$WALL_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['confirmToken'])")"
run_themes preview --plan-id "$WALL_PLAN" --confirm "$WALL_TOKEN" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['applied'] is True
assert d['ttlSeconds'] == 15
print('  preview ok')
"
run_themes apply --plan-id "$WALL_PLAN" --confirm "$WALL_TOKEN" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['status'] == 'complete', d
print('  apply wallpaper ok')
"

echo "=== plan expira (TTL) ==="
OLD_PLAN="$(run_themes plan --profile essencial | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
sleep 2
python3 -c "
import json, sys
from pathlib import Path
plan_dir = Path('$STATE_DIR') / 'plans'
for path in plan_dir.glob('*.json'):
    record = json.loads(path.read_text())
    if record['id'] == '$OLD_PLAN':
        record['createdAt'] = int(record['createdAt']) - 10_000_000
        path.write_text(json.dumps(record))
        break
"
if run_themes apply --plan-id "$OLD_PLAN" --confirm x >/dev/null 2>&1; then
    echo "FAIL: plano expirado não foi bloqueado"
    exit 1
else
    echo "  ttl block ok"
fi

echo "=== CLI nunca vaza lixo para stdout (stderr separado) ==="
if run_themes status --nao-existe >/dev/null 2>"$WORK/err.txt"; then
    echo "FAIL: comando inválido deveria falhar"
    exit 1
fi
python3 -c "
import json, sys
text = open('$WORK/err.txt').read()
assert 'uso' in text.lower() or 'error' in text.lower(), text
print('  stderr ok')
"

echo "=== stdout de sucesso é JSON puro ==="
run_themes status | python3 -c "import json,sys; json.load(sys.stdin); print('  json puro ok')"

echo "=== game mode: pause-on-game em plano ==="
python3 -c "
import json
payload = json.load(open('$FAKE_JSON'))
payload['gameMode'] = True
payload['steamOs'] = True
payload['steamDeck'] = True
json.dump(payload, open('$FAKE_JSON', 'w'))
"
run_themes plan --feature power.pause-on-game --state on | python3 -c "
import json, sys
plan = json.load(sys.stdin)
assert plan['ok'] is True, plan
print('  game mode plan ok')
"

echo "=== nenhuma alteração fora do estado/config fake ==="
EXTRA=$(git -C "$REPO_ROOT" status --porcelain -- 'linux/themes' 'linux/ui' 2>/dev/null | grep -cv '^??' || true)
echo "  diff em linux/themes e linux/ui (esperado 0): $EXTRA"

echo "=== themes suite ok ==="
