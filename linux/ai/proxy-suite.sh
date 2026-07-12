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
PATCH_STATE_DIR="$ROOT/.phasezero-state"

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
9router|https://github.com/decolua/9router.git|20128|npm
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

# Parse dotenv as data. Never source it: a credential file must not execute shell.
load_proxy_env() {
    local file="$1" line key value
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            echo "invalid dotenv line in $file (expected NAME=value)" >&2
            return 2
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" == \"*\" && "$value" == *\" ]] ||
           [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        case "$key" in
            PATH|IFS|CDPATH|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|GLOBIGNORE|LD_*|DYLD_*|PYTHONPATH|PERL5OPT|RUBYOPT|NODE_OPTIONS)
                echo "unsafe dotenv variable rejected in $file: $key" >&2
                return 2
                ;;
        esac
        export "${key?}=$value"
    done < "$file"
}

managed_patch_file() {
    case "$1" in
        kimiproxy|deepsproxy) printf '%s\n' 'src/index.ts' ;;
        mimo-ai-proxy) printf '%s\n' 'main.go' ;;
        *) return 1 ;;
    esac
}

restore_managed_loopback_patch() {
    local id="$1" dir="$2" rel state file backup actual patched baseline backup_hash
    rel="$(managed_patch_file "$id" 2>/dev/null || true)"
    [ -n "$rel" ] || return 0
    state="$PATCH_STATE_DIR/$id.json"
    backup="$PATCH_STATE_DIR/$id.original"
    file="$dir/$rel"
    [ -f "$state" ] && [ -f "$file" ] && [ -f "$backup" ] || return 0
    actual="$(sha256sum "$file" | awk '{print $1}')"
    patched="$(jq -r '.patchedSha256 // empty' "$state" 2>/dev/null || true)"
    baseline="$(jq -r '.baselineSha256 // empty' "$state" 2>/dev/null || true)"
    backup_hash="$(sha256sum "$backup" | awk '{print $1}')"
    if [ -n "$patched" ] && [ "$actual" = "$patched" ] &&
       [ -n "$baseline" ] && [ "$backup_hash" = "$baseline" ]; then
        cp -p -- "$backup" "$file"
        rm -f -- "$state" "$backup"
        pz_info "restored managed loopback patch before update: $id"
    else
        pz_warn "managed proxy source changed after loopback patch; preserving local edits: $id/$rel"
    fi
}

apply_loopback_patch() {
    local id="$1" dir="$2" file rel baseline patched state backup
    case "$id" in
        kimiproxy|deepsproxy)
            rel="src/index.ts"
            file="$dir/$rel"
            [ -f "$file" ] || { pz_error "loopback patch target missing: $id/$rel"; return 1; }
            if grep -q 'process.env.PZ_BIND_HOST' "$file"; then return 0; fi
            if grep -Eq 'hostname:.*(process\.env\.(HOST|BIND_HOST)|127\.0\.0\.1)' "$file"; then
                pz_info "upstream already has configurable loopback bind: $id"
                return 0
            fi
            baseline="$(sha256sum "$file" | awk '{print $1}')"
            install -d "$PATCH_STATE_DIR"
            backup="$PATCH_STATE_DIR/$id.original"
            cp -p -- "$file" "$backup"
            perl -0pi -e 's/serve\(\{\s*fetch: app\.fetch,\s*port\s*\}\);/serve({\n      fetch: app.fetch,\n      port,\n      hostname: process.env.PZ_BIND_HOST || process.env.HOST || "127.0.0.1"\n    });/g' "$file"
            grep -q 'process.env.PZ_BIND_HOST' "$file" || { pz_error "loopback patch no longer matches upstream: $id"; return 1; }
            ;;
        mimo-ai-proxy)
            rel="main.go"
            file="$dir/$rel"
            [ -f "$file" ] || { pz_error "loopback patch target missing: $id/$rel"; return 1; }
            if grep -q 'PZ_BIND_HOST' "$file"; then return 0; fi
            baseline="$(sha256sum "$file" | awk '{print $1}')"
            install -d "$PATCH_STATE_DIR"
            backup="$PATCH_STATE_DIR/$id.original"
            cp -p -- "$file" "$backup"
            perl -0pi -e 's|// For Docker environments, it'"'"'s safer to bind to 0\.0\.0\.0 explicitly\s*\n\s*address := "0\.0\.0\.0:" \+ port|host := os.Getenv("PZ_BIND_HOST")\n\tif host == "" {\n\t\thost = os.Getenv("HOST")\n\t}\n\tif host == "" {\n\t\thost = "127.0.0.1"\n\t}\n\taddress := host + ":" + port|s' "$file"
            grep -q 'PZ_BIND_HOST' "$file" || { pz_error "loopback patch no longer matches upstream: $id"; return 1; }
            ;;
        *) return 0 ;;
    esac
    patched="$(sha256sum "$file" | awk '{print $1}')"
    state="$PATCH_STATE_DIR/$id.json"
    jq -n --arg id "$id" --arg file "$rel" --arg baselineSha256 "$baseline" \
        --arg patchedSha256 "$patched" --arg appliedAt "$(date -Iseconds)" \
        '{schemaVersion:1,id:$id,file:$file,baselineSha256:$baselineSha256,patchedSha256:$patchedSha256,appliedAt:$appliedAt}' \
        > "$state"
    pz_info "loopback bind patch applied: $id"
}

