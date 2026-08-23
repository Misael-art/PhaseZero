#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux Waydroid automation.
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

bash -n "$REPO_ROOT/linux/pz"
bash -n "$REPO_ROOT/linux/steamdeck/display-session.sh"
bash -n "$REPO_ROOT/linux/waydroid/waydroid.sh"
bash -n "$REPO_ROOT/linux/waydroid/waydroid-boot-prepare.sh"
bash -n "$REPO_ROOT/linux/waydroid/waydroid-session.sh"
bash -n "$REPO_ROOT/linux/waydroid/waydroid-shares-prepare.sh"
jq empty "$REPO_ROOT/profiles/waydroid-linux.json"

"$REPO_ROOT/linux/pz" waydroid status | jq -e '(.host | has("binderFilesystem") and has("kwinWayland")) and (.access | has("sharesReady") and has("usbBusShared") and has("hostLink") and has("hostLinked")) and (.android | has("sessionRunning"))' >/dev/null
plan_output="$("$REPO_ROOT/linux/pz" waydroid plan)"
grep -q 'PhaseZero Waydroid plan' <<< "$plan_output"
boot_output="$("$REPO_ROOT/linux/pz" waydroid boot dry-run)"
grep -q 'one-shot boot' <<< "$boot_output"
grep -q 'pz_boot_validate_active_efi_safe' "$REPO_ROOT/linux/waydroid/waydroid.sh"
grep -q 'pz_boot_require_current_root_target' "$REPO_ROOT/linux/waydroid/waydroid.sh"
grep -q 'BOOT_ID="phasezero-waydroid"' "$REPO_ROOT/linux/waydroid/waydroid.sh"
grep -q -- "--hotkey=a" "$REPO_ROOT/linux/waydroid/waydroid.sh"
# shellcheck disable=SC2016 # literal: script must call grub-reboot "$BOOT_ID" verbatim
grep -q 'grub-reboot "$BOOT_ID"' "$REPO_ROOT/linux/waydroid/waydroid.sh"
target_status="$("$REPO_ROOT/linux/pz" waydroid boot --target-root / status)"
grep -q 'target_root: /' <<< "$target_status"
grep -q 'artifacts_current:' <<< "$target_status"

stale_env="$TMP_ROOT/waydroid-stale.env"
cat > "$stale_env" <<EOF
PZ_WAYDROID_REPO=/phasezero-live
PZ_WAYDROID_BOOT_USER=biglinux
EOF
fake_bin="$TMP_ROOT/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/waydroid" <<'EOF'
#!/usr/bin/env bash
[ -z "${PZ_WAYDROID_TEST_ARGS:-}" ] || printf '%s\n' "$*" >> "${PZ_WAYDROID_TEST_ARGS}.log"
if [ "${1:-}" = "status" ]; then
    printf '%s\n' "${PZ_WAYDROID_FAKE_STATUS:-Session: STOPPED
Container: STOPPED}"
fi
exit 0
EOF
chmod +x "$fake_bin/waydroid"

# CCS-005: container ativo + sessão parada — status expõe os dois fatos.
fake_systemctl="$fake_bin/systemctl"
cat > "$fake_systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    is-active) echo active ;;
    is-enabled) echo enabled ;;
esac
exit 0
EOF
chmod +x "$fake_systemctl"
mixed_status="$(PATH="$fake_bin:$PATH" "$REPO_ROOT/linux/pz" waydroid status --json | jq -c .android)"
jq -e '.serviceActive == "active" and .sessionRunning == false' <<< "$mixed_status" >/dev/null

# stop com sessão rodando chama session stop e reporta stopped.
stop_args="$TMP_ROOT/waydroid-stop-args"
stop_result="$(
    PATH="$fake_bin:$PATH" PZ_WAYDROID_FAKE_STATUS='Session: RUNNING' \
    PZ_WAYDROID_TEST_ARGS="$stop_args" "$REPO_ROOT/linux/pz" waydroid stop --json
)"
jq -e '.success == true and .state == "stopped"' <<< "$stop_result" >/dev/null
grep -Fxq 'session stop' "$stop_args.log"

# CCS-005: stop idempotente — sessão já parada é sucesso e não chama stop de novo.
idle_args="$TMP_ROOT/waydroid-idle-args"
rm -f "$idle_args.log"
idle_result="$(PATH="$fake_bin:$PATH" PZ_WAYDROID_TEST_ARGS="$idle_args" "$REPO_ROOT/linux/pz" waydroid stop --json)"
jq -e '.success == true and .state == "already-stopped"' <<< "$idle_result" >/dev/null
if [ -f "$idle_args.log" ] && grep -Fxq 'session stop' "$idle_args.log"; then
    echo "FAIL: stop idempotente chamou session stop sem sessão"
    exit 1
