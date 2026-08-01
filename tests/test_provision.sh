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
    if echo "$haystack" | grep -F -q "$needle"; then
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

# Hermetic preflight fixture: plan must not depend on host state (CI lacks
# swtpm/daemons). PZ_PREFLIGHT_JSON is consumed by provision.sh plan but only
# with the PZ_TEST_MODE=1 sentinel — production always runs the real preflight.
PREFLIGHT_PASS_FIXTURE='{"status":"pass","swtpm":{"binary":true,"running":true},"virtio":{"outdated":false}}'

echo "=== provision: plan generation ==="

# Create dummy ISO
DUMMY_ISO="$(mktemp -d)/dummy.iso"
dd if=/dev/urandom bs=1M count=10 of="$DUMMY_ISO" 2>/dev/null

PZ_STATE_DIR="$(mktemp -d)"
PLAN_OUT=$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null || echo "")
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
PLAN_OUT2=$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --image-index 3 --json 2>/dev/null || echo "")
IMAGE_INDEX2=$(echo "$PLAN_OUT2" | jq -r '.imageIndex // 0' 2>/dev/null || echo "0")
assert_eq "custom imageIndex is 3" "3" "$IMAGE_INDEX2"

echo ""
echo "=== provision: plan validation ==="
BLOCKERS=$(echo "$PLAN_OUT" | jq '.blockers | length' 2>/dev/null || echo "1")
assert_eq "no blockers" "0" "$BLOCKERS"

echo ""
echo "=== provision: preflight override sentinel ==="
# Without PZ_TEST_MODE=1 the override must NOT be honored: an invalid fixture
# must never reach the plan as preflight data.
set +e
PLAN_NO_SENTINEL="$(PZ_PREFLIGHT_JSON='not-json' PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null)"
NO_SENTINEL_RC=$?
set -e
assert_eq "override without sentinel does not abort plan" "0" "$NO_SENTINEL_RC"
if [ -n "$PLAN_NO_SENTINEL" ]; then
    assert_contains "no sentinel: override ignored, plan still valid" "$PLAN_NO_SENTINEL" '"id"'
fi
# With the sentinel, an invalid fixture is rejected loudly (rc != 0).
set +e
PLAN_BAD_FIXTURE="$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON='not-json' PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null)"
BAD_FIXTURE_RC=$?
set -e
assert_eq "bad fixture with sentinel rejected" "1" "$BAD_FIXTURE_RC"
# A fixture missing required fields is rejected too.
set +e
PLAN_BAD_SCHEMA="$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON='{"status":"pass"}' PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null)"
BAD_SCHEMA_RC=$?
set -e
assert_eq "schema-missing fixture with sentinel rejected" "1" "$BAD_SCHEMA_RC"

