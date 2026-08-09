#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"
export HOME="$WORK/home"
export PATH="/usr/bin:/bin"
export PZ_CODEXBAR_NO_FALLBACK=1
export PZ_CODEXBAR_WATCHDOG_NO_ENABLE=1
mkdir -p "$HOME"

step() { echo "step: $*" >&2; }

step "dry-run"
"$ROOT/linux/ai/setup-codexbar.sh" dry-run | tail -1 \
    | jq -e '.tool == "codexbar" and (.planned | length) == 4' >/dev/null

step "status without install"
"$ROOT/linux/ai/setup-codexbar.sh" status | tail -1 \
    | jq -e '.cli.available == false and .plasmoid.installed == false and .config.exists == false' >/dev/null

step "configure writes managed config"
"$ROOT/linux/ai/setup-codexbar.sh" configure >/dev/null
jq -e '._managedBy == "phasezero" and .version == 1 and
  any(.providers[]; .id == "codex" and .enabled == true)' "$XDG_CONFIG_HOME/codexbar/config.json" >/dev/null
[ "$(stat -c %a "$XDG_CONFIG_HOME/codexbar/config.json")" = 600 ]

step "configure keeps unmanaged user config"
printf '{"version":1,"providers":[{"id":"codex","enabled":false}],"custom":true}\n' > "$XDG_CONFIG_HOME/codexbar/config.json"
rm -f "$XDG_STATE_HOME/phasezero/ai/codexbar.json"
"$ROOT/linux/ai/setup-codexbar.sh" configure >/dev/null
jq -e '.custom == true' "$XDG_CONFIG_HOME/codexbar/config.json" >/dev/null
PZ_CODEXBAR_FORCE=1 "$ROOT/linux/ai/setup-codexbar.sh" configure >/dev/null
jq -e '._managedBy == "phasezero"' "$XDG_CONFIG_HOME/codexbar/config.json" >/dev/null

step "install-cli from faked release (file:// URLs, sha256 verified)"
FAKE="$WORK/fake-release"
mkdir -p "$FAKE/pkg"
cat > "$FAKE/pkg/codexbar" <<'FAKECLI'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "codexbar 0.0.1-test" ;;
    --help) echo "usage config" ;;
    usage) printf '%s\n' '[{"provider":"codex","usage":{"percent":12}}]' ;;
    config)
        case "${2:-}" in
            --help) echo "providers enable disable set-api-key validate" ;;
            validate)
                cfg="${CODEXBAR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/codexbar/config.json}"
                jq -e '.version == 1 and (.providers | type == "array") and all(.providers[]; (.id | type == "string"))' "$cfg" >/dev/null
                echo 'Config: OK'
                ;;
            set-api-key) cat >/dev/null; echo '{"saved":true}' ;;
        esac
        ;;
    *) echo "codexbar 0.0.1-test" ;;
esac
FAKECLI
chmod +x "$FAKE/pkg/codexbar"
tar -czf "$FAKE/codexbar-0.0.1-linux-x86_64.tar.gz" -C "$FAKE/pkg" codexbar
( cd "$FAKE" && sha256sum codexbar-0.0.1-linux-x86_64.tar.gz | awk '{print $1}' \
    > codexbar-0.0.1-linux-x86_64.tar.gz.sha256 )
printf 'deadbeef  codexbar-0.0.1-macos-arm64.zip\n' > "$FAKE/codexbar-0.0.1-macos-arm64.zip.sha256"
jq -n --arg dir "file://$FAKE" '{
    tag_name: "v0.0.1-test",
    assets: [
        {name: "codexbar-0.0.1-macos-arm64.zip.sha256", browser_download_url: ($dir + "/codexbar-0.0.1-macos-arm64.zip.sha256")},
        {name: "codexbar-0.0.1-linux-x86_64.tar.gz", browser_download_url: ($dir + "/codexbar-0.0.1-linux-x86_64.tar.gz")},
        {name: "codexbar-0.0.1-linux-x86_64.tar.gz.sha256", browser_download_url: ($dir + "/codexbar-0.0.1-linux-x86_64.tar.gz.sha256")},
        {name: "codexbar-0.0.1-macos-arm64.zip", browser_download_url: ($dir + "/nonexistent.zip")}
    ]
}' > "$FAKE/release.json"
PZ_CODEXBAR_REPO_API="file://$FAKE/release.json" "$ROOT/linux/ai/setup-codexbar.sh" install-cli >/dev/null
[ -x "$HOME/.local/bin/codexbar" ]
[ "$("$HOME/.local/bin/codexbar" --version)" = "codexbar 0.0.1-test" ]
jq -e '.cli.releaseTag == "v0.0.1-test" and .cli.checksumVerified == true and (.cli.sha256 | startswith("") )' \
    "$XDG_STATE_HOME/phasezero/ai/codexbar.json" >/dev/null

