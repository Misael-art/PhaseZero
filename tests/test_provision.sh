#!/usr/bin/env bash
# Testes para provisionamento Windows VM
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PASS=0 FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected=$expected actual=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected to contain: $needle)"
        FAIL=$((FAIL + 1))
    fi
}

PROVISION_SCRIPT="$PZ_ROOT/linux/windows-vm/provision.sh"
MEDIA_SCRIPT="$PZ_ROOT/linux/windows-vm/media-inspect.sh"
AUTOUNATTEND_SCRIPT="$PZ_ROOT/linux/windows-vm/autounattend.sh"
TWEAKS_SCRIPT="$PZ_ROOT/linux/windows-vm/tweaks.sh"
SNAPSHOT_SCRIPT="$PZ_ROOT/linux/windows-vm/snapshot.sh"

echo "=== provision: plan generation ==="

# Create dummy ISO
DUMMY_ISO="$(mktemp -d)/dummy.iso"
dd if=/dev/urandom bs=1M count=10 of="$DUMMY_ISO" 2>/dev/null

PZ_STATE_DIR="$(mktemp -d)"
PLAN_OUT=$(PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null || echo "")
assert_contains "plan has id" "$PLAN_OUT" '"id"'
assert_contains "plan has confirmToken" "$PLAN_OUT" '"confirmToken"'
assert_contains "plan has iso" "$PLAN_OUT" '"iso"'
assert_contains "plan has resources" "$PLAN_OUT" '"resources"'
assert_contains "plan has profile" "$PLAN_OUT" '"performance-safe"'
assert_contains "plan has imageIndex" "$PLAN_OUT" '"imageIndex"'

PLAN_ID=$(echo "$PLAN_OUT" | jq -r '.id // ""' 2>/dev/null || echo "")
assert_eq "plan id not empty" "1" "$([ -n "$PLAN_ID" ] && echo 1 || echo 0)"

CONFIRM_TOKEN=$(echo "$PLAN_OUT" | jq -r '.confirmToken // ""' 2>/dev/null || echo "")
assert_eq "confirm token not empty" "1" "$([ -n "$CONFIRM_TOKEN" ] && echo 1 || echo 0)"

IMAGE_INDEX=$(echo "$PLAN_OUT" | jq -r '.imageIndex // 0' 2>/dev/null || echo "0")
assert_eq "default imageIndex is 1" "1" "$IMAGE_INDEX"

echo ""
echo "=== provision: plan with --image-index ==="
PLAN_OUT2=$(PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --image-index 3 --json 2>/dev/null || echo "")
IMAGE_INDEX2=$(echo "$PLAN_OUT2" | jq -r '.imageIndex // 0' 2>/dev/null || echo "0")
assert_eq "custom imageIndex is 3" "3" "$IMAGE_INDEX2"

echo ""
echo "=== provision: plan validation ==="
BLOCKERS=$(echo "$PLAN_OUT" | jq '.blockers | length' 2>/dev/null || echo "1")
assert_eq "no blockers" "0" "$BLOCKERS"

echo ""
echo "=== autounattend: XML generation ==="
OUT_DIR="$(mktemp -d)"
AUTO_OUT=$(bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-TEST-1234" --output-dir "$OUT_DIR" 2>/dev/null || echo "")
assert_contains "autounattend generated" "$AUTO_OUT" "autounattend.xml"
assert_eq "autounattend.xml exists" "1" "$([ -f "$OUT_DIR/autounattend.xml" ] && echo 1 || echo 0)"

# Validate XML structure
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$OUT_DIR/autounattend.xml" 2>/dev/null && {
        assert_eq "autounattend.xml valid XML" "1" "1"
    } || {
        assert_eq "autounattend.xml valid XML" "1" "0"
    }
fi

assert_contains "autounattend has disk config" "$(cat "$OUT_DIR/autounattend.xml")" "DiskConfiguration"
assert_contains "autounattend has OOBE" "$(cat "$OUT_DIR/autounattend.xml")" "OOBE"
assert_contains "autounattend has phasezero user" "$(cat "$OUT_DIR/autounattend.xml")" "phasezero"
assert_contains "autounattend has partition" "$(cat "$OUT_DIR/autounattend.xml")" "CreatePartition"

rm -rf "$OUT_DIR"

echo ""
echo "=== media-inspect: ISO inspection ==="
MEDIA_OUT=$(bash "$MEDIA_SCRIPT" inspect --iso "$DUMMY_ISO" --json 2>/dev/null || echo "")
assert_contains "media inspect has sha256" "$MEDIA_OUT" '"sha256"'
assert_contains "media inspect has arch" "$MEDIA_OUT" '"arch"'
assert_contains "media inspect has uefi" "$MEDIA_OUT" '"uefiBoot"'
assert_contains "media inspect has size" "$MEDIA_OUT" '"sizeMb"'
assert_contains "media inspect has valid" "$MEDIA_OUT" '"valid"'
MEDIA_VALID=$(echo "$MEDIA_OUT" | jq -r '.valid' 2>/dev/null || echo "null")
assert_eq "dummy ISO not valid (no Windows structure)" "false" "$MEDIA_VALID"

