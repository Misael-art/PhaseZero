#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status="$("$ROOT/linux/pz" ai proxies status)"
[ "$(jq 'length' <<< "$status")" -eq 10 ]
jq -e 'map(.id) | index("qwen-worker-proxy") != null and index("unlimited-ai-proxy") != null' <<< "$status" >/dev/null
jq -e '
  .[] | select(.id == "unlimited-ai-proxy") | .kind == "node" and .port == 8787
' <<< "$status" >/dev/null
jq -e '
  .[] | select(.id == "mimo-ai-proxy") | .kind == "go" and .port == 3005
' <<< "$status" >/dev/null
plan="$("$ROOT/linux/pz" ai proxies plan all)"
[ "$(grep -c '^would install ' <<< "$plan")" -eq 10 ]
echo "linux-ai-proxies smoke ok"