step "status after install"
"$ROOT/linux/ai/setup-codexbar.sh" status | tail -1 \
    | jq -e '.cli.available == true and .cli.releaseTag == "v0.0.1-test" and .config.managed == true' >/dev/null

step "auth detects sessions without exposing credential"
mkdir -p "$HOME/.codex" "$HOME/.claude" "$HOME/.zcode/v2"
printf '{"tokens":{"access_token":"private"}}\n' > "$HOME/.codex/auth.json"
printf '{"oauth":{"token":"private"}}\n' > "$HOME/.claude/.credentials.json"
printf '{"provider":{"zai":{"enabled":true,"options":{"apiKey":"zai-private","baseURL":"https://api.z.ai"}}}}\n' \
    > "$HOME/.zcode/v2/config.json"
auth="$("$ROOT/linux/ai/setup-codexbar.sh" auth --provider all)"
jq -e '.providers.codex.state == "authenticated" and .providers.claude.state == "authenticated" and .providers.zai.state == "authenticated"' <<< "$auth" >/dev/null
if grep -q 'zai-private\|access_token\|oauth.*token' <<< "$auth"; then
    echo "FAIL: secrets leaked into auth output"
    exit 1
fi

step "health validates binary config and provider usage"
"$ROOT/linux/ai/setup-codexbar.sh" health \
    | jq -e '.verdict == "healthy" and .usageChecked == true and (.problems | length) == 0' >/dev/null

step "watchdog lifecycle is deterministic without a user systemd session"
"$ROOT/linux/ai/setup-codexbar.sh" watchdog install \
    | tail -1 \
    | jq -e '.watchdog.unitExists == true' >/dev/null
"$ROOT/linux/ai/setup-codexbar.sh" watchdog status \
    | jq -e '.watchdog.unit == "phasezero-codexbar-health.timer"' >/dev/null
"$ROOT/linux/ai/setup-codexbar.sh" watchdog remove \
    | tail -1 \
    | jq -e '.watchdog.unitExists == false' >/dev/null

step "setup never installs external Plasma QML automatically"
PZ_CODEXBAR_REPO_API="file://$FAKE/release.json" \
PZ_KODEXBAR_REPO_URL="file:///must-not-be-cloned" \
    "$ROOT/linux/ai/setup-codexbar.sh" setup >/dev/null
[ ! -d "$HOME/.local/share/plasma/plasmoids/org.kde.plasma.kodexbar" ]

step "live plasmoid replacement is blocked when an instance exists"
mkdir -p "$XDG_CONFIG_HOME" "$WORK/kde-bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/kde-bin/kpackagetool6"
printf '#!/bin/sh\nexit 0\n' > "$WORK/kde-bin/plasmashell"
chmod +x "$WORK/kde-bin/kpackagetool6" "$WORK/kde-bin/plasmashell"
printf '[Containments][1][Applets][2]\nplugin=org.kde.plasma.kodexbar\n' \
    > "$XDG_CONFIG_HOME/plasma-org.kde.plasma.desktop-appletsrc"
rc=0
PATH="$WORK/kde-bin:$PATH" PZ_KODEXBAR_REPO_URL="file:///must-not-be-cloned" \
    "$ROOT/linux/ai/setup-codexbar.sh" install-plasmoid >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ]
rm -f "$XDG_CONFIG_HOME/plasma-org.kde.plasma.desktop-appletsrc"

step "install-cli rejects checksum mismatch"
printf '%064d\n' 0 > "$FAKE/codexbar-0.0.1-linux-x86_64.tar.gz.sha256"
rc=0
PZ_CODEXBAR_FORCE=1 PZ_CODEXBAR_REPO_API="file://$FAKE/release.json" \
    "$ROOT/linux/ai/setup-codexbar.sh" install-cli >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ]

step "remove"
"$ROOT/linux/ai/setup-codexbar.sh" remove >/dev/null 2>&1
[ ! -e "$HOME/.local/bin/codexbar" ]
[ ! -f "$XDG_CONFIG_HOME/codexbar/config.json" ]
[ ! -f "$XDG_STATE_HOME/phasezero/ai/codexbar.json" ]

echo "linux-ai-codexbar smoke ok"
