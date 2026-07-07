#!/usr/bin/env bash
# Portable Linux installer/manager for PhaseZero AI proxy repositories.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
TARGET="${2:-all}"
ROOT="${PZ_AI_PROXY_ROOT:-$HOME/.local/share/phasezero/ai-proxies}"
BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
RUNTIME="$ROOT/.runtime/node24"
NODE_BIN="$RUNTIME/node_modules/node/bin/node"
NPM_CLI="$RUNTIME/node_modules/npm/bin/npm-cli.js"

# Ports mirror the Windows catalog (3010-3013) to avoid colliding with common
# local services: open-webui/grafana default to :3000 and uptime-kuma (homelab)
# to :3001, so the older 3000/3001 assignment made kimi/qwen fail with EADDRINUSE.
proxy_rows() {
    cat <<'EOF'
kimiproxy|https://github.com/pedrofariasx/kimiproxy.git|3010|node
qwen-worker-proxy|https://github.com/aptdnfapt/qwen-worker-proxy.git|0|worker
qwenproxy|https://github.com/pedrofariasx/qwenproxy.git|3011|node
antigravity-proxy|https://github.com/pedrofariasx/antigravity-proxy.git|8090|node
antigravity-openai-adapter|https://github.com/pedrofariasx/antigravity-openai-adapter.git|8081|node
ollieproxy|https://github.com/pedrofariasx/ollieproxy.git|3002|node
airlock|https://github.com/pedrofariasx/airlock.git|0|library
unlimited-ai-proxy|https://github.com/pedrofariasx/unlimited-ai-proxy.git|8787|node
deepsproxy|https://github.com/pedrofariasx/deepsproxy.git|3012|node
mimo-ai-proxy|https://github.com/pedrofariasx/mimo-ai-proxy.git|3013|go
EOF
}

selected_rows() {
    if [ "$TARGET" = all ]; then proxy_rows; else proxy_rows | awk -F'|' -v id="$TARGET" '$1 == id'; fi
}

ensure_node_runtime() {
    local system_npm
    system_npm="$(command -v npm || true)"
    [ -n "$system_npm" ] || { pz_error "npm required"; return 1; }
    if [ ! -x "$NODE_BIN" ] || [ ! -f "$NPM_CLI" ]; then
        pz_info "Installing isolated Node.js 24 runtime for proxy compatibility"
        install -d "$RUNTIME"
        "$system_npm" install --prefix "$RUNTIME" --no-save "node@24" "npm@10"
    fi
    install -d "$RUNTIME/bin"
    ln -sfn "$NODE_BIN" "$RUNTIME/bin/node"
    pz_info "Proxy runtime: Node $("$NODE_BIN" --version), npm $("$NODE_BIN" "$NPM_CLI" --version)"
}

run_npm() {
    local dir="$1"
    shift
    (cd "$dir" && PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$NPM_CLI" "$@")
}

install_one() {
    local id="$1" repo="$2" port="$3" kind="$4" dir="$ROOT/$id"
    install -d "$ROOT" "$BIN" "$UNITS"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" fetch --prune
        if [ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir" rev-parse '@{upstream}')" ]; then
            if [ -n "$(git -C "$dir" status --porcelain)" ]; then
                pz_warn "Update skipped for $id: managed checkout has local/generated changes"
            else
                git -C "$dir" merge --ff-only '@{upstream}'
            fi
        fi
    else
        git clone --depth 1 "$repo" "$dir"
    fi
    case "$kind" in
        node|worker|library)
            if [ -f "$dir/package-lock.json" ]; then run_npm "$dir" ci --ignore-scripts=false
            elif [ -f "$dir/package.json" ]; then run_npm "$dir" install --ignore-scripts=false
            fi
            if [ "$kind" = node ] && jq -er '.scripts.start // ""' "$dir/package.json" 2>/dev/null | grep -q 'dist/'; then
                run_npm "$dir" run build
            fi
            case "$id" in
                kimiproxy|qwenproxy|deepsproxy)
                    run_npm "$dir" exec -- playwright install chromium
                    ;;
            esac
            ;;
        go)
            if [ -f "$dir/go.mod" ]; then
                install -d "$dir/.phasezero-bin"
                (cd "$dir" && go build -o "$dir/.phasezero-bin/$id" .)
            fi
            ;;
    esac
    if [ "$kind" = node ] || [ "$kind" = go ]; then
        local run_command
        if [ "$kind" = node ]; then
            run_command="exec \"$NODE_BIN\" \"$NPM_CLI\" start"
        else
            run_command="exec \"$dir/.phasezero-bin/$id\""
        fi
        pz_write_managed_file "$BIN/$id" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$dir"
