#!/usr/bin/env bash
# Portable Linux installer/manager for PhaseZero AI proxy repositories.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
TARGET="${2:-all}"
ENSURE_DRY_RUN=0
case "$ACTION" in
    ensure|use|prepare)
        for _ensure_arg in "${@:3}"; do
            [ "$_ensure_arg" = "--dry-run" ] && ENSURE_DRY_RUN=1
        done
        if [ "$TARGET" = "--dry-run" ]; then
            TARGET="${3:-all}"
            ENSURE_DRY_RUN=1
            [ "$TARGET" = "--dry-run" ] && TARGET=all
        fi
        ;;
esac
ROOT="${PZ_AI_PROXY_ROOT:-$HOME/.local/share/phasezero/ai-proxies}"
BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
RUNTIME="$ROOT/.runtime/node24"
NODE_BIN="$RUNTIME/node_modules/node/bin/node"
NPM_CLI="$RUNTIME/node_modules/npm/bin/npm-cli.js"
PATCH_STATE_DIR="$ROOT/.phasezero-state"
TRUSTED_SOURCES_FILE="${PZ_AI_PROXY_TRUSTED_SOURCES_FILE:-$PZ_ROOT/assets/ai/proxy-suite-trusted-sources.json}"

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
    local system_npm system_node
    system_npm="$(command -v npm || true)"
    system_node="$(command -v node || true)"
    [ -n "$system_npm" ] || { pz_error "npm required"; return 1; }
    if [ ! -x "$NODE_BIN" ] || [ ! -f "$NPM_CLI" ]; then
        pz_info "Installing isolated Node.js 24 runtime for proxy compatibility"
        install -d "$RUNTIME"
        # npm 11+/12 blocks the node package preinstall (downloads the real binary)
        # unless allowScripts lists it. A local package.json is required for
        # `npm install-scripts approve`.
        if [ ! -f "$RUNTIME/package.json" ]; then
            printf '%s\n' '{"private":true,"name":"phasezero-proxy-node24"}' > "$RUNTIME/package.json"
        fi
        (
            cd "$RUNTIME"
            "$system_npm" install --no-save --foreground-scripts "node@24" "npm@10" || true
            if [ ! -x "$NODE_BIN" ] && "$system_npm" install-scripts approve node >/dev/null 2>&1; then
                "$system_npm" install --no-save --foreground-scripts "node@24" "npm@10"
            fi
        )
    fi
    if [ ! -x "$NODE_BIN" ]; then
        if [ -n "$system_node" ]; then
            pz_warn "isolated Node 24 binary missing; falling back to system node $($system_node --version)"
            NODE_BIN="$system_node"
            NPM_CLI="$system_npm"
        else
            pz_error "isolated Node 24 failed to install (npm allowScripts blocked node@24 preinstall)"
            return 1
        fi
    fi
    install -d "$RUNTIME/bin"
    ln -sfn "$NODE_BIN" "$RUNTIME/bin/node"
    pz_info "Proxy runtime: Node $("$NODE_BIN" --version), npm $("$NODE_BIN" "$NPM_CLI" --version 2>/dev/null || "$system_npm" --version)"
}

