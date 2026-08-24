#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
# proxy-suite.sh resolves opencode/zcode/ide-defaults under $XDG_CONFIG_HOME, so
# keep it aligned with the seeded $HOME/.config tree (Continue already uses HOME).
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$WORK/state"
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
[ "$(jq 'length' <<< "$status")" -eq 11 ]
jq -e 'map(.id) | index("qwen-worker-proxy") != null and index("unlimited-ai-proxy") != null' <<< "$status" >/dev/null
jq -e '
  .[] | select(.id == "unlimited-ai-proxy") | .kind == "node" and .port == 8787
' <<< "$status" >/dev/null
jq -e '
  .[] | select(.id == "mimo-ai-proxy") | .kind == "go" and .port == 3013
' <<< "$status" >/dev/null
plan="$("$ROOT/linux/pz" ai proxies plan all)"
[ "$(grep -c '^would install ' <<< "$plan")" -eq 4 ]
[ "$(grep -c '^blocked ' <<< "$plan")" -eq 6 ]
grep -Eq '^would install kimiproxy .* at commit [0-9a-f]{40} ' <<< "$plan"
auth="$("$ROOT/linux/pz" ai proxies auth all)"
[ "$(jq 'length' <<< "$auth")" -eq 11 ]
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
if grep -Eq 'SERVICE_TOKEN|USER_ID|XIAOMI_CHATBOT_PH|API_KEY|phasezero-qwen' <<< "$auth"; then
    echo "FAIL: credentials leaked into proxies auth output"
    exit 1
fi
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

# Consolidated snapshot for the native UI "Proxies IA" page: same 11 proxies as
# auth plus redacted IDE integration counters, in a single read-only command.
detailed="$("$ROOT/linux/pz" ai proxies detailed-status)"
jq -e '.schemaVersion == 1 and (.proxies | length == 11)' <<< "$detailed" >/dev/null
jq -e '.proxies[] | select(.id == "deepsproxy") | .webValidation.kind == "browser-session"' <<< "$detailed" >/dev/null
jq -e '.ide | has("envDefaults") and has("opencodeProviders") and has("continueModels") and has("zcodeProviders")' <<< "$detailed" >/dev/null
jq -e '.ide.envDefaults == true and .ide.opencodeProviders >= 1 and .ide.continueModels == 11' <<< "$detailed" >/dev/null
jq -e '.provenance.trustMode == "snapshot-pin" and .provenance.semanticAudit == false and (.provenance.sources | length == 4)' <<< "$detailed" >/dev/null
if grep -Eq 'API_KEY=|Bearer ' <<< "$detailed"; then
    echo "FAIL: credentials leaked into detailed auth output"
    exit 1
fi
grep -q 'restart) service_action restart ;;' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'ensure|use|prepare) ensure_selected' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'SuccessExitStatus=143' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'emit_login_json' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'login_window_kind' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'set_proxy_credentials' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'open_opencode_proxy' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'qwenproxy.db' "$ROOT/linux/ai/proxy-suite.sh"
# set-credentials must persist via upsert and never echo the payload keys' values in jq.
grep -q 'upsert_env_var "\$file" SERVICE_TOKEN' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'jq -r .serviceToken' "$ROOT/linux/ai/proxy-suite.sh" || grep -q 'serviceToken' "$ROOT/linux/ai/proxy-suite.sh"
# Regression: `[ id = qwenproxy ] && pz_info` as last command made kimi/deeps login exit 1.
if grep -n '\[ "$id" = qwenproxy \] && pz_info' "$ROOT/linux/ai/proxy-suite.sh"; then
    echo "FAIL: login_proxy still ends with a failing && for non-qwen ids"
    exit 1
fi
# Remove deliberately incomplete auth-only fixture before provenance-gated ensure.
rm -rf "$HOME/.local/share/phasezero/ai-proxies/deepsproxy"
ensure="$("$ROOT/linux/pz" ai proxies ensure qwenproxy --dry-run)"
jq -e '.schemaVersion == 1 and .dryRun == true and .id == "qwenproxy" and (.summary|length>0)' <<< "$ensure" >/dev/null
jq -e '.steps | map(.name) | index("install") != null and index("login") != null' <<< "$ensure" >/dev/null
if grep -Eq 'API_KEY=|Bearer |SERVICE_TOKEN' <<< "$ensure"; then
    echo "FAIL: credentials leaked into proxies ensure output"
    exit 1
fi
ensure_all="$("$ROOT/linux/pz" ai proxies ensure all --dry-run)"
jq -e '.schemaVersion == 1 and .dryRun == true and (.proxies|length==4) and (.summary|length>0)' <<< "$ensure_all" >/dev/null

# Trusted-source manifest must pin four exact snapshots, never a moving branch.
jq -e '
  .trustMode == "snapshot-pin" and .semanticAudit == false and
  (.sources | length == 4) and
  all(.sources[]; (.commit | test("^[0-9a-f]{40}$")) and (.tree | test("^[0-9a-f]{40}$")) and .approvedForInstall == true)
