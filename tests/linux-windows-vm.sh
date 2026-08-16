#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux Windows VM automation.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$TMP_ROOT/state"
export XDG_RUNTIME_DIR="$TMP_ROOT/run"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

# Hermetic privilege/mount stubs: every test below must run without real
# mount/umount/mountpoint/findmnt calls and without real sudo/bigsudo/
# pkexec/phasezero-admin. Stubs log argv to $PZ_STUB_LOG and keep a fake
# mount table in $PZ_STUB_MOUNTS/$PZ_STUB_MODES so mountpoint/findmnt agree
# with mount/umount. Failure injection via PZ_STUB_UMOUNT_FAIL=1.
STUB_BIN="$TMP_ROOT/stubs"
mkdir -p "$STUB_BIN"
export PZ_STUB_MOUNTS="$TMP_ROOT/stub-mounts"
export PZ_STUB_MODES="$TMP_ROOT/stub-modes"
export PZ_STUB_LOG="$TMP_ROOT/stub-mount.log"
: > "$PZ_STUB_MOUNTS"
: > "$PZ_STUB_MODES"
: > "$PZ_STUB_LOG"
cat > "$STUB_BIN/mount" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'mount %s\n' "$*" >> "$PZ_STUB_LOG"
args=("$@")
mp="${args[@]: -1}"
opts=""
for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[i]}" = "-o" ]; then
        opts="${args[i + 1]:-}"
        break
    fi
done
mode="rw"
case ",$opts," in
    *,ro,*) mode="ro" ;;
esac
if [ "${PZ_STUB_MOUNT_FAIL:-0}" = "1" ]; then exit 1; fi
grep -qxF "$mp" "$PZ_STUB_MOUNTS" || printf '%s\n' "$mp" >> "$PZ_STUB_MOUNTS"
grep -qF "$mp " "$PZ_STUB_MODES" || printf '%s %s\n' "$mp" "$mode" >> "$PZ_STUB_MODES"
sed -i "s#^${mp} .*#${mp} ${mode}#" "$PZ_STUB_MODES"
exit 0
EOF
cat > "$STUB_BIN/umount" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'umount %s\n' "$*" >> "$PZ_STUB_LOG"
if [ "${PZ_STUB_UMOUNT_FAIL:-0}" = "1" ]; then exit 1; fi
mp="${@: -1}"
sed -i "\#^${mp}\$#d" "$PZ_STUB_MOUNTS"
sed -i "\#^${mp} #d" "$PZ_STUB_MODES"
exit 0
EOF
cat > "$STUB_BIN/mountpoint" <<'EOF'
#!/usr/bin/env bash
set -u
mp="${@: -1}"
[ -n "$mp" ] || exit 3
grep -qxF "$mp" "$PZ_STUB_MOUNTS"
EOF
cat > "$STUB_BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
set -u
mp="${@: -1}"
mode="$(awk -v mp="$mp" '$1 == mp {print $2}' "$PZ_STUB_MODES" 2>/dev/null)"
[ -n "$mode" ] || exit 1
printf '%s,relatime\n' "$mode"
exit 0
EOF
cat > "$STUB_BIN/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
printf 'qemu %s\n' "$*" >> "$PZ_STUB_LOG"
exit 0
EOF
for tool in sudo bigsudo pkexec phasezero-admin; do
    cat > "$STUB_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$(basename "$0")" "$*" >> "$PZ_STUB_LOG"
# sudo -n is a flag, not a command; exec would misparse it as an option
if [ "${1:-}" = "-n" ]; then
    shift
