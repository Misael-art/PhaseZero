#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/linux/windows-vm/container-frontends.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/home" "$TMP/config/winpodx"

printf 'fake-appimage-payload\n' > "$TMP/payload"
size="$(stat -c %s "$TMP/payload")"
sha="$(sha256sum "$TMP/payload" | awk '{print $1}')"

cat > "$TMP/qwen-unused" <<'EOF'
unused
EOF

cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        -H|--retry|--retry-delay|--connect-timeout) shift 2 ;;
        -*) shift ;;
        *) url="\$1"; shift ;;
    esac
done
if [ -n "\$out" ]; then cp "$TMP/payload" "\$out"; exit 0; fi
case "\$url" in
  *winboat*)
    printf '%s\n' '{"tag_name":"v0.9.0","published_at":"2025-11-23T00:00:00Z","assets":[{"name":"winboat-0.9.0-x86_64.AppImage","state":"uploaded","size":$size,"digest":"sha256:$sha","browser_download_url":"https://github.com/TibixDev/winboat/releases/download/v0.9.0/winboat-0.9.0-x86_64.AppImage"}]}' ;;
  *winpodx*)
    printf '%s\n' '{"tag_name":"v0.9.0","published_at":"2026-07-11T00:00:00Z","assets":[{"name":"winpodx-x86_64.AppImage","state":"uploaded","size":$size,"digest":"sha256:$sha","browser_download_url":"https://github.com/kernalix7/winpodx/releases/download/v0.9.0/winpodx-x86_64.AppImage"}]}' ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$BIN/curl"

for command in podman podman-compose xfreerdp3 systemctl; do
    cat > "$BIN/$command" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  inspect) exit 1 ;;
  ps) exit 0 ;;
  is-active) exit 1 ;;
esac
exit 0
EOF
    chmod 0755 "$BIN/$command"
done

cat > "$BIN/winpodx-cli" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$TMP/config/winpodx"
touch "$TMP/config/winpodx/winpodx.toml"
printf '%s|%s\n' "\${3:-}" "\${4:-}" >> "$TMP/winpodx-set.log"
EOF
chmod 0755 "$BIN/winpodx-cli"

env_common=(
    PATH="$BIN:$PATH" HOME="$TMP/home" XDG_DATA_HOME="$TMP/data"
    XDG_CACHE_HOME="$TMP/cache" XDG_CONFIG_HOME="$TMP/config"
    XDG_STATE_HOME="$TMP/state" PZ_LOCAL_BIN="$TMP/local-bin"
    PZ_WINDOWS_APPS_ROOT="$TMP/apps" PZ_WINDOWS_APPS_CACHE="$TMP/app-cache"
    PZ_WINBOAT_API_URL="https://mock/winboat" PZ_WINPODX_API_URL="https://mock/winpodx"
    PZ_WINPODX_CLI="$BIN/winpodx-cli" PZ_WINPODX_CONFIG="$TMP/config/winpodx/winpodx.toml"
)

bash -n "$SCRIPT"
env "${env_common[@]}" "$SCRIPT" install-winboat >/dev/null
env "${env_common[@]}" "$SCRIPT" install-winpodx >/dev/null
status="$(env "${env_common[@]}" "$SCRIPT" status)"
jq -e '.winboat.installed and .winpodx.installed and .host.podman and .host.podmanCompose and .host.freeRdp3' <<< "$status" >/dev/null

# Fake KVM for configure is unnecessary: use real host only when available.
if [ -e /dev/kvm ]; then
    env "${env_common[@]}" "$SCRIPT" configure >/dev/null
    jq -e '.containerRuntime == "Podman" and .scale == 125 and .disableAnimations == true' "$TMP/home/.winboat/winboat.config.json" >/dev/null
    grep -q '^pod.backend|podman$' "$TMP/winpodx-set.log"
    grep -q '^rdp.extra_flags|+multitouch$' "$TMP/winpodx-set.log"
fi

echo "PASS: Windows container frontends"
