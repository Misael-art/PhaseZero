#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for profile in safe-base dev-ai gaming homelab emulation-linux steamdeck-linux; do
    jq empty "profiles/$profile.json" >/dev/null
    jq -e '.packages.linux.pacman | index("git")' "profiles/$profile.json" >/dev/null || fail "$profile missing git"
    jq -e '.packages.linux.pacman | index("git-lfs")' "profiles/$profile.json" >/dev/null || fail "$profile missing git-lfs"
    jq -e '.packages.linux.pacman | index("github-cli")' "profiles/$profile.json" >/dev/null || fail "$profile missing github-cli"
done

for profile in safe-base dev-ai gaming emulation-linux steamdeck-linux; do
    jq -e '.scripts.linux | index("linux/tuning/git-config.sh")' "profiles/$profile.json" >/dev/null || fail "$profile missing git-config script"
done

bash -n linux/tuning/git-config.sh
bash -n linux/audit/doctor.sh
bash -n linux/ai/status.sh
grep -q 'for tool in node npm python3 rustc cargo go jq git gh' linux/audit/doctor.sh || fail "doctor missing gh"
grep -q 'DEV_git-lfs' linux/audit/doctor.sh || fail "doctor missing git-lfs"
grep -q 'command_record gitLfs git-lfs --version' linux/ai/status.sh || fail "status missing git-lfs"
grep -q 'github_auth_record' linux/ai/status.sh || fail "status missing GitHub auth record"
grep -q 'sudo pacman -S github-cli' linux/ai/status.sh || fail "status missing gh recommendation"
grep -q 'sudo pacman -S git-lfs' linux/ai/status.sh || fail "status missing git-lfs recommendation"
grep -q 'gh auth login' linux/ai/status.sh || fail "status missing gh auth recommendation"
grep -q 'DEV_GITHUB_AUTH' linux/audit/doctor.sh || fail "doctor missing GitHub auth check"
grep -q 'choco.Source install git.install' bootstrap-tools.ps1 || fail "Windows git choco fallback missing"

safe_base_dry_run="$("$ROOT/linux/pz" install safe-base --dry-run)"
grep -q 'would install pacman package: github-cli' <<< "$safe_base_dry_run" || fail "safe-base dry-run missing github-cli"
grep -q 'would execute .*/linux/tuning/git-config.sh' <<< "$safe_base_dry_run" || fail "safe-base dry-run missing git-config"

echo "PASS: linux git/github resilience"