' "$ROOT/assets/ai/proxy-suite-trusted-sources.json" >/dev/null

# Build a local exact snapshot. It validates provenance without network access.
mkdir -p "$WORK/bin" "$WORK/mimo-source" "$HOME/.config/phasezero/ai-proxies"
printf '%s\n' 'package main' 'func main() {}' > "$WORK/mimo-source/main.go"
printf '%s\n' 'test license' > "$WORK/mimo-source/LICENSE"
printf '%s\n' 'example.invalid/module v1.0.0 h1:test' > "$WORK/mimo-source/go.sum"
git -C "$WORK/mimo-source" init -q
git -C "$WORK/mimo-source" config user.name PhaseZero
git -C "$WORK/mimo-source" config user.email phasezero@example.invalid
git -C "$WORK/mimo-source" add main.go LICENSE go.sum
git -C "$WORK/mimo-source" commit -qm snapshot
mimo_commit="$(git -C "$WORK/mimo-source" rev-parse HEAD)"
mimo_tree="$(git -C "$WORK/mimo-source" rev-parse 'HEAD^{tree}')"
mimo_license="$(sha256sum "$WORK/mimo-source/LICENSE" | awk '{print $1}')"
mimo_lock="$(sha256sum "$WORK/mimo-source/go.sum" | awk '{print $1}')"
rm -rf "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy"
git clone -q "$WORK/mimo-source" "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy"
jq -n --arg repo "$WORK/mimo-source" --arg commit "$mimo_commit" --arg tree "$mimo_tree" \
    --arg license "$mimo_license" --arg lock "$mimo_lock" '
  {schemaVersion:1,trustMode:"snapshot-pin",semanticAudit:false,sources:[{
    id:"mimo-ai-proxy",repository:$repo,branch:"main",commit:$commit,tree:$tree,
    approvedForInstall:true,license:{path:"LICENSE",spdx:"test",sha256:$license},
    dependencyLocks:[{path:"go.sum",sha256:$lock}]
  }]}
' > "$WORK/mimo-manifest.json"
PZ_AI_PROXY_TRUSTED_SOURCES_FILE="$WORK/mimo-manifest.json" \
    "$ROOT/linux/pz" ai proxies provenance mimo-ai-proxy \
    | jq -e '.sources[0].ready == true and .sources[0].commitMatch == true' >/dev/null

# A configured, valid proxy whose user service fails must never be reported ready.
cat > "$WORK/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --user)
    shift
    [ "${1:-}" = is-active ] && { printf '%s\n' inactive; exit 3; }
    [ "${1:-}" = reset-failed ] && exit 0
    [ "${1:-}" = enable ] && exit 1
    ;;
esac
exit 1
SH
chmod +x "$WORK/bin/systemctl"
printf '%s\n' 'SERVICE_TOKEN=test' 'USER_ID=test' 'XIAOMI_CHATBOT_PH=test' \
    > "$HOME/.config/phasezero/ai-proxies/mimo-ai-proxy.env"
set +e
mimo_failed="$(PZ_AI_PROXY_TRUSTED_SOURCES_FILE="$WORK/mimo-manifest.json" PATH="$WORK/bin:$PATH" \
    "$ROOT/linux/pz" ai proxies ensure mimo-ai-proxy 2>/dev/null)"
mimo_rc=$?
set -e
[ "$mimo_rc" -ne 0 ]
jq -e '.ok == false and .status == "error" and (.summary | test("não iniciou"))' \
    <<< "$mimo_failed" >/dev/null

# A commit mismatch blocks runtime before systemctl can start anything.
git -C "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy" config user.name PhaseZero
git -C "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy" config user.email phasezero@example.invalid
git -C "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy" commit --allow-empty -qm unapproved
cat > "$WORK/bin/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' called >> "$WORK/systemctl-called"
exit 0
SH
chmod +x "$WORK/bin/systemctl"
set +e
PZ_AI_PROXY_TRUSTED_SOURCES_FILE="$WORK/mimo-manifest.json" PATH="$WORK/bin:$PATH" \
    "$ROOT/linux/pz" ai proxies start mimo-ai-proxy >/dev/null 2>&1
tamper_rc=$?
set -e
[ "$tamper_rc" -eq 69 ]
[ ! -e "$WORK/systemctl-called" ]
PZ_AI_PROXY_TRUSTED_SOURCES_FILE="$WORK/mimo-manifest.json" \
    "$ROOT/linux/pz" ai proxies provenance mimo-ai-proxy \
    | jq -e '.sources[0].ready == false and .sources[0].commitMatch == false' >/dev/null
grep -q 'start_proxy_service' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'wait_proxy_chat' "$ROOT/linux/ai/proxy-suite.sh"
echo "linux-ai-proxies smoke ok"