run_npm() {
    local dir="$1"
    shift
    if [ -n "${NPM_CLI:-}" ] && [ -f "$NPM_CLI" ]; then
        (cd "$dir" && PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$NPM_CLI" "$@")
    else
        (cd "$dir" && PATH="$RUNTIME/bin:$PATH" npm "$@")
    fi
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

trusted_manifest_valid() {
    [ -f "$TRUSTED_SOURCES_FILE" ] || return 1
    jq -e '
      .schemaVersion == 1 and
      .trustMode == "snapshot-pin" and
      .semanticAudit == false and
      (.sources | type == "array" and length > 0) and
      (([.sources[].id] | unique | length) == (.sources | length)) and
      all(.sources[];
        (.id | type == "string" and length > 0) and
        (.repository | type == "string" and length > 0) and
        (.commit | test("^[0-9a-f]{40}$")) and
        (.tree | test("^[0-9a-f]{40}$")) and
        (.approvedForInstall == true) and
        (.license.path | test("^(?!/)(?!.*(^|/)\\.\\.(/|$)).+$")) and
        (.license.sha256 | test("^[0-9a-f]{64}$")) and
        all(.dependencyLocks[];
          (.path | test("^(?!/)(?!.*(^|/)\\.\\.(/|$)).+$")) and
          (.sha256 | test("^[0-9a-f]{64}$")))
      )
    ' "$TRUSTED_SOURCES_FILE" >/dev/null 2>&1
}

trusted_source_record() {
    local id="$1"
    trusted_manifest_valid || return 1
    jq -ce --arg id "$id" '.sources[] | select(.id == $id and .approvedForInstall == true)' \
        "$TRUSTED_SOURCES_FILE" 2>/dev/null
}

source_material_valid() {
    local dir="$1" record="$2" rel expected actual encoded
    rel="$(jq -r '.license.path' <<< "$record")"
    expected="$(jq -r '.license.sha256' <<< "$record")"
    [ -f "$dir/$rel" ] || return 1
    actual="$(sha256sum "$dir/$rel" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || return 1
    while IFS= read -r encoded; do
        [ -n "$encoded" ] || continue
        rel="$(base64 -d <<< "$encoded" | jq -r '.path')"
        expected="$(base64 -d <<< "$encoded" | jq -r '.sha256')"
        [ -f "$dir/$rel" ] || return 1
        actual="$(sha256sum "$dir/$rel" | awk '{print $1}')"
        [ "$actual" = "$expected" ] || return 1
    done < <(jq -r '.dependencyLocks[] | @base64' <<< "$record")
}

managed_worktree_valid() {
    local id="$1" dir="$2" rel state backup actual patched baseline backup_hash git_baseline changes
    changes="$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null || true)"
    if [ "$id" = mimo-ai-proxy ]; then
        changes="$(printf '%s\n' "$changes" | grep -vFx '?? .phasezero-bin/mimo-ai-proxy' || true)"
    fi
    [ -z "$changes" ] && return 0
    rel="$(managed_patch_file "$id" 2>/dev/null || true)"
    [ -n "$rel" ] || return 1
    [ "$changes" = " M $rel" ] || return 1
    state="$PATCH_STATE_DIR/$id.json"
    backup="$PATCH_STATE_DIR/$id.original"
    [ -f "$state" ] && [ -f "$backup" ] && [ -f "$dir/$rel" ] || return 1
    [ "$(jq -r '.id // empty' "$state" 2>/dev/null)" = "$id" ] || return 1
    [ "$(jq -r '.file // empty' "$state" 2>/dev/null)" = "$rel" ] || return 1
    actual="$(sha256sum "$dir/$rel" | awk '{print $1}')"
    patched="$(jq -r '.patchedSha256 // empty' "$state" 2>/dev/null)"
    baseline="$(jq -r '.baselineSha256 // empty' "$state" 2>/dev/null)"
    backup_hash="$(sha256sum "$backup" | awk '{print $1}')"
    git_baseline="$(git -C "$dir" show "HEAD:$rel" | sha256sum | awk '{print $1}')"
    [ -n "$patched" ] && [ "$actual" = "$patched" ] &&
        [ -n "$baseline" ] && [ "$backup_hash" = "$baseline" ] &&
        [ "$git_baseline" = "$baseline" ]
}

provenance_json_one() {
    local id="$1" dir="$ROOT/$1" record="" expected_repo="" expected_commit="" expected_tree=""
    local actual_repo="" actual_commit="" actual_tree="" reason="snapshot aprovado e íntegro"
    local installed=false approved=false manifest_valid=false origin_match=false commit_match=false tree_match=false
    local materials_valid=false worktree_valid=false ready=false
    if trusted_manifest_valid; then manifest_valid=true; fi
    record="$(trusted_source_record "$id" 2>/dev/null || true)"
    if [ -n "$record" ]; then
        approved=true
        expected_repo="$(jq -r '.repository' <<< "$record")"
        expected_commit="$(jq -r '.commit' <<< "$record")"
        expected_tree="$(jq -r '.tree' <<< "$record")"
    else
        reason="fonte sem snapshot aprovado"
    fi
    if [ -d "$dir/.git" ] && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        installed=true
        actual_repo="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
        actual_commit="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
        actual_tree="$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
    elif [ -e "$dir" ]; then
        installed=true
        reason="instalação não é um checkout Git válido"
    else
        reason="ainda não instalado"
    fi
    if [ "$approved" = true ] && [ "$installed" = true ]; then
        [ "$actual_repo" = "$expected_repo" ] && origin_match=true
        [ "$actual_commit" = "$expected_commit" ] && commit_match=true
        [ "$actual_tree" = "$expected_tree" ] && tree_match=true
        source_material_valid "$dir" "$record" && materials_valid=true
        managed_worktree_valid "$id" "$dir" && worktree_valid=true
        if [ "$origin_match" = true ] && [ "$commit_match" = true ] && [ "$tree_match" = true ] &&
           [ "$materials_valid" = true ] && [ "$worktree_valid" = true ]; then
            ready=true
        elif [ "$origin_match" != true ]; then reason="origem Git diverge do snapshot aprovado"
        elif [ "$commit_match" != true ] || [ "$tree_match" != true ]; then reason="commit Git diverge do snapshot aprovado"
        elif [ "$materials_valid" != true ]; then reason="licença ou lockfile diverge do snapshot aprovado"
        else reason="arquivos locais não gerenciados alteram o snapshot"
        fi
    fi
    jq -nc --arg id "$id" --arg mode "snapshot-pin" --arg reason "$reason" \
        --arg manifest "$TRUSTED_SOURCES_FILE" --arg expectedRepository "$expected_repo" \
        --arg actualRepository "$actual_repo" --arg expectedCommit "$expected_commit" \
        --arg actualCommit "$actual_commit" --arg expectedTree "$expected_tree" --arg actualTree "$actual_tree" \
        --argjson semanticAudit false --argjson installed "$installed" --argjson approved "$approved" \
        --argjson manifestValid "$manifest_valid" --argjson originMatch "$origin_match" \
        --argjson commitMatch "$commit_match" --argjson treeMatch "$tree_match" \
        --argjson materialsValid "$materials_valid" --argjson managedWorktreeValid "$worktree_valid" \
        --argjson ready "$ready" \
        '{id:$id,trustMode:$mode,semanticAudit:$semanticAudit,installed:$installed,approvedForInstall:$approved,
          manifestValid:$manifestValid,originMatch:$originMatch,commitMatch:$commitMatch,treeMatch:$treeMatch,
          materialsValid:$materialsValid,managedWorktreeValid:$managedWorktreeValid,ready:$ready,reason:$reason,
          manifest:$manifest,expected:{repository:$expectedRepository,commit:$expectedCommit,tree:$expectedTree},
          actual:{repository:$actualRepository,commit:$actualCommit,tree:$actualTree}}'
}

provenance_ready() {
    provenance_json_one "$1" | jq -e '.ready == true' >/dev/null
}

provenance_status_json() {
    local id first=true item ready_count=0 approved_count=0 installed_count=0 invalid_installed=0 total=0 all_ready=true ids=()
    if [ "$TARGET" = all ]; then
        ids=(kimiproxy qwenproxy deepsproxy mimo-ai-proxy)
    else
        ids=("$TARGET")
    fi
    printf '{"schemaVersion":1,"trustMode":"snapshot-pin","semanticAudit":false,"sources":['
    for id in "${ids[@]}"; do
        item="$(provenance_json_one "$id")"
        $first || printf ','
        first=false
        printf '%s' "$item"
        total=$((total + 1))
        jq -e '.approvedForInstall == true' <<< "$item" >/dev/null && approved_count=$((approved_count + 1))
        if jq -e '.installed == true' <<< "$item" >/dev/null; then
            installed_count=$((installed_count + 1))
            jq -e '.ready == true' <<< "$item" >/dev/null || invalid_installed=$((invalid_installed + 1))
        fi
        if jq -e '.ready == true' <<< "$item" >/dev/null; then
            ready_count=$((ready_count + 1))
        else
            all_ready=false
        fi
    done
    printf '],"summary":{"total":%d,"approved":%d,"installed":%d,"ready":%d,"invalidInstalled":%d,"allReady":%s}}\n' \
        "$total" "$approved_count" "$installed_count" "$ready_count" "$invalid_installed" "$all_ready"
}

clone_approved_snapshot() {
    local id="$1" repo="$2" dir="$3" record expected_commit stage
    record="$(trusted_source_record "$id" 2>/dev/null || true)"
    [ -n "$record" ] || { pz_error "blocked: no approved snapshot for $id"; return 69; }
    [ "$(jq -r '.repository' <<< "$record")" = "$repo" ] || {
        pz_error "blocked: catalog repository differs from approved snapshot for $id"
        return 69
    }
    expected_commit="$(jq -r '.commit' <<< "$record")"
    stage="$(mktemp -d "$ROOT/.stage-$id.XXXXXX")"
    if ! git -C "$stage" init -q ||
       ! git -C "$stage" remote add origin "$repo" ||
       ! git -C "$stage" fetch -q --depth=1 origin "$expected_commit" ||
       ! git -C "$stage" checkout -q --detach FETCH_HEAD ||
       [ "$(git -C "$stage" rev-parse HEAD 2>/dev/null || true)" != "$expected_commit" ] ||
       ! source_material_valid "$stage" "$record" ||
       [ "$(git -C "$stage" rev-parse 'HEAD^{tree}' 2>/dev/null || true)" != "$(jq -r '.tree' <<< "$record")" ]; then
        rm -rf -- "$stage"
        pz_error "blocked: fetched snapshot failed provenance checks for $id"
        return 69
    fi
    git -C "$stage" remote set-url --push origin DISABLED
    mv -- "$stage" "$dir"
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
        if ! provenance_ready "$id"; then
            pz_error "blocked: installed $id differs from approved snapshot; inspect 'pz ai proxies provenance $id'"
            return 69
        fi
    else
        [ ! -e "$dir" ] || { pz_error "blocked: $dir exists but is not a Git checkout"; return 69; }
        clone_approved_snapshot "$id" "$repo" "$dir"
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
            if [ "$id" = qwenproxy ] && [ -f "$dir/web/package.json" ]; then
                # prestart runs `npm --prefix web run build` (vite). Root npm ci
                # does not install web/ node_modules, so the unit crash-loops.
                if [ -f "$dir/web/package-lock.json" ]; then
                    run_npm "$dir/web" ci --ignore-scripts=false
                else
                    run_npm "$dir/web" install --ignore-scripts=false
                fi
                run_npm "$dir" run build:admin
            fi
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
SuccessExitStatus=143 15

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
    local id repo port kind count=0
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        [ "$id" = 9router ] && continue
        trusted_source_record "$id" >/dev/null 2>&1 || {
            pz_error "blocked: no approved snapshot for $id"
            return 69
        }
    done < <(selected_rows)
    ensure_node_runtime
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

service_rows() {
    local mode="$1" id
    if [ "$mode" = stop ] || [ "$TARGET" != all ]; then
        selected_rows
        return
    fi
    for id in kimiproxy qwenproxy deepsproxy mimo-ai-proxy; do
        lookup_proxy_row "$id"
    done
}

service_action() {
    local mode="$1" id repo port kind count=0
    if [ "$mode" != stop ]; then
        while IFS='|' read -r id repo port kind; do
            { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } || continue
            [ "$id" = 9router ] && continue
            provenance_ready "$id" || {
                pz_error "blocked: $id is not an intact approved snapshot"
                return 69
            }
        done < <(service_rows "$mode")
    fi
    while IFS='|' read -r id repo port kind; do
        { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } || continue
        case "$mode" in
            start) systemctl --user enable --now "phasezero-$id.service" ;;
            restart) systemctl --user restart "phasezero-$id.service" ;;
            *) systemctl --user disable --now "phasezero-$id.service" ;;
        esac
        count=$((count + 1))
    done < <(service_rows "$mode")
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
MIMO_STUDIO_URL="https://aistudio.xiaomimimo.com"
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
    pz_backup_file "$file" user >/dev/null
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
        merge_opencode_provider "$OPENCODE_JSON" "$pid" "$name" "$baseurl" "$key" "$models"
        # Legacy JSONC is migration input only; never recreate parallel global config.
        [ -f "$OPENCODE_JSONC" ] && merge_opencode_provider "$OPENCODE_JSONC" "$pid" "$name" "$baseurl" "$key" "$models"
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
                pz_warn "$cli could not install $CONTINUE_EXTENSION (stub or broken editor CLI)"
                continue
            }
        fi
        "$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx 'continue.continue' || {
            pz_warn "$CONTINUE_EXTENSION unavailable in $cli after installation"
            continue
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
    pz_backup_file "$CONTINUE_CONFIG" user >/dev/null
    jq --slurpfile managed "$models_file" '
      .models = (((.models // []) | if type == "array" then . else [] end)
        | map(select(((.title // "") | startswith("[PhaseZero Proxy] ")) | not)))
        + $managed[0]
      | .allowAnonymousTelemetry = false
    ' "$CONTINUE_CONFIG" > "$tmp"
    mv "$tmp" "$CONTINUE_CONFIG"
    chmod 600 "$CONTINUE_CONFIG"
    pz_backup_prune "$CONTINUE_CONFIG" 5
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
    pz_backup_file "$CONTINUE_GLOBAL_CONTEXT" user >/dev/null
    mv "$tmp" "$CONTINUE_GLOBAL_CONTEXT"
    chmod 600 "$CONTINUE_GLOBAL_CONTEXT"
    pz_backup_prune "$CONTINUE_GLOBAL_CONTEXT" 5
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
    pz_backup_file "$ZCODE_STORE" user >/dev/null
    tmp="$(mktemp)"
    jq --argjson providers "$rows_json" \
       '."phasezero-ai-proxies" = {source:"phasezero", providers:$providers}' \
       "$ZCODE_STORE" > "$tmp" && mv "$tmp" "$ZCODE_STORE"
    pz_info "zcode: recorded $(printf '%s' "$rows_json" | jq 'length') PhaseZero proxy providers in $ZCODE_STORE"
}

configure_ides() {
    [ "${PZ_NO_IDES:-0}" = 1 ] && { pz_info "PZ_NO_IDES=1: skipping IDE configuration"; return 0; }
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
# Cards the Control Center "Usar" flow prepares. Legacy sources remain
# catalog-only until they receive their own reviewed snapshots.
USER_FACING_PROXIES=(kimiproxy qwenproxy deepsproxy mimo-ai-proxy)

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
    local id="$1" dir="$ROOT/$1" db count
    case "$id" in
        kimiproxy) [ -s "$dir/kimi_profile/Default/Cookies" ] ;;
        qwenproxy)
            db="$dir/data/qwenproxy.db"
            if [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
                count="$(sqlite3 "$db" 'SELECT COUNT(*) FROM accounts;' 2>/dev/null || echo 0)"
                [ "${count:-0}" -gt 0 ]
            else
                find "$dir/qwen_profiles" -type f -name Cookies -size +0c -print -quit 2>/dev/null | grep -q .
            fi
            ;;
        deepsproxy) [ -s "$dir/deepseek_profile/Default/Cookies" ] ;;
        *) return 1 ;;
    esac
}

proxy_profile_needle() {
    case "$1" in
        kimiproxy) printf '%s\n' "kimi_profile" ;;
        qwenproxy) printf '%s\n' "qwen_profiles" ;;
        deepsproxy) printf '%s\n' "deepseek_profile" ;;
        *) return 1 ;;
    esac
}

