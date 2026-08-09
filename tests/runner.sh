#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
FAILED_NAMES=()

for test_file in tests/linux-*.sh tests/test_provision.sh; do
    [ -f "$test_file" ] || continue
    name="$(basename "$test_file" .sh)"
    printf '\n--- %s ---\n' "$name"

    TMP="$(mktemp -d)"
    if bash "$test_file" 2>&1; then
        printf '  %s OK\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  %s FAIL (exit %d)\n' "$name" $?
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$name")
    fi
    rm -rf "$TMP"
done

printf '\n=== RESULTS: %d pass, %d fail ===\n' "$PASS" "$FAIL"
if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
    printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
    exit 1
fi
