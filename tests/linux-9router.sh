#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
listener_pid=""
cleanup() {
    [ -z "$listener_pid" ] || kill "$listener_pid" >/dev/null 2>&1 || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$TMP_ROOT/run"
export PZ_AI_PROXY_ROOT="$HOME/.local/share/phasezero/ai-proxies"
export PZ_9ROUTER_INSTALL_ROOT="$PZ_AI_PROXY_ROOT/9router"
export PZ_9ROUTER_DATA_DIR="$HOME/.9router"
export PZ_LOCAL_BIN="$HOME/.local/bin"
export PZ_9ROUTER_NODE_BIN="$(command -v node)"
export PZ_9ROUTER_NPM_CLI="$TMP_ROOT/npm-cli.js"
export PZ_9ROUTER_MANAGED_PZ="$ROOT/linux/pz"
mkdir -p "$PZ_9ROUTER_INSTALL_ROOT/bin" \
    "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/app" \
    "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/hooks" \
    "$PZ_9ROUTER_DATA_DIR/auth" "$XDG_RUNTIME_DIR"
printf '#!/usr/bin/env bash\nexit 99\n' > "$PZ_9ROUTER_INSTALL_ROOT/bin/9router"
chmod +x "$PZ_9ROUTER_INSTALL_ROOT/bin/9router"
printf '{"version":"0.0.0-test"}\n' > "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/package.json"
printf 'machine\n' > "$PZ_9ROUTER_DATA_DIR/machine-id"
printf 'secret\n' > "$PZ_9ROUTER_DATA_DIR/auth/cli-secret"
printf 'module.exports={ensureSqliteRuntime(){},buildEnvWithRuntime(e){return e}};\n' \
    > "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/hooks/sqliteRuntime.js"
printf 'setInterval(() => {}, 1000);\n' > "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/app/server.js"
touch "$PZ_9ROUTER_NPM_CLI"

bash -n "$ROOT/linux/ai/9router-manager.sh"
node --check "$ROOT/linux/ai/9router-server-runner.js"
grep -Fq 'pz ai 9router tui' "$ROOT/linux/pz"
grep -Fq 'pz ai 9router repair' "$ROOT/linux/pz"

sleep 120 &
listener_pid=$!
stub_bin="$TMP_ROOT/stubs"
mkdir -p "$stub_bin"
cat > "$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *'is-active'*) echo active ;;
    *'show phasezero-9router.service -p MainPID --value'*) echo "$PZ_TEST_LISTENER_PID" ;;
    *'is-enabled'*) echo enabled ;;
esac
exit 0
EOF
cat > "$stub_bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:20128 0.0.0.0:* users:(("node",pid=%s,fd=20))\n' "$PZ_TEST_LISTENER_PID"
EOF
cat > "$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *'/api/health'*) printf '{"ok":true}\n' ;;
    *'/api/providers'*) printf '{"connections":[]}\n' ;;
    *'/api/combos'*) printf '{"combos":[]}\n' ;;
    *'/api/usage/stats'*) printf '{}\n' ;;
    *) printf '{}\n' ;;
esac
EOF
chmod +x "$stub_bin"/*
export PATH="$stub_bin:$PATH"
export PZ_TEST_LISTENER_PID="$listener_pid"

secret_marker='sk-phasezero-must-never-print-test'
mkdir -p "$XDG_CONFIG_HOME/phasezero/ai-proxies"
printf 'PHASEZERO_9ROUTER_API_KEY=%s\n' "$secret_marker" > "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"
chmod 0600 "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"

before_pid="$listener_pid"
repair_output="$("$ROOT/linux/pz" ai 9router repair)"
kill -0 "$before_pid"
tui_output="$("$HOME/.local/bin/9router")"
kill -0 "$before_pid"
after_pid="$listener_pid"
test "$before_pid" = "$after_pid"
if grep -Fq "$secret_marker" <<< "$repair_output$tui_output"; then
    echo "9Router secret leaked to PhaseZero output" >&2
    exit 1
fi
jq -e '(.listener.pid == (env.PZ_TEST_LISTENER_PID | tonumber)) and
       .listener.ownedByService == true' <<< "$tui_output" >/dev/null

service_unit="$XDG_CONFIG_HOME/systemd/user/phasezero-9router.service"
watch_unit="$XDG_CONFIG_HOME/systemd/user/phasezero-9router-watch.service"
grep -Fq 'ExecStart='"$HOME/.local/bin/phasezero-9router-server" "$service_unit"
grep -Fq "$ROOT/linux/ai/9router-server-runner.js" "$HOME/.local/bin/phasezero-9router-server"
if grep -Rq '/current/' "$XDG_CONFIG_HOME/systemd/user" "$HOME/.local/share/applications"; then
    echo "stale current symlink path found in managed launchers" >&2
    exit 1
fi
if grep -Fq 'killProcessOnPort' "$ROOT/linux/ai/9router-server-runner.js"; then
    echo "server runner must not contain upstream port-kill lifecycle" >&2
    exit 1
fi
grep -Eq '^ExecStart=(/usr/lib/phasezero/linux/pz|'"$ROOT"'/linux/pz) ai 9router watch-once$' "$watch_unit"

"$HOME/.local/bin/phasezero-9router-server" >/dev/null 2>&1 &
runner_pid=$!
sleep 0.3
kill -0 "$runner_pid"
kill -TERM "$runner_pid" >/dev/null 2>&1 || true
wait "$runner_pid" 2>/dev/null || true

echo "9router attach-only, stable units, PID and secret redaction ok"
