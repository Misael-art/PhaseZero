#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux SteamOS-like UX.
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
find "$REPO_ROOT/linux" -type f -name '*.sh' -exec bash -n {} \;

jq empty "$REPO_ROOT"/profiles/*.json

display_root="$TMP_ROOT/display"
mkdir -p "$display_root/dmi" "$display_root/sys/class/drm/card1-eDP-1" "$display_root/sys/class/drm/card1-DP-1"
printf 'Jupiter\n' > "$display_root/dmi/product_name"
printf 'connected\n' > "$display_root/sys/class/drm/card1-eDP-1/status"
printf 'disconnected\n' > "$display_root/sys/class/drm/card1-DP-1/status"
display_profile="$(
    PZ_DISPLAY_DMI_ROOT="$display_root/dmi" \
    PZ_DISPLAY_SYSFS_ROOT="$display_root/sys" \
    bash -c ". '$REPO_ROOT/linux/steamdeck/display-session.sh'; pz_display_profile"
)"
test "$display_profile" = "steamdeck-lcd-handheld"
printf 'connected\n' > "$display_root/sys/class/drm/card1-DP-1/status"
display_profile="$(
    PZ_DISPLAY_DMI_ROOT="$display_root/dmi" \
    PZ_DISPLAY_SYSFS_ROOT="$display_root/sys" \
    bash -c ". '$REPO_ROOT/linux/steamdeck/display-session.sh'; pz_display_profile"
)"
test "$display_profile" = "steamdeck-docked"
printf 'GenericBox\n' > "$display_root/dmi/product_name"
display_profile="$(
    PZ_DISPLAY_DMI_ROOT="$display_root/dmi" \
    PZ_DISPLAY_SYSFS_ROOT="$display_root/sys" \
    bash -c ". '$REPO_ROOT/linux/steamdeck/display-session.sh'; pz_display_profile"
)"
test "$display_profile" = "generic"

"$REPO_ROOT/linux/pz" help >/dev/null
"$REPO_ROOT/linux/pz" steamdeck detect >/dev/null
"$REPO_ROOT/linux/pz" steamdeck keyboard status | jq -e '.provider' >/dev/null
PZ_DRY_RUN=1 "$REPO_ROOT/linux/pz" steamdeck keyboard repair >/dev/null
"$REPO_ROOT/linux/pz" steamdeck hotkeys dry-run >/dev/null
"$REPO_ROOT/linux/pz" steamdeck hotkeys status >/dev/null
"$REPO_ROOT/linux/pz" steamdeck watcher dry-run >/dev/null
"$REPO_ROOT/linux/pz" steamdeck watcher status >/dev/null
"$REPO_ROOT/linux/pz" steamdeck privileged dry-run >/dev/null
"$REPO_ROOT/linux/pz" steamdeck privileged status >/dev/null
"$REPO_ROOT/linux/pz" steamdeck boot dry-run >/dev/null
boot_plan="$("$REPO_ROOT/linux/pz" steamdeck boot plan)"
grep -q 'one-shot boot' <<< "$boot_plan"
grep -q 'phasezero-steamos.desktop' <<< "$boot_plan"
grep -q 'no global handheld input/video drop-in' <<< "$boot_plan"
grep -q 'GRUB_TERMINAL_INPUT="console usb_keyboard at_keyboard"' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh" && exit 1
grep -q 'usb_keyboard ehci ohci uhci at_keyboard' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh" && exit 1
grep -q 'pz_boot_preflight_grub' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
grep -q 'pz_boot_backup_bundle "steamdeck-boot-install"' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
grep -q 'pz_boot_validate_active_efi_safe' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
grep -q 'pz_boot_require_current_root_target' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
grep -q 'BOOT_ID="phasezero-steamos"' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
grep -q -- "--hotkey=s" "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
# shellcheck disable=SC2016 # literal "$BOOT_ID" text searched in script source
grep -q 'grub-reboot "$BOOT_ID"' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
grep -q 'startkde-biglinux wayland' "$REPO_ROOT/linux/steamdeck/steamos-session.sh"
grep -q 'session-target' "$REPO_ROOT/linux/steamdeck/os-session-select.sh"
test_sddm="$TMP_ROOT/sddm"
test_sessions="$TMP_ROOT/sessions"
mkdir -p "$test_sddm" "$test_sessions"
printf '[Desktop Entry]\nExec=true\n' > "$test_sessions/phasezero-steamos.desktop"
printf '# PhaseZero managed\n' > "$test_sddm/91-phasezero-windows-vm.conf"
printf '# PhaseZero managed\n' > "$test_sddm/92-phasezero-waydroid.conf"
PZ_BOOT_CMDLINE='quiet phasezero.steamos=1' PZ_SDDM_CONF_DIR="$test_sddm" PZ_WAYLAND_SESSION_DIR="$test_sessions" \
    bash "$REPO_ROOT/linux/steamdeck/steamos-boot-prepare.sh"
grep -q 'Session=phasezero-steamos.desktop' "$test_sddm/90-phasezero-steamos.conf"
test ! -e "$test_sddm/91-phasezero-windows-vm.conf"
test ! -e "$test_sddm/92-phasezero-waydroid.conf"
fake_gamescope="$TMP_ROOT/fake-gamescope"
fake_desktop="$TMP_ROOT/fake-desktop"
cat > "$fake_gamescope" <<'EOF'
#!/usr/bin/env bash
printf 'desktop\n' > "${XDG_RUNTIME_DIR}/phasezero-steamos/session-target"
EOF
cat > "$fake_desktop" <<'EOF'
#!/usr/bin/env bash
touch "${XDG_RUNTIME_DIR}/desktop-started"
EOF
chmod +x "$fake_gamescope" "$fake_desktop"
PZ_STEAMOS_GAMESCOPE_BIN="$fake_gamescope" PZ_STEAMOS_DESKTOP_BIN="$fake_desktop" \
    bash "$REPO_ROOT/linux/steamdeck/steamos-session.sh"
test -f "$XDG_RUNTIME_DIR/desktop-started"
PZ_STEAMOS_SKIP_STEAM_SHUTDOWN=1 bash "$REPO_ROOT/linux/steamdeck/os-session-select.sh" plasma
grep -q '^desktop$' "$XDG_RUNTIME_DIR/phasezero-steamos/session-target"
"$REPO_ROOT/linux/pz" steamdeck boot status >/dev/null
"$REPO_ROOT/linux/pz" steamdeck plugins status | jq -e '.desiredPlugins | length >= 5' >/dev/null
"$REPO_ROOT/linux/pz" steamdeck plugins status | jq -e '.desiredPlugins[] | select(.id == "PowerTools" and .installMode == "database")' >/dev/null
"$REPO_ROOT/linux/pz" steamdeck plugins status | jq -e '.desiredPlugins[] | select(.id == "PowerTools") | has("healthy") and has("healthIssue")' >/dev/null
"$REPO_ROOT/linux/pz" steamdeck plugins status | jq -e '.decky.service | has("dualServiceConflict")' >/dev/null
"$REPO_ROOT/linux/pz" steamdeck plugins theme status | jq -e '. | length >= 4' >/dev/null
"$REPO_ROOT/linux/pz" steamdeck plugins dry-run | grep -q 'Decky Loader'
"$REPO_ROOT/linux/pz" steamdeck plugins guide | grep -q 'PowerTools'
"$REPO_ROOT/linux/pz" steamdeck plugins guide | grep -q 'install-plugin-privileged'
"$REPO_ROOT/linux/pz" steamdeck plugins guide | grep -q 'install-plugins-privileged'
"$REPO_ROOT/linux/pz" steamdeck launch-options get balanced | grep -q 'MANGOHUD=1 gamemoderun %command%'
"$REPO_ROOT/linux/pz" steamdeck launch-options json | jq -e '.balanced == "MANGOHUD=1 gamemoderun %command%"' >/dev/null
runtime_fixture="$TMP_ROOT/steam-runtime.txt"
cat > "$runtime_fixture" <<'JSON'
"LD_* scout runtime" information:
{
  "steam-runtime-system-info": {"version": "test"},
  "can-write-uinput": true,
  "steam-installation": {"issues": []},
  "runtime": {"ok": true, "version": "test"},
  "architectures": {},
  "vulkan": {
    "implicit_layers": [
      {"name": "VK_LAYER_MANGOHUD_overlay_x86_64"},
      {"name": "VK_LAYER_FROG_gamescope_wsi_x86_64"},
      {"name": "VK_LAYER_VALVE_steam_overlay_64"}
    ]
  },
  "display": {"wayland-ok": true, "x11-type": "xwayland"},
  "xdg-portals": {"ok": true},
  "renderer": "AMD Custom GPU 0405 (RADV VANGOGH)"
}
JSON
"$REPO_ROOT/linux/pz" steamdeck runtime diagnose "$runtime_fixture" | jq -e '.status == "ok"' >/dev/null
"$REPO_ROOT/linux/pz" install steamdeck-linux --dry-run >/dev/null
"$REPO_ROOT/linux/pz" repair-plan >/dev/null

echo "linux-steamos-ux smoke ok"
