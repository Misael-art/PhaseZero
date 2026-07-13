#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/linux/ai/desktop-apps.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
printf 'qwen-appimage\n' > "$TMP/payload"
size="$(stat -c %s "$TMP/payload")"
sha="$(sha256sum "$TMP/payload" | awk '{print $1}')"

cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -H|--retry|--retry-delay|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) shift ;;
  esac
done
if [ -n "\$out" ]; then cp "$TMP/payload" "\$out"; exit 0; fi
printf '%s\n' '{"name":"Qwen Code Desktop v0.0.5","tag_name":"desktop-latest","published_at":"2026-06-15T00:00:00Z","assets":[{"name":"Qwen-Code-Desktop-x86_64.AppImage","state":"uploaded","size":$size,"digest":"sha256:$sha","browser_download_url":"https://github.com/QwenLM/qwen-code/releases/download/desktop-latest/Qwen-Code-Desktop-x86_64.AppImage"}]}'
EOF
chmod 0755 "$TMP/bin/curl"

env_args=(
  PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_DATA_HOME="$TMP/data"
  XDG_CACHE_HOME="$TMP/cache" XDG_CONFIG_HOME="$TMP/config"
  XDG_STATE_HOME="$TMP/state" PZ_LOCAL_BIN="$TMP/local-bin"
  PZ_QWEN_ROOT="$TMP/qwen" PZ_QWEN_CACHE="$TMP/qwen-cache"
  PZ_QWEN_API_URL="https://mock/qwen"
)
env "${env_args[@]}" "$SCRIPT" install-qwen >/dev/null
status="$(env "${env_args[@]}" "$SCRIPT" status)"
jq -e --arg sha "$sha" '.schemaVersion == 2 and .qwenCodeDesktop.installed and .qwenCodeDesktop.sha256 == $sha and .qwenCodeDesktop.source == "official-qwen-github-release"' <<< "$status" >/dev/null
test -x "$TMP/local-bin/qwen-code-desktop"
test -f "$TMP/data/applications/qwen-code-desktop.desktop"
test "$(stat -c %a "$TMP/home/.craft-agent")" = 700

echo "PASS: Qwen Code Desktop"
