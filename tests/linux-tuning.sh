#!/usr/bin/env bash
# Smoke tests for user tuning and security-safe browser defaults.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_STATE_HOME="$TMP_ROOT/state"
mkdir -p "$HOME/.mozilla/firefox/test.default-release" "$HOME/.config/chromium"

bash -n "$REPO_ROOT/linux/tuning/browser-hardening.sh"
bash -n "$REPO_ROOT/linux/tuning/dev-tweaks.sh"
shellcheck --severity=error "$REPO_ROOT/linux/tuning/browser-hardening.sh" "$REPO_ROOT/linux/tuning/dev-tweaks.sh"

bash "$REPO_ROOT/linux/tuning/browser-hardening.sh" >/dev/null
userjs="$HOME/.mozilla/firefox/test.default-release/user.js"
chromium_policy="$HOME/.config/chromium/Default/policies/managed/phasezero-hardening.json"
test -s "$userjs"
jq empty "$chromium_policy"
grep -Fq 'browser.safebrowsing.downloads.remote.enabled", true' "$userjs"
grep -Fq 'browser.safebrowsing.malware.enabled", true' "$userjs"
grep -Fq 'browser.safebrowsing.phishing.enabled", true' "$userjs"
! grep -Eq 'browser\.safebrowsing\.(downloads\.remote|malware|phishing)\.enabled", false' "$userjs"

bash "$REPO_ROOT/linux/tuning/browser-hardening.sh" >/dev/null
find "$HOME/.mozilla/firefox/test.default-release" -maxdepth 1 -name 'user.js.bak.*' -type f | grep -q .
! grep -Fq 'cat | sudo tee' "$REPO_ROOT/linux/tuning/dev-tweaks.sh"

echo "linux-tuning smoke ok"
