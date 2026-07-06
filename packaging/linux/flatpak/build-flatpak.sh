#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
VERSION="$(jq -r .version "$ROOT/version.json")"
REPO="${PZ_FLATPAK_REPO:-$ROOT/build/flatpak-repo}"
BUILD="${PZ_FLATPAK_BUILD:-$ROOT/build/flatpak}"

command -v flatpak-builder >/dev/null || {
    echo "flatpak-builder missing" >&2
    exit 69
}

python3 -m pip download --only-binary=:all: --no-deps --python-version 312 \
    --dest "$HERE" \
    PySide6==6.8.3 shiboken6==6.8.3 PySide6_Essentials==6.8.3 PySide6_Addons==6.8.3

rm -rf "$BUILD"
flatpak-builder --force-clean --repo="$REPO" \
    "$BUILD" "$HERE/io.phasezero.ControlCenter.yml"
mkdir -p "$OUT"
flatpak build-bundle "$REPO" "$OUT/PhaseZero-$VERSION.flatpak" io.phasezero.ControlCenter
