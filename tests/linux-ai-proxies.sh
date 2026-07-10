#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"

grep -q 'apply_loopback_patch' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'PZ_BIND_HOST' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'unsafe dotenv variable rejected' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'secure proxy key generation failed' "$ROOT/linux/ai/proxy-suite.sh"
status="$("$ROOT/linux/pz" ai proxies status)"
[ "$(jq 'length' <<< "$status")" -eq 10 ]
jq -e 'map(.id) | index("qwen-worker-proxy") != null and index("unlimited-ai-proxy") != null' <<< "$status" >/dev/null
jq -e '
  .[] | select(.id == "unlimited-ai-proxy") | .kind == "node" and .port == 8787
' <<< "$status" >/dev/null
jq -e '
  .[] | select(.id == "mimo-ai-proxy") | .kind == "go" and .port == 3013
' <<< "$status" >/dev/null
plan="$("$ROOT/linux/pz" ai proxies plan all)"
[ "$(grep -c '^would install ' <<< "$plan")" -eq 10 ]
auth="$("$ROOT/linux/pz" ai proxies auth all)"
[ "$(jq 'length' <<< "$auth")" -eq 10 ]
jq -e '
  .[] | select(.id == "qwenproxy") |
  .webValidation.required == true and
  .webValidation.kind == "browser-session" and
  (.webValidation.command | test("login qwenproxy"))
' <<< "$auth" >/dev/null
jq -e '
  .[] | select(.id == "mimo-ai-proxy") |
  .webValidation.required == true and
  .webValidation.kind == "env-session" and
  .webValidation.status == "missing-credentials" and
  (.webValidation.missing | length == 3)
' <<< "$auth" >/dev/null
! grep -Eq 'SERVICE_TOKEN|USER_ID|XIAOMI_CHATBOT_PH|API_KEY|phasezero-qwen' <<< "$auth"
echo "linux-ai-proxies smoke ok"