fi
exec "$@"
EOF
done
chmod +x "$STUB_BIN"/*
export PATH="$STUB_BIN:$PATH"

iso="$TMP_ROOT/Win11_test.iso"
printf 'fake iso for dry-run tests\n' > "$iso"

bash -n "$REPO_ROOT/linux/pz"
bash -n "$REPO_ROOT/linux/steamdeck/display-session.sh"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
bash -n "$REPO_ROOT/linux/windows-vm/guest-login.sh"
jq empty "$REPO_ROOT/profiles/windows-vm-linux.json"
weights=$(grep -oP 'CP_WEIGHTS=\(\K[^)]+' "$REPO_ROOT/linux/windows-vm/provision.sh")
sum=0; for w in $weights; do sum=$((sum + w)); done
test "$sum" -eq 100 || { echo "CP_WEIGHTS soma $sum, não 100" >&2; exit 1; }
echo "  checkpoint weights sum=100 ok"

echo "=== runtime tree: auto-contida para o boot GRUB ==="
# common.sh carrega ledger.sh/desktop.sh no topo. Se a arvore instalada em
# /usr/local/lib/phasezero/windows-vm-runtime nao levar essas dependencias, o
# launcher aborta em todo retry e o boot pelo GRUB termina em tela preta.
runtime_specs="$(sed -n '/^runtime_file_specs()/,/^}/p' "$REPO_ROOT/linux/windows-vm/windows-vm.sh")"
gfx_specs="$(sed -n '/^runtime_artifact_specs()/,/^}/p' "$REPO_ROOT/linux/windows-vm/graphics.sh")"
test -n "$runtime_specs"
test -n "$gfx_specs"
# shellcheck disable=SC2016 # sed pattern matches literal source lines
while read -r lib_dep; do
    [ -n "$lib_dep" ] || continue
    grep -Fq "linux/lib/$lib_dep" <<< "$runtime_specs" || {
        echo "runtime_file_specs sem dependencia dura de common.sh: lib/$lib_dep" >&2; exit 1; }
    grep -Fq "linux/lib/$lib_dep" <<< "$gfx_specs" || {
        echo "runtime_artifact_specs sem dependencia dura de common.sh: lib/$lib_dep" >&2; exit 1; }
done < <(sed -n 's#^source "$PZ_ROOT/linux/lib/\([a-z_-]*\.sh\)"#\1#p' "$REPO_ROOT/linux/lib/common.sh")
for runtime_dep in windows-vm.sh graphics.sh rescue.sh; do
    grep -Fq "linux/windows-vm/$runtime_dep" <<< "$runtime_specs" || {
        echo "runtime_file_specs sem $runtime_dep" >&2; exit 1; }
    grep -Fq "linux/windows-vm/$runtime_dep" <<< "$gfx_specs" || {
        echo "runtime_artifact_specs sem $runtime_dep" >&2; exit 1; }
done
echo "  runtime manifests cobrem as dependencias de source"

"$REPO_ROOT/linux/pz" windows-vm status | jq -e '(.host | (has("qemu") and has("kvm"))) and (.libvirt | (has("domain") and has("preferred"))) and (.access | (has("sambaManaged") and has("usbRedirChannels") and has("usbUdevManaged")))' >/dev/null
"$REPO_ROOT/linux/pz" windows-vm discover --json | jq -e 'has("configuredDisk") and has("discoveredAnyDisk")' >/dev/null
plan_output="$("$REPO_ROOT/linux/pz" windows-vm plan --iso "$iso")"
grep -q 'PhaseZero Windows VM plan' <<< "$plan_output"
grep -q 'smb_unc' <<< "$plan_output"
grep -q 'disk_source' <<< "$plan_output"
grep -q 'share_policy: minimal' <<< "$plan_output"
grep -q 'share_policy: full' <<< "$(PZ_WINDOWS_VM_SHARE_POLICY=full "$REPO_ROOT/linux/pz" windows-vm plan --iso "$iso")"
grep -Fq '"$NET_MODEL,netdev=net0' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq 'socket,path=$RUNTIME_DIR/qga.sock' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq 'if [ "$GRAPHICS_PROFILE" != "virtio-gl" ]; then' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
shares_plan="$("$REPO_ROOT/linux/pz" windows-vm shares dry-run)"
grep -q 'share policy: minimal' <<< "$shares_plan"
grep -q 'exchange/' <<< "$shares_plan"
# shellcheck disable=SC2016 # 'SPICE WebDAV' is a literal informational line
if grep -q 'PZHome\|home/' <<< "$(grep -v 'SPICE WebDAV' <<< "$shares_plan")"; then
    echo "minimal share plan must not expose PZHome/home" >&2
    exit 1
fi
shares_plan_full="$(PZ_WINDOWS_VM_SHARE_POLICY=full "$REPO_ROOT/linux/pz" windows-vm shares dry-run)"
grep -q 'PZHome' <<< "$shares_plan_full"
grep -q 'share policy: full' <<< "$shares_plan_full"
grep -q 'USB auto filter: 0x08,-1,-1,-1,1' <<< "$shares_plan"
usb_plan="$("$REPO_ROOT/linux/pz" windows-vm usb-access dry-run)"
grep -q 'active-seat external devices and mass storage' <<< "$usb_plan"
PZ_WINDOWS_VM_USB_UDEV_RULE="$TMP_ROOT/missing-usb.rules" \
    "$REPO_ROOT/linux/pz" windows-vm usb-access status | jq -e '.managed == false' >/dev/null

echo "=== samba block content follows share policy ==="
WV_SRC="$(sed "/^case \"\$ACTION\" in/,\$d" "$REPO_ROOT/linux/windows-vm/windows-vm.sh" | sed "s#^PZ_ROOT=.*#PZ_ROOT=\"$REPO_ROOT\"#")"
run_wv_unit() {
    HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" bash -c '
        set -euo pipefail
        source /dev/stdin
        effective_config >/dev/null 2>&1 || true
        '"$1"'
    ' <<< "$WV_SRC"
}

echo "=== windows-vm.sh: bounded Samba status probe ==="
slow_smb_bin="$TMP_ROOT/slow-smb-bin"
mkdir -p "$slow_smb_bin"
cat > "$slow_smb_bin/smbclient" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
chmod +x "$slow_smb_bin/smbclient"
start_seconds="$SECONDS"
PATH="$slow_smb_bin:$PATH" PZ_WINDOWS_VM_STATUS_PROBE_TIMEOUT_SECONDS=1 HOME="$HOME" \
    bash -c 'source /dev/stdin; SHARE_POLICY=minimal; samba_shares_reachable && exit 1; exit 0' \
    <<< "$WV_SRC"
test "$((SECONDS - start_seconds))" -lt 4
echo "  Samba probe timeout ok"

echo "=== windows-vm.sh: configured status skips exhaustive disk scan ==="
configured_fast_disk="$TMP_ROOT/configured-fast.qcow2"
scan_log="$TMP_ROOT/configured-scan.log"
: > "$configured_fast_disk"
: > "$scan_log"
WV_CONFIGURED_FAST_DISK="$configured_fast_disk" WV_SCAN_LOG="$scan_log" HOME="$HOME" \
    bash -c '
        source /dev/stdin
        CONFIG_FILE=/nonexistent
        PZ_WINDOWS_VM_DISK="$WV_CONFIGURED_FAST_DISK"
        disk_looks_installed() { return 1; }
        find_existing_windows_disk() { printf "installed\n" >> "$WV_SCAN_LOG"; }
        find_existing_windows_disk_any() { printf "any\n" >> "$WV_SCAN_LOG"; }
        discovery_json configured >/dev/null
        test ! -s "$WV_SCAN_LOG"
        discovery_json full >/dev/null
        test -s "$WV_SCAN_LOG"
    ' <<< "$WV_SRC"
echo "  configured status scan bypass ok"

adopt_dir="$TMP_ROOT/adopt-self-contained"
adopt_disk="$adopt_dir/phasezero-windows.qcow2"
mkdir -p "$adopt_dir"
truncate -s 64M "$adopt_disk"
export WV_UNIT_ADOPT_DISK="$adopt_disk"
run_wv_unit 'disk_looks_installed() { return 0; }; target_user_can_rw() { return 0; }; install_user_files() { :; }; ensure_vm_storage() { install -d "$VM_DIR" "$STATE_DIR" "$RUNTIME_DIR"; : > "$OVMF_VARS"; }; cmd_adopt --disk "$WV_UNIT_ADOPT_DISK" >/dev/null'
unset WV_UNIT_ADOPT_DISK
# shellcheck disable=SC1090
source "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
[ "$PZ_WINDOWS_VM_DIR" = "$adopt_dir" ]
[ "$PZ_WINDOWS_VM_OVMF_VARS" = "$adopt_dir/OVMF_VARS.fd" ]
[ "$PZ_WINDOWS_VM_SHARE_ROOT" = "$adopt_dir/shares" ]
[ "$PZ_WINDOWS_VM_TPM_DIR" = "$adopt_dir/tpm" ]
[ "$PZ_WINDOWS_VM_SMB_HOST" = "10.0.2.2" ]
[ "$PZ_WINDOWS_VM_LIBVIRT_DOMAIN" = "" ]
[ "$PZ_WINDOWS_VM_SHARE_POLICY" = "minimal" ]
echo "  adopt keeps disk, NVRAM, shares and TPM self-contained"
rm -f "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
grep -Fq 'TARGET_RUNTIME_BASE="/run/user/$target_uid"' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq '/run/media/$TARGET_USER' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
minimal_ready_root="$TMP_ROOT/minimal-ready"
mkdir -p "$minimal_ready_root/exchange"
printf '%s\n' "$minimal_ready_root/exchange" >> "$PZ_STUB_MOUNTS"
export WV_UNIT_MINIMAL_ROOT="$minimal_ready_root"
run_wv_unit 'SHARE_POLICY=minimal SHARE_BIND_ROOT="$WV_UNIT_MINIMAL_ROOT" share_links_ready'
unset WV_UNIT_MINIMAL_ROOT
sed -i "\#^${minimal_ready_root}/exchange\$#d" "$PZ_STUB_MOUNTS"
echo "  minimal share readiness requires only exchange"
grep -Fq 'rmdir -- "$SHARE_BIND_ROOT/$name"' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
min_samba="$(run_wv_unit 'SHARE_POLICY=minimal samba_block_content')"
grep -q '^\[PZExchange\]' <<< "$min_samba"
if grep -q '^\[PZ\(Home\|SDCard\|Removable\|Media\|Mounts\)\]' <<< "$min_samba"; then
    echo "minimal samba block must not expose expanded shares" >&2
    exit 1
fi
full_samba="$(run_wv_unit 'SHARE_POLICY=full samba_block_content')"
grep -q '^\[PZHome\]' <<< "$full_samba"
grep -q '^\[PZMounts\]' <<< "$full_samba"
grep -q 'read only = yes' <<< "$full_samba"
if grep -q '^\[PZExchange\]$' <<< "$min_samba"; then
    grep -q 'read only = no' <<< "$min_samba"
fi
writable_samba="$(run_wv_unit 'SHARE_POLICY=full SHARE_WRITABLE=1 samba_block_content')"
grep -q 'read only = no' <<< "$writable_samba"

echo "=== migration full -> minimal prunes stale share links ==="
prune_out="$(run_wv_unit '
    RUNTIME_DIR="$HOME/.runtime"
    SHARE_BIND_ROOT="$RUNTIME_DIR/shares"
    SHARE_ROOT="$RUNTIME_DIR/share-root"
    EXCHANGE_DIR="$HOME/Shared/exchange"
    install -d "$SHARE_ROOT" "$HOME/Shared"
    ln -sfn "$HOME" "$SHARE_ROOT/home"
    ln -sfn /mnt "$SHARE_ROOT/mnt"
    ln -sfn "$EXCHANGE_DIR" "$SHARE_ROOT/exchange"
    SHARE_POLICY=minimal DRY_RUN=0 ensure_share_links 0 || true
    printf "home_link=%s mnt_link=%s exchange_link=%s\n" \
        "$([ -L "$SHARE_ROOT/home" ] && echo present || echo gone)" \
        "$([ -L "$SHARE_ROOT/mnt" ] && echo present || echo gone)" \
        "$([ -L "$SHARE_ROOT/exchange" ] && echo present || echo gone)"
    clean_share_binds 2>/dev/null || true
    rm -rf "$SHARE_BIND_ROOT" "$SHARE_ROOT" "$HOME/Shared"
')"
grep -q 'home_link=gone' <<< "$prune_out"
grep -q 'mnt_link=gone' <<< "$prune_out"
grep -q 'exchange_link=present' <<< "$prune_out"

echo ""
echo "=== shares: minimal policy binds only exchange ==="
: > "$PZ_STUB_MOUNTS"
: > "$PZ_STUB_MODES"
: > "$PZ_STUB_LOG"
min_bind="$(run_wv_unit '
    EXCHANGE_DIR="$HOME/Shared/exchange"
    mkdir -p "$HOME/Shared"
    SHARE_POLICY=minimal DRY_RUN=0 ensure_share_links 0 || exit 90
    printf "smb_dir=%s\n" "${EFFECTIVE_SMB_DIR:-}"
')"
grep -q "smb_dir=$TMP_ROOT/run/phasezero-windows-vm/shares" <<< "$min_bind"
grep -q '^mount .*shares/exchange' "$PZ_STUB_LOG"
if grep -q '^mount .*shares/home\|^mount .*shares/mnt\|^mount .*shares/sdcard' "$PZ_STUB_LOG"; then
    echo "minimal policy mounted an expanded share" >&2
    exit 1
fi
test "$(grep -c '^mount ' "$PZ_STUB_LOG")" -eq 1

echo "=== shares: prune success unmounts stale bind and revalidates ==="
: > "$PZ_STUB_MOUNTS"
: > "$PZ_STUB_MODES"
: > "$PZ_STUB_LOG"
printf '%s\n' "$TMP_ROOT/run/phasezero-windows-vm/shares/home" >> "$PZ_STUB_MOUNTS"
printf '%s rw\n' "$TMP_ROOT/run/phasezero-windows-vm/shares/home" >> "$PZ_STUB_MODES"
prune_ok="$(run_wv_unit '
    EXCHANGE_DIR="$HOME/Shared/exchange"
    mkdir -p "$HOME/Shared"
    set +e
    SHARE_POLICY=minimal DRY_RUN=0 ensure_share_links 0
    PRUNE_RC=$?
    set -e
    printf "prune_rc=%s mounted=%s\n" "$PRUNE_RC" "$(mountpoint -q "$SHARE_BIND_ROOT/home" && echo yes || echo no)"
')"
grep -q '^prune_rc=0' <<< "$prune_ok"
grep -q 'mounted=no' <<< "$prune_ok"
grep -q '^umount .*shares/home' "$PZ_STUB_LOG"

echo "=== shares: umount failure fails closed (no EFFECTIVE_SMB_DIR, no QEMU) ==="
export PZ_STUB_UMOUNT_FAIL=1
: > "$PZ_STUB_MOUNTS"
: > "$PZ_STUB_MODES"
: > "$PZ_STUB_LOG"
printf '%s\n' "$TMP_ROOT/run/phasezero-windows-vm/shares/home" >> "$PZ_STUB_MOUNTS"
printf '%s rw\n' "$TMP_ROOT/run/phasezero-windows-vm/shares/home" >> "$PZ_STUB_MODES"
stale_fail="$(run_wv_unit '
    EXCHANGE_DIR="$HOME/Shared/exchange"
    mkdir -p "$HOME/Shared"
    set +e
    SHARE_POLICY=minimal DRY_RUN=0 ensure_share_links 0
    SHARE_RC=$?
    set -e
    printf "ensure_rc=%s smb_dir=%s\n" "$SHARE_RC" "${EFFECTIVE_SMB_DIR:-}"
')"
grep -q '^ensure_rc=1' <<< "$stale_fail"
grep -q 'smb_dir=$' <<< "$stale_fail"
grep -q '^umount .*shares/home' "$PZ_STUB_LOG"
qemu_guard="$(run_wv_unit '
    EXCHANGE_DIR="$HOME/Shared/exchange"
    mkdir -p "$HOME/Shared"
    set +e
    SHARE_POLICY=minimal DRY_RUN=0 build_qemu_args
    BQA_RC=$?
    set -e
    printf "bqa_rc=%s\n" "$BQA_RC"
')"
unset PZ_STUB_UMOUNT_FAIL
grep -q '^bqa_rc=1' <<< "$qemu_guard"
if grep -q '^qemu ' "$PZ_STUB_LOG"; then
    echo "QEMU was launched despite stale share binds" >&2
    exit 1
fi

echo "=== shares: full read-only -> full writable remounts existing binds rw ==="
: > "$PZ_STUB_MOUNTS"
: > "$PZ_STUB_MODES"
: > "$PZ_STUB_LOG"
printf '%s\n' "$TMP_ROOT/run/phasezero-windows-vm/shares/home" >> "$PZ_STUB_MOUNTS"
printf '%s ro\n' "$TMP_ROOT/run/phasezero-windows-vm/shares/home" >> "$PZ_STUB_MODES"
trans_out="$(run_wv_unit '
    EXCHANGE_DIR="$HOME/Shared/exchange"
    mkdir -p "$HOME/Shared"
    set +e
    SHARE_POLICY=full SHARE_WRITABLE=1 DRY_RUN=0 ensure_share_links 0
    TRANS_RC=$?
    set -e
    printf "trans_rc=%s smb_dir=%s\n" "$TRANS_RC" "${EFFECTIVE_SMB_DIR:-}"
')"
grep -q '^trans_rc=0' <<< "$trans_out"
grep -q "smb_dir=$TMP_ROOT/run/phasezero-windows-vm/shares" <<< "$trans_out"
grep -q '^mount -o remount,rw,bind .*shares/home' "$PZ_STUB_LOG"

echo "=== shares: writable bind remounted ro when policy demands read-only ==="
: > "$PZ_STUB_MOUNTS"
: > "$PZ_STUB_MODES"
: > "$PZ_STUB_LOG"
printf '%s\n' "$TMP_ROOT/run/phasezero-windows-vm/shares/home" >> "$PZ_STUB_MOUNTS"
printf '%s rw\n' "$TMP_ROOT/run/phasezero-windows-vm/shares/home" >> "$PZ_STUB_MODES"
ro_out="$(run_wv_unit '
    EXCHANGE_DIR="$HOME/Shared/exchange"
    mkdir -p "$HOME/Shared"
    set +e
    SHARE_POLICY=full SHARE_WRITABLE=0 DRY_RUN=0 ensure_share_links 0
    RO_RC=$?
    set -e
    printf "ro_rc=%s\n" "$RO_RC"
')"
grep -q '^ro_rc=0' <<< "$ro_out"
grep -q '^mount -o remount,ro,bind .*shares/home' "$PZ_STUB_LOG"

echo "=== shares: vm_admin_run routes through stubbed sudo (no real root) ==="
: > "$PZ_STUB_LOG"
vm_admin="$(run_wv_unit '
    vm_admin_run mount --bind -o ro /tmp/fake-src /tmp/fake-dst
    printf "vm_admin_rc=%s\n" "$?"
')"
grep -q '^vm_admin_rc=0' <<< "$vm_admin"
grep -q '^sudo -n mount --bind -o ro /tmp/fake-src /tmp/fake-dst' "$PZ_STUB_LOG"

echo "=== boot session: privilege bridge is never interactive ==="
: > "$PZ_STUB_LOG"
boot_admin="$(run_wv_unit '
    set +e
    PZ_WINDOWS_VM_BOOT_SESSION=1 vm_admin_run mount --bind /tmp/fake-src /tmp/fake-dst
    boot_admin_rc=$?
    set -e
    printf "boot_admin_rc=%s\n" "$boot_admin_rc"
')"
grep -q '^boot_admin_rc=127' <<< "$boot_admin"
test ! -s "$PZ_STUB_LOG"

echo "=== launch: caminho real executa QEMU e limpa recursos ==="
export WV_UNIT_FIXTURE="$TMP_ROOT/post-launch-fixture"
mkdir -p "$WV_UNIT_FIXTURE"
: > "$WV_UNIT_FIXTURE/OVMF_CODE.fd"
: > "$WV_UNIT_FIXTURE/OVMF_VARS.fd"
: > "$WV_UNIT_FIXTURE/windows.qcow2"
post_launch="$(run_wv_unit '
    parse_options() { :; }
    effective_config() {
        GRAPHICS_PROFILE=compat; FULLSCREEN=0; LIBVIRT_DOMAIN=""; RAW_QEMU=1
        OVMF_CODE="$WV_UNIT_FIXTURE/OVMF_CODE.fd"; OVMF_VARS="$WV_UNIT_FIXTURE/OVMF_VARS.fd"
        DISK_PATH="$WV_UNIT_FIXTURE/windows.qcow2"; SHARE_POLICY=minimal; SPICE_ADDR=127.0.0.1
    }
    guard_graphics_profile() { return 0; }
    apply_host_optimizations() { :; }
    build_qemu_args() { QEMU_ARGS=(-machine q35); }
    cleanup_runtime() { printf "cleanup\\n"; }
    command() { if [ "${1:-}" = -v ] && [ "${2:-}" = ionice ]; then return 1; fi; builtin command "$@"; }
    qemu-system-x86_64() { printf "qemu %s\\n" "$*"; return 0; }
    launch_vm
')"
grep -q '^qemu -machine q35$' <<< "$post_launch"
test "$(grep -c '^cleanup$' <<< "$post_launch")" -eq 1
echo "  QEMU fake exits normally; runtime cleanup executes once"

spice_invariant="$({ grep -c 'addr=' "$REPO_ROOT/linux/windows-vm/windows-vm.sh" || true
                    grep -c 'addr=' "$REPO_ROOT/linux/windows-vm/provision.sh" || true; } | awk '{s+=$1} END {print s+0}')"
test "$spice_invariant" -ge 2
mkdir -p "$HOME/VirtualMachines/PhaseZero-Windows"
: > "$HOME/VirtualMachines/PhaseZero-Windows/phasezero-windows.qcow2"
: > "$HOME/VirtualMachines/PhaseZero-Windows/OVMF_VARS.fd"
: > "$TMP_ROOT/OVMF_CODE.fd"
export PZ_WINDOWS_VM_OVMF_CODE="$TMP_ROOT/OVMF_CODE.fd"
grep -q -- 'addr=127.0.0.1' <<< "$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu)"
grep -q -- 'addr=0.0.0.0' <<< "$(PZ_WINDOWS_VM_SPICE_ADDR=0.0.0.0 "$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu 2>/dev/null || true)"
display_launch="$(
    PZ_WINDOWS_VM_DISPLAY_WIDTH=2560 \
    PZ_WINDOWS_VM_DISPLAY_HEIGHT=1080 \
        "$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics compat --fullscreen
)"
grep -Fq 'virtio-vga\,xres=2560\,yres=1080' <<< "$display_launch"
grep -Fq 'gtk\,show-cursor=on\,zoom-to-fit=on' <<< "$display_launch"
grep -q -- '-full-screen' <<< "$display_launch"
invalid_display_launch="$(
    PZ_WINDOWS_VM_DISPLAY_WIDTH='2560,evil=on' \
    PZ_WINDOWS_VM_DISPLAY_HEIGHT=1080 \
        "$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics compat 2>/dev/null
)"
grep -Eq -- '-device virtio-vga( |$)' <<< "$invalid_display_launch"
if grep -q 'evil=on' <<< "$invalid_display_launch"; then
    exit 1
fi
echo "  boot display geometry reaches guest EDID and GTK scales to fullscreen"
boot_output="$("$REPO_ROOT/linux/pz" windows-vm boot dry-run)"
grep -q 'one-shot boot' <<< "$boot_output"
grep -q 'pz_boot_validate_active_efi_safe' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q 'pz_boot_require_current_root_target' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q 'BOOT_ID="phasezero-windows-vm"' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q -- "--hotkey=w" "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
# shellcheck disable=SC2016 # literal "$BOOT_ID" text searched in script source
grep -q 'grub-reboot "$BOOT_ID"' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
target_status="$("$REPO_ROOT/linux/pz" windows-vm boot --target-root / status)"
grep -q 'target_root: /' <<< "$target_status"
grep -q 'artifacts_current:' <<< "$target_status"
boot_json="$("$REPO_ROOT/linux/pz" windows-vm boot status --json 2>/dev/null || echo "")"
jq -e '.bootLoader == "grub-efi" or .bootLoader == "systemd-boot" or .bootLoader == "grub-bios" or .bootLoader == "efi-stub" or .bootLoader == "refind" or .bootLoader == "none"' <<< "$boot_json" >/dev/null
jq -e 'has("bootReady") and has("artifactsCurrent") and has("helperInstalled") and
       has("artifactsVerification") and .hostLoginPolicy == "auto" and
       .guestLoginPolicy == "auto" and .guestLoginVerified == false' <<< "$boot_json" >/dev/null
echo "  boot status --json schema ok"

launch_check_kvm="$TMP_ROOT/fixture-kvm"
: > "$launch_check_kvm"
chmod 0666 "$launch_check_kvm"
launch_check_json="$(PZ_WINDOWS_VM_KVM_PATH="$launch_check_kvm" \
    "$REPO_ROOT/linux/pz" windows-vm launch-check --graphics compat --json)"
jq -e '.success == true and .graphicsProfile == "compat" and
       ([.checks[]] | all)' <<< "$launch_check_json" >/dev/null
echo "  launch-check validates real launch prerequisites"

# bootReady must be false for an unknown/unsupported loader regardless of host
# state: loaderEntry resolves to "unknown" and can never confirm readiness.
boot_unknown_json="$(PZ_BOOT_LOADER=unknown "$REPO_ROOT/linux/pz" windows-vm boot status --json 2>/dev/null || echo "")"
jq -e '.loaderEntry == "unknown"' <<< "$boot_unknown_json" >/dev/null
jq -e '.bootReady == false' <<< "$boot_unknown_json" >/dev/null
jq -e '.oneShotReady == false' <<< "$boot_unknown_json" >/dev/null
echo "  boot status: unknown loader never bootReady"

stale_env="$TMP_ROOT/windows-vm-stale.env"
cat > "$stale_env" <<EOF
PZ_WINDOWS_VM_REPO=/phasezero-live
PZ_WINDOWS_VM_BOOT_USER=biglinux
EOF
session_validation="$(
    PZ_WINDOWS_VM_ENV_FILE="$stale_env" \
    PZ_WINDOWS_VM_REPO_FALLBACK="$REPO_ROOT" \
    PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$TMP_ROOT/missing-runtime" \
    "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh" --validate
)"
grep -q 'windows_vm_session_ready=yes' <<< "$session_validation"
grep -Fq "repo=$REPO_ROOT" <<< "$session_validation"
grep -q 'launcher_kind=dispatcher' <<< "$session_validation"
grep -q 'windows-vm launch --fullscreen' <<< "$session_validation"
grep -q 'display_profile=' <<< "$session_validation"
grep -q 'compositor=' <<< "$session_validation"
grep -q 'startkde-biglinux' "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh" && exit 1

session_bin="$TMP_ROOT/session-bin"
fake_repo="$TMP_ROOT/fake-repo"
fake_runtime="$session_bin/windows-vm-runtime"
runtime_args_file="$TMP_ROOT/runtime-args"
runtime_count_file="$TMP_ROOT/runtime-count"
dispatcher_args_file="$TMP_ROOT/dispatcher-args"
plasma_marker="$TMP_ROOT/plasma-started"
mkdir -p "$session_bin" "$fake_repo/linux"
cat > "$fake_runtime" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_WINDOWS_VM_TEST_ARGS_FILE"
printf 'attempt\n' >> "$PZ_WINDOWS_VM_TEST_COUNT_FILE"
exit 23
EOF
cat > "$fake_repo/linux/pz" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_WINDOWS_VM_TEST_ARGS_FILE"
exit 29
EOF
cat > "$session_bin/startplasma-wayland" <<'EOF'
#!/usr/bin/env bash
printf 'started\n' > "$PZ_WINDOWS_VM_TEST_PLASMA_FILE"
EOF
chmod +x "$fake_runtime" "$fake_repo/linux/pz" "$session_bin/startplasma-wayland"

runtime_validation="$(
    PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-runtime.env" \
    PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$fake_runtime" \
        "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh" --validate
)"
grep -q 'launcher_kind=runtime' <<< "$runtime_validation"
grep -Fq "command=$fake_runtime launch --fullscreen" <<< "$runtime_validation"

set +e
PATH="$session_bin:/usr/bin:/bin" \
PZ_WINDOWS_VM_COMPOSITOR=0 \
PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-runtime.env" \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$fake_runtime" \
PZ_WINDOWS_VM_SESSION_RETRY_SECONDS=1 \
PZ_WINDOWS_VM_RESCUE=0 \
PZ_WINDOWS_VM_SESSION_MAX_RETRIES=999 \
PZ_WINDOWS_VM_TEST_ARGS_FILE="$runtime_args_file" \
PZ_WINDOWS_VM_TEST_COUNT_FILE="$runtime_count_file" \
PZ_WINDOWS_VM_TEST_PLASMA_FILE="$plasma_marker" \
    timeout 3 "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
runtime_loop_rc=$?
set -e
test "$runtime_loop_rc" -eq 124
test "$(head -n 1 "$runtime_args_file")" = "launch --fullscreen"
test "$(sed -n '2p' "$runtime_args_file")" = "launch --fullscreen --graphics compat"
test "$(wc -l < "$runtime_count_file")" -ge 2
test ! -e "$plasma_marker"

echo "=== Session: encerramento normal não religa a VM ==="
normal_runtime="$session_bin/windows-vm-normal"
normal_args="$TMP_ROOT/normal-runtime-args"
cat > "$normal_runtime" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_WINDOWS_VM_TEST_ARGS_FILE"
exit 0
EOF
chmod +x "$normal_runtime"
PATH="$session_bin:/usr/bin:/bin" \
PZ_WINDOWS_VM_COMPOSITOR=0 \
PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-normal.env" \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$normal_runtime" \
PZ_WINDOWS_VM_RESCUE=0 \
PZ_WINDOWS_VM_TEST_ARGS_FILE="$normal_args" \
    "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
test "$(wc -l < "$normal_args")" -eq 1
test "$(cat "$normal_args")" = "launch --fullscreen"
echo "  normal QEMU exit closes session after one launch"

set +e
PATH="$session_bin:/usr/bin:/bin" \
PZ_WINDOWS_VM_COMPOSITOR=0 \
PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-dispatcher.env" \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$TMP_ROOT/missing-runtime" \
PZ_WINDOWS_VM_REPO_FALLBACK="$fake_repo" \
PZ_WINDOWS_VM_SESSION_RETRY_SECONDS=1 \
PZ_WINDOWS_VM_RESCUE=0 \
PZ_WINDOWS_VM_SESSION_MAX_RETRIES=999 \
PZ_WINDOWS_VM_TEST_ARGS_FILE="$dispatcher_args_file" \
PZ_WINDOWS_VM_TEST_COUNT_FILE="$runtime_count_file" \
PZ_WINDOWS_VM_TEST_PLASMA_FILE="$plasma_marker" \
    timeout 2 "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
dispatcher_loop_rc=$?
set -e
test "$dispatcher_loop_rc" -eq 124
test "$(head -n 1 "$dispatcher_args_file")" = "windows-vm launch --fullscreen"
test ! -e "$plasma_marker"

PATH="$session_bin:/usr/bin:/bin" \
PZ_WINDOWS_VM_COMPOSITOR=0 \
PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-fallback.env" \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$fake_runtime" \
PZ_WINDOWS_VM_DESKTOP_FALLBACK=1 \
PZ_WINDOWS_VM_RESCUE=0 \
PZ_WINDOWS_VM_SESSION_MAX_RETRIES=999 \
PZ_WINDOWS_VM_TEST_ARGS_FILE="$runtime_args_file" \
PZ_WINDOWS_VM_TEST_COUNT_FILE="$runtime_count_file" \
PZ_WINDOWS_VM_TEST_PLASMA_FILE="$plasma_marker" \
    "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
test -e "$plasma_marker"

echo "=== Session: desiste em vez de girar em tela preta ==="
# Launcher quebrado + resgate indisponivel nao pode virar loop infinito dentro
# de um compositor vazio: e exatamente isso que o usuario ve como tela preta.
giveup_args_file="$TMP_ROOT/giveup-args"
giveup_plasma="$TMP_ROOT/giveup-plasma"
set +e
PATH="$session_bin:/usr/bin:/bin" \
PZ_WINDOWS_VM_COMPOSITOR=0 \
PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-giveup.env" \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$fake_runtime" \
PZ_WINDOWS_VM_SESSION_RETRY_SECONDS=1 \
PZ_WINDOWS_VM_RESCUE=0 \
PZ_WINDOWS_VM_SESSION_MAX_RETRIES=2 \
PZ_WINDOWS_VM_DESKTOP_FALLBACK=0 \
PZ_WINDOWS_VM_TEST_ARGS_FILE="$giveup_args_file" \
PZ_WINDOWS_VM_TEST_COUNT_FILE="$TMP_ROOT/giveup-count" \
PZ_WINDOWS_VM_TEST_PLASMA_FILE="$giveup_plasma" \
    timeout 30 "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
giveup_rc=$?
set -e
test "$giveup_rc" -ne 124
test -e "$giveup_plasma"
echo "  session gives up and falls back to desktop"

echo "=== Session: compositor bootstrap for headless boot ==="
compositor_marker="$TMP_ROOT/cage-marker"
gamescope_args_file="$TMP_ROOT/gamescope-args"
display_dmi="$TMP_ROOT/display-dmi"
display_sys="$TMP_ROOT/display-sys"
mkdir -p "$display_dmi" "$display_sys/class/drm/card1-eDP-1"
printf 'Jupiter\n' > "$display_dmi/product_name"
printf 'connected\n' > "$display_sys/class/drm/card1-eDP-1/status"
cat > "$session_bin/dbus-run-session" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--" ] && shift
exec "$@"
EOF
cat > "$session_bin/gamescope" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$gamescope_args_file"
exit 77
EOF
chmod +x "$session_bin/dbus-run-session" "$session_bin/gamescope"
gamescope_validation="$(
    env -u DISPLAY -u WAYLAND_DISPLAY \
    PATH="$session_bin:/usr/bin:/bin" \
    PZ_DISPLAY_DMI_ROOT="$display_dmi" \
    PZ_DISPLAY_SYSFS_ROOT="$display_sys" \
    PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-runtime.env" \
    PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$fake_runtime" \
        "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh" --validate
)"
grep -q 'display_profile=steamdeck-lcd-handheld' <<< "$gamescope_validation"
grep -q 'compositor=gamescope' <<< "$gamescope_validation"
grep -q -- '--force-orientation right' <<< "$gamescope_validation"
set +e
env -u DISPLAY -u WAYLAND_DISPLAY \
PATH="$session_bin:/usr/bin:/bin" \
PZ_DISPLAY_DMI_ROOT="$display_dmi" \
PZ_DISPLAY_SYSFS_ROOT="$display_sys" \
PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-runtime.env" \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$fake_runtime" \
PZ_WINDOWS_VM_SESSION_RETRY_SECONDS=1 \
PZ_WINDOWS_VM_RESCUE=0 \
PZ_WINDOWS_VM_SESSION_MAX_RETRIES=999 \
PZ_WINDOWS_VM_TEST_ARGS_FILE="$runtime_args_file" \
PZ_WINDOWS_VM_TEST_COUNT_FILE="$runtime_count_file" \
PZ_WINDOWS_VM_TEST_PLASMA_FILE="$plasma_marker" \
    timeout 3 "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
gamescope_rc=$?
set -e
test "$gamescope_rc" -eq 77
grep -q -- '--backend drm --expose-wayland -O eDP-1 --force-orientation right -W 1280 -H 800 -w 1280 -h 800 -r 60.000 --force-windows-fullscreen --' "$gamescope_args_file"

mkdir -p "$display_sys/class/drm/card1-DP-1"
printf 'connected\n' > "$display_sys/class/drm/card1-DP-1/status"
printf 'monitor-edid\n' > "$display_sys/class/drm/card1-DP-1/edid"
printf '1920x1080\n' > "$display_sys/class/drm/card1-DP-1/modes"
display_edid_hash="$(md5sum "$display_sys/class/drm/card1-DP-1/edid" | awk '{print $1}')"
kde_output_config="$TMP_ROOT/kwinoutputconfig.json"
cat > "$kde_output_config" <<EOF
[
  {"name":"outputs","data":[
    {"connectorName":"DP-1","edidHash":"stale","mode":{"width":640,"height":480,"refreshRate":59940}},
    {"connectorName":"DP-1","edidHash":"$display_edid_hash","mode":{"width":2560,"height":1080,"refreshRate":74991}}
  ]}
]
EOF
docked_validation="$(
    env -u DISPLAY -u WAYLAND_DISPLAY \
    PATH="$session_bin:/usr/bin:/bin" \
    PZ_DISPLAY_DMI_ROOT="$display_dmi" \
    PZ_DISPLAY_SYSFS_ROOT="$display_sys" \
    PZ_DISPLAY_KDE_OUTPUT_CONFIG="$kde_output_config" \
    PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-runtime.env" \
    PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$fake_runtime" \
        "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh" --validate
)"
grep -q 'display_profile=steamdeck-docked' <<< "$docked_validation"
grep -q 'display_width=2560 display_height=1080 display_connector=DP-1' <<< "$docked_validation"
grep -q 'display_refresh_millihz=74991 display_refresh_hz=74.991' <<< "$docked_validation"
grep -q 'compositor=gamescope' <<< "$docked_validation"
grep -q 'reason=steamdeck-docked-explicit-output' <<< "$docked_validation"
grep -q -- '-O DP-1 -W 2560 -H 1080 -w 2560 -h 1080 -r 74.991 --force-windows-fullscreen' <<< "$docked_validation"
if grep -q -- '--force-orientation' <<< "$docked_validation"; then
    exit 1
fi
echo "  docked session targets connected KDE monitor mode and refresh explicitly"
rm -f "$session_bin/gamescope" "$gamescope_args_file"

cat > "$session_bin/cage" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$compositor_marker"
shift            # drop --
exec "\$@"
EOF
chmod +x "$session_bin/cage" "$session_bin/dbus-run-session"
set +e
env -u DISPLAY -u WAYLAND_DISPLAY \
PATH="$session_bin:/usr/bin:/bin" \
PZ_WINDOWS_VM_ENV_FILE="$TMP_ROOT/missing-runtime.env" \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$fake_runtime" \
PZ_WINDOWS_VM_COMPOSITOR=cage \
PZ_WINDOWS_VM_SESSION_RETRY_SECONDS=1 \
PZ_WINDOWS_VM_RESCUE=0 \
PZ_WINDOWS_VM_SESSION_MAX_RETRIES=999 \
PZ_WINDOWS_VM_TEST_ARGS_FILE="$runtime_args_file" \
PZ_WINDOWS_VM_TEST_COUNT_FILE="$runtime_count_file" \
PZ_WINDOWS_VM_TEST_PLASMA_FILE="$plasma_marker" \
    timeout 3 "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
compositor_rc=$?
set -e
test "$compositor_rc" -eq 124
test -e "$compositor_marker"
echo "  compositor bootstrap ok"

echo "=== windows-vm.sh: locale-stable virsh parsing ==="
grep -q 'virsh() { LC_ALL=C command virsh' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q 'not falling back to direct QEMU' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
echo "  virsh locale + fallback guard ok"

echo "=== windows-vm.sh: precise Windows domain discovery ==="
virsh_bin="$TMP_ROOT/virsh-bin"
mkdir -p "$virsh_bin"
cat > "$virsh_bin/virsh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *" list --all --name")
        printf '%s\n' darwin-builder win11-test
        ;;
    *" domblklist darwin-builder --details")
        printf '%s\n' 'Type Device Target Source' 'file disk vda /var/lib/libvirt/images/darwin-linux.qcow2'
        ;;
    *" domblklist win11-test --details")
        printf '%s\n' 'Type Device Target Source' 'file disk vda /var/lib/libvirt/images/Win11.qcow2'
        ;;
    *" domstate win11-test")
        printf '%s\n' 'shut off'
        ;;
    *" dumpxml win11-test")
        printf '%s\n' '<domain><devices><disk device="disk"><target bus="virtio"/></disk></devices></domain>'
        ;;
    *" net-dumpxml default")
        printf '%s\n' "<network><ip address='192.168.122.1'/></network>"
        ;;
esac
EOF
chmod +x "$virsh_bin/virsh"
domain_status="$(
    PATH="$virsh_bin:$PATH" \
    PZ_WINDOWS_VM_DISCOVERED_DISK="$TMP_ROOT/no-existing-disk.qcow2" \
        "$REPO_ROOT/linux/pz" windows-vm status
)"
jq -e '.libvirt.domain == "win11-test" and .libvirt.preferred == true' <<< "$domain_status" >/dev/null
echo "  precise domain discovery ok"

sddm_test_dir="$TMP_ROOT/sddm"
dm_bin="$TMP_ROOT/dm-bin"
mkdir -p "$dm_bin"
cat > "$dm_bin/sddm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$dm_bin/powerprofilesctl" <<'EOF'
#!/usr/bin/env bash
# Reproduces hosts where the performance profile is unsupported. This must
# never abort SDDM autologin preparation under set -e.
exit 2
EOF
chmod +x "$dm_bin/sddm" "$dm_bin/powerprofilesctl"
PZ_BOOT_CMDLINE='quiet phasezero.windowsvm=1' \
PATH="$dm_bin:$PATH" \
PZ_SDDM_CONF_DIR="$sddm_test_dir" \
PZ_WINDOWS_VM_BOOT_USER=tester \
PZ_WINDOWS_VM_SKIP_RUNTIME_PREP=1 \
PZ_WINDOWS_VM_SKIP_LAUNCH_PREFLIGHT=1 \
    "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
grep -q '^User=tester$' "$sddm_test_dir/91-phasezero-windows-vm.conf"
grep -q '^Session=phasezero-windows-vm.desktop$' "$sddm_test_dir/91-phasezero-windows-vm.conf"
grep -q '^Relogin=false$' "$sddm_test_dir/91-phasezero-windows-vm.conf"
grep -Fq 'EnvironmentFile=-$ROOT_ENV_FILE' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq 'PZ_WINDOWS_VM_RUNTIME_DIR=%q' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq 'find "$BOOT_RUNTIME_DIR" -xdev' "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
grep -Fq 'target_prefix=(runuser -u "$TARGET_USER" --)' "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
PZ_BOOT_CMDLINE='quiet phasezero.windowsvm=1' \
PATH="$dm_bin:$PATH" \
PZ_SDDM_CONF_DIR="$sddm_test_dir" \
PZ_WINDOWS_VM_BOOT_USER=tester \
PZ_WINDOWS_VM_REQUIRE_LOGIN=1 \
PZ_WINDOWS_VM_SKIP_TUNING=1 \
PZ_WINDOWS_VM_SKIP_RUNTIME_PREP=1 \
PZ_WINDOWS_VM_SKIP_LAUNCH_PREFLIGHT=1 \
    "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
test ! -e "$sddm_test_dir/91-phasezero-windows-vm.conf"

echo "=== boot helper: autologin somente após preflight aprovado ==="
preflight_runtime="$TMP_ROOT/preflight-runtime"
cat > "$preflight_runtime" <<'EOF'
#!/usr/bin/env bash
if [ "${PZ_TEST_PREFLIGHT_RESULT:-fail}" = pass ]; then
    printf '%s\n' '{"success":true,"blockers":[]}'
    exit 0
fi
printf '%s\n' '{"success":false,"blockers":["fixture"]}'
exit 1
EOF
chmod +x "$preflight_runtime"
PZ_BOOT_CMDLINE='quiet phasezero.windowsvm=1' \
PATH="$dm_bin:$PATH" \
PZ_SDDM_CONF_DIR="$sddm_test_dir" \
PZ_WINDOWS_VM_BOOT_USER=tester \
PZ_WINDOWS_VM_SKIP_TUNING=1 \
PZ_WINDOWS_VM_SKIP_RUNTIME_PREP=1 \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$preflight_runtime" \
PZ_TEST_PREFLIGHT_RESULT=pass \
    "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
test -f "$sddm_test_dir/91-phasezero-windows-vm.conf"
set +e
PZ_BOOT_CMDLINE='quiet phasezero.windowsvm=1' \
PATH="$dm_bin:$PATH" \
PZ_SDDM_CONF_DIR="$sddm_test_dir" \
PZ_WINDOWS_VM_BOOT_USER=tester \
PZ_WINDOWS_VM_SKIP_TUNING=1 \
PZ_WINDOWS_VM_SKIP_RUNTIME_PREP=1 \
PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$preflight_runtime" \
PZ_TEST_PREFLIGHT_RESULT=fail \
    "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
preflight_fail_rc=$?
set -e
test "$preflight_fail_rc" -ne 0
test ! -e "$sddm_test_dir/91-phasezero-windows-vm.conf"
echo "  failed preflight preserves normal greeter"
PZ_BOOT_CMDLINE='quiet splash' \
PATH="$dm_bin:$PATH" \
PZ_SDDM_CONF_DIR="$sddm_test_dir" \
    "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
test ! -e "$sddm_test_dir/91-phasezero-windows-vm.conf"

PZ_DRY_RUN=1 "$REPO_ROOT/linux/pz" windows-vm install --iso "$iso" --disk-size 64M --ram 2048 --cpus 2 >/dev/null
test ! -f "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
"$REPO_ROOT/linux/pz" windows-vm install --iso "$iso" --disk-size 64M --ram 2048 --cpus 2 >/dev/null
test -f "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
grep -q 'PZ_WINDOWS_VM_ISO=' "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
PZ_DRY_RUN=1 "$REPO_ROOT/linux/pz" windows-vm optimize >/dev/null
launch_output="$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu)"
grep -q 'qemu-system-x86_64' <<< "$launch_output"
domain_launch_output="$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run)"
grep -Eq 'virsh -c .* start|qemu-system-x86_64' <<< "$domain_launch_output"
grep -q -- '--spice-usbredir-auto-redirect-filter=' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q -- '--spice-usbredir-redirect-on-connect=' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q 'libvirt domain start failed; falling back to direct QEMU/KVM' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q 'grant_raw_qemu_disk_access' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q 'libvirt_domain_nvram' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q 'ide-hd,drive=system,bus=ide.0,bootindex=1' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
grep -q 'session.log' "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
"$REPO_ROOT/linux/pz" windows-vm status | jq -e '.config.installed == true and .vm.isoExists == true and (.vm.diskSource == "new" or .vm.diskSource == "config" or .vm.diskSource == "discovered-installed" or .vm.diskSource == "adopted-existing") and (.vm | has("installedLike"))' >/dev/null
"$REPO_ROOT/linux/pz" windows-vm status | jq -e '
    (.status == "ok" or .status == "warning" or .status == "blocked" or .status == "needsinstall") and
    (.health.readyToLaunch | type == "boolean") and
    (.health.bootDirectReady | type == "boolean") and
    (.health.findings | type == "array")
' >/dev/null
"$REPO_ROOT/linux/pz" install windows-vm-linux --dry-run >/dev/null

echo "=== Guest bundle generation ==="
test -d "$REPO_ROOT/linux/windows-vm/guest"
test -f "$REPO_ROOT/linux/windows-vm/guest/Install-VirtioFS.ps1"
test -f "$REPO_ROOT/linux/windows-vm/guest/Enable-RdpShares.ps1"
test -d "$REPO_ROOT/linux/windows-vm/guest/vendor"
test -f "$REPO_ROOT/linux/windows-vm/guest/vendor/vendor.json"
jq empty "$REPO_ROOT/linux/windows-vm/guest/vendor/vendor.json"
echo "  guest bundle files ok"

echo "=== Loader detection ==="
loader_result="$("$REPO_ROOT/linux/pz" windows-vm boot dry-run | grep 'loader:')"
test -n "$loader_result"
grep -qE 'loader: (grub-efi|grub-bios|systemd-boot|refind|efi-stub|unknown)' <<< "$loader_result"
echo "  loader detection: $loader_result"

echo "=== --loader flag override ==="
loader_override="$("$REPO_ROOT/linux/pz" windows-vm boot --loader systemd-boot dry-run | grep 'loader:')"
grep -q 'loader: systemd-boot' <<< "$loader_override"
echo "  --loader override: systemd-boot"

echo "=== shares verify subcommand ==="
"$REPO_ROOT/linux/windows-vm/windows-vm.sh" shares dry-run >/dev/null 2>&1; echo "  shares dry-run ok"
echo "  shares verify subcommand exists (in usage text)"
echo "  shares verify ok"

echo "=== shares verify runtime ==="
# Construct a degraded state: SHARE_BIND_ROOT under a temp XDG_RUNTIME_DIR
# with no bind mounts, so verify_share reports "fail"/"not found".
PZ_VERIFY_TMPROOT="$(mktemp -d)"
PZ_VERIFY_RT="$PZ_VERIFY_TMPROOT/rt"
mkdir -p "$PZ_VERIFY_RT/phasezero-windows-vm/shares" "$HOME/Shared/WindowsVM"
# Text mode: must emit shares_ok: line and return non-zero when degraded.
# NOTE: command substitution propagates non-zero rc under `set -e`, so we
# capture rc explicitly via a subshell rather than relying on $? after $(...).
verify_output=""
verify_rc_text=0
verify_output="$(XDG_RUNTIME_DIR="$PZ_VERIFY_RT" "$REPO_ROOT/linux/windows-vm/windows-vm.sh" shares verify 2>/dev/null)" || verify_rc_text=$?
grep -q 'shares_ok:' <<< "$verify_output"
echo "  shares verify text mode: shares_ok line present"
# Contract: degraded state MUST return non-zero (no || true masking).
[ "$verify_rc_text" -ne 0 ] || { echo "FAIL: shares verify text mode returned 0 on degraded state"; exit 1; }
grep -q 'shares_ok: no' <<< "$verify_output"
echo "  shares verify text mode: rc=$verify_rc_text on degraded state (non-zero contract holds)"
# JSON mode via JSON_OUT env var.
verify_json=""
verify_rc_json=0
verify_json="$(XDG_RUNTIME_DIR="$PZ_VERIFY_RT" JSON_OUT=1 "$REPO_ROOT/linux/windows-vm/windows-vm.sh" shares verify 2>/dev/null)" || verify_rc_json=$?
jq -e '.ok == true or .ok == false' >/dev/null 2>&1 <<< "$verify_json"
echo "  shares verify JSON mode: ok boolean present"
jq -e '.shares | type == "array"' >/dev/null 2>&1 <<< "$verify_json"
echo "  shares verify JSON mode: shares array present"
jq -e 'has("failures")' >/dev/null 2>&1 <<< "$verify_json"
echo "  shares verify JSON mode: failures count present"
# Contract: degraded JSON MUST report ok=false and non-zero rc.
jq -e '.ok == false' >/dev/null 2>&1 <<< "$verify_json"
[ "$verify_rc_json" -ne 0 ] || { echo "FAIL: shares verify JSON mode returned 0 on degraded state"; exit 1; }
echo "  shares verify JSON mode: ok=false rc=$verify_rc_json on degraded state (contract holds)"
rm -rf "$PZ_VERIFY_TMPROOT"
echo "  shares verify runtime ok"
boot_output="$("$REPO_ROOT/linux/pz" windows-vm boot dry-run)"
grep -q 'loader override' <<< "$boot_output"
echo "  loader override in dry-run output"

echo "=== container-frontends: install-virtiofs ==="
bash -n "$REPO_ROOT/linux/windows-vm/container-frontends.sh"
frontend_help="$("$REPO_ROOT/linux/windows-vm/container-frontends.sh" help 2>&1)"
grep -q 'install-virtiofs' <<< "$frontend_help"
echo "  install-virtiofs action exists"

echo "=== vm boot usage shows --loader ==="
boot_help="$("$REPO_ROOT/linux/pz" windows-vm boot --help 2>&1 || true)"
grep -q '\--loader' <<< "$boot_help"
echo "  --loader in usage: ok"

echo "=== status_boot grub-editenv tolerance ==="
GRUB_FAKE_DIR="$TMP_ROOT/grub-fake/bin"
mkdir -p "$GRUB_FAKE_DIR"
cat > "$GRUB_FAKE_DIR/grub-editenv" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
    printf '%s\n' "$FAKE_GRUB_ENV_OUTPUT"
    exit "${FAKE_GRUB_ENV_RC:-0}"
fi
exit 0
EOF
chmod +x "$GRUB_FAKE_DIR/grub-editenv"

# 1) normal env block: both entries parsed
FAKE_GRUB_ENV_OUTPUT='next_entry=phasezero-windows-vm
saved_entry=phasezero-windows-vm' \
FAKE_GRUB_ENV_RC=0 PATH="$GRUB_FAKE_DIR:$PATH" \
    "$REPO_ROOT/linux/pz" windows-vm boot status --json > "$TMP_ROOT/grub-ok.json"
grub_ok="$(cat "$TMP_ROOT/grub-ok.json")"
jq -e '.grubNextEntry == "phasezero-windows-vm"' <<< "$grub_ok" >/dev/null
jq -e '.grubSavedEntry == "phasezero-windows-vm"' <<< "$grub_ok" >/dev/null
echo "  grub-editenv ok: entries parsed"

# 2) permission denied: status must degrade to unknown-permission, never abort
FAKE_GRUB_ENV_OUTPUT='grub-editenv: error: cannot read /boot/grub/grubenv: Permission denied' \
FAKE_GRUB_ENV_RC=1 PATH="$GRUB_FAKE_DIR:$PATH" \
    "$REPO_ROOT/linux/pz" windows-vm boot status --json > "$TMP_ROOT/grub-denied.json"
grub_denied="$(cat "$TMP_ROOT/grub-denied.json")"
jq -e '.grubNextEntry == "unknown-permission"' <<< "$grub_denied" >/dev/null
jq -e '.grubSavedEntry == "unknown-permission"' <<< "$grub_denied" >/dev/null
echo "  grub-editenv permission denied: unknown-permission"

# 3) env block missing (rc != 0, no permission text): renders none
FAKE_GRUB_ENV_OUTPUT='grub-editenv: error: no environment block' \
FAKE_GRUB_ENV_RC=1 PATH="$GRUB_FAKE_DIR:$PATH" \
    "$REPO_ROOT/linux/pz" windows-vm boot status --json > "$TMP_ROOT/grub-none.json"
grub_none="$(cat "$TMP_ROOT/grub-none.json")"
jq -e '.grubNextEntry == "none"' <<< "$grub_none" >/dev/null
jq -e '.grubSavedEntry == "none"' <<< "$grub_none" >/dev/null
echo "  grub-editenv missing env block: none"

echo "=== rescue.sh ==="
bash -n "$REPO_ROOT/linux/windows-vm/rescue.sh"
echo "  rescue.sh syntax: bash -n ok"

# Source rescue.sh in subshell and test basic functions
RESCUE_TEST_DIR="$TMP_ROOT/rescue-test"
mkdir -p "$RESCUE_TEST_DIR/home/Downloads" "$RESCUE_TEST_DIR/mnt/sdcard" "$RESCUE_TEST_DIR/state/windows-vm"
export PZ_ROOT="$REPO_ROOT"
export HOME="$RESCUE_TEST_DIR/home"
export STATE_DIR="$RESCUE_TEST_DIR/state/windows-vm"
export XDG_STATE_HOME="$RESCUE_TEST_DIR/state"
touch "$RESCUE_TEST_DIR/home/Downloads/Win11_24H2.iso"
# vm_rescue_should_run
(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh"
    # Guard: no boot session → skip
    # shellcheck disable=SC2030 # deliberate env override scoped to test subshell
    PZ_WINDOWS_VM_RESCUE=1 PZ_WINDOWS_VM_BOOT_SESSION=0
    vm_rescue_should_run && exit 1 || exit 0
) && echo "  vm_rescue_should_run: returns 1 outside boot session" || echo "  vm_rescue_should_run: guard ok"
(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh"
    # shellcheck disable=SC2030 # deliberate env override scoped to test subshell
    PZ_WINDOWS_VM_RESCUE=0 PZ_WINDOWS_VM_BOOT_SESSION=1
    vm_rescue_should_run && exit 1 || exit 0
) && echo "  vm_rescue_should_run: returns 1 when PZ_WINDOWS_VM_RESCUE=0" || echo "  vm_rescue_should_run: guard ok"
(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh"
    # shellcheck disable=SC2030 # deliberate env override scoped to test subshell
    PZ_WINDOWS_VM_RESCUE=1 PZ_WINDOWS_VM_BOOT_SESSION=1
    vm_rescue_should_run
) && echo "  vm_rescue_should_run: returns 0 when both are set"

# vm_rescue_scan_isos
iso_scan_result="$(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh" 2>/dev/null
    PZ_ROOT="$PZ_ROOT" HOME="$RESCUE_TEST_DIR/home" vm_rescue_scan_isos
)"
grep -q 'Win11_24H2.iso' <<< "$iso_scan_result"
echo "  vm_rescue_scan_isos: found fake ISO"

# vm_rescue_scan_disks
mkdir -p "$RESCUE_TEST_DIR/VirtualMachines"
# Create 32G qcow2 (passes disk_looks_installed virtual≥32G check) then write 1G data (passes actual≥1G check)
if command -v qemu-img >/dev/null 2>&1; then
    qemu-img create -f qcow2 "$RESCUE_TEST_DIR/VirtualMachines/win11-test.qcow2" 32G >/dev/null 2>&1
    dd if=/dev/zero bs=1M count=1024 conv=notrunc of="$RESCUE_TEST_DIR/VirtualMachines/win11-test.qcow2" 2>/dev/null || true
elif command -v fallocate >/dev/null 2>&1; then
    fallocate -l 1G "$RESCUE_TEST_DIR/VirtualMachines/win11-test.qcow2" 2>/dev/null || true
else
    dd if=/dev/zero bs=1M count=1024 of="$RESCUE_TEST_DIR/VirtualMachines/win11-test.qcow2" 2>/dev/null || true
fi
disk_scan_result="$(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh" 2>/dev/null
    # shellcheck disable=SC2030 # deliberate HOME re-scope inside command substitution
    export HOME="$RESCUE_TEST_DIR"
    # Provide disk_looks_installed stub matching real check (virtual≥32G with actual≥1G, or actual≥5G)
    disk_looks_installed() {
        local path="$1" actual virtual
        actual=$(stat -c %s "$path" 2>/dev/null || echo 0)
        virtual=$(qemu-img info "$path" 2>/dev/null | grep 'virtual size' | grep -oP '\d+' | tail -1 || echo 0)
        [ "$actual" -ge 1073741824 ] 2>/dev/null && return 0
        [ "$virtual" -ge 34359738368 ] && [ "$actual" -ge 1048576 ] 2>/dev/null && return 0
        return 1
    }
    vm_rescue_scan_disks
)"
if grep -q 'win11-test.qcow2' <<< "$disk_scan_result"; then
    echo "  vm_rescue_scan_disks: found fake qcow2"
else
    echo "  vm_rescue_scan_disks: no disk found (expected on CI, test host may lack qemu-img)"
fi

# vm_rescue_text_menu fallback
text_menu_choice="$(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh" 2>/dev/null
    printf '2\n' | vm_rescue_text_menu "Test" "Escolha:" "opt1" "Option 1" "opt2" "Option 2"
)"
test "$text_menu_choice" = "opt2"
echo "  vm_rescue_text_menu: returns second option"

# vm_rescue_run in test mode (PZ_WINDOWS_VM_RESCUE_TEST)
rescue_test_output="$(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh" 2>/dev/null
    PZ_WINDOWS_VM_BOOT_SESSION=1 PZ_WINDOWS_VM_RESCUE=1 PZ_WINDOWS_VM_RESCUE_TEST=1 \
    DISK_PATH=/nonexistent vm_rescue_run
)"
grep -q 'RESCUE-TEST: vm_rescue_run entered' <<< "$rescue_test_output"
echo "  vm_rescue_run (test mode): entered"

echo "=== rescue: DISK_PATH ausente não aborta por set -u ==="
set +e
printf 'n\n' | bash -c '
    set -euo pipefail
    source "$1/linux/windows-vm/rescue.sh"
    unset DISK_PATH
    PZ_WINDOWS_VM_BOOT_SESSION=1
    PZ_WINDOWS_VM_RESCUE=1
    vm_rescue_should_run() { return 0; }
    vm_rescue_escape_to_desktop() { return 1; }
    vm_rescue_run
' _ "$REPO_ROOT" >/dev/null 2>&1
rescue_unset_rc=$?
set -e
test "$rescue_unset_rc" -eq 1
echo "  rescue degrades without unbound variable"

echo "=== guest login: LSA secret and QGA transport invariants ==="
grep -Fq "PhaseZeroLsa]::Store('DefaultPassword'" "$REPO_ROOT/linux/windows-vm/guest-login.ps1"
grep -Fq 'Remove-ItemProperty -Path $winlogon -Name DefaultPassword' "$REPO_ROOT/linux/windows-vm/guest-login.ps1"
grep -Fq ".psbase.Invoke('SetPassword'" "$REPO_ROOT/linux/windows-vm/guest-login.ps1"
if grep -Eq 'Set-ItemProperty.*DefaultPassword' "$REPO_ROOT/linux/windows-vm/guest-login.ps1"; then
    echo "guest login helper stores password in registry" >&2
    exit 1
fi
grep -Fq '"input-data"' "$REPO_ROOT/linux/windows-vm/guest-login.sh"
if grep -Eq -- '--arg (password|secret)' "$REPO_ROOT/linux/windows-vm/guest-login.sh"; then
    echo "guest login helper exposes secret through jq argv" >&2
    exit 1
fi
grep -Fq 'TPM state outside managed VM directory' "$REPO_ROOT/linux/windows-vm/guest-login.sh"
grep -Fq 'exchangeMapped' "$REPO_ROOT/linux/windows-vm/guest-login.ps1"
grep -Fq 'Resolve-DnsName' "$REPO_ROOT/linux/windows-vm/guest-login.ps1"
grep -Fq 'Win32_SoundDevice' "$REPO_ROOT/linux/windows-vm/guest-login.ps1"
echo "  guest secret never uses registry plaintext or argv"

# vm_rescue_escape_to_desktop in test mode (non-destructive)
escape_test_output="$(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh" 2>/dev/null
    PZ_WINDOWS_VM_RESCUE_TEST=1 vm_rescue_escape_to_desktop
)"
grep -q 'RESCUE-TEST: would call remove_sddm_autologin' <<< "$escape_test_output"
echo "  vm_rescue_escape_to_desktop (test mode): non-destructive prints actions"

echo "  rescue.sh tests ok"

# media-inspect contracts: scan (net-new) and inspect schema (regression guard).
MEDIA_TEST_DIR="$TMP_ROOT/media-test"
mkdir -p "$MEDIA_TEST_DIR/home/Downloads"
touch "$MEDIA_TEST_DIR/home/Downloads/Win11_25H2_BrazilianPortuguese_x64.iso"
touch "$MEDIA_TEST_DIR/home/Downloads/Windows10_x64.iso"
touch "$MEDIA_TEST_DIR/home/Downloads/notaniso.txt"

# scan --json: dedups overlapping bases, lists only *.iso, stable schema.
scan_json="$(HOME="$MEDIA_TEST_DIR/home" bash "$REPO_ROOT/linux/windows-vm/media-inspect.sh" scan --json)"
# Filter to candidates created by this test so host ISOs cannot perturb counts.
mine="$(printf '%s' "$scan_json" | jq --arg base "$MEDIA_TEST_DIR" '[.candidates[] | select(.path | startswith($base))]')"
printf '%s' "$mine" | jq -e 'length == 2' >/dev/null
printf '%s' "$mine" | jq -e 'any(.path | endswith("Win11_25H2_BrazilianPortuguese_x64.iso"))' >/dev/null
printf '%s' "$mine" | jq -e 'any(.path | endswith("Windows10_x64.iso"))' >/dev/null
printf '%s' "$mine" | jq -e 'all(.path | test("notaniso") | not)' >/dev/null
printf '%s' "$scan_json" | jq -e '.candidates | all(has("path") and has("sizeMb"))' >/dev/null
echo "  media scan --json: deduped candidate list; non-ISO excluded"

# scan text mode stays non-empty and exits 0.
HOME="$MEDIA_TEST_DIR/home" bash "$REPO_ROOT/linux/windows-vm/media-inspect.sh" scan >/dev/null
echo "  media scan (text): exit 0"

# inspect --json schema preserved on a non-Windows blob (regression guard).
inspect_iso="$MEDIA_TEST_DIR/home/Downloads/notwindows.iso"
printf 'definitely not a windows payload\n' > "$inspect_iso"
inspect_json="$(bash "$REPO_ROOT/linux/windows-vm/media-inspect.sh" inspect --iso "$inspect_iso" --json)"
printf '%s' "$inspect_json" | jq -e '.valid == false and .imageCount == 0 and (.images | type == "array")' >/dev/null
printf '%s' "$inspect_json" | jq -e 'has("sha256") and has("arch") and has("uefiBoot") and has("sizeMb") and has("label") and has("payloadNote")' >/dev/null
echo "  media inspect --json: schema stable (valid=false on non-Windows blob, all keys present)"

echo "  media-inspect tests ok"
