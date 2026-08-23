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
grep -q '=== Steam Deck ===' <<< "$output" && exit 1
jq -e 'type == "array" and length >= 10' <<< "$(sed -n '/^Results JSON:$/,$p' <<< "$output" | tail -n +2)" >/dev/null
if grep -q '\[FAIL\]\|\[ERROR\]' <<< "$output"; then
    test "$rc" -ne 0
else
    test "$rc" -eq 0
fi

# CCS-016: host fresco sem subsystems.conf → subsystemas opcionais viram
# INFO, não uma parede de WARN.
fresh_home="$(mktemp -d)"
set +e
fresh_out="$(XDG_CONFIG_HOME="$fresh_home/.config" HOME="$fresh_home" PZ_DOCTOR_SCOPE=full timeout 120 bash "$REPO_ROOT/linux/audit/doctor.sh")"
rc=$?
set -e
rm -rf "$fresh_home"
grep -q '\[INFO\] WAYDROID00' <<< "$fresh_out" || {
    echo "FAIL: sem conf, o Waydroid deveria ser INFO (nunca optado)"
    exit 1
}
waydroid_warns="$(grep -c '^\[WARN\] WAYDROID' <<< "$fresh_out" || true)"
test "$waydroid_warns" -eq 0 || { echo "FAIL: $waydroid_warns WARN de Waydroid em host sem conf"; exit 1; }
# pz doctor --scope system roda o mesmo recorte
scoped="$("$REPO_ROOT/linux/pz" doctor --scope system 2>/dev/null | grep -c '=== Steam Deck ===' || true)"
test "$scoped" -eq 0 || { echo "FAIL: --scope system vazou seções além de system"; exit 1; }

echo "linux-doctor smoke ok"