install_one() {
    local id="$1" repo="$2" port="$3" kind="$4" dir
    if [ "$id" = 9router ] && [ "$kind" = npm ]; then
        bash "$PZ_ROOT/linux/ai/9router-manager.sh" install
        return
    fi
    dir="$ROOT/$id"
    install -d "$ROOT" "$BIN" "$UNITS"
    if [ -d "$dir/.git" ]; then
        restore_managed_loopback_patch "$id" "$dir"
        git -C "$dir" fetch --prune
        if [ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir" rev-parse '@{upstream}')" ]; then
            if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
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
            apply_loopback_patch "$id" "$dir"
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
            apply_loopback_patch "$id" "$dir"
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
$(declare -f load_proxy_env)
cd "$dir"
load_proxy_env "\$HOME/.config/phasezero/ai-proxies/$id.env"
export PORT="\${PORT:-$port}"
export PZ_BIND_HOST="\${PZ_BIND_HOST:-\${PHASEZERO_AI_PROXY_HOST:-127.0.0.1}}"
export HOST="\$PZ_BIND_HOST"
export BIND_HOST="\$PZ_BIND_HOST"
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
    command -v jq >/dev/null || { pz_error "jq required"; return 1; }
    command -v sha256sum >/dev/null || { pz_error "sha256sum required"; return 1; }
    command -v perl >/dev/null || { pz_error "perl required for safe loopback patching"; return 1; }
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
        if [ "$id" = 9router ]; then
            [ -x "$dir/bin/9router" ] && installed=true
        else
            [ -d "$dir/.git" ] && installed=true
        fi
        { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } &&
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
        { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } || continue
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
CONTINUE_CONFIG="${PZ_CONTINUE_CONFIG:-$HOME/.continue/config.json}"
CONTINUE_GLOBAL_CONTEXT="${PZ_CONTINUE_GLOBAL_CONTEXT:-$HOME/.continue/index/globalContext.json}"
CONTINUE_EXTENSION="Continue.continue"

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

ordered_proxy_ide_rows() {
    proxy_ide_rows | awk -F'|' -v preferred="$IDE_DEFAULT_PROXY" '$1 == preferred'
    proxy_ide_rows | awk -F'|' -v preferred="$IDE_DEFAULT_PROXY" '$1 != preferred'
}

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
    local id="$1" port="$2" file key=""
    file="$PROXY_ENV_DIR/$id.env"
    [ -f "$file" ] && key="$(awk -F= '$1=="API_KEY"{print $2; exit}' "$file")"
    if [ -z "$key" ]; then
        key="pz-$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
        [ "${#key}" -ge 35 ] || { pz_error "secure proxy key generation failed"; return 1; }
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

ensure_continue_extensions() {
    [ "${PZ_AI_PROXY_SKIP_EXTENSION_INSTALL:-0}" = 1 ] && return 0
    local cli installed found=false
    for cli in code code-oss codium cursor windsurf; do
        command -v "$cli" >/dev/null 2>&1 || continue
        found=true
        installed="$("$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        if ! grep -qx 'continue.continue' <<< "$installed"; then
            pz_info "installing Continue for $cli"
            "$cli" --install-extension "$CONTINUE_EXTENSION" --force >/dev/null || {
                pz_error "$cli could not install $CONTINUE_EXTENSION"
                return 1
            }
        fi
        "$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx 'continue.continue' || {
            pz_error "$CONTINUE_EXTENSION unavailable in $cli after installation"
            return 1
        }
    done
    $found || pz_warn "VS Code-compatible editor not found; Continue configuration was still generated"
}