[ -f "\$HOME/.config/phasezero/ai-proxies/$id.env" ] && set -a && source "\$HOME/.config/phasezero/ai-proxies/$id.env" && set +a
export PORT="\${PORT:-$port}"
export PATH="$RUNTIME/bin:\$PATH"
$run_command
EOF
        chmod +x "$BIN/$id"
        pz_write_managed_file "$UNITS/phasezero-$id.service" user <<EOF
[Unit]
Description=PhaseZero $id OpenAI-compatible proxy
After=network-online.target

[Service]
Type=simple
ExecStart=$BIN/$id
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    fi
    pz_info "AI proxy installed: $id ($kind)"
}

install_selected() {
    command -v git >/dev/null || { pz_error "git required"; return 1; }
    ensure_node_runtime
    local id repo port kind count=0
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        install_one "$id" "$repo" "$port" "$kind"
        count=$((count + 1))
    done < <(selected_rows)
    [ "$count" -gt 0 ] || { pz_error "unknown proxy: $TARGET"; return 2; }
    systemctl --user daemon-reload >/dev/null 2>&1 || true
}

status_json() {
    local first=true id repo port kind dir installed service
    printf '['
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        dir="$ROOT/$id"; installed=false; service="not-applicable"
        [ -d "$dir/.git" ] && installed=true
        { [ "$kind" = node ] || [ "$kind" = go ]; } &&
            service="$(systemctl --user is-active "phasezero-$id.service" 2>/dev/null || true)"
        $first || printf ','
        first=false
        jq -cn --arg id "$id" --arg repo "$repo" --arg kind "$kind" --arg path "$dir" \
            --arg service "${service:-inactive}" --argjson port "$port" --argjson installed "$installed" \
            '{id:$id,repo:$repo,kind:$kind,path:$path,port:$port,installed:$installed,service:$service}'
    done < <(selected_rows)
    printf ']\n'
}

service_action() {
    local mode="$1" id repo port kind count=0
    while IFS='|' read -r id repo port kind; do
        { [ "$kind" = node ] || [ "$kind" = go ]; } || continue
        if [ "$mode" = start ]; then
            systemctl --user enable --now "phasezero-$id.service"
        else
            systemctl --user disable --now "phasezero-$id.service"
        fi
        count=$((count + 1))
    done < <(selected_rows)
    [ "$count" -gt 0 ] || pz_warn "no local service for $TARGET"
}

# --- IDE integration (opencode / opencode-desktop / zcode) -------------------
#
# Parity with the Windows ai-proxy-suite: expose the local proxies as selectable
# OpenAI-compatible providers in the IDEs. The proxies scrape vendor web UIs via
# Playwright, so a model only *answers* after a one-time `npm run login`; wiring
# the provider is independent of that and safe to do up front. We deliberately do
# NOT make a proxy the opencode default (that would reintroduce "Interrompido"
# until the user logs in) — the keyless Zen free default from setup-opencode.sh
# stays in charge; proxies are just selectable.
OPENCODE_JSONC="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc"
OPENCODE_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
ZCODE_STORE="${XDG_CONFIG_HOME:-$HOME/.config}/ai.z.zcode/store.json"
PROXY_ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-proxies"
IDE_ENV_DEFAULTS="$PROXY_ENV_DIR/ide-defaults.env"

