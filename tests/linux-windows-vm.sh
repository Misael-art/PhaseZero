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
grep -q 'grub-reboot "$BOOT_ID"' "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
target_status="$("$REPO_ROOT/linux/pz" windows-vm boot --target-root / status)"
grep -q 'target_root: /' <<< "$target_status"
grep -q 'artifacts_current:' <<< "$target_status"

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
! grep -q 'startkde-biglinux' "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"

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
PZ_WINDOWS_VM_TEST_ARGS_FILE="$runtime_args_file" \
PZ_WINDOWS_VM_TEST_COUNT_FILE="$runtime_count_file" \
PZ_WINDOWS_VM_TEST_PLASMA_FILE="$plasma_marker" \
    "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh"
test -e "$plasma_marker"

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
PZ_WINDOWS_VM_SESSION_RETRY_SECONDS=1 \
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

echo "linux-windows-vm smoke ok"
