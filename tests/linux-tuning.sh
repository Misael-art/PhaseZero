#!/usr/bin/env bash
# Smoke tests for user tuning and security-safe browser defaults.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_STATE_HOME="$TMP_ROOT/state"
export PZ_BACKUP_ROOT="$XDG_STATE_HOME/backups"
mkdir -p "$HOME/.mozilla/firefox/test.default-release" "$HOME/.config/chromium" "$PZ_BACKUP_ROOT"

bash -n "$REPO_ROOT/linux/tuning/browser-hardening.sh"
bash -n "$REPO_ROOT/linux/tuning/dev-tweaks.sh"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --severity=error "$REPO_ROOT/linux/tuning/browser-hardening.sh" "$REPO_ROOT/linux/tuning/dev-tweaks.sh"
fi

bash "$REPO_ROOT/linux/tuning/browser-hardening.sh" >/dev/null
userjs="$HOME/.mozilla/firefox/test.default-release/user.js"
chromium_policy="$HOME/.config/chromium/Default/policies/managed/phasezero-hardening.json"
test -s "$userjs"
jq empty "$chromium_policy"
grep -Fq 'browser.safebrowsing.downloads.remote.enabled", true' "$userjs"
grep -Fq 'browser.safebrowsing.malware.enabled", true' "$userjs"
grep -Fq 'browser.safebrowsing.phishing.enabled", true' "$userjs"
if grep -Eq 'browser\.safebrowsing\.(downloads\.remote|malware|phishing)\.enabled", false' "$userjs"; then
    echo "FAIL: safebrowsing still disabled in user.js"
    exit 1
fi

bash "$REPO_ROOT/linux/tuning/browser-hardening.sh" >/dev/null
find "${PZ_BACKUP_ROOT:-$XDG_STATE_HOME/backups}" -type f -name 'user.js.bak.*' -print -quit | grep -q .
if grep -Fq 'cat | sudo tee' "$REPO_ROOT/linux/tuning/dev-tweaks.sh"; then
    echo "FAIL: dev-tweaks.sh still uses 'cat | sudo tee'"
    exit 1
fi

# CCS-003: --dry-run é preview da área — zero escrita, plano listado.
for area in browser gaming dev; do
    before="$(find "$TMP_ROOT" -mindepth 1 | sort)"
    dry_out="$("$REPO_ROOT/linux/pz" tune "$area" --dry-run)"
    after="$(find "$TMP_ROOT" -mindepth 1 | sort)"
    test "$before" = "$after" || { echo "FAIL: tune $area --dry-run escreveu arquivos"; exit 1; }
    grep -q "dry-run" <<< "$dry_out" || { echo "FAIL: tune $area --dry-run sem plano"; exit 1; }
done

# argumento inválido falha em vez de aplicar silenciosamente
if "$REPO_ROOT/linux/tuning/gaming-tweaks.sh" --modo-ruim >/dev/null 2>&1; then
    echo "FAIL: gaming-tweaks.sh aceitou modo inválido"
    exit 1
fi

echo "linux-tuning smoke ok"