echo ""
echo "=== autounattend: XML generation ==="
OUT_DIR="$(mktemp -d)"
AUTO_OUT=$(bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-TEST-1234" --output-dir "$OUT_DIR" 2>/dev/null || echo "")
assert_contains "autounattend generated" "$AUTO_OUT" "autounattend.xml"
assert_eq "autounattend.xml exists" "1" "$([ -f "$OUT_DIR/autounattend.xml" ] && echo 1 || echo 0)"

# Validate XML structure
if command -v xmllint >/dev/null 2>&1; then
    if xmllint --noout "$OUT_DIR/autounattend.xml" 2>/dev/null; then
        assert_eq "autounattend.xml valid XML" "1" "1"
    else
        assert_eq "autounattend.xml valid XML" "1" "0"
    fi
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
if command -v qemu-img >/dev/null 2>&1; then
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
else
    echo "  (snapshot tests skipped: qemu-img not installed)"
fi

rm -rf "$SNAP_DIR"

echo ""
echo "=== secret redaction ==="
# Verify bootstrap secret is stored with 0600 permissions and never in stdout
OUT_DIR2="$(mktemp -d)"
bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-SECRET-TEST" \
    --password "SuperSecretP@ss123!" --output-dir "$OUT_DIR2" > /dev/null 2>&1
SECRET_OUT_DIR="$(mktemp -d)"
PWD_IN_OUTPUT=$(bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-SECRET-TEST" \
    --password "SuperSecretP@ss123!" --output-dir "$SECRET_OUT_DIR" 2>&1 || true)
assert_eq "password not in stdout" "0" "$(echo "$PWD_IN_OUTPUT" | grep -c 'SuperSecretP@ss123!' || true)"
rm -rf "$OUT_DIR2" "$SECRET_OUT_DIR"

echo ""
echo "=== provision: cancel set -u safety ==="
# Verify provision_cancel uses $operation_id not $op (no crash under set -u)
CANCEL_TEST_DIR="$(mktemp -d)"
mkdir -p "$CANCEL_TEST_DIR/phasezero/operations/test-cancel"
mkdir -p "$CANCEL_TEST_DIR/phasezero/windows-vm/vms/test-cancel"
echo '{"id":"test-cancel","state":"running","checkpoint":"assets","progress":10}' > "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/operation.json"
echo "$CANCEL_TEST_DIR/phasezero/windows-vm/vms/test-cancel" > "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/vm_dir"
set +e
CANCEL_JSON=$(XDG_STATE_HOME="$CANCEL_TEST_DIR" bash "$PROVISION_SCRIPT" cancel --operation-id test-cancel --json 2>/dev/null)
CANCEL_RC=$?
set -e
CANCEL_STATE=$(jq -r '.state // ""' "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/operation.json" 2>/dev/null || echo "")
assert_eq "cancel changes state to cancelled" "cancelled" "$CANCEL_STATE"
assert_eq "cancel --json rc 0" "0" "$CANCEL_RC"
assert_eq "cancel --json success" "true" "$(echo "$CANCEL_JSON" | jq -r '.success' 2>/dev/null || echo "")"
assert_eq "cancel --json cancelled" "true" "$(echo "$CANCEL_JSON" | jq -r '.cancelled' 2>/dev/null || echo "")"
assert_eq "cancel --json removalRequested (assets checkpoint)" "true" "$(echo "$CANCEL_JSON" | jq -r '.removalRequested' 2>/dev/null || echo "")"
assert_eq "cancel --json removalSucceeded" "true" "$(echo "$CANCEL_JSON" | jq -r '.removalSucceeded' 2>/dev/null || echo "")"
rm -rf "$CANCEL_TEST_DIR"

echo ""
echo "=== provision: cancel --json refuses external staging ==="
CANCEL_EVIL_T="$(mktemp -d)"
mkdir -p "$CANCEL_EVIL_T/phasezero/operations/cancel-evil" "$CANCEL_EVIL_T/external-staging"
echo '{"id":"cancel-evil","state":"running","checkpoint":"validate","progress":5}' > "$CANCEL_EVIL_T/phasezero/operations/cancel-evil/operation.json"
echo "$CANCEL_EVIL_T/external-staging" > "$CANCEL_EVIL_T/phasezero/operations/cancel-evil/vm_dir"
set +e
CANCEL_EVIL_JSON=$(XDG_STATE_HOME="$CANCEL_EVIL_T" bash "$PROVISION_SCRIPT" cancel --operation-id cancel-evil --remove-staging --json 2>/dev/null)
CANCEL_EVIL_RC=$?
set -e
assert_eq "cancel external staging rc non-zero" "1" "$CANCEL_EVIL_RC"
assert_eq "cancel external staging preserved" "1" "$([ -d "$CANCEL_EVIL_T/external-staging" ] && echo 1 || echo 0)"
assert_eq "cancel --json success false" "false" "$(echo "$CANCEL_EVIL_JSON" | jq -r '.success' 2>/dev/null || echo "")"
assert_eq "cancel --json removalSucceeded false" "false" "$(echo "$CANCEL_EVIL_JSON" | jq -r '.removalSucceeded' 2>/dev/null || echo "")"
assert_eq "cancel --json preservedPath set" "$CANCEL_EVIL_T/external-staging" "$(echo "$CANCEL_EVIL_JSON" | jq -r '.preservedPath' 2>/dev/null || echo "")"
rm -rf "$CANCEL_EVIL_T"

# shellcheck source=linux/windows-vm/provision.sh
source "$PROVISION_SCRIPT" 2>/dev/null || true

echo ""
echo "=== provision: validate_qemu_pid guards ==="
# Never kill real processes: use the test shell's own pid (alive, not qemu)
# and a background sleeper with a forged qemu argv0 (qemu-like but no op).
set +e
validate_qemu_pid "$$" "" "op-guard" 2>/dev/null
GUARD_NOT_QEMU=$?
set -e
assert_eq "alive non-qemu pid refused" "1" "$GUARD_NOT_QEMU"
sleep 60 &
FAKE_QEMU_PID=$!
set +e
validate_qemu_pid "$FAKE_QEMU_PID" "" "op-guard" 2>/dev/null
GUARD_SLEEPER=$?
set -e
kill "$FAKE_QEMU_PID" 2>/dev/null || true
wait "$FAKE_QEMU_PID" 2>/dev/null || true
assert_eq "sleeper pid refused (not qemu)" "1" "$GUARD_SLEEPER"
set +e
validate_qemu_pid "999999" "" "op-guard" 2>/dev/null
GUARD_DEAD=$?
set -e
assert_eq "dead pid refused" "1" "$GUARD_DEAD"
set +e
validate_qemu_pid "abc" "" "op-guard" 2>/dev/null
GUARD_NAN=$?
set -e
assert_eq "non-numeric pid refused" "1" "$GUARD_NAN"
set +e
validate_qemu_pid "" "" "op-guard" 2>/dev/null
GUARD_EMPTY=$?
set -e
assert_eq "empty pid refused" "1" "$GUARD_EMPTY"

echo ""
echo "=== graphics: plan serialization ==="
GFX_PLAN_DIR="$(mktemp -d)"
GFX_VIRTIO=$(PZ_STATE="$GFX_PLAN_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --graphics virtio-gl --json 2>/dev/null | jq -r '.graphics // ""' 2>/dev/null || echo "")
assert_eq "plan --graphics virtio-gl produces virtio-gl" "virtio-gl" "$GFX_VIRTIO"
GFX_DEFAULT=$(PZ_STATE="$GFX_PLAN_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null | jq -r '.graphics // ""' 2>/dev/null || echo "")
assert_eq "plan without --graphics defaults to compat" "compat" "$GFX_DEFAULT"
rm -rf "$GFX_PLAN_DIR"

echo ""
echo "=== graphics: preflight compat ==="
GFX_COM_DIR="$(mktemp -d)"
mkdir -p "$GFX_COM_DIR/gfx-test-compat"
echo '{"id":"gfx-test-compat","checkpoint":"validate","state":"running","log":[]}' > "$GFX_COM_DIR/gfx-test-compat/operation.json"
OPERATIONS_DIR="$GFX_COM_DIR" graphics_preflight "gfx-test-compat" "compat"
assert_eq "preflight compat returns 0" "0" "$?"
rm -rf "$GFX_COM_DIR"

echo ""
echo "=== graphics: preflight virtio-gl fail-loud ==="
GFX_VGL_DIR="$(mktemp -d)"
mkdir -p "$GFX_VGL_DIR/gfx-test-vgl"
echo '{"id":"gfx-test-vgl","checkpoint":"validate","state":"running","log":[]}' > "$GFX_VGL_DIR/gfx-test-vgl/operation.json"
OPERATIONS_DIR="$GFX_VGL_DIR" PZ_GFX_RENDER_NODE="" PZ_GFX_KVM_PATH="/nonexistent/kvm" \
    PZ_GFX_QEMU_BIN="false" PZ_GFX_VIRGL_PRESENT=0 PZ_GFX_QEMU_VIRTIO_VGA_GL=0 \
    graphics_preflight "gfx-test-vgl" "virtio-gl" && true
assert_eq "preflight virtio-gl fails without resources" "1" "$?"
LOG_TEXT=$(jq -r '.log[]' "$GFX_VGL_DIR/gfx-test-vgl/operation.json" 2>/dev/null || echo "")
assert_contains "preflight logs fallback message" "$LOG_TEXT" "fallback: --graphics compat"
rm -rf "$GFX_VGL_DIR"

echo ""
echo "=== graphics: preflight unknown profile ==="
GFX_UNK_DIR="$(mktemp -d)"
mkdir -p "$GFX_UNK_DIR/gfx-test-unk"
echo '{"id":"gfx-test-unk","checkpoint":"validate","state":"running","log":[]}' > "$GFX_UNK_DIR/gfx-test-unk/operation.json"
OPERATIONS_DIR="$GFX_UNK_DIR" graphics_preflight "gfx-test-unk" "vfio-looking-glass" && true
assert_eq "preflight unknown profile fails" "1" "$?"
LOG_UNK=$(jq -r '.log[]' "$GFX_UNK_DIR/gfx-test-unk/operation.json" 2>/dev/null || echo "")
assert_contains "preflight logs unknown profile" "$LOG_UNK" "unknown graphics profile"
rm -rf "$GFX_UNK_DIR"

echo ""
echo "=== graphics: resolve_qemu_args compat ==="
GFX_RES_COM_DIR="$(mktemp -d)"
mkdir -p "$GFX_RES_COM_DIR/gfx-resolve-compat"
echo '{"id":"gfx-resolve-compat","state":"running","log":[]}' > "$GFX_RES_COM_DIR/gfx-resolve-compat/operation.json"
GRAPHICS_VGA="" GRAPHICS_DISPLAY="" GRAPHICS_ACCEL_LOG=""
OPERATIONS_DIR="$GFX_RES_COM_DIR" resolve_graphics_qemu_args "gfx-resolve-compat" "compat"
assert_eq "resolve compat VGA" "-vga qxl" "$GRAPHICS_VGA"
assert_eq "resolve compat display" "-display gtk" "$GRAPHICS_DISPLAY"
assert_contains "resolve compat accel log" "$GRAPHICS_ACCEL_LOG" "NONE (QXL)"
RESOLVED_PROFILE=$(jq < "$GFX_RES_COM_DIR/gfx-resolve-compat/operation.json" -r '.graphicsResolved.profile // ""' 2>/dev/null || echo "")
assert_eq "resolve compat persists profile" "compat" "$RESOLVED_PROFILE"
RESOLVED_VGA=$(jq < "$GFX_RES_COM_DIR/gfx-resolve-compat/operation.json" -r '.graphicsResolved.vgaDevice // ""' 2>/dev/null || echo "")
assert_eq "resolve compat persists vgaDevice" "-vga qxl" "$RESOLVED_VGA"
rm -rf "$GFX_RES_COM_DIR"

echo ""
echo "=== graphics: resolve_qemu_args virtio-gl ==="
GFX_RES_VGL_DIR="$(mktemp -d)"
mkdir -p "$GFX_RES_VGL_DIR/gfx-resolve-vgl"
echo '{"id":"gfx-resolve-vgl","state":"running","log":[]}' > "$GFX_RES_VGL_DIR/gfx-resolve-vgl/operation.json"
GRAPHICS_VGA="" GRAPHICS_DISPLAY="" GRAPHICS_ACCEL_LOG=""
OPERATIONS_DIR="$GFX_RES_VGL_DIR" resolve_graphics_qemu_args "gfx-resolve-vgl" "virtio-gl"
assert_eq "resolve vgl VGA" "-device virtio-vga-gl" "$GRAPHICS_VGA"
assert_eq "resolve vgl display" "-display gtk,gl=on" "$GRAPHICS_DISPLAY"
assert_contains "resolve vgl accel log" "$GRAPHICS_ACCEL_LOG" "virgl"
RESOLVED_VGL_PROFILE=$(jq < "$GFX_RES_VGL_DIR/gfx-resolve-vgl/operation.json" -r '.graphicsResolved.profile // ""' 2>/dev/null || echo "")
assert_eq "resolve vgl persists profile" "virtio-gl" "$RESOLVED_VGL_PROFILE"
RESOLVED_VGL_VGA=$(jq < "$GFX_RES_VGL_DIR/gfx-resolve-vgl/operation.json" -r '.graphicsResolved.vgaDevice // ""' 2>/dev/null || echo "")
assert_eq "resolve vgl persists vgaDevice" "-device virtio-vga-gl" "$RESOLVED_VGL_VGA"
rm -rf "$GFX_RES_VGL_DIR"

echo ""
echo "=== graphics: run_relaunch qemu_args per profile ==="
if command -v qemu-img >/dev/null 2>&1; then
    RL_DIR="$(mktemp -d)"
    mkdir -p "$RL_DIR/phasezero/vms/relaunch-test"
    SNAP_DISK_V="$RL_DIR/phasezero/vms/relaunch-test/disk.qcow2"
    SNAP_PATH_V="$RL_DIR/phasezero/vms/relaunch-test/golden-clean.qcow2"
    qemu-img create -f qcow2 "$SNAP_DISK_V" 64M 2>/dev/null
    qemu-img create -f qcow2 -b "$SNAP_DISK_V" -F qcow2 "$SNAP_PATH_V" 2>/dev/null
    mkdir -p "$RL_DIR/phasezero/operations/relaunch-compat"
    echo '{"id":"rl-plan","graphics":"compat","resources":{"ramMb":2048,"cpus":2},"iso":{"path":"'"$DUMMY_ISO"'","arch":"x64"}}' > "$RL_DIR/phasezero/operations/relaunch-compat/plan.json"
    echo '{"id":"relaunch-compat","state":"running","checkpoint":"relaunch","log":[]}' > "$RL_DIR/phasezero/operations/relaunch-compat/operation.json"
    echo "$RL_DIR/phasezero/vms/relaunch-test" > "$RL_DIR/phasezero/operations/relaunch-compat/vm_dir"
    touch "$RL_DIR/phasezero/ovmf_vars.fd"
    XDG_STATE_HOME="$RL_DIR" PZ_GFX_KVM_PATH="/dev/null" \
        PZ_WINDOWS_VM_OVMF_CODE="$RL_DIR/phasezero/ovmf_vars.fd" \
        PZ_GFX_RENDER_NODE="" PZ_GFX_VIRGL_PRESENT=0 PZ_GFX_QEMU_VIRTIO_VGA_GL=0 PZ_GFX_QEMU_BIN="true" \
        bash -c '
    source "'"$PROVISION_SCRIPT"'" 2>/dev/null || true
    run_relaunch "relaunch-compat" 2>/dev/null || true
    ' 2>/dev/null || true
    RL_LOG=$(jq -r '.log[]' "$RL_DIR/phasezero/operations/relaunch-compat/operation.json" 2>/dev/null || echo "")
    assert_contains "relaunch compat logs NONE" "$RL_LOG" "NONE (QXL)"
    assert_contains "relaunch compat logs relaunch" "$RL_LOG" "relaunching with display"
    rm -rf "$RL_DIR"
else
    echo "  (relaunch test skipped: qemu-img not installed)"
fi

echo ""
echo "=== graphics: headless invariant ==="
SETUP_COUNT=$(grep -c '\-vga qxl' "$PROVISION_SCRIPT" 2>/dev/null || echo 0)
HEADLESS_COUNT=$(grep -c '\-display none' "$PROVISION_SCRIPT" 2>/dev/null || echo 0)
# setup, drivers, tweaks each have -vga qxl (3 total)
# relaunch also has a -vga line but it's dynamic (GRAPHICS_VGA)
assert_eq "at least 3 instances of -vga qxl (setup+drivers+tweaks)" "1" "$([ "$SETUP_COUNT" -ge 3 ] && echo 1 || echo 0)"
assert_eq "at least 3 instances of -display none (setup+drivers+tweaks)" "1" "$([ "$HEADLESS_COUNT" -ge 3 ] && echo 1 || echo 0)"

echo ""
echo "=== graphics: QGA display-adapter check logic ==="
# Verify base64 decoding of guest-exec-status out-data in isolation.
# The full post-driver check runs inside provision.sh via qga_exec; we test
# the parsing logic directly.
MOCK_BASIC_DISPLAY=$(echo -n "Microsoft Basic Display Adapter" | base64 -w0 2>/dev/null || echo "")
DECODED=$(echo "$MOCK_BASIC_DISPLAY" | base64 -d 2>/dev/null || echo "")
assert_eq "QGA display base64 roundtrip" "Microsoft Basic Display Adapter" "$DECODED"
# Verify grep detection of Basic Display
BASIC_CHECK=$(echo "$DECODED" | grep -qi "Microsoft Basic Display" && echo "WARN" || echo "OK")
assert_eq "QGA Basic Display triggers WARN" "WARN" "$BASIC_CHECK"
# Verify VirtIO GPU does NOT trigger WARN
VIRTIO_CHECK=$(echo "Red Hat VirtIO GPU DOD" | grep -qi "Microsoft Basic Display" && echo "WARN" || echo "OK")
assert_eq "QGA VirtIO GPU does not trigger WARN" "OK" "$VIRTIO_CHECK"

echo ""
echo "=== graphics: venus plan (experimental) ==="
VENUS_PLAN=$(bash "$PZ_ROOT/linux/windows-vm/graphics.sh" plan --profile virtio-venus --json 2>/dev/null || echo '{}')
VENUS_ELIGIBLE=$(jq -r '.eligible' <<< "$VENUS_PLAN")
VENUS_MODE=$(jq -r '.mode' <<< "$VENUS_PLAN")
VENUS_ALLOW=$(jq -r '.applyAllowed' <<< "$VENUS_PLAN")
VENUS_NOTES=$(jq -r '.notes' <<< "$VENUS_PLAN")
assert_eq "venus plan eligible" "true" "$VENUS_ELIGIBLE"
assert_eq "venus plan mode experimental" "experimental" "$VENUS_MODE"
assert_eq "venus apply blocked" "false" "$VENUS_ALLOW"
assert_contains "venus notes mention Vulkan" "$VENUS_NOTES" "Vulkan"
assert_contains "venus notes mention experimental" "$VENUS_NOTES" "EXPERIMENTAL"
assert_contains "venus notes mention Deck" "$VENUS_NOTES" "Steam Deck"

echo ""
echo "=== preflight: JSON output structure ==="
PREFLIGHT_SCRIPT="$PZ_ROOT/linux/windows-vm/preflight.sh"
PRE_OUT=$(bash "$PREFLIGHT_SCRIPT" --json 2>/dev/null || echo '{}')
# Convert jq boolean output to "1"/"0" so assert_eq works
pre_has() { echo "$PRE_OUT" | jq "has($1)" 2>/dev/null | grep -q true && echo 1 || echo 0; }
pre_sub_has() { echo "$PRE_OUT" | jq ".$1 | has($2)" 2>/dev/null | grep -q true && echo 1 || echo 0; }
assert_eq "preflight has status" "1" "$(pre_has '"status"')"
assert_eq "preflight has swtpm" "1" "$(pre_has '"swtpm"')"
assert_eq "preflight has virtio" "1" "$(pre_has '"virtio"')"
assert_eq "preflight has graphics" "1" "$(pre_has '"graphics"')"
assert_eq "preflight has resources" "1" "$(pre_has '"resources"')"
assert_eq "swtpm has binary" "1" "$(pre_sub_has 'swtpm' '"binary"')"
assert_eq "swtpm has running" "1" "$(pre_sub_has 'swtpm' '"running"')"
assert_eq "virtio has pinned" "1" "$(pre_sub_has 'virtio' '"pinned"')"
assert_eq "virtio has latest" "1" "$(pre_sub_has 'virtio' '"latest"')"
assert_eq "virtio has outdated" "1" "$(pre_sub_has 'virtio' '"outdated"')"
assert_eq "resources has ramMb" "1" "$(pre_sub_has 'resources' '"ramMb"')"
assert_eq "resources has cpus" "1" "$(pre_sub_has 'resources' '"cpus"')"
assert_eq "resources has diskGb" "1" "$(pre_sub_has 'resources' '"diskGb"')"
assert_eq "resources has kvmAccess" "1" "$(pre_sub_has 'resources' '"kvmAccess"')"
assert_eq "resources has ovmfPresent" "1" "$(pre_sub_has 'resources' '"ovmfPresent"')"

echo ""
echo "=== preflight: swtpm detection ==="
SWTPM_BINARY=$(echo "$PRE_OUT" | jq -r '.swtpm.binary' 2>/dev/null || echo "false")
if command -v swtpm >/dev/null 2>&1; then
    assert_eq "swtpm binary detected when installed" "true" "$SWTPM_BINARY"
else
    assert_eq "swtpm binary not detected when missing" "false" "$SWTPM_BINARY"
fi

echo ""
echo "=== provision plan includes preflight ==="
# Create a fresh state dir for plan test
PZ_STATE_DIR2="$(mktemp -d)"
PLAN_PRE=$(PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR2" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null || echo '{}')
assert_eq "plan has preflight field" "1" "$(echo "$PLAN_PRE" | jq 'has("preflight")' 2>/dev/null | grep -q true && echo 1 || echo 0)"
PLAN_PRE_SWTPM=$(echo "$PLAN_PRE" | jq -r '.preflight.swtpm.binary' 2>/dev/null || echo "false")
if command -v swtpm >/dev/null 2>&1; then
    assert_eq "plan.preflight.swtpm matches host" "true" "$PLAN_PRE_SWTPM"
fi
PLAN_PRE_STATUS=$(echo "$PLAN_PRE" | jq -r '.preflight.status' 2>/dev/null || echo "")
assert_eq "plan.preflight status is pass/warn/fail" "1" "$(echo "$PLAN_PRE_STATUS" | grep -cE '^(pass|warn|fail)$' || echo 0)"
assert_eq "plan has warnings array" "1" "$(echo "$PLAN_PRE" | jq 'has("warnings")' 2>/dev/null | grep -q true && echo 1 || echo 0)"

rm -rf "$PZ_STATE_DIR2"

echo ""
echo "=== preflight: auto-fix dry run ==="
PZ_STATE_DIR3="$(mktemp -d)"
AUTO_FIX_OUT=$(PZ_STATE="$PZ_STATE_DIR3" bash "$PREFLIGHT_SCRIPT" --auto-fix 2>&1 || true)
HAS_ERROR=0
echo "$AUTO_FIX_OUT" | grep -q '^ERROR' 2>/dev/null && HAS_ERROR=1
assert_eq "auto-fix completes without error" "0" "$HAS_ERROR"
rm -rf "$PZ_STATE_DIR3"

rm -rf "$DUMMY_ISO" "$(dirname "$DUMMY_ISO")" "$PZ_STATE_DIR"

echo ""
echo "=== resilient checks: preflight structure (hermetic) ==="

RESILIENT_PREFLIGHT="$(bash "$PZ_ROOT/linux/windows-vm/preflight.sh" --json 2>/dev/null || echo '{}')"
rp_has() { echo "$RESILIENT_PREFLIGHT" | jq "has($1)" 2>/dev/null | grep -q true && echo 1 || echo 0; }
rp_sub_has() { echo "$RESILIENT_PREFLIGHT" | jq ".$1 | has($2)" 2>/dev/null | grep -q true && echo 1 || echo 0; }
assert_eq "preflight resources has ovmfPresent" "1" "$(rp_sub_has 'resources' '"ovmfPresent"')"
assert_eq "preflight graphics has failures array" "1" "$(rp_sub_has 'graphics' '"failures"')"
assert_eq "preflight swtpm has running key" "1" "$(rp_sub_has 'swtpm' '"running"')"
assert_eq "preflight graphics has supported" "1" "$(rp_sub_has 'graphics' '"supported"')"
assert_eq "preflight virtio has outdated" "1" "$(rp_sub_has 'virtio' '"outdated"')"

echo ""
echo "=== provision: staging removal safety ==="
SAFE_T="$(mktemp -d)"
# valid case: op dir under official layout with matching metadata
mkdir -p "$SAFE_T/phasezero/windows-vm/vms/valid-op" "$SAFE_T/phasezero/operations/valid-op"
echo '{"id":"valid-op","state":"cancelled"}' > "$SAFE_T/phasezero/operations/valid-op/operation.json"
echo "$SAFE_T/phasezero/windows-vm/vms/valid-op" > "$SAFE_T/phasezero/operations/valid-op/vm_dir"
RESOLVED_OK=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
resolve_vm_staging_dir "valid-op" >/dev/null 2>&1 && echo OK || echo FAILED
')
assert_eq "staging resolves valid op" "OK" "$RESOLVED_OK"
# root
REJECT_ROOT=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/root-op"
echo "/" > "$OPERATIONS_DIR/root-op/vm_dir"
echo "{\"id\":\"root-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/root-op/operation.json"
resolve_vm_staging_dir "root-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects root" "REJECTED" "$REJECT_ROOT"
# outside the official base
REJECT_OUTSIDE=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/evil-op"
echo "{\"id\":\"evil-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/evil-op/operation.json"
echo "/tmp/evil-outside" > "$OPERATIONS_DIR/evil-op/vm_dir"
resolve_vm_staging_dir "evil-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects external path" "REJECTED" "$REJECT_OUTSIDE"
# '..' traversal
REJECT_DOTS=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/dots-op"
echo "{\"id\":\"dots-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/dots-op/operation.json"
echo "$PZ_STATE/windows-vm/vms/dots-op/../../../etc" > "$OPERATIONS_DIR/dots-op/vm_dir"
resolve_vm_staging_dir "dots-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects .. traversal" "REJECTED" "$REJECT_DOTS"
# metadata id mismatch
REJECT_MISMATCH=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/mismatch-op"
echo "{\"id\":\"other-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/mismatch-op/operation.json"
echo "$PZ_STATE/windows-vm/vms/valid-op" > "$OPERATIONS_DIR/mismatch-op/vm_dir"
resolve_vm_staging_dir "mismatch-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects metadata id mismatch" "REJECTED" "$REJECT_MISMATCH"
# corrupt metadata
REJECT_CORRUPT=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/corrupt-op"
echo "not-json" > "$OPERATIONS_DIR/corrupt-op/operation.json"
echo "$PZ_STATE/windows-vm/vms/valid-op" > "$OPERATIONS_DIR/corrupt-op/vm_dir"
resolve_vm_staging_dir "corrupt-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects corrupt metadata" "REJECTED" "$REJECT_CORRUPT"
# symlink escape
REJECT_SYMLINK=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/symlink-op" "$PZ_STATE/windows-vm/vms/real-dir" /tmp/pz-symlink-target
echo "{\"id\":\"symlink-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/symlink-op/operation.json"
ln -sfn /tmp/pz-symlink-target "$PZ_STATE/windows-vm/vms/real-dir"
echo "$PZ_STATE/windows-vm/vms/real-dir" > "$OPERATIONS_DIR/symlink-op/vm_dir"
resolve_vm_staging_dir "symlink-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects symlink escape" "REJECTED" "$REJECT_SYMLINK"
rm -rf "$SAFE_T" /tmp/pz-symlink-target

echo ""
echo "=== provision: cancel with staging removal ==="
CANCEL_SAFE_T="$(mktemp -d)"
mkdir -p "$CANCEL_SAFE_T/phasezero/operations/cancel-rm" "$CANCEL_SAFE_T/phasezero/windows-vm/vms/cancel-rm"
echo '{"id":"cancel-rm","state":"running","checkpoint":"validate","progress":5}' > "$CANCEL_SAFE_T/phasezero/operations/cancel-rm/operation.json"
echo "$CANCEL_SAFE_T/phasezero/windows-vm/vms/cancel-rm" > "$CANCEL_SAFE_T/phasezero/operations/cancel-rm/vm_dir"
XDG_STATE_HOME="$CANCEL_SAFE_T" bash "$PROVISION_SCRIPT" cancel --operation-id cancel-rm --remove-staging >/dev/null 2>&1 || true
assert_eq "cancel --remove-staging removes staged dir" "0" "$([ -d "$CANCEL_SAFE_T/phasezero/windows-vm/vms/cancel-rm" ] && echo 1 || echo 0)"
CANCEL_RM_STATE=$(jq -r '.state // ""' "$CANCEL_SAFE_T/phasezero/operations/cancel-rm/operation.json" 2>/dev/null || echo "")
assert_eq "cancel --remove-staging state cancelled" "cancelled" "$CANCEL_RM_STATE"
# cancel refusing an external staging dir must NOT delete it
mkdir -p "$CANCEL_SAFE_T/phasezero/operations/cancel-evil" "$CANCEL_SAFE_T/external-staging"
echo '{"id":"cancel-evil","state":"running","checkpoint":"validate","progress":5}' > "$CANCEL_SAFE_T/phasezero/operations/cancel-evil/operation.json"
echo "$CANCEL_SAFE_T/external-staging" > "$CANCEL_SAFE_T/phasezero/operations/cancel-evil/vm_dir"
XDG_STATE_HOME="$CANCEL_SAFE_T" bash "$PROVISION_SCRIPT" cancel --operation-id cancel-evil --remove-staging >/dev/null 2>&1 || true
assert_eq "cancel refuses external staging dir" "1" "$([ -d "$CANCEL_SAFE_T/external-staging" ] && echo 1 || echo 0)"
rm -rf "$CANCEL_SAFE_T"

echo ""
echo "=== provision: atomic lock lifecycle ==="
LOCK_T="$(mktemp -d)"
(
    XDG_STATE_HOME="$LOCK_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR"
    # acquire op A
    provision_lock_acquire "op-a" || exit 10
    # A is running -> a different operation B must be blocked
    mkdir -p "$OPERATIONS_DIR/op-a"
    echo '{"id":"op-a","state":"running"}' > "$OPERATIONS_DIR/op-a/operation.json"
    mkdir -p "$OPERATIONS_DIR/op-b"
    echo '{"id":"op-b","state":"failed"}' > "$OPERATIONS_DIR/op-b/operation.json"
    provision_lock_acquire "op-b" 2>/dev/null && exit 11 || true
    # complete A -> B can take over (recovery)
    echo '{"id":"op-a","state":"completed"}' > "$OPERATIONS_DIR/op-a/operation.json"
    provision_lock_acquire "op-b" || exit 12
    # clear must only remove when content matches: op-b is current, clearing
    # op-a must leave the lock file in place
    provision_lock_clear "op-a"
    [ -f "$PROVISION_DIR/active.lock" ] || exit 13
    # same-op re-acquire after completion is the worker handoff -> proceeds
    provision_lock_acquire "op-a" || exit 14
    provision_lock_clear "op-a"
    [ ! -f "$PROVISION_DIR/active.lock" ] || exit 15
    # corrupt reference -> refused with diagnostic
    printf 'ghost-op\n' > "$PROVISION_DIR/active.lock"
    provision_lock_acquire "op-c" 2>/dev/null && exit 16 || true
    printf 'ghost-op\n' > "$PROVISION_DIR/active.lock"
    mkdir -p "$OPERATIONS_DIR/ghost-op"
    echo 'garbage' > "$OPERATIONS_DIR/ghost-op/operation.json"
    provision_lock_acquire "op-c" 2>/dev/null && exit 17 || true
    exit 0
)
LOCK_RC=$?
assert_eq "lock lifecycle (acquire/block/recover/clear)" "0" "$LOCK_RC"
rm -rf "$LOCK_T"

echo ""
echo "=== provision: lock across separate processes (crash handoff) ==="
LOCK2_T="$(mktemp -d)"
(
    XDG_STATE_HOME="$LOCK2_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR/op-a" "$OPERATIONS_DIR/op-b"
    echo '{"id":"op-a","state":"running"}' > "$OPERATIONS_DIR/op-a/operation.json"
    echo '{"id":"op-b","state":"failed"}' > "$OPERATIONS_DIR/op-b/operation.json"
    provision_lock_acquire "op-a" || exit 20
    echo '{"id":"op-a","state":"completed"}' > "$OPERATIONS_DIR/op-a/operation.json"
    # Crash: exit without provision_lock_release. flock auto-releases; the
    # recorded operation id survives because <> never truncates the file.
    exit 0
) &
HOLDER_PID=$!
sleep 0.5
B_OUT=$(
    XDG_STATE_HOME="$LOCK2_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    provision_lock_acquire "op-b" || exit 21
    # B holds the lock now; clearing a stale op id must be a no-op.
    provision_lock_clear "op-a"
    [ -f "$PROVISION_DIR/active.lock" ] || exit 22
    [ "$(cat "$PROVISION_DIR/active.lock" 2>/dev/null || true)" = "op-b" ] || exit 23
    provision_lock_clear "op-b"
    [ ! -f "$PROVISION_DIR/active.lock" ] || exit 24
    exit 0
)
B_RC=$?
wait "$HOLDER_PID" 2>/dev/null || true
assert_eq "crash handoff: B takes over after holder exit" "0" "$B_RC"
rm -rf "$LOCK2_T"

echo ""
echo "=== provision: lock inode stable across re-acquire (flock mode) ==="
LOCK3_T="$(mktemp -d)"
INODE_OUT=$(
    XDG_STATE_HOME="$LOCK3_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR/op-i1" "$OPERATIONS_DIR/op-i2"
    echo '{"id":"op-i1","state":"completed"}' > "$OPERATIONS_DIR/op-i1/operation.json"
    echo '{"id":"op-i2","state":"failed"}' > "$OPERATIONS_DIR/op-i2/operation.json"
    provision_lock_acquire "op-i1" || exit 30
    INODE_1=$(stat -c %i "$PROVISION_DIR/active.lock" 2>/dev/null || echo 0)
    provision_lock_release
    provision_lock_acquire "op-i2" || exit 31
    INODE_2=$(stat -c %i "$PROVISION_DIR/active.lock" 2>/dev/null || echo 0)
    provision_lock_clear "op-i2"
    printf '%s %s\n' "$INODE_1" "$INODE_2"
)
assert_eq "lock inode stable (no truncate/recreate between acquires)" \
    "$(echo "$INODE_OUT" | awk '{print $1}') $(echo "$INODE_OUT" | awk '{print $1}')" \
    "$INODE_OUT"
rm -rf "$LOCK3_T"

echo ""
echo "=== provision: mkdir fallback lock (stale dead pid recovers, live holder refuses) ==="
LOCK4_T="$(mktemp -d)"
set +e
(
    export PZ_LOCK_FORCE_MKDIR=1
    XDG_STATE_HOME="$LOCK4_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR/op-d" "$OPERATIONS_DIR/op-e"
    echo '{"id":"op-d","state":"running"}' > "$OPERATIONS_DIR/op-d/operation.json"
    echo '{"id":"op-e","state":"failed"}' > "$OPERATIONS_DIR/op-e/operation.json"
    # Stale lock: holder pid not alive -> recovered with warning.
    mkdir -p "$PROVISION_DIR/active.lock.d"
    echo '999999999' > "$PROVISION_DIR/active.lock.d/pid"
    provision_lock_acquire "op-d" || exit 40
    [ -f "$PROVISION_DIR/active.lock.d/pid" ] || exit 41
    provision_lock_release
    # Live holder: sleep holds the pid -> acquisition refused.
    sleep 60 &
    LIVE_PID=$!
    mkdir -p "$PROVISION_DIR/active.lock.d"
    echo "$LIVE_PID" > "$PROVISION_DIR/active.lock.d/pid"
    provision_lock_acquire "op-e" 2>/dev/null && exit 42 || true
    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
    exit 0
)
MK_RC=$?
set -e
assert_eq "mkdir lock: stale recovers, live holder refused" "0" "$MK_RC"
rm -rf "$LOCK4_T"

echo ""
echo "=== provision: SPICE loopback invariant ==="
SPICE_LINES=$(grep -h 'spice.*port=5930' "$PROVISION_SCRIPT" | grep -cv 'addr=127.0.0.1' || true)
assert_eq "every provision -spice line binds loopback" "0" "$SPICE_LINES"

echo ""
echo "=== media-inspect: hermetic fake-tool structure gates ==="
MK_T="$(mktemp -d)"
FAKE_BIN="$MK_T/bin"
mkdir -p "$FAKE_BIN"
# Fake `file`: always reports an ISO/UDF image so the format gate passes and
# the boot/payload gates are exercised independently.
cat > "$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
echo "ISO 9660 CD-ROM filesystem data (fake for hermetic test)"
EOF
chmod +x "$FAKE_BIN/file"
# Fake listing/extract tool: member list from $FAKE_MEMBERS, WIM payload from
# $FAKE_WIM_STREAM when the extract pattern matches install.wim.
cat > "$FAKE_BIN/7z" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "l" ]; then
    cat "${FAKE_MEMBERS:-}" 2>/dev/null || true
    exit 0
fi
if [ "$1" = "e" ] && [ "$2" = "-so" ]; then
    case " $* " in
        *"install.wim"*) cat "${FAKE_WIM_STREAM:-}" 2>/dev/null || true ;;
    esac
    exit 0
fi
exit 2
EOF
chmod +x "$FAKE_BIN/7z"

# A valid WIM container header (208 bytes) + XML with two images, emitted as
# the streamed payload so wim_payload_images can parse it in bounded fashion.
FAKE_WIM_STREAM="$MK_T/install.wim"
printf 'WIM\0' > "$FAKE_WIM_STREAM"
truncate -s 208 "$FAKE_WIM_STREAM"
printf '\x02\x00\x00\x00' | dd of="$FAKE_WIM_STREAM" bs=1 seek=48 conv=notrunc 2>/dev/null
printf '\xd0\x00\x00\x00\x00\x00\x00\x00' | dd of="$FAKE_WIM_STREAM" bs=1 seek=76 conv=notrunc 2>/dev/null
printf '\x00\x02\x00\x00\x00\x00\x00\x00' | dd of="$FAKE_WIM_STREAM" bs=1 seek=84 conv=notrunc 2>/dev/null
printf '<WIM><IMAGE INDEX="1"><NAME>Windows 11 Pro</NAME><DISPLAYNAME>Windows 11 Pro</DISPLAYNAME></IMAGE><IMAGE INDEX="2"><NAME>Home</NAME><DISPLAYNAME>Home</DISPLAYNAME></IMAGE></WIM>' | dd of="$FAKE_WIM_STREAM" bs=1 seek=208 conv=notrunc 2>/dev/null

FAKE_ISO="$MK_T/win.iso"
printf 'fakeiso\n' > "$FAKE_ISO"

FULL_OUT=$(
    export PATH="$FAKE_BIN:$PATH"
    export FAKE_WIM_STREAM
    FAKE_MEMBERS="$MK_T/members-full.txt"
    printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /BOOTMGR;1\n' > "$FAKE_MEMBERS"
    printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SOURCES/INSTALL.WIM;1\n' >> "$FAKE_MEMBERS"
    printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SETUP.EXE;1\n' >> "$FAKE_MEMBERS"
    export FAKE_MEMBERS
    bash "$MEDIA_SCRIPT" inspect --iso "$FAKE_ISO" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "boot+wim valid" "true" "$(echo "$FULL_OUT" | jq -r '.valid' 2>/dev/null || echo false)"
assert_eq "uppercase/;1 normalized -> 2 wim images parsed" "2" "$(echo "$FULL_OUT" | jq -r '.imageCount' 2>/dev/null || echo 0)"

echo "--- setup.exe alone is NOT a boot chain ---"
SETUP_OUT=$(
    export PATH="$FAKE_BIN:$PATH" FAKE_WIM_STREAM
    FAKE_MEMBERS="$MK_T/members-setup.txt"
    printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SETUP.EXE;1\n' > "$FAKE_MEMBERS"
    export FAKE_MEMBERS
    bash "$MEDIA_SCRIPT" inspect --iso "$FAKE_ISO" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "setup.exe alone invalid" "false" "$(echo "$SETUP_OUT" | jq -r '.valid' 2>/dev/null || echo true)"

echo "--- boot chain without install.wim invalid ---"
NOBOOT_OUT=$(
    export PATH="$FAKE_BIN:$PATH" FAKE_WIM_STREAM
    FAKE_MEMBERS="$MK_T/members-noboot.txt"
    printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /BOOTMGR;1\n' > "$FAKE_MEMBERS"
    export FAKE_MEMBERS
    bash "$MEDIA_SCRIPT" inspect --iso "$FAKE_ISO" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "bootmgr without wim invalid" "false" "$(echo "$NOBOOT_OUT" | jq -r '.valid' 2>/dev/null || echo true)"

echo "--- payload only inside ISO: imageCount=0 + payloadNote ---"
NOSTREAM_OUT=$(
    export PATH="$FAKE_BIN:$PATH"
    FAKE_MEMBERS="$MK_T/members-nostream.txt"
    printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /BOOTMGR;1\n' > "$FAKE_MEMBERS"
    printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SOURCES/INSTALL.WIM;1\n' >> "$FAKE_MEMBERS"
    export FAKE_MEMBERS FAKE_WIM_STREAM=/nonexistent/install.wim
    bash "$MEDIA_SCRIPT" inspect --iso "$FAKE_ISO" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "structure still valid with unparseable payload" "true" "$(echo "$NOSTREAM_OUT" | jq -r '.valid' 2>/dev/null || echo false)"
assert_eq "imageCount 0 when payload only inside ISO" "0" "$(echo "$NOSTREAM_OUT" | jq -r '.imageCount' 2>/dev/null || echo 1)"
assert_contains "payloadNote present" "$NOSTREAM_OUT" "payload only inside ISO"
rm -rf "$MK_T"

echo ""
echo "=== media-inspect: WIM header stream bounded (no WIM-sized temp files) ==="
MK2_T="$(mktemp -d)"
FAKE2_BIN="$MK2_T/bin"
mkdir -p "$FAKE2_BIN"
cat > "$FAKE2_BIN/file" <<'EOF'
#!/usr/bin/env bash
echo "ISO 9660 CD-ROM filesystem data (fake for hermetic test)"
EOF
chmod +x "$FAKE2_BIN/file"
cat > "$FAKE2_BIN/7z" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "l" ]; then
    cat "${FAKE_MEMBERS:-}" 2>/dev/null || true
    exit 0
fi
if [ "$1" = "e" ] && [ "$2" = "-so" ]; then
    cat "${FAKE_WIM_STREAM:-}" 2>/dev/null || true
    exit 0
fi
exit 2
EOF
chmod +x "$FAKE2_BIN/7z"
FAKE2_MEMBERS="$MK2_T/members.txt"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /BOOTMGR;1\n' > "$FAKE2_MEMBERS"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SOURCES/INSTALL.WIM;1\n' >> "$FAKE2_MEMBERS"
# Fake payload that is far larger than any temp file the bounded reader may
# create: real WIM header + XML (208B + 512B) followed by 60MB of zeros.
BIG_WIM="$MK2_T/install.wim"
printf 'WIM\0' > "$BIG_WIM"
truncate -s 208 "$BIG_WIM"
printf '\x01\x00\x00\x00' | dd of="$BIG_WIM" bs=1 seek=48 conv=notrunc 2>/dev/null
printf '\xd0\x00\x00\x00\x00\x00\x00\x00' | dd of="$BIG_WIM" bs=1 seek=76 conv=notrunc 2>/dev/null
printf '\x00\x02\x00\x00\x00\x00\x00\x00' | dd of="$BIG_WIM" bs=1 seek=84 conv=notrunc 2>/dev/null
printf '<WIM><IMAGE INDEX="1"><NAME>Windows 11 Pro</NAME><DISPLAYNAME>Windows 11 Pro</DISPLAYNAME></IMAGE></WIM>' | dd of="$BIG_WIM" bs=1 seek=208 conv=notrunc 2>/dev/null
truncate -s 62914560 "$BIG_WIM"
printf 'fakeiso\n' > "$MK2_T/win.iso"
BIG_OUT=$(
    export PATH="$FAKE2_BIN:$PATH"
    export FAKE_MEMBERS="$FAKE2_MEMBERS" FAKE_WIM_STREAM="$BIG_WIM"
    bash "$MEDIA_SCRIPT" inspect --iso "$MK2_T/win.iso" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "imageCount parsed from bounded stream" "1" "$(echo "$BIG_OUT" | jq -r '.imageCount' 2>/dev/null || echo 0)"
BIG_TEMPS=$(find "$MK2_T" -type f -size +1M ! -name 'install.wim' | wc -l)
assert_eq "no temp file of WIM size created" "0" "$BIG_TEMPS"
rm -rf "$MK2_T"

echo ""
echo "=== media-inspect: unreadable listing tool degrades to deterministic JSON ==="
MK3_T="$(mktemp -d)"
FAKE3_BIN="$MK3_T/bin"
mkdir -p "$FAKE3_BIN"
cat > "$FAKE3_BIN/file" <<'EOF'
#!/usr/bin/env bash
echo "ISO 9660 CD-ROM filesystem data (fake for hermetic test)"
EOF
chmod +x "$FAKE3_BIN/file"
# Listing tools that exist but cannot read the medium (rc != 0): the inspect
# must degrade to deterministic JSON instead of aborting under pipefail.
for tool in 7z 7za 7zr bsdtar; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE3_BIN/$tool"
    chmod +x "$FAKE3_BIN/$tool"
done
printf 'fakeiso\n' > "$MK3_T/win.iso"
set +e
NO_TOOL_OUT=$(PATH="$FAKE3_BIN:$PATH" bash "$MEDIA_SCRIPT" inspect --iso "$MK3_T/win.iso" --json 2>/dev/null)
NO_TOOL_RC=$?
set -e
assert_eq "unreadable listing tool: rc 0" "0" "$NO_TOOL_RC"
assert_contains "unreadable listing tool: valid key present" "$NO_TOOL_OUT" '"valid"'
assert_eq "unreadable listing tool: valid false" "false" "$(echo "$NO_TOOL_OUT" | jq -r '.valid' 2>/dev/null || echo true)"
assert_eq "unreadable listing tool: imageCount 0" "0" "$(echo "$NO_TOOL_OUT" | jq -r '.imageCount' 2>/dev/null || echo 1)"
rm -rf "$MK3_T"

echo ""
echo "=== media-inspect: UDF-style listing detection ==="
if command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1; then
    UDF_T="$(mktemp -d)"
    mkdir -p "$UDF_T/tree/sources" "$UDF_T/tree/efi/boot"
    printf 'boot\n' > "$UDF_T/tree/bootmgr"
    printf 'setup\n' > "$UDF_T/tree/setup.exe"
    printf 'wim\n' > "$UDF_T/tree/sources/install.wim"
    printf 'x64\n' > "$UDF_T/tree/efi/boot/bootx64.efi"
    UDF_ISO="$UDF_T/win-udf.iso"
    (cd "$UDF_T/tree" && genisoimage -quiet -udf -o "$UDF_ISO" . 2>/dev/null || mkisofs -quiet -udf -o "$UDF_ISO" . 2>/dev/null) || true
    if [ -f "$UDF_ISO" ]; then
        UDF_OUT=$(bash "$MEDIA_SCRIPT" inspect --iso "$UDF_ISO" --json 2>/dev/null || echo '{"valid":false}')
        assert_eq "UDF fixture detected valid" "true" "$(echo "$UDF_OUT" | jq -r '.valid // false' 2>/dev/null || echo false)"
        assert_eq "UDF fixture uefi boot detected" "1" "$(echo "$UDF_OUT" | jq -r '.uefiBoot // 0' 2>/dev/null || echo 0)"
    else
        echo "  (UDF fixture generation failed; skipped)"
    fi
    rm -rf "$UDF_T"
else
    echo "  (UDF fixture test skipped: genisoimage/mkisofs not installed)"
fi

echo ""
echo "=== results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
