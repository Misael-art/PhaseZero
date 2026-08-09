#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -m unittest "$ROOT/tests/test_claude_code_manager.py" "$ROOT/tests/test_opencode_9router_manager.py"
python3 -m py_compile "$ROOT/linux/ai/claude_code_manager.py" "$ROOT/linux/ai/opencode_9router_manager.py"
bash -n "$ROOT/linux/ai/setup-claude-code.sh"
bash -n "$ROOT/linux/ai/9router-manager.sh"
grep -q 'service_owns_listener' "$ROOT/linux/ai/9router-manager.sh"
grep -q 'listener_is_loopback' "$ROOT/linux/ai/9router-manager.sh"
grep -q 'Using existing Node.js' "$ROOT/linux/ai/9router-manager.sh"
grep -q 'BONSAI_ROUTE' "$ROOT/linux/ai/claude_code_manager.py"
grep -q 'dns-not-implemented' "$ROOT/linux/ai/claude_code_manager.py"
grep -q '{file:' "$ROOT/linux/ai/opencode_9router_manager.py"
"$ROOT/linux/pz" ai claude status | jq -e '.schemaVersion == 1 and .secretsRedacted == true' >/dev/null
echo "linux-ai-claude smoke ok"
