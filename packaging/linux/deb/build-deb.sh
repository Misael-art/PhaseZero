#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
WORK="${PZ_DEB_WORK:-$ROOT/build/deb}"
VERSION="$(jq -r .version "$ROOT/version.json")"
PKG="$WORK/phasezero-control-center_${VERSION}_all"

rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$PKG/usr/lib/phasezero" "$PKG/usr/bin" \
    "$PKG/usr/share/applications" "$PKG/usr/share/metainfo" \
    "$PKG/usr/share/icons/hicolor/scalable/apps"
cp "$ROOT/packaging/linux/deb/control" "$PKG/DEBIAN/control"
# The tracked control file's Version field is documentation, not the build input;
# always stamp the copy with version.json so a shipped .deb never reports a stale
# version if the tracked file falls out of sync.
sed -i "s/^Version:.*/Version: $VERSION/" "$PKG/DEBIAN/control"
cp -a "$ROOT/linux" "$ROOT/profiles" "$ROOT/version.json" "$PKG/usr/lib/phasezero/"
find "$PKG/usr/lib/phasezero" -type d -name __pycache__ -exec rm -rf {} +
install -m755 "$ROOT/packaging/linux/phasezero-control-center" "$PKG/usr/bin/"
install -m644 "$ROOT/packaging/linux/io.phasezero.ControlCenter.desktop" "$PKG/usr/share/applications/"
install -m644 "$ROOT/packaging/linux/io.phasezero.ControlCenter.metainfo.xml" "$PKG/usr/share/metainfo/"
install -m644 "$ROOT/packaging/linux/io.phasezero.ControlCenter.svg" "$PKG/usr/share/icons/hicolor/scalable/apps/"
mkdir -p "$OUT"
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --root-owner-group --build "$PKG" "$OUT/"
else
    command -v ar >/dev/null || { echo "dpkg-deb/ar missing" >&2; exit 69; }
    MANUAL="$WORK/manual"
    rm -rf "$MANUAL"
    mkdir -p "$MANUAL/control" "$MANUAL/data"
    cp "$PKG/DEBIAN/control" "$MANUAL/control/control"
    cp -a "$PKG/usr" "$MANUAL/data/"
    printf '2.0\n' > "$MANUAL/debian-binary"
    tar --owner=0 --group=0 -C "$MANUAL/control" -czf "$MANUAL/control.tar.gz" .
    tar --owner=0 --group=0 -C "$MANUAL/data" -czf "$MANUAL/data.tar.gz" .
    (
        cd "$MANUAL"
        ar r "$OUT/phasezero-control-center_${VERSION}_all.deb" \
            debian-binary control.tar.gz data.tar.gz
    )
fi
