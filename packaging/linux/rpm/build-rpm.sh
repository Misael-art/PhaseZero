#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
TOP="${PZ_RPM_TOPDIR:-$ROOT/build/rpm}"
VERSION="$(jq -r .version "$ROOT/version.json")"
SOURCE="$TOP/source/PhaseZero-$VERSION"

command -v rpmbuild >/dev/null || { echo "rpmbuild missing" >&2; exit 69; }
rm -rf "$TOP"
mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    "$SOURCE/packaging"
cp -a "$ROOT/linux" "$ROOT/profiles" "$ROOT/version.json" "$SOURCE/"
cp -a "$ROOT/packaging/linux" "$SOURCE/packaging/"
find "$SOURCE" -type d -name __pycache__ -exec rm -rf {} +
tar -C "$TOP/source" -czf "$TOP/SOURCES/v$VERSION.tar.gz" "PhaseZero-$VERSION"
rpmbuild -bb --define "_topdir $TOP" \
    "$ROOT/packaging/linux/rpm/phasezero-control-center.spec"
mkdir -p "$OUT"
find "$TOP/RPMS" -type f -name '*.rpm' -exec cp -f {} "$OUT/" \;