# id|port|providerId|displayName|defaultModel|models(csv) — the user-facing four.
# Ports mirror proxy_rows() above so the provider baseURL matches the listener.
proxy_ide_rows() {
    cat <<'EOF'
kimiproxy|3010|phasezero-kimi|PhaseZero Kimi (K2, proxy)|k2d6-thinking|k2d6-thinking,k2d6
qwenproxy|3011|phasezero-qwen|PhaseZero Qwen (proxy)|qwen3.6-plus|qwen3.6-plus,qwen3.6-plus-no-thinking
deepsproxy|3012|phasezero-deepseek|PhaseZero DeepSeek (proxy)|deepseek-v4-flash|deepseek-v4-flash,deepseek-v4-flash-thinking,deepseek-v4-pro,deepseek-v4-pro-thinking
mimo-ai-proxy|3013|phasezero-mimo|PhaseZero Mimo (proxy)|mimo-v2.5-pro|mimo-v2.5-pro,mimo-v2.5,mimo-v2.5-no-thinking
EOF
}

# The proxy the shared env defaults point at (user preference: deepseek flash free).
IDE_DEFAULT_PROXY="${PZ_AI_PROXY_IDE_DEFAULT:-deepsproxy}"

upsert_env_var() {
    local file="$1" key="$2" value="$3" tmp
    install -d "$(dirname "$file")"
    [ -f "$file" ] || : > "$file"
    tmp="$(mktemp)"
    grep -vE "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
    chmod 600 "$file"
}

# Return (and persist) a stable local API key for a proxy, without clobbering any
# other vars the user configured (QWEN_*, mimo tokens, ...).
ensure_proxy_key() {
    local id="$1" port="$2" file="$PROXY_ENV_DIR/$id.env" key=""
    [ -f "$file" ] && key="$(awk -F= '$1=="API_KEY"{print $2; exit}' "$file")"
    if [ -z "$key" ]; then
        key="pz-$(head -c 24 /dev/urandom | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 28)"
        [ -n "$key" ] || key="pz-$id-local"
    fi
    upsert_env_var "$file" PORT "$port"
    upsert_env_var "$file" API_KEY "$key"
    printf '%s\n' "$key"
}

