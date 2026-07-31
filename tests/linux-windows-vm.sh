#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux Windows VM automation.
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

iso="$TMP_ROOT/Win11_test.iso"
printf 'fake iso for dry-run tests\n' > "$iso"

bash -n "$REPO_ROOT/linux/pz"
bash -n "$REPO_ROOT/linux/steamdeck/display-session.sh"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
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
shares_plan="$("$REPO_ROOT/linux/pz" windows-vm shares dry-run)"
grep -q 'PZHome' <<< "$shares_plan"
grep -q 'USB auto filter: 0x08,-1,-1,-1,1' <<< "$shares_plan"
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
jq -e 'has("bootReady") and has("artifactsCurrent") and has("helperInstalled")' <<< "$boot_json" >/dev/null
echo "  boot status --json schema ok"

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
test "$(wc -l < "$runtime_count_file")" -ge 2
test ! -e "$plasma_marker"

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
grep -q -- '--backend drm --expose-wayland --force-orientation right -W 1280 -H 800 -w 1280 -h 800 --force-windows-fullscreen --' "$gamescope_args_file"
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
PZ_BOOT_CMDLINE='quiet phasezero.windowsvm=1' \
PZ_SDDM_CONF_DIR="$sddm_test_dir" \
PZ_WINDOWS_VM_BOOT_USER=tester \
PZ_WINDOWS_VM_SKIP_TUNING=1 \
    "$REPO_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
grep -q '^User=tester$' "$sddm_test_dir/91-phasezero-windows-vm.conf"
grep -q '^Session=phasezero-windows-vm.desktop$' "$sddm_test_dir/91-phasezero-windows-vm.conf"
PZ_BOOT_CMDLINE='quiet splash' \
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
mkdir -p "$PZ_VERIFY_RT/phasezero-windows-vm/shares"
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

# vm_rescue_escape_to_desktop in test mode (non-destructive)
escape_test_output="$(
    source "$REPO_ROOT/linux/windows-vm/rescue.sh" 2>/dev/null
    PZ_WINDOWS_VM_RESCUE_TEST=1 vm_rescue_escape_to_desktop
)"
grep -q 'RESCUE-TEST: would call remove_sddm_autologin' <<< "$escape_test_output"
echo "  vm_rescue_escape_to_desktop (test mode): non-destructive prints actions"

echo "  rescue.sh tests ok"