proxy_window_pattern() {
    case "$1" in
        kimiproxy) printf '%s\n' 'kimi\.com|Kimi Chat' ;;
        qwenproxy) printf '%s\n' 'Qwen|qwen\.ai|qianwen' ;;
        deepsproxy) printf '%s\n' 'deepseek' ;;
        *) return 1 ;;
    esac
}

chrome_cmd_has_profile() {
    local needle="$1" pid cmd
    for pid in /proc/[0-9]*; do
        [ -r "$pid/cmdline" ] || continue
        cmd="$(tr '\0' ' ' < "$pid/cmdline" 2>/dev/null || true)"
        case "$cmd" in
            *ms-playwright*) ;;
            *) continue ;;
        esac
        case "$cmd" in
            *headless-shell*|*--type=*|*crashpad*) continue ;;
        esac
        case "$cmd" in
            *"$needle"*) return 0 ;;
        esac
    done
    return 1
}

login_window_kind() {
    local id="$1" pattern titles needle
    pattern="$(proxy_window_pattern "$id" || true)"
    needle="$(proxy_profile_needle "$id" || true)"
    [ -n "$pattern" ] || { printf '%s\n' none; return 0; }
    titles=""
    if command -v kdotool >/dev/null 2>&1; then
        titles="$(kdotool search 2>/dev/null | while read -r wid; do
            [ -n "$wid" ] || continue
            kdotool getwindowname "$wid" 2>/dev/null || true
        done)"
    fi
    if [ -n "$titles" ] && grep -qiE "$pattern" <<< "$titles"; then
        printf '%s\n' headed
        return 0
    fi
    if chrome_cmd_has_profile "$needle"; then
        printf '%s\n' zombie
        return 0
    fi
    printf '%s\n' none
}

login_pid_alive() {
    local id="$1" state="$PZ_STATE/ai-proxies/$1-login.json" pid cwd
    [ -f "$state" ] || return 1
    pid="$(jq -r '.pid // 0' "$state" 2>/dev/null || echo 0)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    [ "$cwd" = "$ROOT/$id" ]
}

reap_stale_login() {
    local id="$1" state="$PZ_STATE/ai-proxies/$1-login.json" pid needle
    pid="$(jq -r '.pid // 0' "$state" 2>/dev/null || echo 0)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        kill "$pid" >/dev/null 2>&1 || true
        sleep 1
        kill -9 "$pid" >/dev/null 2>&1 || true
        pkill -P "$pid" >/dev/null 2>&1 || true
    fi
    needle="$(proxy_profile_needle "$id" || true)"
    if [ -n "$needle" ]; then
        for proc in /proc/[0-9]*; do
            [ -r "$proc/cmdline" ] || continue
            cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
            case "$cmd" in
                *ms-playwright*"$needle"*)
                    case "$cmd" in
                        *--type=*|*crashpad*) continue ;;
                    esac
                    kill "${proc##*/}" >/dev/null 2>&1 || true
                    ;;
            esac
        done
    fi
    rm -f "$PZ_STATE/ai-proxies/$id-login.fifo"
    if [ -f "$state" ]; then
        record_login_status "$id" needs-login
    fi
}

