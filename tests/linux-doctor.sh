#!/usr/bin/env bash
# Fast system scope powers UI overview without repeating every subsystem audit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set +e
output="$(PZ_DOCTOR_SCOPE=system timeout 15 bash "$REPO_ROOT/linux/audit/doctor.sh")"
rc=$?
set -e

grep -q '=== System Info ===' <<< "$output"
grep -q '=== Services ===' <<< "$output"
grep -q '=== Summary ===' <<< "$output"
grep -q 'Results JSON:' <<< "$output"
! grep -q '=== Steam Deck ===' <<< "$output"
jq -e 'type == "array" and length >= 10' <<< "$(sed -n '/^Results JSON:$/,$p' <<< "$output" | tail -n +2)" >/dev/null
if grep -q '\[FAIL\]\|\[ERROR\]' <<< "$output"; then
    test "$rc" -ne 0
else
    test "$rc" -eq 0
fi

echo "linux-doctor smoke ok"