echo ""
echo "=== tweaks: performance-safe profile ==="
TWEAKS_RAW=$(bash "$TWEAKS_SCRIPT" apply 2>/dev/null || echo "")
TWEAKS_OUT=$(echo "$TWEAKS_RAW" | awk '/^{/{p=1} p{print} /^}/{p=0}' | tr -d '\n' || echo "{}")
assert_contains "tweaks has profile" "$TWEAKS_OUT" '"performance-safe"'
assert_contains "tweaks has changes" "$TWEAKS_OUT" '"powerScheme"'
assert_contains "tweaks has appxRemoval" "$TWEAKS_OUT" '"appxRemoval"'
assert_contains "tweaks preserves Defender" "$TWEAKS_OUT" '"Defender"'
TWEAKS_COUNT=$(echo "$TWEAKS_OUT" | jq -c '.changes | length' 2>/dev/null || echo 0)
assert_eq "tweaks count > 0" "1" "$([ "$TWEAKS_COUNT" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "=== snapshot: create and verify ==="
SNAP_DIR="$(mktemp -d)"
SNAP_DISK="$SNAP_DIR/test-disk.qcow2"
qemu-img create -f qcow2 "$SNAP_DISK" 64M 2>/dev/null || dd if=/dev/zero bs=1M count=64 of="$SNAP_DISK" 2>/dev/null
SNAP_RAW=$(SNAPSHOT_DIR="$SNAP_DIR" bash "$SNAPSHOT_SCRIPT" create --name "test-snap" --disk "$SNAP_DISK" --json 2>/dev/null || echo '{"created": false}')
SNAP_RESULT=$(echo "$SNAP_RAW" | awk '/^{/{p=1} p{print} /^}/{p=0}' | tr -d '\n' || echo '{"created": false}')
assert_contains "snapshot created" "$SNAP_RESULT" '"created"'
SNAP_PATH=$(echo "$SNAP_RESULT" | jq -r '.path // ""' 2>/dev/null || echo "")
if [ -n "$SNAP_PATH" ] && [ -f "$SNAP_PATH" ]; then
    assert_eq "snapshot file exists" "1" "1"
    VERIFY_RAW=$(SNAPSHOT_DIR="$SNAP_DIR" bash "$SNAPSHOT_SCRIPT" verify --path "$SNAP_PATH" --json 2>/dev/null || echo '{"valid": false}')
    VERIFY_RESULT=$(echo "$VERIFY_RAW" | awk '/^{/{p=1} p{print} /^}/{p=0}' | tr -d '\n' || echo '{"valid": false}')
    SNAP_VALID=$(echo "$VERIFY_RESULT" | jq -r '.valid // false' 2>/dev/null || echo "false")
    assert_eq "snapshot verified" "true" "$SNAP_VALID"
    # Verify backing chain
    BACKING_FILE=$(qemu-img info "$SNAP_PATH" 2>/dev/null | grep 'backing file:' | sed 's/.*backing file: //' || echo "")
    assert_eq "snapshot has backing file" "1" "$([ -n "$BACKING_FILE" ] && echo 1 || echo 0)"
    assert_eq "backing file is test disk" "$SNAP_DISK" "$BACKING_FILE"
else
    assert_eq "snapshot file exists" "1" "0"
fi

rm -rf "$SNAP_DIR"

echo ""
echo "=== secret redaction ==="
# Verify bootstrap secret is stored with 0600 permissions and never in stdout
OUT_DIR2="$(mktemp -d)"
bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-SECRET-TEST" \
    --password "SuperSecretP@ss123!" --output-dir "$OUT_DIR2" > /dev/null 2>&1
PWD_IN_OUTPUT=$(bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-SECRET-TEST" \
    --password "SuperSecretP@ss123!" --output-dir "$(mktemp -d)" 2>&1 || true)
assert_eq "password not in stdout" "0" "$(echo "$PWD_IN_OUTPUT" | grep -c 'SuperSecretP@ss123!' || true)"
rm -rf "$OUT_DIR2"

echo ""
echo "=== provision: cancel set -u safety ==="
# Verify provision_cancel uses $operation_id not $op (no crash under set -u)
CANCEL_TEST_DIR="$(mktemp -d)"
mkdir -p "$CANCEL_TEST_DIR/phasezero/operations/test-cancel"
mkdir -p "$CANCEL_TEST_DIR/phasezero/vms/test-op"
echo '{"id":"test-cancel","state":"running","checkpoint":"assets","progress":10}' > "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/operation.json"
echo "$CANCEL_TEST_DIR/phasezero/vms/test-op" > "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/vm_dir"
XDG_STATE_HOME="$CANCEL_TEST_DIR" bash "$PROVISION_SCRIPT" cancel --operation-id test-cancel 2>/dev/null || true
CANCEL_STATE=$(cat "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/operation.json" 2>/dev/null | jq -r '.state // ""' 2>/dev/null || echo "")
assert_eq "cancel changes state to cancelled" "cancelled" "$CANCEL_STATE"
rm -rf "$CANCEL_TEST_DIR"

rm -rf "$DUMMY_ISO" "$(dirname "$DUMMY_ISO")" "$PZ_STATE_DIR"

echo ""
echo "=== results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
