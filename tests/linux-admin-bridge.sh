#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$ROOT/linux/ai/setup-admin-bridge.sh"

HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" PZ_LOCAL_BIN="$TMP/bin" "$ROOT/linux/ai/setup-admin-bridge.sh" dry-run |
    jq -e '.tool == "admin-bridge" and .security.noPasswordlessSudo == true' >/dev/null

mkdir -p "$TMP/home" "$TMP/bin"
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" PZ_LOCAL_BIN="$TMP/bin" "$ROOT/linux/ai/setup-admin-bridge.sh" setup >/dev/null

[ -x "$TMP/bin/phasezero-admin" ] || fail "phasezero-admin missing"
"$TMP/bin/phasezero-admin" --status | jq -e '.policy.noStoredPassword == true' >/dev/null
"$TMP/bin/phasezero-admin" --dry-run true | grep -q 'phasezero-admin dry-run' || fail "dry-run failed"

grep -q 'admin escalation' "$ROOT/assets/agent-skills/phasezero-tools-always-on.md" || fail "rule asset missing admin escalation"
grep -q 'setup-admin-bridge.sh' "$ROOT/profiles/dev-ai.json" || fail "dev-ai profile missing admin bridge"
grep -q 'admin|admin-bridge|bigsudo' "$ROOT/linux/pz" || fail "pz missing admin route"

echo "PASS: linux admin bridge"
