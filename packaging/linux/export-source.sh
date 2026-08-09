#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="${1:-}"
[ -n "$DESTINATION" ] || { echo "usage: export-source.sh DESTINATION" >&2; exit 64; }
case "$DESTINATION" in
    /|"$HOME"|"$ROOT") echo "unsafe export destination: $DESTINATION" >&2; exit 64 ;;
esac

mkdir -p "$DESTINATION"
if find "$DESTINATION" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "export destination must be empty: $DESTINATION" >&2
    exit 65
fi

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ "${PZ_ALLOW_DIRTY_SOURCE:-0}" != "1" ] &&
        [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
        echo "tracked worktree changes present; commit before packaging" >&2
        exit 65
    fi
    git -C "$ROOT" archive "${PZ_SOURCE_REF:-HEAD}" | tar -x -C "$DESTINATION"
    if [ "${PZ_ALLOW_DIRTY_SOURCE:-0}" = "1" ]; then
        changed=()
        while IFS= read -r -d '' path; do
            [ -e "$ROOT/$path" ] || [ -L "$ROOT/$path" ] || continue
            changed+=("$path")
        done < <(git -C "$ROOT" ls-files -z --modified --others --exclude-standard)
        if [ "${#changed[@]}" -gt 0 ]; then
            tar -C "$ROOT" -cf - -- "${changed[@]}" | tar -x -C "$DESTINATION"
        fi
        while IFS= read -r -d '' path; do
            rm -rf -- "${DESTINATION:?}/$path"
        done < <(git -C "$ROOT" diff --name-only --diff-filter=D -z)
    fi
else
    # Verified source release archives contain no VCS metadata. Exclude runtime
    # caches and filesystem recovery ghosts when re-exporting such an archive.
    tar -C "$ROOT" \
        --exclude=.git --exclude='*/__pycache__' --exclude='*.py[co]' \
        --exclude='*/.ghost-ntfs-3g-*' -cf - . | tar -x -C "$DESTINATION"
fi

find "$DESTINATION" -type d -name __pycache__ -prune -exec rm -rf -- {} +
if find "$DESTINATION" -name '.ghost-ntfs-3g-*' -print -quit | grep -q .; then
    echo "filesystem ghost entered canonical source export" >&2
    exit 1
fi
[ -f "$DESTINATION/version.json" ] || { echo "version.json missing from export" >&2; exit 1; }