merge_opencode_provider() {
    local file="$1" pid="$2" name="$3" baseurl="$4" key="$5" models_csv="$6"
    [ -f "$file" ] || return 0
    if ! jq empty "$file" >/dev/null 2>&1; then
        pz_warn "$(basename "$file") is not strict JSON (comments?); skipped proxy provider merge"
        return 0
    fi
    local models_json tmp
    models_json="$(printf '%s' "$models_csv" | jq -R 'split(",") | map({(.): {}}) | add')"
    cp "$file" "$file.bak.$(date +%s)"
    tmp="$(mktemp)"
    jq --arg pid "$pid" --arg name "$name" --arg url "$baseurl" --arg key "$key" --argjson models "$models_json" '
        .provider = (.provider // {})
        | .provider[$pid] = {
            "npm": "@ai-sdk/openai-compatible",
            "name": $name,
            "options": {"baseURL": $url, "apiKey": $key},
            "models": $models
          }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

configure_opencode_ide() {
    local id port pid name default models key baseurl count=0
    while IFS='|' read -r id port pid name default models; do
        [ -n "$id" ] || continue
        key="$(ensure_proxy_key "$id" "$port")"
        baseurl="http://127.0.0.1:$port/v1"
        merge_opencode_provider "$OPENCODE_JSONC" "$pid" "$name" "$baseurl" "$key" "$models"
        merge_opencode_provider "$OPENCODE_JSON"  "$pid" "$name" "$baseurl" "$key" "$models"
        count=$((count + 1))
    done < <(proxy_ide_rows)
    pz_info "opencode/opencode-desktop: wired $count PhaseZero proxy providers (default model unchanged; select a proxy model after 'npm run login')"
}

write_ide_env_defaults() {
    local id port pid name default models key baseurl def_key="" def_url="" def_model="" def_pid=""
    install -d "$PROXY_ENV_DIR"
    : > "$IDE_ENV_DEFAULTS.tmp"
    {
        printf '# PhaseZero AI proxy suite — OpenAI-compatible IDE defaults (Linux).\n'
        printf '# Source this for zcode/any OpenAI-compatible tool: set -a; . %s; set +a\n' "$IDE_ENV_DEFAULTS"
    } >> "$IDE_ENV_DEFAULTS.tmp"
    while IFS='|' read -r id port pid name default models; do
        [ -n "$id" ] || continue
        key="$(ensure_proxy_key "$id" "$port")"
        baseurl="http://127.0.0.1:$port/v1"
        local envprefix
        envprefix="$(printf '%s' "$pid" | tr 'a-z-' 'A-Z_')"
        {
            printf '%s_API_KEY=%s\n' "$envprefix" "$key"
            printf '%s_BASE_URL=%s\n' "$envprefix" "$baseurl"
            printf '%s_MODEL=%s\n' "$envprefix" "$default"
        } >> "$IDE_ENV_DEFAULTS.tmp"
        if [ "$id" = "$IDE_DEFAULT_PROXY" ]; then
            def_key="$key"; def_url="$baseurl"; def_model="$default"; def_pid="$pid"
        fi
    done < <(proxy_ide_rows)
    {
        printf 'OPENAI_API_KEY=%s\n' "$def_key"
        printf 'OPENAI_BASE_URL=%s\n' "$def_url"
        printf 'OPENAI_MODEL=%s\n' "$def_model"
        printf 'OPENAI_COMPAT_PROVIDER=%s\n' "$def_pid"
        printf 'PHASEZERO_AI_PROXY_DEFAULT=%s\n' "$def_pid"
    } >> "$IDE_ENV_DEFAULTS.tmp"
    mv "$IDE_ENV_DEFAULTS.tmp" "$IDE_ENV_DEFAULTS"
    chmod 600 "$IDE_ENV_DEFAULTS"
    pz_info "IDE env defaults written: $IDE_ENV_DEFAULTS (default provider: $def_pid/$def_model)"
}

# zcode (ai.z.zcode) is an electron-store app; like Windows it consumes
# OpenAI-compatible endpoints via environment/its own settings rather than a
# provider schema we can safely synthesize. We record the proxy providers in the
# store under a namespaced key (non-breaking) so the app and the user can see
# them, and rely on the shared env defaults for actual routing.
configure_zcode_ide() {
    command -v jq >/dev/null 2>&1 || return 0
    install -d "$(dirname "$ZCODE_STORE")"
    [ -f "$ZCODE_STORE" ] || jq -n '{}' > "$ZCODE_STORE"
    if ! jq empty "$ZCODE_STORE" >/dev/null 2>&1; then
        pz_warn "$ZCODE_STORE is not strict JSON; skipped zcode proxy record"
        return 0
    fi
    local rows_json tmp
    rows_json="$(proxy_ide_rows | jq -R -s '
        split("\n") | map(select(length>0)) | map(split("|")) |
        map({id: .[0], providerId: .[2], name: .[3],
             baseUrl: ("http://127.0.0.1:" + .[1] + "/v1"),
             defaultModel: .[4], models: (.[5] | split(","))})')"
    cp "$ZCODE_STORE" "$ZCODE_STORE.bak.$(date +%s)"
    tmp="$(mktemp)"
    jq --argjson providers "$rows_json" \
       '."phasezero-ai-proxies" = {source:"phasezero", providers:$providers}' \
       "$ZCODE_STORE" > "$tmp" && mv "$tmp" "$ZCODE_STORE"
    pz_info "zcode: recorded $(printf '%s' "$rows_json" | jq 'length') PhaseZero proxy providers in $ZCODE_STORE"
}

configure_ides() {
    command -v jq >/dev/null 2>&1 || { pz_error "jq required for IDE configuration"; return 1; }
    configure_opencode_ide
    write_ide_env_defaults
    configure_zcode_ide
    pz_info "Proxy IDE configuration complete. Chat via a proxy model needs a one-time login: cd $ROOT/<proxy> && PATH=\"$RUNTIME/bin:\$PATH\" npm run login"
}

port_open() {
    timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# Honest end-to-end probe. These proxies launch a Playwright/Chromium session
# BEFORE binding (kimi/deepseek/mimo serve a static /v1/models; qwen's is dynamic
# and needs a Qwen session), so we (1) warm every service in parallel, (2) wait
# for the TCP port, then (3) classify: service up/down, models ok/needs-login,
# chat ok/needs-login. Chat and qwen's models require a one-time `npm run login`.
test_proxies() {
    local id repo port kind first=true
    local ids=() ports=()
    # Pass 1: start every user-facing proxy so they warm up concurrently.
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        { [ "$kind" = node ] || [ "$kind" = go ]; } || continue
        proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{f=1} END{exit f?0:1}' || continue
        systemctl --user start "phasezero-$id.service" >/dev/null 2>&1 || true
        ids+=("$id"); ports+=("$port")
    done < <(proxy_rows)

    printf '['
    local idx key url up i mcode ccode models chat model
    for idx in "${!ids[@]}"; do
        id="${ids[$idx]}"; port="${ports[$idx]}"
        key="$(awk -F= '$1=="API_KEY"{print $2; exit}' "$PROXY_ENV_DIR/$id.env" 2>/dev/null || true)"
        url="http://127.0.0.1:$port/v1"
        model="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print $5}')"
        up=false
        for i in $(seq 1 40); do port_open "$port" && { up=true; break; }; sleep 1; done
        models=unreachable; chat=unreachable
        if $up; then
            local mbody
            mbody="$(curl -s -m 10 -H "Authorization: Bearer $key" "$url/models" 2>/dev/null || true)"
            # Require a real OpenAI models list; rejects HTML from a colliding
            # service (e.g. open-webui) that merely returns HTTP 200.
            if printf '%s' "$mbody" | jq -e '(.data|type=="array" and length>0) or (.object=="list")' >/dev/null 2>&1; then
                models=ok
            else
                models=needs-login
            fi
            ccode="$(curl -s -m 25 -o /dev/null -w '%{http_code}' -X POST "$url/chat/completions" \
                -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
                --data "$(jq -nc --arg m "$model" '{model:$m, messages:[{role:"user",content:"ping"}], stream:false, max_tokens:8}')" 2>/dev/null || true)"
            [ "$ccode" = "200" ] && chat=ok || chat=needs-login
        fi
        $first || printf ','
        first=false
        jq -nc --arg id "$id" --arg url "$url" --arg svc "$($up && echo running || echo down)" \
            --arg models "$models" --arg chat "$chat" \
            '{id:$id, endpoint:$url, service:$svc, modelsEndpoint:$models, chat:$chat}'
    done
    printf ']\n'
}

case "$ACTION" in
    status|list) status_json ;;
    plan|dry-run) selected_rows | awk -F'|' '{print "would install " $1 " from " $2 " (" $4 ")"}' ;;
    install|setup|update|repair)
        install_selected
        configure_ides
        ;;
    configure-ides|ides|configure) configure_ides ;;
    test|verify) test_proxies ;;
    start|enable) service_action start ;;
    stop|disable) service_action stop ;;
    *) pz_error "usage: proxy-suite.sh (status|plan|install|configure-ides|test|start|stop) [all|id]"; exit 2 ;;
esac
