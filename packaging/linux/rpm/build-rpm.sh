#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
TOP="${PZ_RPM_TOPDIR:-$ROOT/build/rpm}"
VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"))' "$ROOT/version.json")"

command -v rpmbuild >/dev/null || { echo "rpmbuild missing" >&2; exit 69; }
mkdir -p "$TOP"
TOP="$(cd "$TOP" && pwd)"
case "$TOP" in
    /|"$HOME"|"$ROOT") echo "unsafe PZ_RPM_TOPDIR: $TOP" >&2; exit 64 ;;
esac
SOURCE="$TOP/source/PhaseZero-$VERSION"
rm -rf -- "$TOP/BUILD" "$TOP/BUILDROOT" "$TOP/RPMS" "$TOP/SOURCES" \
    "$TOP/SPECS" "$TOP/SRPMS" "$TOP/source"
mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    "$SOURCE/packaging"
cp -a "$ROOT/linux" "$ROOT/profiles" "$ROOT/assets" "$ROOT/version.json" "$SOURCE/"
cp -a "$ROOT/packaging/linux" "$SOURCE/packaging/"
find "$SOURCE" -type d -name __pycache__ -exec rm -rf {} +
tar -C "$TOP/source" -czf "$TOP/SOURCES/v$VERSION.tar.gz" "PhaseZero-$VERSION"
# Build from a copy of the spec, stamped with version.json's Version: the tracked
# .spec is documentation between releases and must not be mutated by a build.
SPEC="$TOP/SPECS/phasezero-control-center.spec"
cp "$ROOT/packaging/linux/rpm/phasezero-control-center.spec" "$SPEC"
sed -i "s/^Version:.*/Version:        $VERSION/" "$SPEC"
rpmbuild -bb --define "_topdir $TOP" "$SPEC"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
find "$TOP/RPMS" -type f -name '*.rpm' -exec cp -f {} "$OUT/" \;
