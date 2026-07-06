#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
WORK="${PZ_APPIMAGE_WORK:-$ROOT/build/appimage}"
APPDIR="$WORK/PhaseZero.AppDir"
PYTHON="${PYTHON:-python3}"
APPIMAGETOOL="${APPIMAGETOOL:-$(command -v appimagetool || true)}"

[ -n "$APPIMAGETOOL" ] || {
    echo "appimagetool missing: set APPIMAGETOOL=/path/to/appimagetool" >&2
    exit 69
}

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib/phasezero" \
    "$APPDIR/usr/lib/python3/site-packages" "$APPDIR/usr/share/applications" \
    "$APPDIR/usr/share/metainfo"

cp -a "$ROOT/linux" "$ROOT/profiles" "$ROOT/version.json" "$APPDIR/usr/lib/phasezero/"
find "$APPDIR/usr/lib/phasezero" -type d -name __pycache__ -exec rm -rf {} +
cp "$ROOT/packaging/linux/appimage/AppRun" "$APPDIR/AppRun"
cp "$ROOT/packaging/linux/io.phasezero.ControlCenter.desktop" \
    "$APPDIR/io.phasezero.ControlCenter.desktop"
cp "$ROOT/packaging/linux/io.phasezero.ControlCenter.desktop" \
    "$APPDIR/usr/share/applications/"
cp "$ROOT/packaging/linux/io.phasezero.ControlCenter.metainfo.xml" \
    "$APPDIR/usr/share/metainfo/"
cp "$(command -v "$PYTHON")" "$APPDIR/usr/bin/python3"
PY_VER="$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
STDLIB="$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
LIBPYTHON="$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("LDLIBRARY"))')"
cp -a "$STDLIB" "$APPDIR/usr/lib/python$PY_VER"
rm -rf "$APPDIR/usr/lib/python$PY_VER/site-packages"
cp -a "/usr/lib/$LIBPYTHON"* "$APPDIR/usr/lib/"

"$PYTHON" -m pip install --disable-pip-version-check --no-compile \
    --target "$APPDIR/usr/lib/python3/site-packages" \
    "PySide6==6.11.1" "shiboken6==6.11.1"

cp "$ROOT/packaging/linux/io.phasezero.ControlCenter.svg" \
    "$APPDIR/io.phasezero.ControlCenter.svg"
ln -s "io.phasezero.ControlCenter.svg" "$APPDIR/.DirIcon"
chmod +x "$APPDIR/AppRun" "$APPDIR/usr/lib/phasezero/linux/pz" \
    "$APPDIR/usr/lib/phasezero/linux/ui/native.sh"

# Bundle sanity: the AppDir must run standalone from any cwd before packaging.
SMOKE_DIR="$(mktemp -d)"
(cd "$SMOKE_DIR" && QT_QPA_PLATFORM=offscreen "$APPDIR/AppRun" --smoke-test)
rm -rf "$SMOKE_DIR"

VERSION="$(jq -r .version "$ROOT/version.json" 2>/dev/null || echo 1.0.0)"
mkdir -p "$OUT"
ARCH="${ARCH:-$(uname -m)}" "$APPIMAGETOOL" "$APPDIR" "$OUT/PhaseZero-$VERSION-$(uname -m).AppImage"
