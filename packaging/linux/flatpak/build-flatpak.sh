#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
VERSION="$(jq -r .version "$ROOT/version.json")"

# flatpak-builder's OSTree repo and its .flatpak-builder state/cache dir must
# live on the SAME filesystem (it hardlinks between them) and ideally not on a
# FUSE mount at all (ostree needs xattr/hardlink semantics NTFS-3g may not give
# reliably — the same class of silent corruption found in the AppImage build,
# see packaging/linux/appimage/build-appimage.sh). Default all three to a fresh
# tmpfs dir; PZ_FLATPAK_* still override for callers on a safe filesystem.
WORK="${PZ_FLATPAK_WORK:-}"
CLEANUP_WORK=0
if [ -z "$WORK" ]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/pz-flatpak-build.XXXXXX")"
    CLEANUP_WORK=1
fi
REPO="${PZ_FLATPAK_REPO:-$WORK/repo}"
BUILD="${PZ_FLATPAK_BUILD:-$WORK/build}"
STATE="${PZ_FLATPAK_STATE:-$WORK/state}"

command -v flatpak-builder >/dev/null || {
    echo "flatpak-builder missing" >&2
    exit 69
}

python3 -m pip download --only-binary=:all: --no-deps --python-version 312 \
    --dest "$HERE" \
    PySide6==6.8.3 shiboken6==6.8.3 PySide6_Essentials==6.8.3 PySide6_Addons==6.8.3

rm -rf "$BUILD"
flatpak-builder --force-clean --state-dir="$STATE" --repo="$REPO" \
    "$BUILD" "$HERE/io.phasezero.ControlCenter.yml"
mkdir -p "$OUT"
flatpak build-bundle "$REPO" "$OUT/PhaseZero-$VERSION.flatpak" io.phasezero.ControlCenter
[ "$CLEANUP_WORK" = 1 ] && rm -rf "$WORK"
true
