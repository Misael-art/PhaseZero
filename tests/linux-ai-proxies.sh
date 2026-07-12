#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"
export HOME="$WORK/home"
export PZ_AI_PROXY_SKIP_EXTENSION_INSTALL=1
mkdir -p "$HOME/.config/opencode" "$HOME/.continue/index"
printf '{}\n' > "$HOME/.config/opencode/opencode.json"
printf '{}\n' > "$HOME/.config/opencode/opencode.jsonc"
printf '%s\n' '{"selectedModelsByProfileId":{"local":{"chat":"[PhaseZero Proxy] Kimi — old","edit":null,"apply":"External model"}}}' \
    > "$HOME/.continue/index/globalContext.json"

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
"$ROOT/linux/pz" ai proxies configure-ides >/dev/null
jq -e '.provider."phasezero-deepseek".models."deepseek-v4-flash"' "$HOME/.config/opencode/opencode.json" >/dev/null
jq -e '[.models[] | select((.title // "") | startswith("[PhaseZero Proxy] "))] | length == 11' "$HOME/.continue/config.json" >/dev/null
jq -e '.models[] | select(.model == "deepseek-v4-flash") | .apiBase == "http://127.0.0.1:3012/v1" and .provider == "openai"' "$HOME/.continue/config.json" >/dev/null
jq -e '.models[0].model == "deepseek-v4-flash"' "$HOME/.continue/config.json" >/dev/null
jq -e '.selectedModelsByProfileId.local.chat | contains("DeepSeek")' "$HOME/.continue/index/globalContext.json" >/dev/null
jq -e '.selectedModelsByProfileId.local.edit | contains("DeepSeek")' "$HOME/.continue/index/globalContext.json" >/dev/null
jq -e '.selectedModelsByProfileId.local.apply == "External model"' "$HOME/.continue/index/globalContext.json" >/dev/null
[ "$(stat -c '%a' "$HOME/.continue/config.json")" = 600 ]
mkdir -p "$HOME/.local/share/phasezero/ai-proxies/deepsproxy/.git" \
    "$HOME/.local/share/phasezero/ai-proxies/deepsproxy/deepseek_profile/Default"
printf 'session-data\n' > "$HOME/.local/share/phasezero/ai-proxies/deepsproxy/deepseek_profile/Default/Cookies"
DISPLAY=:0 "$ROOT/linux/pz" ai proxies auth deepsproxy \
    | jq -e '.[0].webValidation.status == "session-present"' >/dev/null
grep -q 'done < <(selected_rows)' "$ROOT/linux/ai/proxy-suite.sh"
echo "linux-ai-proxies smoke ok"
