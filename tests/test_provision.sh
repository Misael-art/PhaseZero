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

# shellcheck source=linux/windows-vm/provision.sh
source "$PROVISION_SCRIPT" 2>/dev/null || true

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
LOG_TEXT=$(cat "$GFX_VGL_DIR/gfx-test-vgl/operation.json" | jq -r '.log[]' 2>/dev/null || echo "")
assert_contains "preflight logs fallback message" "$LOG_TEXT" "fallback: --graphics compat"
rm -rf "$GFX_VGL_DIR"

echo ""
echo "=== graphics: preflight unknown profile ==="
GFX_UNK_DIR="$(mktemp -d)"
mkdir -p "$GFX_UNK_DIR/gfx-test-unk"
echo '{"id":"gfx-test-unk","checkpoint":"validate","state":"running","log":[]}' > "$GFX_UNK_DIR/gfx-test-unk/operation.json"
OPERATIONS_DIR="$GFX_UNK_DIR" graphics_preflight "gfx-test-unk" "vfio-looking-glass" && true
assert_eq "preflight unknown profile fails" "1" "$?"
LOG_UNK=$(cat "$GFX_UNK_DIR/gfx-test-unk/operation.json" | jq -r '.log[]' 2>/dev/null || echo "")
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
RESOLVED_PROFILE=$(cat "$GFX_RES_COM_DIR/gfx-resolve-compat/operation.json" | jq -r '.graphicsResolved.profile // ""' 2>/dev/null || echo "")
assert_eq "resolve compat persists profile" "compat" "$RESOLVED_PROFILE"
RESOLVED_VGA=$(cat "$GFX_RES_COM_DIR/gfx-resolve-compat/operation.json" | jq -r '.graphicsResolved.vgaDevice // ""' 2>/dev/null || echo "")
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
RESOLVED_VGL_PROFILE=$(cat "$GFX_RES_VGL_DIR/gfx-resolve-vgl/operation.json" | jq -r '.graphicsResolved.profile // ""' 2>/dev/null || echo "")
assert_eq "resolve vgl persists profile" "virtio-gl" "$RESOLVED_VGL_PROFILE"
RESOLVED_VGL_VGA=$(cat "$GFX_RES_VGL_DIR/gfx-resolve-vgl/operation.json" | jq -r '.graphicsResolved.vgaDevice // ""' 2>/dev/null || echo "")
assert_eq "resolve vgl persists vgaDevice" "-device virtio-vga-gl" "$RESOLVED_VGL_VGA"
rm -rf "$GFX_RES_VGL_DIR"

echo ""
echo "=== graphics: run_relaunch qemu_args per profile ==="
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
RL_LOG=$(cat "$RL_DIR/phasezero/operations/relaunch-compat/operation.json" 2>/dev/null | jq -r '.log[]' 2>/dev/null || echo "")
assert_contains "relaunch compat logs NONE" "$RL_LOG" "NONE (QXL)"
assert_contains "relaunch compat logs relaunch" "$RL_LOG" "relaunching with display"
rm -rf "$RL_DIR"

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
PLAN_PRE=$(PZ_STATE="$PZ_STATE_DIR2" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null || echo '{}')
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
echo "=== results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