login_process_running() {
    local id="$1" kind
    login_pid_alive "$id" || return 1
    kind="$(login_window_kind "$id")"
    if [ "$kind" = headed ]; then
        return 0
    fi
    reap_stale_login "$id"
    return 1
}

login_tsx() {
    local dir="$1"
    if [ -f "$dir/node_modules/tsx/dist/cli.mjs" ]; then
        printf '%s\n' "$dir/node_modules/tsx/dist/cli.mjs"
    elif [ -x "$dir/node_modules/.bin/tsx" ]; then
        printf '%s\n' "$dir/node_modules/.bin/tsx"
    else
        return 1
    fi
}

quick_chat_ok() {
    local id="$1" row port model key url code payload
    row="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print; exit}')"
    [ -n "$row" ] || return 1
    port="$(cut -d'|' -f2 <<< "$row")"
    model="$(cut -d'|' -f5 <<< "$row")"
    key="$(awk -F= '$1=="API_KEY"{print $2; exit}' "$PROXY_ENV_DIR/$id.env" 2>/dev/null || true)"
    [ -n "$key" ] || return 1
    port_open "$port" || return 1
    url="http://127.0.0.1:$port/v1/chat/completions"
    payload="$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply only: OK"}],stream:false,max_tokens:8}')"
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST "$url" \
        -H "Authorization: Bearer $key" -H 'Content-Type: application/json' --data "$payload" 2>/dev/null || true)"
    [ "$code" = 200 ]
}

wait_port_free() {
    local port="$1" i
    [ -n "$port" ] && [ "$port" != 0 ] || return 0
    for ((i = 0; i < 12; i++)); do
        port_open "$port" || return 0
        sleep 1
    done
    return 1
}

wait_for_login_window() {
    local log="$1" pid="$2" timeout="${3:-40}" i
    for ((i = 0; i < timeout; i++)); do
        kill -0 "$pid" 2>/dev/null || return 1
        if grep -Eqi 'Browser opened|Launching chromium|Opening chromium|Opening DeepSeek' "$log" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_proxy_service() {
    local id="$1" row port i
    row="$(lookup_proxy_row "$id")"
    [ -n "$row" ] || return 1
    if ! provenance_ready "$id"; then
        pz_error "blocked: $id is not an intact approved snapshot"
        return 69
    fi
    port="$(cut -d'|' -f3 <<< "$row")"
    systemctl --user reset-failed "phasezero-$id.service" >/dev/null 2>&1 || true
    if ! systemctl --user enable --now "phasezero-$id.service"; then
        return 1
    fi
    for ((i = 0; i < 12; i++)); do
        if systemctl --user is-active --quiet "phasezero-$id.service" 2>/dev/null && port_open "$port"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_proxy_chat() {
    local id="$1" attempts="${2:-8}" i
    for ((i = 0; i < attempts; i++)); do
        quick_chat_ok "$id" && return 0
        sleep 2
    done
    return 1
}

emit_login_json() {
    local id="$1" ok="$2" status="$3" summary="$4" next="$5" log="${6:-}"
    jq -nc --arg id "$id" --arg name "$(proxy_display_name "$id")" \
        --arg status "$status" --arg summary "$summary" --arg next "$next" \
        --arg log "$log" --argjson ok "$ok" \
        '{schemaVersion:1,id:$id,name:$name,ok:$ok,status:$status,summary:$summary,next:$next,needsUser:(if $status=="ready" then "none" else "browser-login" end),log:$log}'
}

patch_proxy_unit_success_exit() {
    local id="$1" unit="$UNITS/phasezero-$1.service"
    [ -f "$unit" ] || return 0
    grep -q '^SuccessExitStatus=' "$unit" && return 0
    local tmp
    tmp="$(mktemp)"
    awk '{print} /^RestartSec=/ && !seen {print "SuccessExitStatus=143 15"; seen=1}' "$unit" > "$tmp"
    mv "$tmp" "$unit"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
}

watch_login_then_restart() {
    local id="$1" pid="$2" log="$PZ_STATE/ai-proxies/$1-login.log"
    (
        while kill -0 "$pid" 2>/dev/null; do
            if grep -Eqi 'Account added|Login detected|session saved' "$log" 2>/dev/null; then
                sleep 2
                kill "$pid" >/dev/null 2>&1 || true
                sleep 1
                kill -9 "$pid" >/dev/null 2>&1 || true
                break
            fi
            sleep 2
        done
        if grep -Eqi 'Account added|Login detected|session saved' "$log" 2>/dev/null; then
            if start_proxy_service "$id" >>"$log" 2>&1 && wait_proxy_chat "$id" 15; then
                record_login_authenticated "$id"
            else
                record_login_status "$id" start-required
                printf '%s\n' "PhaseZero: login salvo, mas serviço/chat não ficou pronto" >>"$log"
            fi
        fi
    ) >/dev/null 2>&1 &
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
            command="linux/pz ai proxies open-studio"
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

# Read-only snapshot of what configure_ides has already wired, so the UI can
# show integration health without mutating any IDE configuration.
ide_status_json() {
    local defaults=false opencode=0 continue_models=0 zcode=0 file
    [ -f "$IDE_ENV_DEFAULTS" ] && defaults=true
    for file in "$OPENCODE_JSON" "$OPENCODE_JSONC"; do
        [ -f "$file" ] || continue
        jq empty "$file" >/dev/null 2>&1 || continue
        opencode="$(jq '[(.provider // {}) | keys[] | select(startswith("phasezero-"))] | length' "$file")"
        [ "$opencode" -gt 0 ] && break
    done
    if [ -f "$CONTINUE_CONFIG" ] && jq empty "$CONTINUE_CONFIG" >/dev/null 2>&1; then
        continue_models="$(jq '[.models[]? | select((.title // "") | startswith("[PhaseZero Proxy] "))] | length' "$CONTINUE_CONFIG")"
    fi
    if [ -f "$ZCODE_STORE" ] && jq empty "$ZCODE_STORE" >/dev/null 2>&1; then
        zcode="$(jq '."phasezero-ai-proxies".providers // [] | length' "$ZCODE_STORE")"
    fi
    jq -cn --argjson envDefaults "$defaults" --argjson opencodeProviders "$opencode" \
        --argjson continueModels "$continue_models" --argjson zcodeProviders "$zcode" \
        --arg envDefaultsPath "$IDE_ENV_DEFAULTS" --arg defaultProxy "$IDE_DEFAULT_PROXY" \
        '{envDefaults:$envDefaults, envDefaultsPath:$envDefaultsPath, defaultProxy:$defaultProxy,
          opencodeProviders:$opencodeProviders, continueModels:$continueModels, zcodeProviders:$zcodeProviders}'
}

# One consolidated read-only payload for the native UI "Proxies IA" page:
# install/service/auth per proxy plus IDE integration counters, in one call.
detailed_status_json() {
    local previous_target="$TARGET"
    TARGET=all
    jq -cn --argjson proxies "$(auth_status_json)" --argjson ide "$(ide_status_json)" \
        --argjson provenance "$(provenance_status_json)" \
        '{schemaVersion:1, proxies:$proxies, ide:$ide, provenance:$provenance}'
    TARGET="$previous_target"
}

login_proxy() {
    local id="$1" dir="$ROOT/$1" log state login_pid port tsx fifo name
    name="$(proxy_display_name "$id")"
    if ! is_login_capable_proxy "$id"; then
        pz_error "no browser login flow for '$id' (supported: ${LOGIN_CAPABLE_PROXIES[*]})" >&2
        emit_login_json "$id" false error "Este proxy não usa login no navegador." "Use as credenciais no arquivo de ambiente." ""
        return 2
    fi
    if ! provenance_ready "$id"; then
        emit_login_json "$id" false blocked \
            "$name foi bloqueado: a instalação não corresponde ao snapshot aprovado." \
            "Abra Procedência dos proxies para revisar origem, commit e arquivos locais." ""
        return 69
    fi
    if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        emit_login_json "$id" false "gui-required" \
            "$name precisa de uma sessão gráfica para abrir o Chromium." \
            "Abra a Central no desktop (não via SSH) e clique em Usar de novo." ""
        return 3
    fi
    if [ ! -d "$dir/.git" ]; then
        emit_login_json "$id" false error "$name ainda não está instalado." "Clique em Usar para instalar." ""
        return 1
    fi
    if login_process_running "$id"; then
        log="$PZ_STATE/ai-proxies/$id-login.log"
        emit_login_json "$id" true "needs-login" \
            "O login do $name já está aberto no navegador." \
            "Conclua o login na janela do Chromium. O proxy inicia sozinho depois." "$log"
        return 0
    fi
    ensure_node_runtime >/dev/null

    if saved_login_status "$id" && systemctl --user is-active --quiet "phasezero-$id.service" 2>/dev/null && quick_chat_ok "$id"; then
        emit_login_json "$id" true ready "$name já está autenticado e respondendo." "Pode usar nas IDEs." ""
        return 0
    fi

    port="$(lookup_proxy_row "$id" | cut -d'|' -f3)"
    patch_proxy_unit_success_exit "$id"
    systemctl --user stop "phasezero-$id.service" >/dev/null 2>&1 || true
    wait_port_free "$port" || true

    install -d -m 700 "$PZ_STATE/ai-proxies"
    log="$PZ_STATE/ai-proxies/$id-login.log"
    state="$PZ_STATE/ai-proxies/$id-login.json"
    : > "$log"

    if [ "$id" = qwenproxy ]; then
        tsx="$(login_tsx "$dir")" || { emit_login_json "$id" false error "Qwen não tem o runtime de login (tsx)." "Reinstale o proxy." "$log"; return 2; }
        fifo="$PZ_STATE/ai-proxies/$id-login.fifo"
        rm -f "$fifo"
        mkfifo -m 600 "$fifo"
        (
            cd "$dir"
            exec setsid env PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$tsx" src/login.ts
        ) <"$fifo" >"$log" 2>&1 &
        login_pid=$!
        (
            printf 'M\n'
            waited=0
            while [ "$waited" -lt 50 ]; do
                grep -q 'Press Enter to open the browser' "$log" 2>/dev/null && break
                kill -0 "$login_pid" 2>/dev/null || exit 0
                sleep 0.2
                waited=$((waited + 1))
            done
            printf '\n'
            waited=0
            while [ "$waited" -lt 180 ]; do
                grep -q 'Login detected' "$log" 2>/dev/null && break
                kill -0 "$login_pid" 2>/dev/null || exit 0
                sleep 2
                waited=$((waited + 1))
            done
            printf 'phasezero-qwen@local\n\nQ\n'
            while kill -0 "$login_pid" 2>/dev/null; do sleep 2; done
        ) >"$fifo" &
    else
        (
            cd "$dir"
            exec setsid env PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$NPM_CLI" run login
        ) </dev/null >"$log" 2>&1 &
        login_pid=$!
    fi

    jq -n --arg id "$id" --arg log "$log" --arg startedAt "$(date -Iseconds)" --argjson pid "$login_pid" \
        '{schemaVersion:1,id:$id,status:"started",pid:$pid,log:$log,startedAt:$startedAt,restartServiceAfterExit:true}' > "$state"

    watch_login_then_restart "$id" "$login_pid"

    if wait_for_login_window "$log" "$login_pid" 40; then
        emit_login_json "$id" true "needs-login" \
            "Uma janela do navegador abriu para o login do $name." \
            "Conclua o login no Chromium e feche a janela. O serviço inicia sozinho." "$log"
        return 0
    fi
    if kill -0 "$login_pid" 2>/dev/null; then
        emit_login_json "$id" true "needs-login" \
            "Login do $name iniciado. O Chromium deve abrir em instantes." \
            "Se a janela não aparecer, use o modo avançado." "$log"
        return 0
    fi
    emit_login_json "$id" false error "Não foi possível abrir o login do $name." \
        "Tente de novo. Detalhes técnicos ficam no modo avançado." "$log"
    return 1
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

proxy_display_name() {
    case "$1" in
        kimiproxy) printf '%s\n' "Kimi" ;;
        qwenproxy) printf '%s\n' "Qwen" ;;
        deepsproxy) printf '%s\n' "DeepSeek" ;;
        mimo-ai-proxy) printf '%s\n' "Mimo" ;;
        9router) printf '%s\n' "9Router" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

