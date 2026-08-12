#!/usr/bin/env bash
# Lists every shell script in the repository, NUL separated.
#
# Selecting by extension misses the entry points that have none - linux/pz
# above all, the CLI the whole product is driven through - so those went
# unchecked by both shellcheck and bash -n while being edited constantly.
# Shell scripts without a suffix are identified by their shebang.
#
# Only tracked files are considered: a bare find also sweeps build artefacts
# and vendored node_modules, which are absent from a clean checkout and would
# make results depend on what happens to be lying around.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

git ls-files -z '*.sh'

git ls-files -z | while IFS= read -r -d '' candidate; do
    case "$candidate" in *.*) continue ;; esac
    [ -f "$candidate" ] || continue
    if head -n 1 "$candidate" 2>/dev/null | grep -qE '^#!.*\b(ba)?sh\b'; then
        printf '%s\0' "$candidate"
    fi
done
