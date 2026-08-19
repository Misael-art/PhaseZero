#!/usr/bin/env bash
# Hermetic contract for the post-transaction boot runtime notice: it warns,
# records the pending-sync marker, never fails the transaction, and stays
# silent when there is nothing to warn about.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Fake PZ_LIB whose windows-vm.sh answers runtime-check with a canned state.
make_lib() {
    local state="$1"
    mkdir -p "$TEST_ROOT/lib-$state/linux/windows-vm"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        # shellcheck disable=SC2016 # the stub must keep "$1" literal
        printf '%s\n' 'case "$1" in'
        printf '%s\n' '  boot) cat <<JSON'
        printf '%s\n' "{\"bootRuntimeState\":\"$state\"}"
        printf '%s\n' 'JSON'
        printf '%s\n' '  ;;'
        printf '%s\n' 'esac'
    } > "$TEST_ROOT/lib-$state/linux/windows-vm/windows-vm.sh"
}

run_notice() {
    local lib_dir="$1" helper="$2" marker="$3"
    PZ_LIB_DIR="$lib_dir" \
    PZ_BOOT_HELPER="$helper" \
    PZ_BOOT_RUNTIME_PENDING="$marker" \
        bash "$REPO_ROOT/linux/windows-vm/boot-runtime-notice.sh" 2>"$TEST_ROOT/notice.err"
}

# stale runtime + boot integration installed -> warn AND leave the marker.
make_lib stale
touch "$TEST_ROOT/helper"
MARKER="$TEST_ROOT/pending.marker"
run_notice "$TEST_ROOT/lib-stale" "$TEST_ROOT/helper" "$MARKER"
grep -q 'OUTDATED' "$TEST_ROOT/notice.err"
grep -q 'stale' "$MARKER"

# boot integration never installed -> silent, no marker.
rm -f "$TEST_ROOT/notice.err" "$MARKER"
run_notice "$TEST_ROOT/lib-stale" "$TEST_ROOT/absent-helper" "$MARKER"
[ ! -e "$MARKER" ]
[ ! -s "$TEST_ROOT/notice.err" ]

# runtime current -> silent, no marker.
make_lib current
run_notice "$TEST_ROOT/lib-current" "$TEST_ROOT/helper" "$MARKER"
[ ! -e "$MARKER" ]
[ ! -s "$TEST_ROOT/notice.err" ]

# lib unreadable -> still exit 0 (transaction must never fail).
run_notice "$TEST_ROOT/no-such-lib" "$TEST_ROOT/helper" "$MARKER"
[ ! -e "$MARKER" ]

echo "boot runtime notice contract ok"