proxy_is_installed() {
    local id="$1" dir="$ROOT/$1"
    if [ "$id" = 9router ]; then
        [ -x "$dir/bin/9router" ]
    else
        [ -d "$dir/.git" ]
    fi
}

lookup_proxy_row() {
    proxy_rows | awk -F'|' -v i="$1" '$1==i {print; exit}'
}

_ensure_steps_add() {
    local file="$1" name="$2" status="$3" detail="${4:-}" tmp
    tmp="$(mktemp)"
    jq --arg name "$name" --arg status "$status" --arg detail "$detail" \
        '. + [{name:$name, status:$status, detail:$detail}]' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# One-click Control Center path: install if missing, start, open headed login
# when the proxy still needs a browser session. Stdout is a single JSON object
# so the simple UI can show `summary`/`next` without npm/git noise.
ensure_one() {
    local id="$1" dry="$2"
    local name row repo port kind dir log steps_file
    local installed=false service="" auth_status="" needs_user="none"
    local status="ready" summary="" next="" ok=true
    name="$(proxy_display_name "$id")"
    row="$(lookup_proxy_row "$id")"
    if [ -z "$row" ]; then
        jq -nc --arg id "$id" --arg summary "Proxy desconhecido: $id" \
            '{schemaVersion:1,id:$id,ok:false,status:"error",summary:$summary,needsUser:"none",dryRun:false,steps:[]}'
        return 2
    fi
    IFS='|' read -r _id repo port kind <<< "$row"
    dir="$ROOT/$id"
    log="$PZ_STATE/ai-proxies/$id-ensure.log"
    install -d -m 700 "$PZ_STATE/ai-proxies"
    steps_file="$(mktemp)"
    printf '[]\n' > "$steps_file"

    if proxy_is_installed "$id"; then
        if [ "$id" != 9router ] && ! provenance_ready "$id"; then
            local provenance reason
            provenance="$(provenance_json_one "$id")"
            reason="$(jq -r '.reason' <<< "$provenance")"
            _ensure_steps_add "$steps_file" provenance blocked "$reason"
            jq -nc --arg id "$id" --arg name "$name" --arg reason "$reason" \
                --argjson provenance "$provenance" --argjson steps "$(cat "$steps_file")" \
                '{schemaVersion:1,id:$id,name:$name,ok:false,status:"blocked",
                  summary:($name + " foi bloqueado: " + $reason + "."),
                  next:"Abra Procedência dos proxies. Reinstalação exige snapshot aprovado; alterações locais não são executadas.",
                  needsUser:"review-provenance",dryRun:false,installed:true,provenance:$provenance,steps:$steps}'
            rm -f "$steps_file"
            return 69
        fi
        installed=true
        _ensure_steps_add "$steps_file" provenance ok "snapshot aprovado e íntegro"
        _ensure_steps_add "$steps_file" install skipped "já instalado"
    elif [ "$id" != 9router ] && [ -e "$dir" ]; then
        local collision_provenance collision_reason
        collision_provenance="$(provenance_json_one "$id")"
        collision_reason="$(jq -r '.reason' <<< "$collision_provenance")"
        _ensure_steps_add "$steps_file" provenance blocked "$collision_reason"
        jq -nc --arg id "$id" --arg name "$name" --arg reason "$collision_reason" \
            --argjson provenance "$collision_provenance" --argjson steps "$(cat "$steps_file")" \
            '{schemaVersion:1,id:$id,name:$name,ok:false,status:"blocked",
              summary:($name + " foi bloqueado: " + $reason + "."),
              next:"Revise o diretório existente antes de instalar o snapshot aprovado.",
              needsUser:"review-provenance",dryRun:false,installed:true,provenance:$provenance,steps:$steps}'
        rm -f "$steps_file"
        return 69
    elif [ "$id" != 9router ] && ! trusted_source_record "$id" >/dev/null 2>&1; then
        _ensure_steps_add "$steps_file" provenance blocked "fonte sem snapshot aprovado"
        jq -nc --arg id "$id" --arg name "$name" --argjson steps "$(cat "$steps_file")" \
            '{schemaVersion:1,id:$id,name:$name,ok:false,status:"blocked",
              summary:($name + " foi bloqueado: fonte sem snapshot aprovado."),
              next:"Uma revisão precisa fixar repositório, commit, árvore, licença e lockfiles antes da instalação.",
              needsUser:"review-provenance",dryRun:false,installed:false,steps:$steps}'
        rm -f "$steps_file"
        return 69
    elif [ "$dry" = 1 ]; then
        _ensure_steps_add "$steps_file" provenance ok "snapshot aprovado para instalação"
        _ensure_steps_add "$steps_file" install would-run "clone e build"
    else
        echo >&2 "Preparando $name…"
        if install_one "$id" "$repo" "$port" "$kind" >>"$log" 2>&1; then
            installed=true
            _ensure_steps_add "$steps_file" install ok
        else
            _ensure_steps_add "$steps_file" install failed "veja $log"
            jq -nc --arg id "$id" --arg name "$name" --arg log "$log" \
                --arg summary "Não foi possível instalar $name." \
                --argjson steps "$(cat "$steps_file")" \
                '{schemaVersion:1,id:$id,ok:false,status:"error",summary:$summary,next:"Tente de novo. Detalhes técnicos ficam no modo avançado.",needsUser:"none",dryRun:false,log:$log,steps:$steps}'
            rm -f "$steps_file"
            return 1
        fi
    fi

    service="$(systemctl --user is-active "phasezero-$id.service" 2>/dev/null || true)"

    if is_login_capable_proxy "$id"; then
        if saved_login_status "$id"; then
            auth_status="authenticated"
        elif login_process_running "$id"; then
            auth_status="login-running"
        elif session_artifact_present "$id"; then
            auth_status="session-present"
        elif [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            auth_status="gui-required"
        else
            auth_status="ready-for-login"
        fi
        if [ "$auth_status" = "authenticated" ]; then
            if [ "$service" = active ]; then
                _ensure_steps_add "$steps_file" start skipped "já rodando"
            elif [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" start would-run
            else
                if start_proxy_service "$id" >>"$log" 2>&1; then
                    _ensure_steps_add "$steps_file" start ok
                else
                    _ensure_steps_add "$steps_file" start failed "veja $log"
                    ok=false
                    status=error
                    summary="Não foi possível iniciar $name."
                    next="Tente de novo. Detalhes técnicos ficam no modo avançado."
                fi
            fi
            if [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" login skipped "sessão salva; será validada"
                summary="Vai iniciar $name e validar a sessão salva."
            elif [ "$ok" = true ] && wait_proxy_chat "$id" 5; then
                _ensure_steps_add "$steps_file" login skipped "sessão validada por chat"
                summary="$name já está pronto para usar."
            elif [ "$ok" = true ]; then
                record_login_needs_login "$id"
                _ensure_steps_add "$steps_file" login stale "sessão salva não respondeu"
                if login_proxy "$id" >>"$log" 2>&1; then
                    _ensure_steps_add "$steps_file" login opened "renovação necessária"
                    needs_user="browser-login"
                    status="needs-login"
                    summary="A sessão salva do $name expirou. O navegador foi aberto."
                    next="Conclua o login no Chromium. O serviço inicia sozinho depois."
                else
                    _ensure_steps_add "$steps_file" login failed "veja $log"
                    ok=false
                    status=error
                    summary="A sessão do $name expirou e o login não abriu."
                    next="Tente de novo. Detalhes técnicos ficam no modo avançado."
                fi
            fi
        elif [ "$auth_status" = "login-running" ]; then
            _ensure_steps_add "$steps_file" start skipped "login em andamento"
            _ensure_steps_add "$steps_file" login skipped "janela já aberta"
            needs_user="browser-login"
            status="needs-login"
            summary="O login do $name já está aberto no navegador."
            next="Conclua o login na janela do Chromium. O proxy inicia sozinho depois."
        elif [ "$auth_status" = "gui-required" ]; then
            if [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" start would-run
                _ensure_steps_add "$steps_file" login blocked "precisa de sessão gráfica"
                summary="Vai preparar $name. O login só abre no desktop gráfico."
            else
                if start_proxy_service "$id" >>"$log" 2>&1; then
                    _ensure_steps_add "$steps_file" start ok
                else
                    _ensure_steps_add "$steps_file" start failed "veja $log"
                    ok=false
                    status=error
                fi
                _ensure_steps_add "$steps_file" login blocked "precisa de sessão gráfica"
                if [ "$ok" = true ]; then
                    summary="$name está instalado, mas o login precisa de uma sessão gráfica."
                else
                    summary="$name foi instalado, mas o serviço não iniciou."
                fi
            fi
            needs_user="gui"
            status="gui-required"
            ok=true
            next="Abra a Central no desktop (não via SSH) e clique em Usar de novo."
        else
            needs_user="browser-login"
            status="needs-login"
            if [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" start deferred "depois do login"
                _ensure_steps_add "$steps_file" login would-open "Chromium visível"
                summary="Vai instalar o $name se faltar, abrir o navegador para login e iniciar o serviço."
                next="Uma janela do Chromium abre para você entrar na conta. O proxy sobe sozinho depois."
            else
                _ensure_steps_add "$steps_file" start deferred "depois do login"
                if login_proxy "$id" >>"$log" 2>&1; then
                    _ensure_steps_add "$steps_file" login opened
                    summary="Uma janela do navegador abriu para o login do $name."
                    next="Conclua o login no Chromium e volte. O serviço inicia sozinho."
                else
                    _ensure_steps_add "$steps_file" login failed "veja $log"
                    ok=false
                    status="error"
                    summary="Não foi possível abrir o login do $name."
                    next="Tente de novo. Detalhes técnicos ficam no modo avançado."
                fi
            fi
        fi
    elif [ "$id" = "mimo-ai-proxy" ]; then
        local missing_json
        missing_json="$(mimo_missing_groups_json "$PROXY_ENV_DIR/$id.env")"
        if [ "$(jq 'length' <<< "$missing_json")" -eq 0 ]; then
            if [ "$service" = active ]; then
                _ensure_steps_add "$steps_file" start skipped "já rodando"
            elif [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" start would-run
            elif start_proxy_service "$id" >>"$log" 2>&1; then
                _ensure_steps_add "$steps_file" start ok
            else
                _ensure_steps_add "$steps_file" start failed "veja $log"
                ok=false
                status=error
            fi
            _ensure_steps_add "$steps_file" credentials skipped "configuradas"
            if [ "$ok" = true ]; then
                summary="$name já está pronto para usar."
            else
                summary="As credenciais do $name existem, mas o serviço não iniciou."
                next="Tente de novo. Detalhes técnicos ficam no modo avançado."
            fi
        else
            needs_user="env-credentials"
            status="needs-credentials"
            _ensure_steps_add "$steps_file" start deferred "aguarda credenciais"
            _ensure_steps_add "$steps_file" credentials missing
            if [ "$dry" != 1 ]; then
                if command -v xdg-open >/dev/null 2>&1; then
                    xdg-open "$MIMO_STUDIO_URL" >/dev/null 2>&1 || true
                fi
            fi
            summary="Xiaomi AI Studio abre para gerar o token do Mimo."
            next="Entre na conta, envie uma mensagem no chat, copie token + user id + PH (F12 → Rede → bot/chat) e cole na Central."
        fi
    else
        if [ "$kind" != node ] && [ "$kind" != go ] && [ "$kind" != npm ]; then
            _ensure_steps_add "$steps_file" start skipped "sem serviço local"
            summary="$name não tem serviço local para iniciar."
        elif [ "$service" = active ]; then
            _ensure_steps_add "$steps_file" start skipped "já rodando"
            summary="$name já está rodando."
        elif [ "$dry" = 1 ]; then
            _ensure_steps_add "$steps_file" start would-run
            summary="Vai iniciar $name."
        else
            if start_proxy_service "$id" >>"$log" 2>&1; then
                _ensure_steps_add "$steps_file" start ok
                summary="$name iniciado."
            else
                _ensure_steps_add "$steps_file" start failed "veja $log"
                ok=false
                status=error
                summary="Não foi possível iniciar $name."
                next="Tente de novo. Detalhes técnicos ficam no modo avançado."
            fi
        fi
    fi

    if [ "$dry" = 1 ] && [ "$status" = "ready" ]; then
        status="planned"
        [ -n "$summary" ] || summary="Vai preparar $name."
    fi

    local dry_json=false
    [ "$dry" = 1 ] && dry_json=true
    jq -nc --arg id "$id" --arg name "$name" --arg status "$status" \
        --arg summary "$summary" --arg next "$next" --arg needsUser "$needs_user" \
        --arg log "$log" --argjson ok "$ok" --argjson dryRun "$dry_json" \
        --argjson installed "$installed" --argjson steps "$(cat "$steps_file")" \
        '{schemaVersion:1,id:$id,name:$name,ok:$ok,status:$status,summary:$summary,next:$next,needsUser:$needsUser,dryRun:$dryRun,installed:$installed,log:$log,steps:$steps}'
    rm -f "$steps_file"
    [ "$ok" = true ]
}

ensure_selected() {
    local dry="$ENSURE_DRY_RUN" id item results_file ok=true dry_json=false
    local ide_ok=true ide_status="not-run" ide_log="$PZ_STATE/ai-proxies/ensure-ides.log"
    local ids=() envelope_status=ready
    [ "$dry" = 1 ] && dry_json=true
    results_file="$(mktemp)"
    printf '[]\n' > "$results_file"
    if [ "$TARGET" = all ]; then
        ids=("${USER_FACING_PROXIES[@]}")
    else
        ids=("$TARGET")
    fi
    for id in "${ids[@]}"; do
        item="$(ensure_one "$id" "$dry")" || true
        printf '%s\n' "$item" | jq -e . >/dev/null 2>&1 || item="$(jq -nc --arg id "$id" '{schemaVersion:1,id:$id,ok:false,status:"error",summary:"Falha inesperada ao preparar o proxy.",needsUser:"none",dryRun:false,steps:[]}')"
        jq --argjson item "$item" '. + [$item]' "$results_file" > "$results_file.tmp"
        mv "$results_file.tmp" "$results_file"
        jq -e '.ok == true' <<< "$item" >/dev/null || ok=false
    done
    if [ "$dry" != 1 ] && [ "$ok" = true ]; then
        if configure_ides >>"$ide_log" 2>&1; then
            ide_status=configured
        else
            ide_ok=false
            ide_status=failed
        fi
    elif [ "$ok" != true ]; then
        ide_ok=false
        ide_status=blocked
    fi
    if [ "$TARGET" = all ]; then
        local login=0 creds=0 failed=0 summary next=""
        login="$(jq '[.[] | select(.needsUser=="browser-login")] | length' "$results_file")"
        creds="$(jq '[.[] | select(.needsUser=="env-credentials")] | length' "$results_file")"
        failed="$(jq '[.[] | select(.ok==false)] | length' "$results_file")"
        if [ "$failed" -gt 0 ]; then
            envelope_status=error
            summary="Alguns proxies não puderam ser preparados."
            next="Abra o modo avançado para ver o que falhou."
        elif [ "$dry" = 1 ]; then
            envelope_status=planned
            summary="Vai preparar Kimi, Qwen, DeepSeek e Mimo. O navegador abre só se ainda faltar login."
            next="Confirme para instalar, ligar os serviços e abrir o Chromium quando necessário."
        elif [ "$login" -gt 0 ]; then
            envelope_status=needs-login
            summary="Proxies prontos. $login ainda precisam de login no navegador."
            next="Conclua o login nas janelas do Chromium que abriram."
        elif [ "$creds" -gt 0 ]; then
            envelope_status=needs-credentials
            summary="Proxies prontos. Mimo ainda precisa das credenciais da conta."
        elif [ "$ide_ok" != true ]; then
            envelope_status=degraded
            summary="Os proxies estão prontos, mas a integração com as IDEs falhou."
            next="Use Configurar IDEs (proxies) ou abra o modo avançado para ver o log."
        else
            summary="Os quatro proxies estão prontos para usar."
        fi
        jq -nc --argjson ok "$ok" --argjson dryRun "$dry_json" --arg status "$envelope_status" \
            --arg summary "$summary" --arg next "$next" --argjson proxies "$(cat "$results_file")" \
            --arg ideStatus "$ide_status" --arg ideLog "$ide_log" --argjson ideOk "$ide_ok" \
            '{schemaVersion:1,ok:$ok,status:$status,summary:$summary,next:$next,dryRun:$dryRun,proxies:$proxies,
              ide:{ok:$ideOk,status:$ideStatus,log:$ideLog}}'
    else
        jq --arg ideStatus "$ide_status" --arg ideLog "$ide_log" --argjson ideOk "$ide_ok" '
          .[0] | .ide={ok:$ideOk,status:$ideStatus,log:$ideLog} |
          if ($ideOk|not) and .status=="ready" then
            .status="degraded" |
            .summary=(.name + " está pronto, mas a integração com as IDEs falhou.") |
            .next="Use Configurar IDEs (proxies) ou abra o modo avançado para ver o log."
          else . end
        ' "$results_file"
    fi
    rm -f "$results_file"
    [ "$ok" = true ]
}

open_mimo_studio() {
    command -v xdg-open >/dev/null 2>&1 || { pz_error "xdg-open missing"; return 1; }
    xdg-open "$MIMO_STUDIO_URL" >/dev/null 2>&1 &
    jq -nc --arg url "$MIMO_STUDIO_URL" \
        '{schemaVersion:1,ok:true,status:"needs-credentials",summary:"Xiaomi AI Studio aberto no navegador.",next:"Entre na conta, envie uma mensagem no Mimo e copie token, user id e PH (F12 → Rede → bot/chat).",studioUrl:$url,needsUser:"env-credentials"}'
}

set_proxy_credentials() {
    local id="${TARGET:-mimo-ai-proxy}" payload file token user ph
    [ "$id" = "mimo-ai-proxy" ] || [ "$id" = mimo ] || { pz_error "set-credentials only supports mimo-ai-proxy"; return 2; }
    id=mimo-ai-proxy
    if ! provenance_ready "$id"; then
        jq -nc '{schemaVersion:1,ok:false,status:"blocked",summary:"Mimo foi bloqueado: a instalação não corresponde ao snapshot aprovado.",next:"Abra Procedência dos proxies antes de salvar ou usar credenciais.",needsUser:"review-provenance"}'
        return 69
    fi
    payload="$(cat)"
    printf '%s' "$payload" | jq -e 'type=="object"' >/dev/null 2>&1 || {
        jq -nc '{schemaVersion:1,ok:false,status:"error",summary:"Credenciais inválidas.",needsUser:"env-credentials"}'
        return 2
    }
    token="$(jq -r '.serviceToken // .SERVICE_TOKEN // empty' <<< "$payload")"
    user="$(jq -r '.userId // .USER_ID // empty' <<< "$payload")"
    ph="$(jq -r '.chatbotPh // .XIAOMI_CHATBOT_PH // empty' <<< "$payload")"
    if [ -z "$token" ] || [ -z "$user" ] || [ -z "$ph" ]; then
        jq -nc '{schemaVersion:1,ok:false,status:"needs-credentials",summary:"Faltam os três valores: token, user id e PH.",next:"Cole os três campos e salve de novo.",needsUser:"env-credentials"}'
        return 2
    fi
    file="$PROXY_ENV_DIR/$id.env"
    install -d -m 700 "$PROXY_ENV_DIR"
    upsert_env_var "$file" SERVICE_TOKEN "$token"
    upsert_env_var "$file" USER_ID "$user"
    upsert_env_var "$file" XIAOMI_CHATBOT_PH "$ph"
    chmod 600 "$file"
    if ! start_proxy_service "$id" >/dev/null 2>&1 || ! wait_proxy_chat "$id" 8; then
        jq -nc --arg summary "Conta Mimo salva, mas o serviço não iniciou." \
            '{schemaVersion:1,ok:false,status:"error",summary:$summary,next:"Tente novamente; no modo avançado, revise o serviço phasezero-mimo-ai-proxy.",needsUser:"none"}'
        return 1
    fi
    jq -nc --arg summary "Conta Mimo salva e serviço validado." \
        '{schemaVersion:1,ok:true,status:"configured",summary:$summary,next:"O OpenCode abrirá automaticamente com o Mimo.",needsUser:"none"}'
}

open_opencode_proxy() {
    local id="$TARGET" row port provider model spec name
    [ "$id" != all ] || id="$IDE_DEFAULT_PROXY"
    row="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print; exit}')"
    [ -n "$row" ] || { jq -nc --arg id "$id" '{schemaVersion:1,ok:false,status:"error",summary:"Proxy desconhecido.",id:$id}'; return 2; }
    port="$(cut -d'|' -f2 <<< "$row")"
    provider="$(cut -d'|' -f3 <<< "$row")"
    model="$(cut -d'|' -f5 <<< "$row")"
    name="$(proxy_display_name "$id")"
    spec="$provider/$model"
    if ! start_proxy_service "$id" >/dev/null 2>&1; then
        jq -nc --arg name "$name" \
            '{schemaVersion:1,ok:false,status:"error",summary:("O serviço do " + $name + " não iniciou."),next:"Tente Usar novamente; detalhes técnicos ficam no modo avançado."}'
        return 1
    fi
    if ! wait_proxy_chat "$id" 5; then
        jq -nc --arg name "$name" \
            '{schemaVersion:1,ok:false,status:"needs-login",summary:("O serviço do " + $name + " iniciou, mas a conta não respondeu."),next:"Clique em Usar para renovar o login antes de abrir o OpenCode."}'
        return 1
    fi
    if ! command -v opencode >/dev/null 2>&1; then
        jq -nc --arg summary "OpenCode CLI não está no PATH." --arg spec "$spec" \
            '{schemaVersion:1,ok:false,status:"error",summary:$summary,next:"Configure o OpenCode em IA e Dev, depois clique de novo.",model:$spec}'
        return 1
    fi
    if command -v konsole >/dev/null 2>&1; then
        konsole -p tabtitle="OpenCode $name" -e opencode -m "$spec" --auto >/dev/null 2>&1 &
    else
        opencode -m "$spec" --auto >/dev/null 2>&1 &
    fi
    jq -nc --arg name "$name" --arg spec "$spec" \
        '{schemaVersion:1,ok:true,status:"ready",summary:("OpenCode aberto com " + $name + " (" + $spec + ")."),next:"A conversa já usa este proxy.",model:$spec,needsUser:"none"}'
}

case "$ACTION" in
    status|list) status_json ;;
    plan|dry-run)
        while IFS='|' read -r id repo port kind; do
            if [ "$id" = 9router ]; then
                printf 'would delegate %s integrity to 9router manager\n' "$id"
            elif record="$(trusted_source_record "$id" 2>/dev/null || true)" && [ -n "$record" ]; then
                printf 'would install %s from %s at commit %s (%s)\n' \
                    "$id" "$repo" "$(jq -r '.commit' <<< "$record")" "$kind"
            else
                printf 'blocked %s: no approved snapshot\n' "$id"
            fi
        done < <(selected_rows)
        ;;
    install|setup|update|repair)
        install_selected
        configure_ides
        ;;
    auth|auth-status|login-status) auth_status_json ;;
    provenance|sources|source-status) provenance_status_json ;;
    detailed-status|detailed|overview) detailed_status_json ;;
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
    restart) service_action restart ;;
    login)
        if [ "$TARGET" = all ]; then
            # Batch OAuth: open one headed login per browser-session proxy that
            # still needs it. login_proxy detaches and skips proxies already
            # authenticated, so this stays honest and non-blocking.
            for login_id in "${LOGIN_CAPABLE_PROXIES[@]}"; do
                login_proxy "$login_id" || pz_warn "login flow failed to open for $login_id"
            done
        else
            login_proxy "$TARGET"
        fi
        ;;
    ensure|use|prepare) ensure_selected ;;
    open|open-client|launch)
        open_opencode_proxy
        ;;
    set-credentials|credentials)
        set_proxy_credentials
        ;;
    open-studio)
        open_mimo_studio
        ;;
    *) pz_error "usage: proxy-suite.sh (status|detailed-status|provenance|plan|install|configure-ides|auth|test|start|stop|restart|login|ensure|open|set-credentials) [all|id] [--dry-run]"; exit 2 ;;
esac
