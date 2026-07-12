#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/dist}"
VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"))' "$ROOT/version.json")"

PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m pytest -q \
    "$ROOT/tests/test_installation_cohesion.py"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

SOURCE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/pz-source-release.XXXXXX")"
trap 'rm -rf -- "$SOURCE_WORK"' EXIT
mkdir -p "$SOURCE_WORK/PhaseZero-$VERSION"
"$HERE/export-source.sh" "$SOURCE_WORK/PhaseZero-$VERSION"
tar -C "$SOURCE_WORK" -czf "$OUT/PhaseZero-$VERSION-source.tar.gz" "PhaseZero-$VERSION"

bash "$HERE/deb/build-deb.sh" "$OUT"
bash "$HERE/rpm/build-rpm.sh" "$OUT"
bash "$HERE/arch/build-arch.sh" "$OUT"
bash "$HERE/appimage/build-appimage.sh" "$OUT"
# Flatpak needs org.kde.Platform//6.11 and a privileged flatpak-builder sandbox,
# which CI runners build in a dedicated job. Set PZ_SKIP_FLATPAK=1 to skip it
# here without failing the artifact verification below.
if [ "${PZ_SKIP_FLATPAK:-0}" != "1" ]; then
    bash "$HERE/flatpak/build-flatpak.sh" "$OUT"
fi

artifacts=(
    "$OUT/phasezero-control-center_${VERSION}_all.deb"
    "$OUT/phasezero-control-center-${VERSION}-1.noarch.rpm"
    "$OUT/PhaseZero-${VERSION}-x86_64.AppImage"
    "$OUT/PhaseZero-${VERSION}-source.tar.gz"
)
[ "${PZ_SKIP_FLATPAK:-0}" = "1" ] || artifacts+=("$OUT/PhaseZero-${VERSION}.flatpak")
while IFS= read -r package; do
    artifacts+=("$package")
done < <(find "$OUT" -maxdepth 1 -type f -name "phasezero-control-center-${VERSION}-1-any.pkg.tar*" -print)

for artifact in "${artifacts[@]}"; do
    [ -s "$artifact" ] || { echo "missing release artifact: $artifact" >&2; exit 1; }
done
(
    cd "$OUT"
    names=()
    for artifact in "${artifacts[@]}"; do
        names+=("$(basename "$artifact")")
    done
    sha256sum "${names[@]}" > "SHA256SUMS-$VERSION"
    sha256sum -c "SHA256SUMS-$VERSION"
)

printf 'Linux release artifacts ready: %s\n' "$VERSION"
