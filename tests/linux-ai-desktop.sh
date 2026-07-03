#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/linux/ai/desktop-apps.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$SCRIPT"
bash -n "$ROOT/linux/pz"
bash -n "$ROOT/linux/ai/menu.sh"
bash -n "$ROOT/linux/ai/status.sh"
bash -n "$ROOT/linux/ai/setup-desktop-apps.sh"
bash -n "$ROOT/linux/audit/doctor.sh"
bash -n "$ROOT/linux/audit/repair-plan.sh"
python3 -m json.tool "$ROOT/profiles/dev-ai.json" >/dev/null
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$SCRIPT"
fi

status="$(
    HOME="$TMP/home" \
    XDG_DATA_HOME="$TMP/data" \
    XDG_CONFIG_HOME="$TMP/config" \
    XDG_STATE_HOME="$TMP/state" \
    XDG_CACHE_HOME="$TMP/cache" \
    "$SCRIPT" status
)"
jq -e '
  .schemaVersion == 1 and
  .claudeDesktop.installed == false and
  .claudeDesktop.source == "official-anthropic-apt" and
  .codexDesktop.repairedPackageReady == false
' <<< "$status" >/dev/null || fail "clean status schema"

mkdir -p "$TMP/workspaces/candidate/builder/scripts" "$TMP/seed/assets" "$TMP/seed/record-replay-linux"
printf 'png\n' > "$TMP/seed/assets/codex-linux.png"
printf 'feature\n' > "$TMP/seed/record-replay-linux/README"
cat > "$TMP/workspaces/candidate/builder/scripts/build-pacman.sh" <<'EOF'
#!/usr/bin/env bash
local pkg_file=""
EOF
chmod 0755 "$TMP/workspaces/candidate/builder/scripts/build-pacman.sh"

HOME="$TMP/home" \
XDG_STATE_HOME="$TMP/state" \
XDG_CACHE_HOME="$TMP/cache" \
PZ_CODEX_UPDATE_BUILDER="$TMP/seed" \
PZ_CLAUDE_ROOT="$TMP/claude" \
PZ_CLAUDE_CACHE="$TMP/claude-cache" \
PZ_LOCAL_BIN="$TMP/bin" \
PZ_CODEX_WORKSPACES="$TMP/workspaces" \
"$SCRIPT" codex-guard-once >/dev/null

[ -f "$TMP/workspaces/candidate/builder/assets/codex-linux.png" ] ||
    fail "Codex icon seed"
[ -f "$TMP/workspaces/candidate/builder/record-replay-linux/README" ] ||
    fail "Codex feature seed"
grep -q PHASEZERO_PKGEXT_COMPAT "$TMP/workspaces/candidate/builder/scripts/build-pacman.sh" ||
    fail "Codex package format patch"

help="$("$ROOT/linux/pz" help)"
grep -q 'pz ai desktop install-claude' <<< "$help" || fail "CLI help integration"
grep -q 'setup-desktop-apps.sh' "$ROOT/profiles/dev-ai.json" || fail "dev-ai profile integration"

echo "PASS: linux AI desktop manager"
