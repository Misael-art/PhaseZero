#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"))' "$ROOT/version.json")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pz-arch-build.XXXXXX")"

cleanup() {
    [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"
}
trap cleanup EXIT

command -v makepkg >/dev/null || { echo "makepkg missing" >&2; exit 69; }
command -v git >/dev/null || { echo "git missing" >&2; exit 69; }
mkdir -p "$OUT"
cp "$ROOT/packaging/linux/aur/PKGBUILD" "$WORK/PKGBUILD"

# Release builds use committed HEAD. This avoids downloading a remote tag and
# guarantees package content matches the commit that passed local gates.
git -C "$ROOT" diff --quiet --cached || {
    echo "staged changes present; commit before Arch package build" >&2
    exit 65
}
git -C "$ROOT" archive \
    --format=tar.gz \
    --prefix="PhaseZero-$VERSION/" \
    -o "$WORK/PhaseZero-$VERSION.tar.gz" HEAD

(
    cd "$WORK"
    makepkg --force --cleanbuild --nodeps --noconfirm
)
package="$(find "$WORK" -maxdepth 1 -type f -name "phasezero-control-center-$VERSION-1-any.pkg.tar*" -print -quit)"
[ -n "$package" ] || { echo "Arch package not produced" >&2; exit 1; }
cp "$package" "$OUT/"
printf '%s\n' "$OUT/$(basename "$package")"