fi
session_validation="$(
    PATH="$fake_bin:$PATH" \
    PZ_WAYDROID_ENV_FILE="$stale_env" \
    PZ_WAYDROID_REPO_FALLBACK="$REPO_ROOT" \
    PZ_WAYDROID_SESSION_TARGET="$REPO_ROOT/linux/waydroid/waydroid-session.sh" \
    "$REPO_ROOT/linux/waydroid/waydroid-session.sh" --validate
)"
grep -q 'waydroid_session_ready=yes' <<< "$session_validation"
grep -q 'display_profile=' <<< "$session_validation"
grep -q 'compositor=' <<< "$session_validation"
if grep -q 'startkde-biglinux' "$REPO_ROOT/linux/waydroid/waydroid-session.sh"; then
    exit 1
fi
grep -q 'session_is_running' "$REPO_ROOT/linux/waydroid/waydroid-session.sh"
grep -q 'android_platform_ready' "$REPO_ROOT/linux/waydroid/waydroid-session.sh"
grep -q 'full UI accepted; monitoring Android session' "$REPO_ROOT/linux/waydroid/waydroid-session.sh"
grep -q 'PZ_WAYDROID_DESKTOP_FALLBACK' "$REPO_ROOT/linux/waydroid/waydroid-session.sh"
grep -q 'desktop fallback disabled' "$REPO_ROOT/linux/waydroid/waydroid-session.sh"

gamescope_args_file="$TMP_ROOT/waydroid-gamescope-args"
display_dmi="$TMP_ROOT/display-dmi"
display_sys="$TMP_ROOT/display-sys"
mkdir -p "$display_dmi" "$display_sys/class/drm/card1-eDP-1"
printf 'Jupiter\n' > "$display_dmi/product_name"
printf 'connected\n' > "$display_sys/class/drm/card1-eDP-1/status"
cat > "$fake_bin/dbus-run-session" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--" ] && shift
exec "$@"
EOF
cat > "$fake_bin/gamescope" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$gamescope_args_file"
exit 77
EOF
chmod +x "$fake_bin/dbus-run-session" "$fake_bin/gamescope"
gamescope_validation="$(
    env -u DISPLAY -u WAYLAND_DISPLAY \
    PATH="$fake_bin:/usr/bin:/bin" \
    PZ_DISPLAY_DMI_ROOT="$display_dmi" \
    PZ_DISPLAY_SYSFS_ROOT="$display_sys" \
    PZ_WAYDROID_ENV_FILE="$stale_env" \
    PZ_WAYDROID_REPO_FALLBACK="$REPO_ROOT" \
    PZ_WAYDROID_SESSION_TARGET="$REPO_ROOT/linux/waydroid/waydroid-session.sh" \
        "$REPO_ROOT/linux/waydroid/waydroid-session.sh" --validate
)"
grep -q 'display_profile=steamdeck-lcd-handheld' <<< "$gamescope_validation"
grep -q 'compositor=gamescope' <<< "$gamescope_validation"
grep -q -- '--force-orientation right' <<< "$gamescope_validation"
set +e
env -u DISPLAY -u WAYLAND_DISPLAY \
PATH="$fake_bin:/usr/bin:/bin" \
PZ_DISPLAY_DMI_ROOT="$display_dmi" \
PZ_DISPLAY_SYSFS_ROOT="$display_sys" \
PZ_WAYDROID_ENV_FILE="$stale_env" \
PZ_WAYDROID_REPO_FALLBACK="$REPO_ROOT" \
PZ_WAYDROID_SESSION_TARGET="$REPO_ROOT/linux/waydroid/waydroid-session.sh" \
    timeout 3 "$REPO_ROOT/linux/waydroid/waydroid-session.sh"
gamescope_rc=$?
set -e
test "$gamescope_rc" -eq 77
grep -q -- '--backend drm --expose-wayland --force-orientation right -W 1280 -H 800 -w 1280 -h 800 --force-windows-fullscreen --' "$gamescope_args_file"

shares_root="$TMP_ROOT/shares"
mkdir -p "$HOME/Desktop" "$HOME/Downloads" "$shares_root/sdcard" "$shares_root/removable" \
    "$shares_root/media" "$shares_root/mnt" "$shares_root/usb" "$shares_root/android"
