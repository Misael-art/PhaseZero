#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"))' "$ROOT/version.json")"

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
MANIFEST="$WORK/io.phasezero.ControlCenter.yml"
SOURCE="$WORK/source"

for guarded_path in "$WORK" "$REPO" "$BUILD" "$STATE"; do
    case "$guarded_path" in
        ""|/|"$HOME"|"$ROOT")
            echo "unsafe Flatpak build path: ${guarded_path:-<empty>}" >&2
            exit 64
            ;;
    esac
done
mkdir -p "$WORK"

cleanup() {
    if [ "$CLEANUP_WORK" = 1 ] && [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT

command -v flatpak-builder >/dev/null || {
    echo "flatpak-builder missing" >&2
    exit 69
}
command -v flatpak >/dev/null || { echo "flatpak missing" >&2; exit 69; }
command -v python3 >/dev/null || { echo "python3 missing" >&2; exit 69; }

case "$(uname -m)" in
    x86_64|amd64) ;;
    *) echo "Flatpak manifest currently supports x86_64 PySide6 wheels only" >&2; exit 69 ;;
esac

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cp "$HERE/io.phasezero.ControlCenter.yml" "$MANIFEST"

# Build the checked-out tree. The release manifest intentionally points at a
# Git tag, but using it here would silently package stale remote code while a
# maintainer validates local changes.
rm -rf -- "$SOURCE"
mkdir -p "$SOURCE"
bash "$ROOT/packaging/linux/export-source.sh" "$SOURCE"
python3 - "$MANIFEST" "$SOURCE" <<'PY'
from pathlib import Path
import re
import sys

manifest = Path(sys.argv[1])
source = sys.argv[2]
text = manifest.read_text(encoding="utf-8")
new = f"""    sources:
      - type: dir
        path: {source}
"""
pattern = re.compile(
    r"    sources:\n"
    r"      - type: git\n"
    r"        url: https://github\.com/Misael-art/PhaseZero\.git\n"
    r"        tag: v[^\n]+\n"
)
text, replacements = pattern.subn(new, text)
if replacements != 1:
    raise SystemExit("unexpected PhaseZero source block in Flatpak manifest")
manifest.write_text(text, encoding="utf-8")
PY

rm -rf -- "$BUILD"
flatpak-builder --force-clean --state-dir="$STATE" --repo="$REPO" \
    "$BUILD" "$MANIFEST"
flatpak build-bundle "$REPO" "$OUT/PhaseZero-$VERSION.flatpak" io.phasezero.ControlCenter