configure_continue_ide() {
    command -v jq >/dev/null 2>&1 || return 1
    install -d -m 700 "$(dirname "$CONTINUE_CONFIG")"
    if [ -f "$CONTINUE_CONFIG" ] && ! jq empty "$CONTINUE_CONFIG" >/dev/null 2>&1; then
        pz_error "$CONTINUE_CONFIG is not strict JSON; refusing to overwrite user configuration"
        return 1
    fi
    [ -f "$CONTINUE_CONFIG" ] || jq -n '{models:[]}' > "$CONTINUE_CONFIG"

    local rows_file models_file tmp id port pid name default models key baseurl model title model_list
    rows_file="$(mktemp)"
    models_file="$(mktemp)"
    tmp="$(mktemp)"
    trap 'rm -f -- "$rows_file" "$models_file" "$tmp"' RETURN
    : > "$rows_file"
    while IFS='|' read -r id port pid name default models; do
        [ -n "$id" ] || continue
        key="$(ensure_proxy_key "$id" "$port")"
        baseurl="http://127.0.0.1:$port/v1"
        IFS=',' read -ra model_list <<< "$models"
        for model in "${model_list[@]}"; do
            title="[PhaseZero Proxy] ${name#PhaseZero } — $model"
            jq -cn --arg title "$title" --arg model "$model" --arg apiBase "$baseurl" --arg apiKey "$key" \
                '{title:$title,provider:"openai",model:$model,apiBase:$apiBase,apiKey:$apiKey,useLegacyCompletionsEndpoint:false}' \
                >> "$rows_file"
        done
    done < <(ordered_proxy_ide_rows)
    jq -s '.' "$rows_file" > "$models_file"
    cp "$CONTINUE_CONFIG" "$CONTINUE_CONFIG.bak.$(date +%s)"
    jq --slurpfile managed "$models_file" '
      .models = (((.models // []) | if type == "array" then . else [] end)
        | map(select(((.title // "") | startswith("[PhaseZero Proxy] ")) | not)))
        + $managed[0]
      | .allowAnonymousTelemetry = false
    ' "$CONTINUE_CONFIG" > "$tmp"
    mv "$tmp" "$CONTINUE_CONFIG"
    chmod 600 "$CONTINUE_CONFIG"
    find "$(dirname "$CONTINUE_CONFIG")" -maxdepth 1 -type f -name 'config.json.bak.*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | awk 'NR>5{sub(/^[^ ]+ /, ""); print}' | xargs -r rm -f --
    trap - RETURN
    rm -f -- "$rows_file" "$models_file"
    configure_continue_selection
    pz_info "Continue: configured $(jq '[.models[] | select((.title // "") | startswith("[PhaseZero Proxy] "))] | length' "$CONTINUE_CONFIG") proxy models for VS Code/Code-OSS"
}

configure_continue_selection() {
    [ -f "$CONTINUE_GLOBAL_CONTEXT" ] || return 0
    jq empty "$CONTINUE_GLOBAL_CONTEXT" >/dev/null 2>&1 || return 0
    local default_title tmp
    default_title="$(jq -r --arg url "http://127.0.0.1:$(proxy_ide_rows | awk -F'|' -v i="$IDE_DEFAULT_PROXY" '$1==i{print $2}')/v1" \
        '[.models[] | select(.apiBase == $url)][0].title // empty' "$CONTINUE_CONFIG")"
    [ -n "$default_title" ] || return 0
    tmp="$(mktemp)"
    jq --arg title "$default_title" '
      if (.selectedModelsByProfileId | type) == "object" then
        .selectedModelsByProfileId |= with_entries(
          .value |= reduce ["chat","edit","apply"][] as $role (.;
            if ((.[$role] // "") == "" or ((.[$role] // "") | startswith("[PhaseZero Proxy] ")))
            then .[$role] = $title else . end))
      else . end
    ' "$CONTINUE_GLOBAL_CONTEXT" > "$tmp"
    cp "$CONTINUE_GLOBAL_CONTEXT" "$CONTINUE_GLOBAL_CONTEXT.bak.$(date +%s)"
    mv "$tmp" "$CONTINUE_GLOBAL_CONTEXT"
    chmod 600 "$CONTINUE_GLOBAL_CONTEXT"
    find "$(dirname "$CONTINUE_GLOBAL_CONTEXT")" -maxdepth 1 -type f -name 'globalContext.json.bak.*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | awk 'NR>5{sub(/^[^ ]+ /, ""); print}' | xargs -r rm -f --
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
    ensure_continue_extensions
    configure_continue_ide
    pz_info "Proxy IDE configuration complete for OpenCode, VS Code, Code-OSS and ZCode. Browser proxies need one valid saved session."
}

port_open() {
    timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# --- Enable + OAuth login (UI "Habilitar" buttons) ---------------------------
#
# kimiproxy/qwenproxy/deepsproxy authenticate by scraping the vendor's own web
# chat via a real, visible Playwright browser (`npm run login`), not a token
# form — there is no headless OAuth endpoint to hit. mimo-ai-proxy is NOT
# included here (it authenticates via manually-copied session tokens in its
# .env, not a browser flow).
#
# On this host, launching `npm run login` through a spawned terminal emulator
# (kitty/alacritty/...), or fully daemonizing it (nohup+disown), reliably made
# Playwright pick chrome-headless-shell instead of a real visible window —
# even with DISPLAY/WAYLAND_DISPLAY correctly inherited either way. Only a
# plain `setsid`-detached child, launched directly (no terminal, no
# nohup/disown), reliably launches headed and survives this script exiting
# (background jobs of a non-interactive script are not SIGHUP'd on exit).
LOGIN_CAPABLE_PROXIES=(kimiproxy qwenproxy deepsproxy)

is_login_capable_proxy() {
    local id="$1" p
    for p in "${LOGIN_CAPABLE_PROXIES[@]}"; do [ "$p" = "$id" ] && return 0; done
    return 1
}

dotenv_has_any_key() {
    local file="$1"
    shift
    [ -f "$file" ] || return 1
    awk -F= -v keys="$*" '
        BEGIN { split(keys, wanted, " "); for (i in wanted) want[wanted[i]]=1 }
        /^[[:space:]]*#/ { next }
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            val=$0
            sub(/^[^=]*=/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (key in want && val != "") found=1
        }
        END { exit found ? 0 : 1 }
    ' "$file"
}

session_artifact_present() {
    local id="$1" dir="$ROOT/$1"
    case "$id" in
        kimiproxy) [ -s "$dir/kimi_profile/Default/Cookies" ] ;;
        qwenproxy) find "$dir/qwen_profiles" -type f -name Cookies -size +0c -print -quit 2>/dev/null | grep -q . ;;
        deepsproxy) [ -s "$dir/deepseek_profile/Default/Cookies" ] ;;
        *) return 1 ;;
    esac
}

login_process_running() {
    local id="$1" state="$PZ_STATE/ai-proxies/$1-login.json" pid cwd
    [ -f "$state" ] || return 1
    pid="$(jq -r '.pid // 0' "$state" 2>/dev/null || echo 0)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    [ "$cwd" = "$ROOT/$id" ]
}

saved_login_status() {
    local state="$PZ_STATE/ai-proxies/$1-login.json"
    [ -f "$state" ] || return 1
    [ "$(jq -r '.status // empty' "$state" 2>/dev/null || true)" = authenticated ]
}

mimo_missing_groups_json() {
    local file="$1" missing=()
    dotenv_has_any_key "$file" SERVICE_TOKEN SERVICE_TOKENS MIMO_SERVICE_TOKEN MIMO_SERVICE_TOKENS XIAOMI_SERVICE_TOKEN XIAOMI_SERVICE_TOKENS || missing+=("service-token-group")
    dotenv_has_any_key "$file" USER_ID USER_IDS MIMO_USER_ID MIMO_USER_IDS XIAOMI_USER_ID XIAOMI_USER_IDS || missing+=("user-id-group")
    dotenv_has_any_key "$file" XIAOMI_CHATBOT_PH XIAOMI_CHATBOT_PHS MIMO_XIAOMI_CHATBOT_PH MIMO_XIAOMI_CHATBOT_PHS || missing+=("chatbot-ph-group")
    jq -cn '$ARGS.positional' --args "${missing[@]}"
}

auth_status_json() {
    local first=true id repo port kind dir installed service env_file api_configured=false
    local required=false web_kind="" web_status="not-applicable" command="" log_path="" missing_json="[]"
    printf '['
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        dir="$ROOT/$id"
        env_file="$PROXY_ENV_DIR/$id.env"
        installed=false
        if [ "$id" = 9router ]; then [ -x "$dir/bin/9router" ] && installed=true
        else [ -d "$dir/.git" ] && installed=true
        fi
        service="not-applicable"
        { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } &&
            service="$(systemctl --user is-active "phasezero-$id.service" 2>/dev/null || true)"
        api_configured=false
        dotenv_has_any_key "$env_file" API_KEY && api_configured=true
        required=false; web_kind=""; web_status="not-applicable"; command=""; log_path=""; missing_json="[]"
        if is_login_capable_proxy "$id"; then
            required=true
            web_kind="browser-session"
            command="linux/pz ai proxies login $id"
            log_path="$PZ_STATE/ai-proxies/$id-login.log"
            if ! $installed; then
                web_status="not-installed"
            elif saved_login_status "$id"; then
                web_status="authenticated"
            elif login_process_running "$id"; then
                web_status="login-running"
            elif session_artifact_present "$id"; then
                web_status="session-present"
            elif [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
                web_status="gui-required"
            else
                web_status="ready-for-login"
            fi
        elif [ "$id" = "mimo-ai-proxy" ]; then
            required=true
            web_kind="env-session"
            command="\$EDITOR $env_file"
            missing_json="$(mimo_missing_groups_json "$env_file")"
            if [ "$(jq 'length' <<< "$missing_json")" -eq 0 ]; then
                web_status="configured"
            else
                web_status="missing-credentials"
            fi
        elif [ "$id" = "9router" ]; then
            required=true
            web_kind="dashboard-provider"
            command="linux/pz ai 9router dashboard"
            if ! $installed; then web_status="not-installed"
            elif [ "$service" != active ]; then web_status="start-required"
            else web_status="dashboard-ready"
            fi
        elif [ "$id" = "qwen-worker-proxy" ]; then
            web_kind="external-deploy"
            web_status="cloudflare-required"
        elif [ "$id" = "airlock" ]; then
            web_kind="library"
            web_status="not-applicable"
        else
            web_kind="local-service"
            web_status="not-required"
        fi
        $first || printf ','
        first=false
        jq -cn --arg id "$id" --arg repo "$repo" --arg kind "$kind" --arg path "$dir" \
            --arg envPath "$env_file" --arg service "${service:-inactive}" --arg webKind "$web_kind" \
            --arg webStatus "$web_status" --arg command "$command" --arg loginLog "$log_path" \
            --argjson port "$port" --argjson installed "$installed" --argjson required "$required" \
            --argjson apiKeyConfigured "$api_configured" --argjson missing "$missing_json" \
            '{
              id:$id, repo:$repo, kind:$kind, path:$path, port:$port,
              installed:$installed, service:$service, envPath:$envPath,
              apiKeyConfigured:$apiKeyConfigured,
              webValidation:{
                required:$required, kind:$webKind, status:$webStatus,
                command:$command, loginLog:$loginLog, missing:$missing
              }
            }'
    done < <(selected_rows)
    printf ']\n'
}

login_proxy() {
    local id="$1" dir="$ROOT/$1" log state login_pid
    if ! is_login_capable_proxy "$id"; then
        pz_error "no browser login flow for '$id' (supported: ${LOGIN_CAPABLE_PROXIES[*]})"
        [ "$id" = "mimo-ai-proxy" ] && pz_error "mimo-ai-proxy authenticates via SERVICE_TOKEN/USER_ID in its .env, not browser login: $PROXY_ENV_DIR/mimo-ai-proxy.env"
        return 2
    fi
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { pz_error "browser login requires a graphical session (DISPLAY or WAYLAND_DISPLAY)"; return 3; }
    [ -d "$dir/.git" ] || { pz_error "$id not installed; run: pz ai proxies install $id"; return 1; }
    [ -f "$dir/package.json" ] && jq -er '.scripts.login // empty' "$dir/package.json" >/dev/null 2>&1 || {
        pz_error "$id has no npm login script"
        return 2
    }
    if login_process_running "$id"; then
        pz_info "login already running for $id; use the existing browser window"
        return 0
    fi
    ensure_node_runtime >/dev/null

    # Avoid reopening OAuth after a valid saved session. A real chat probe is
    # authoritative; profile files alone may contain expired cookies.
    if systemctl --user is-active --quiet "phasezero-$id.service" 2>/dev/null && proxy_chat_probe "$id"; then
        record_login_authenticated "$id"
        pz_info "$id already authenticated; login window not opened"
        return 0
    fi

    # The running proxy SERVER also opens Playwright against this same profile
    # dir, headless (index.ts: initPlaywright(true, ...)). If the service is
    # already up (or starts concurrently) it can win the profile lock before
    # `npm run login` does, and the user never sees a real window — the login
    # script silently ends up sharing the server's existing HEADLESS session.
    # So: stop the service first (freeing the profile), let login claim it
    # exclusively in headed mode, then restart the service once the login
    # process exits, so it picks up the freshly saved cookies.
    systemctl --user stop "phasezero-$id.service" >/dev/null 2>&1 || true

    install -d "$PZ_STATE/ai-proxies"
    log="$PZ_STATE/ai-proxies/$id-login.log"
    state="$PZ_STATE/ai-proxies/$id-login.json"
    : > "$log"

    if [ "$id" = qwenproxy ]; then
        # qwenproxy shows an interactive account-picker menu before opening the
        # browser. Feed the whole answer sequence up front on stdin: Node's
        # readline just blocks on each question() until a line is available,
        # so it's fine that the actual OAuth login (indeterminate wall-clock
        # time) happens between two already-queued lines. "M" = manual browser
        # login, blank = "press enter to open browser", a generated label for
        # the "enter email" prompt (informational only, not a real address),
        # "Q" = quit the menu once the account is saved.
        (cd "$dir" && printf 'M\n\nphasezero-login-%s\n\nQ\n' "$(date +%s)" | \
            setsid env PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$NPM_CLI" run login) >"$log" 2>&1 &
    else
        (cd "$dir" && setsid env PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$NPM_CLI" run login) >"$log" 2>&1 &
    fi
    login_pid=$!
    jq -n --arg id "$id" --arg log "$log" --arg startedAt "$(date -Iseconds)" --argjson pid "$login_pid" \
        '{schemaVersion:1,id:$id,status:"started",pid:$pid,log:$log,startedAt:$startedAt,restartServiceAfterExit:true}' > "$state"

    ( while kill -0 "$login_pid" 2>/dev/null; do sleep 2; done
      systemctl --user enable --now "phasezero-$id.service" >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &

    pz_info "login window opening for $id (real chromium window, not headless) — complete the OAuth login there; phasezero-$id.service restarts automatically once you close it. Log: $log"
    [ "$id" = qwenproxy ] && pz_info "qwenproxy: auto-selected 'manual browser login' from its account menu"
}

record_login_authenticated() {
    record_login_status "$1" authenticated
}

record_login_needs_login() {
    record_login_status "$1" needs-login
}

record_login_status() {
    local id="$1" status="$2" state="$PZ_STATE/ai-proxies/$1-login.json" tmp
    install -d -m 700 "$PZ_STATE/ai-proxies"
    tmp="$(mktemp)"
    if [ -f "$state" ] && jq empty "$state" >/dev/null 2>&1; then
        jq --arg status "$status" --arg checkedAt "$(date -Iseconds)" '.status=$status | .checkedAt=$checkedAt | .pid=0' "$state" > "$tmp"
    else
        jq -n --arg id "$id" --arg status "$status" --arg checkedAt "$(date -Iseconds)" \
            '{schemaVersion:1,id:$id,status:$status,pid:0,checkedAt:$checkedAt}' > "$tmp"
    fi
    mv "$tmp" "$state"
    chmod 600 "$state"
}

proxy_chat_probe() {
    local id="$1" row port model key url code payload
    row="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print; exit}')"
    [ -n "$row" ] || return 1
    port="$(cut -d'|' -f2 <<< "$row")"
    model="$(cut -d'|' -f5 <<< "$row")"
    key="$(sed -n 's/^API_KEY=//p' "$PROXY_ENV_DIR/$id.env" 2>/dev/null | head -1)"
    [ -n "$key" ] || return 1
    port_open "$port" || return 1
    url="http://127.0.0.1:$port/v1/chat/completions"
    payload="$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply only: OK"}],stream:false,max_tokens:8}')"
    code="$(curl -s -m 35 -o /dev/null -w '%{http_code}' -X POST "$url" \
        -H "Authorization: Bearer $key" -H 'Content-Type: application/json' --data "$payload" 2>/dev/null || true)"
    [ "$code" = 200 ]
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
    done < <(selected_rows)

    printf '['
    local idx key url up i models chat model
    for idx in "${!ids[@]}"; do
        id="${ids[$idx]}"; port="${ports[$idx]}"
        key="$(awk -F= '$1=="API_KEY"{print $2; exit}' "$PROXY_ENV_DIR/$id.env" 2>/dev/null || true)"
        url="http://127.0.0.1:$port/v1"
        model="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print $5}')"
        up=false
        for ((i = 1; i <= 40; i++)); do port_open "$port" && { up=true; break; }; sleep 1; done
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
            if [ "$chat" = ok ]; then
                record_login_authenticated "$id"
            elif is_login_capable_proxy "$id"; then
                record_login_needs_login "$id"
            fi
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
    auth|auth-status|login-status) auth_status_json ;;
    configure-ides|ides|configure) configure_ides ;;
    test|verify)
        if [ "$TARGET" = 9router ]; then
            bash "$PZ_ROOT/linux/ai/9router-manager.sh" test | jq -s '.'
        elif [ "$TARGET" = all ]; then
            { test_proxies; bash "$PZ_ROOT/linux/ai/9router-manager.sh" test | jq -s '.'; } | jq -s 'add'
        else
            test_proxies
        fi
        ;;
    start|enable) service_action start ;;
    stop|disable) service_action stop ;;
    login) login_proxy "$TARGET" ;;
    *) pz_error "usage: proxy-suite.sh (status|plan|install|configure-ides|auth|test|start|stop|login) [all|id]"; exit 2 ;;
esac