printf '# base\n' > "$shares_root/config_base"
printf '# runtime\n' > "$shares_root/config"
shares_status="$(
    PZ_WAYDROID_SHARE_TEST_MODE=1 \
    PZ_WAYDROID_SHARE_SKIP_ACL=1 \
    PZ_WAYDROID_BOOT_USER="$(id -un)" \
    PZ_WAYDROID_TARGET_HOME="$HOME" \
    PZ_WAYDROID_LXC_SHARES_CONFIG="$shares_root/shares.conf" \
    PZ_WAYDROID_LXC_CONFIG_BASE="$shares_root/config_base" \
    PZ_WAYDROID_LXC_CONFIG="$shares_root/config" \
    PZ_WAYDROID_ANDROID_MEDIA_ROOT="$shares_root/android" \
    PZ_WAYDROID_SDCARD_PATH="$shares_root/sdcard" \
    PZ_WAYDROID_REMOVABLE_PATH="$shares_root/removable" \
    PZ_WAYDROID_MEDIA_PATH="$shares_root/media" \
    PZ_WAYDROID_MOUNTS_PATH="$shares_root/mnt" \
    PZ_WAYDROID_USB_BUS_PATH="$shares_root/usb" \
        "$REPO_ROOT/linux/waydroid/waydroid-shares-prepare.sh" install
)"
grep -q '^shares_ready: yes$' <<< "$shares_status"
grep -q '^usb_bus_shared: yes$' <<< "$shares_status"
grep -Fqx "lxc.include = $shares_root/shares.conf" "$shares_root/config_base"
grep -Fq ' data/media/0/Host/SDCard ' "$shares_root/shares.conf"
grep -Fq ' dev/bus/usb ' "$shares_root/shares.conf"
test -d "$shares_root/android/Host/SDCard"

sddm_test_dir="$TMP_ROOT/sddm"
PZ_BOOT_CMDLINE='quiet phasezero.waydroid=1' \
PZ_SDDM_CONF_DIR="$sddm_test_dir" \
PZ_WAYDROID_BOOT_USER=tester \
PZ_WAYDROID_SKIP_RUNTIME=1 \
PZ_WAYDROID_SHARES_HELPER="$TMP_ROOT/missing-shares-helper" \
    "$REPO_ROOT/linux/waydroid/waydroid-boot-prepare.sh"
grep -q '^User=tester$' "$sddm_test_dir/92-phasezero-waydroid.conf"
grep -q '^Session=phasezero-waydroid.desktop$' "$sddm_test_dir/92-phasezero-waydroid.conf"
PZ_BOOT_CMDLINE='quiet splash' \
PZ_SDDM_CONF_DIR="$sddm_test_dir" \
PZ_WAYDROID_SKIP_RUNTIME=1 \
PZ_WAYDROID_SHARES_HELPER="$TMP_ROOT/missing-shares-helper" \
    "$REPO_ROOT/linux/waydroid/waydroid-boot-prepare.sh"
test ! -e "$sddm_test_dir/92-phasezero-waydroid.conf"

PZ_DRY_RUN=1 "$REPO_ROOT/linux/pz" waydroid optimize >/dev/null
launch_output="$("$REPO_ROOT/linux/pz" waydroid launch --dry-run)"
grep -q 'Waydroid launcher dry-run' <<< "$launch_output"
"$REPO_ROOT/linux/pz" waydroid install >/dev/null
test -f "$XDG_CONFIG_HOME/phasezero/waydroid.conf"
test -f "$XDG_DATA_HOME/applications/phasezero-waydroid.desktop"
test -f "$XDG_CONFIG_HOME/systemd/user/phasezero-waydroid.service"
"$REPO_ROOT/linux/pz" waydroid status | jq -e '.config.installed == true and (.android | has("serviceActive")) and (.boot | has("grubCfgEntry"))' >/dev/null
"$REPO_ROOT/linux/pz" waydroid status | jq -e '.android.resumablePrefetch == true' >/dev/null
shares_plan="$("$REPO_ROOT/linux/pz" waydroid shares dry-run)"
grep -q 'Internal storage/Host' <<< "$shares_plan"
grep -q 'PZ_WAYDROID_SOURCEFORGE_MIRRORS' "$REPO_ROOT/linux/waydroid/waydroid.sh"
"$REPO_ROOT/linux/pz" install waydroid-linux --dry-run >/dev/null

echo "linux-waydroid smoke ok"
