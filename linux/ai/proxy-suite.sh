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

proxy_rows() {
    cat <<'EOF'
kimiproxy|https://github.com/pedrofariasx/kimiproxy.git|3000|node
qwen-worker-proxy|https://github.com/aptdnfapt/qwen-worker-proxy.git|0|worker
qwenproxy|https://github.com/pedrofariasx/qwenproxy.git|3001|node
antigravity-proxy|https://github.com/pedrofariasx/antigravity-proxy.git|8080|node
antigravity-openai-adapter|https://github.com/pedrofariasx/antigravity-openai-adapter.git|8081|node
ollieproxy|https://github.com/pedrofariasx/ollieproxy.git|3002|node
airlock|https://github.com/pedrofariasx/airlock.git|0|library
unlimited-ai-proxy|https://github.com/pedrofariasx/unlimited-ai-proxy.git|8787|node
deepsproxy|https://github.com/pedrofariasx/deepsproxy.git|3004|node
mimo-ai-proxy|https://github.com/pedrofariasx/mimo-ai-proxy.git|3005|go
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

case "$ACTION" in
    status|list) status_json ;;
    plan|dry-run) selected_rows | awk -F'|' '{print "would install " $1 " from " $2 " (" $4 ")"}' ;;
    install|setup|update|repair) install_selected ;;
    start|enable) service_action start ;;
    stop|disable) service_action stop ;;
    *) pz_error "usage: proxy-suite.sh (status|plan|install|start|stop) [all|id]"; exit 2 ;;
esac
