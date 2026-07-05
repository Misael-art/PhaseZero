#!/usr/bin/env bash
# doctor.sh - PhaseZero system diagnostics (30+ health checks)
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PASS=0 WARN=0 FAIL=0 ERROR=0 INFO=0
RESULTS=()

check() {
    local id="$1" desc="$2" status="$3" msg="$4"
    case "$status" in
        PASS) PASS=$((PASS + 1)) ;;
        WARN) WARN=$((WARN + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        ERROR) ERROR=$((ERROR + 1)) ;;
        INFO) INFO=$((INFO + 1)) ;;
    esac
    RESULTS+=("[$status] $id: $desc — $msg")
    echo "[$status] $desc"
}

header() { echo; echo "=== $1 ==="; }
footer() {
    echo
    echo "=== Summary ==="
    printf "PASS: %d  WARN: %d  FAIL: %d  ERROR: %d  INFO: %d\n" "$PASS" "$WARN" "$FAIL" "$ERROR" "$INFO"
    echo "Total: $((PASS + WARN + FAIL + ERROR + INFO)) checks"
    [ "$FAIL" -gt 0 ] && echo ">>> Some checks FAILED" || echo ">>> All checks passed"
}

header "System Info"
echo "Host:       $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || hostnamectl hostname)"
echo "Kernel:     $(uname -r)"
echo "OS:         $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
echo "Uptime:     $(uptime -p)"
echo "Shell:      $SHELL"
echo "CPU:        $(LANG=C lscpu 2>/dev/null | grep 'Model name' | head -1 | cut -d: -f2 | xargs || echo 'N/A')"

header "Memory"
total_mem_mb=$(free -m | awk '/Mem:/ {print $2 + 0}')
avail_mem_mb=$(free -m | awk '/Mem:/ {print $7 + 0}')
swap_total_mb=$(free -m | awk '/Swap:/ {print $2 + 0}')
total_mem_mb=${total_mem_mb:-0}; avail_mem_mb=${avail_mem_mb:-0}; swap_total_mb=${swap_total_mb:-0}
total_mem_gb=$((total_mem_mb / 1024))
avail_mem_gb=$((avail_mem_mb / 1024))
swap_total_gb=$((swap_total_mb / 1024))
[ "$total_mem_mb" -ge 4096 ] 2>/dev/null && check MEM01 "Total RAM >= 4GB" PASS "${total_mem_gb}GB" || check MEM01 "Total RAM >= 4GB" WARN "${total_mem_gb}GB"
[ "$avail_mem_mb" -ge 1024 ] 2>/dev/null && check MEM02 "Available RAM >= 1GB" PASS "${avail_mem_gb}GB" || check MEM02 "Available RAM >= 1GB" WARN "${avail_mem_gb}GB"
[ "$swap_total_mb" -ge 2048 ] 2>/dev/null && check MEM03 "Swap >= 2GB" PASS "${swap_total_gb}GB" || check MEM03 "Swap >= 2GB" WARN "${swap_total_gb}GB"

header "Disk"
LANG=C df -h --output=source,target,size,used,pcent 2>/dev/null | tail -n+2 > /tmp/pz_disk.txt
while IFS=' ' read -r dev target size used pct; do
    [ -z "$dev" ] && continue
    case "$target" in
        /tmp/.mount_*|/run/user/*|/var/lib/docker/overlay2/*/merged) continue ;;
    esac
    pct_num=${pct%\%}
    [ "$pct_num" -gt 90 ] 2>/dev/null && check "DISK_$(echo "$target" | tr / _)" "$target usage" FAIL "$pct used"
    [ "$pct_num" -le 90 ] 2>/dev/null && [ "$pct_num" -gt 80 ] 2>/dev/null && check "DISK_$(echo "$target" | tr / _)" "$target usage" WARN "$pct used"
done < /tmp/pz_disk.txt
rm -f /tmp/pz_disk.txt

root_pct=$(LANG=C df -h / | tail -1 | awk '{print $5}')
check DISK_ROOT "root partition usage" PASS "$root_pct"

root_fs=$(df -T / | tail -1 | awk '{print $2}')
[[ "$root_fs" =~ btrfs|ext4|xfs ]] && check FS01 "Root filesystem type" PASS "$root_fs" || check FS01 "Root filesystem type" WARN "$root_fs"

if command -v btrfs &>/dev/null && timeout 5 btrfs filesystem show / &>/dev/null 2>&1; then
    check FS02 "Btrfs available" PASS "yes"
fi

header "CPU / Temperature"
temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
temp_c=$((temp / 1000))
[ "$temp_c" -lt 85 ] && check CPU01 "CPU temperature < 85°C" PASS "${temp_c}°C" || check CPU01 "CPU temperature < 85°C" FAIL "${temp_c}°C"

load_1=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1 | xargs)
load_5=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f2 | xargs)
cpus=$(nproc)
awk -v loadavg="$load_1" -v cpus="$cpus" 'BEGIN { exit (loadavg < cpus ? 0 : 1) }' && check CPU02 "CPU load (1m) < cores" PASS "$load_1 / $cpus" || check CPU02 "CPU load (1m) < cores" WARN "$load_1 / $cpus"

header "GPU (AMD)"
lspci -nn | grep -qi "VGA.*AMD\|VGA.*ATI\|VanGogh" && check GPU01 "AMD GPU detected" PASS "VanGogh 0405" || check GPU01 "AMD GPU detected" WARN "not found"
[ -d /sys/class/drm/card1/device ] && check GPU02 "GPU device in sysfs" PASS "" || check GPU02 "GPU device in sysfs" FAIL ""

header "Network"
ping -c 1 -W 2 8.8.8.8 &>/dev/null && check NET01 "Internet connectivity" PASS "" || check NET01 "Internet connectivity" FAIL ""
command -v tailscale &>/dev/null && tailscale status 2>/dev/null | head -1 | grep -q "Connected" && check NET02 "Tailscale connected" PASS "" || check NET02 "Tailscale connected" WARN "not connected or not installed"

header "Services"
for svc in docker sshd NetworkManager bluetooth; do
    systemctl is-active "$svc" &>/dev/null && check "SVC_$svc" "$svc running" PASS "" || check "SVC_$svc" "$svc running" WARN "inactive"
done

header "Steam Deck"
product=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
[ "$product" = "Jupiter" ] && check SD01 "Steam Deck hardware" PASS "Jupiter" || check SD01 "Steam Deck hardware" WARN "not Jupiter"
command -v gamescope &>/dev/null && check SD02 "Gamescope installed" PASS "$(gamescope --version 2>&1 | head -1)" || check SD02 "Gamescope installed" FAIL ""
command -v steam &>/dev/null && check SD03 "Steam installed" PASS "" || check SD03 "Steam installed" FAIL ""

header "SteamOS UX"
command -v steam &>/dev/null && check UX01 "Steam client available" PASS "$(command -v steam)" || check UX01 "Steam client available" WARN "install steam"
command -v gamescope &>/dev/null && check UX02 "Gamescope available" PASS "$(command -v gamescope)" || check UX02 "Gamescope available" WARN "install gamescope"
command -v mangohud &>/dev/null && check UX03 "MangoHud available" PASS "$(command -v mangohud)" || check UX03 "MangoHud available" WARN "install mangohud"
command -v gamemoderun &>/dev/null && check UX04 "GameMode launcher available" PASS "$(command -v gamemoderun)" || check UX04 "GameMode launcher available" WARN "install gamemode"

vk_status="$(bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" status 2>/dev/null || echo '{}')"
if jq -e '.kde.supported == true and .kde.available == true and .kde.enabled == true and (.kde.inputMethod | test("maliit"))' <<< "$vk_status" >/dev/null 2>&1; then
    check UX05 "Virtual keyboard available" PASS "KDE/KWin + Maliit"
elif jq -e '.provider != "none"' <<< "$vk_status" >/dev/null 2>&1; then
    check UX05 "Virtual keyboard available" WARN "provider present but not fully configured; run: linux/pz steamdeck keyboard repair"
else
    check UX05 "Virtual keyboard available" WARN "install maliit-keyboard or run: linux/pz steamdeck keyboard repair"
fi

if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/sxhkd/sxhkdrc" ] || [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/swhkd/swhkdrc" ]; then
    check UX06 "Steam Deck hotkey config installed" PASS "found"
else
    check UX06 "Steam Deck hotkey config installed" WARN "run: linux/pz steamdeck hotkeys install"
fi

if systemctl --user is-active phasezero-steamdeck-hotkeys.service &>/dev/null; then
    check UX07 "Steam Deck hotkeys active" PASS "sxhkd service"
elif command -v qdbus6 &>/dev/null && qdbus6 org.kde.kglobalaccel 2>/dev/null | grep -q 'phasezero_.*_desktop'; then
    check UX07 "Steam Deck hotkeys active" PASS "KDE native shortcuts"
else
    check UX07 "Steam Deck hotkeys active" WARN "inactive or compositor-native shortcuts required"
fi

if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/phasezero-steamdeck-mode-watcher.service" ]; then
    check UX08 "Steam Deck mode watcher installed" PASS "user service"
else
    check UX08 "Steam Deck mode watcher installed" WARN "run: linux/pz steamdeck watcher install"
fi

systemctl --user is-active phasezero-steamdeck-mode-watcher.service &>/dev/null && check UX09 "Steam Deck mode watcher active" PASS "" || check UX09 "Steam Deck mode watcher active" WARN "not running"
command -v ryzenadj &>/dev/null && check UX10 "TDP control available" PASS "$(command -v ryzenadj)" || check UX10 "TDP control available" WARN "install ryzenadj for TDP limits"

priv_helper="/usr/local/lib/phasezero/steamdeck-privileged-control"
priv_dropin="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/phasezero-steamdeck-mode-watcher.service.d/10-privileged-controls.conf"
if [ -x "$priv_helper" ] && [ -f "$priv_dropin" ] && sudo -n "$priv_helper" status >/dev/null 2>&1; then
    check UX11 "Privileged TDP/GPU bridge installed" PASS "$priv_helper"
else
    check UX11 "Privileged TDP/GPU bridge installed" WARN "run: sudo linux/steamdeck/install-privileged-controls.sh install"
fi

steam_plus_fallback="${XDG_CONFIG_HOME:-$HOME/.config}/gamescope-session-plus/sessions.d/steam-plus"
if command -v opengamepadui >/dev/null 2>&1; then
    check UX12 "Steam Big Picture Plus OpenGamepadUI" PASS "$(command -v opengamepadui)"
elif [ -f "$steam_plus_fallback" ]; then
    check UX12 "Steam Big Picture Plus OpenGamepadUI" INFO "missing; user fallback starts Steam Big Picture without QAM overlay"
else
    check UX12 "Steam Big Picture Plus OpenGamepadUI" WARN "missing; install OpenGamepadUI or run: linux/pz steamdeck boot install"
fi

decky_status="$(bash "$PZ_ROOT/linux/steamdeck/plugins.sh" status 2>/dev/null || echo '{}')"
if jq -e '.decky.service.dualServiceConflict == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX13 "Decky Loader Big Picture integration" WARN "system and user plugin_loader services both active; run: linux/pz steamdeck plugins repair"
elif jq -e '.steamDeckExperience.deckyMenuReady == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX13 "Decky Loader Big Picture integration" PASS "loader + CEF debug ready"
elif jq -e '.decky.installed == true and .decky.service.active == true and .decky.cefRemoteDebuggingEnabled == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX13 "Decky Loader Big Picture integration" WARN "restart Steam/Gamepad UI so CEF debug port opens"
else
    check UX13 "Decky Loader Big Picture integration" WARN "run: linux/pz steamdeck plugins install"
fi

if jq -e '.steamDeckExperience.tdpPluginReady == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX14 "Decky PowerTools TDP plugin" PASS "privileged Decky service active"
elif jq -e '.desiredPlugins[] | select(.id == "PowerTools" and .installed == true and .healthy != true)' <<< "$decky_status" >/dev/null 2>&1; then
    check UX14 "Decky PowerTools TDP plugin" WARN "PowerTools incomplete; run: linux/pz steamdeck plugins install-plugin-privileged PowerTools"
elif jq -e '.desiredPlugins[] | select(.id == "PowerTools" and .installed == true)' <<< "$decky_status" >/dev/null 2>&1 &&
    jq -e '.steamDeckExperience.tdpFallbackReady == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX14 "Decky PowerTools TDP plugin" INFO "PowerTools installed; plugin TDP needs privileged Decky, PhaseZero ryzenadj fallback ready"
else
    check UX14 "Decky PowerTools TDP plugin" WARN "run: linux/pz steamdeck plugins install-plugins"
fi

if jq -e '.steamDeckExperience.themePluginReady == true and ([.desiredThemes[] | select(.installed == true)] | length > 0)' <<< "$decky_status" >/dev/null 2>&1; then
    check UX15 "Decky CSS Loader themes" PASS "CSS Loader + themes installed"
else
    check UX15 "Decky CSS Loader themes" WARN "run: linux/pz steamdeck plugins install-themes"
fi

if jq -e '[.desiredPlugins[] | select(.installed == true and .healthy != true)] | length == 0' <<< "$decky_status" >/dev/null 2>&1; then
    check UX16 "Decky plugin package health" PASS "all installed curated plugins have runnable package layout"
else
    bad_plugins="$(jq -r '[.desiredPlugins[] | select(.installed == true and .healthy != true) | .id] | join(", ")' <<< "$decky_status" 2>/dev/null || true)"
    check UX16 "Decky plugin package health" WARN "repair incomplete plugins: ${bad_plugins:-unknown}"
fi

if [ -x /usr/local/lib/phasezero/steamos-session ] &&
    [ -x /usr/lib/os-session-select ] &&
    [ -f /usr/share/wayland-sessions/phasezero-steamos.desktop ]; then
    check UX17 "SteamOS desktop handoff without login" PASS "managed session + os-session-select hook"
else
    check UX17 "SteamOS desktop handoff without login" WARN "run: sudo linux/steamdeck/install-steamos-boot.sh install"
fi

header "Windows VM"
winvm_status="$(bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" status 2>/dev/null || echo '{}')"
if jq -e '.host.qemu != "" and .host.qemuImg != ""' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM01 "QEMU available" PASS "$(jq -r '.host.qemu' <<< "$winvm_status")"
else
    check WINVM01 "QEMU available" WARN "run: linux/pz install windows-vm-linux --dry-run"
fi
if jq -e '.host.kvm == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM02 "KVM device available" PASS "/dev/kvm"
else
    check WINVM02 "KVM device available" WARN "enable virtualization or fix /dev/kvm permissions"
fi
if jq -e '.host.ovmfCodeExists == true and .host.swtpm != ""' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM03 "Windows 11 firmware/TPM ready" PASS "OVMF + swtpm"
else
    check WINVM03 "Windows 11 firmware/TPM ready" WARN "install edk2-ovmf and swtpm"
fi
if jq -e '.config.installed == true and .vm.diskExists == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM04 "Windows VM configured" PASS "$(jq -r '.vm.disk' <<< "$winvm_status")"
else
    check WINVM04 "Windows VM configured" INFO "run: linux/pz windows-vm install --iso /path/to/Win11.iso"
fi
if jq -e '.libvirt.preferred == true and .libvirt.domain != ""' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM08 "Existing libvirt Windows domain selected" PASS "$(jq -r '.libvirt.domain + " (" + .libvirt.state + ")"' <<< "$winvm_status")"
else
    check WINVM08 "Existing libvirt Windows domain selected" INFO "no Windows domain; QEMU disk path will be used"
fi
if jq -e '.discovery.discoveredInstalledDisk.installedLike == true and .discovery.discoveredInstalledDisk.usable != true' <<< "$winvm_status" >/dev/null 2>&1; then
    blocked_disk="$(jq -r '.discovery.discoveredInstalledDisk.path' <<< "$winvm_status")"
    check WINVM07 "Existing Windows VM install usable" WARN "permission blocked: sudo linux/windows-vm/windows-vm.sh adopt --disk '$blocked_disk'"
elif jq -e '.discovery.discoveredUsableDisk.usable == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM07 "Existing Windows VM install usable" PASS "$(jq -r '.discovery.discoveredUsableDisk.path' <<< "$winvm_status")"
fi
if jq -e '.host.smbd != "" and .host.virtiofsd != ""' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM05 "Host folder sharing available" PASS "SMB + virtiofs"
else
    check WINVM05 "Host folder sharing available" WARN "install samba and virtiofsd/qemu"
fi
if jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and .boot.grubCfgEntry == "present"' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM06 "Windows VM direct GRUB boot installed" PASS "boot artifacts current"
elif jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and .boot.grubCfgEntry == "unknown-permission"' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM06 "Windows VM direct GRUB boot installed" INFO "artifacts current; generated GRUB entry needs privileged verification"
else
    check WINVM06 "Windows VM direct GRUB boot installed" WARN "run: sudo linux/windows-vm/windows-vm.sh boot install"
fi

header "Waydroid"
waydroid_status="$(bash "$PZ_ROOT/linux/waydroid/waydroid.sh" status 2>/dev/null || echo '{}')"
if jq -e '.host.waydroid != ""' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID01 "Waydroid command available" PASS "$(jq -r '.host.waydroid' <<< "$waydroid_status")"
else
    check WAYDROID01 "Waydroid command available" WARN "run: linux/pz install waydroid-linux --dry-run"
fi
if jq -e '.host.binderFilesystem == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID02 "Binder filesystem available" PASS "kernel supports binder"
else
    check WAYDROID02 "Binder filesystem available" WARN "load binder_linux or use a kernel with binder support"
fi
if jq -e '.host.binderDevices == true and .host.binderMounted == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID03 "Binder devices mounted" PASS "binder device present"
else
    check WAYDROID03 "Binder devices mounted" WARN "run: sudo linux/waydroid/waydroid.sh repair"
fi
if jq -e '.host.cage != "" or .host.kwinWayland != "" or .host.weston != ""' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID04 "Wayland kiosk compositor available" PASS "cage/kwin/weston"
else
    check WAYDROID04 "Wayland kiosk compositor available" WARN "install cage or kwin_wayland"
fi
if jq -e '.android.serviceEnabled == "enabled" or .android.serviceActive == "active"' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID05 "Waydroid container service configured" PASS "$(jq -r '.android.serviceActive' <<< "$waydroid_status")"
else
    check WAYDROID05 "Waydroid container service configured" INFO "run: sudo linux/waydroid/waydroid.sh repair"
fi
if jq -e '.android.initialized == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID06 "Waydroid Android image initialized" PASS "image present"
else
    check WAYDROID06 "Waydroid Android image initialized" INFO "optional: sudo linux/waydroid/waydroid.sh repair --init"
fi
if jq -e '.android.resumablePrefetch == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID08 "Waydroid image download resilience" PASS "mirror fallback + size/SHA-256 validation"
else
    check WAYDROID08 "Waydroid image download resilience" WARN "reinstall current Waydroid automation"
fi
if jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and .boot.grubCfgEntry == "present"' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID07 "Waydroid direct GRUB boot installed" PASS "boot artifacts current"
elif jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and .boot.grubCfgEntry == "unknown-permission"' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID07 "Waydroid direct GRUB boot installed" INFO "artifacts current; generated GRUB entry needs privileged verification"
else
    check WAYDROID07 "Waydroid direct GRUB boot installed" WARN "run: sudo linux/waydroid/waydroid.sh boot install"
fi
if jq -e '.android.lxcPostStopHookSafe == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID09 "Waydroid LXC stop hook" PASS "executable no-op hook"
else
    check WAYDROID09 "Waydroid LXC stop hook" WARN "run: sudo linux/waydroid/waydroid.sh repair"
fi

header "Emulation"
emulation_root="${PZ_EMULATION_ROOT:-$HOME/Emulation}"
applications_dir="${PZ_APPLICATIONS_DIR:-$HOME/Applications}"
emudeck_app="$applications_dir/EmuDeck.AppImage"
eden_app="$applications_dir/Eden.AppImage"
hydra_app="$applications_dir/Hydra.AppImage"
hydra_classic_config="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/config.json"
hydra_emulators_config="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/emulators_config.json"
[ -d "$emulation_root" ] && check EMU01 "Shared emulation root" PASS "$emulation_root" || check EMU01 "Shared emulation root" WARN "run: linux/pz emulation layout"
emudeck_status="$(bash "$PZ_ROOT/linux/emulation/emudeck.sh" status 2>/dev/null || echo '{}')"
if jq -e '.launcher.installed == true and .launcher.kind == "steamdeck-desktop"' <<< "$emudeck_status" >/dev/null 2>&1; then
    emudeck_launcher="$(jq -r '.launcher.path' <<< "$emudeck_status")"
    check EMU02 "EmuDeck Steam Deck launcher installed" PASS "$emudeck_launcher"
elif jq -e '.appImageInstalled == true' <<< "$emudeck_status" >/dev/null 2>&1 || [ -x "$emudeck_app" ]; then
    check EMU02 "EmuDeck AppImage installed" PASS "$emudeck_app"
else
    check EMU02 "EmuDeck launcher installed" WARN "run: linux/pz emulation emudeck install"
fi
[ -x "$eden_app" ] && check EMU03 "Eden AppImage installed" PASS "$eden_app" || check EMU03 "Eden AppImage installed" WARN "run: linux/pz emulation eden install"
[ -x "$hydra_app" ] && check EMU06 "Hydra AppImage installed" PASS "$hydra_app" || check EMU06 "Hydra AppImage installed" WARN "run: linux/pz emulation hydra install"
if python3 "$PZ_ROOT/linux/emulation/steam-shortcut.py" status --app-name Hydra >/dev/null 2>&1; then
    check EMU07 "Hydra Steam shortcut installed" PASS "Steam userdata"
else
    check EMU07 "Hydra Steam shortcut installed" WARN "run: linux/pz emulation hydra steam-shortcut"
fi
if [ -f "$hydra_classic_config" ] && jq -e '.displayClassicContent == true and .enableRetroUIFeatures == true' "$hydra_classic_config" >/dev/null 2>&1; then
    check EMU08 "Hydra Classic flags enabled" PASS "$hydra_classic_config"
else
    check EMU08 "Hydra Classic flags enabled" WARN "run: linux/pz emulation hydra classic-config"
fi
if [ -f "$hydra_emulators_config" ] && jq -e 'length > 0' "$hydra_emulators_config" >/dev/null 2>&1; then
    hydra_emulator_count="$(jq 'length' "$hydra_emulators_config" 2>/dev/null || echo 0)"
    check EMU09 "Hydra emulator mappings configured" PASS "${hydra_emulator_count} systems"
elif [ -x "$applications_dir/DuckStation.AppImage" ] || [ -x "$applications_dir/pcsx2-Qt.AppImage" ] || [ -x "$applications_dir/rpcs3.AppImage" ]; then
    check EMU09 "Hydra emulator mappings configured" WARN "run: linux/pz emulation hydra emulators-config"
else
    check EMU09 "Hydra emulator mappings configured" INFO "install DuckStation/PCSX2/RPCS3 then run: linux/pz emulation hydra emulators-config"
fi
if [ -d "$emulation_root/bios" ]; then
    bios_count=$(find "$emulation_root/bios" -type f 2>/dev/null | wc -l | tr -d ' ')
    check EMU04 "Local BIOS import folder" PASS "${bios_count} files"
else
    check EMU04 "Local BIOS import folder" WARN "run: linux/pz emulation layout"
fi
if [ -f "$emulation_root/firmware/switch/keys/prod.keys" ]; then
    check EMU05 "Switch keys imported locally" PASS "prod.keys present"
else
    check EMU05 "Switch keys imported locally" INFO "optional: linux/pz emulation switch import-keys <owned-dump-path>"
fi
srm_status="$(bash "$PZ_ROOT/linux/emulation/srm.sh" status 2>/dev/null || echo '{}')"
if jq -e '.configured == true' <<< "$srm_status" >/dev/null 2>&1; then
    srm_count="$(jq -r '.managedParsers // 0' <<< "$srm_status")"
    check EMU10 "Steam ROM Manager paths configured" PASS "${srm_count} managed parsers"
elif jq -e '.appImageInstalled == true or .launcherInstalled == true' <<< "$srm_status" >/dev/null 2>&1; then
    check EMU10 "Steam ROM Manager paths configured" WARN "run: linux/pz emulation srm configure"
else
    check EMU10 "Steam ROM Manager available" INFO "optional: install via EmuDeck"
fi
ps3_status="$(bash "$PZ_ROOT/linux/emulation/ps3.sh" status 2>/dev/null || echo '{}')"
if jq -e '.vfsConfigured == true' <<< "$ps3_status" >/dev/null 2>&1; then
    ps3_games="$(jq -r '.gameEntries // 0' <<< "$ps3_status")"
    ps3_pkg="$(jq -r '.pkgFiles // 0' <<< "$ps3_status")"
    ps3_rap="$(jq -r '.rapFiles // 0' <<< "$ps3_status")"
    check EMU11 "RPCS3 PS3 paths configured" PASS "games=${ps3_games} pkg=${ps3_pkg} rap=${ps3_rap}"
else
    check EMU11 "RPCS3 PS3 paths configured" WARN "run: linux/pz emulation ps3 configure"
fi
shortcut_status="$(bash "$PZ_ROOT/linux/emulation/shortcuts.sh" status --json 2>/dev/null || echo '{}')"
if jq -e '.status == "ok"' <<< "$shortcut_status" >/dev/null 2>&1; then
    shortcut_count="$(jq -r '[.checks[]? | select(.status == "ok")] | length' <<< "$shortcut_status")"
    check EMU12 "Desktop AppImage launchers clean" PASS "${shortcut_count} managed launchers"
else
    shortcut_warns="$(jq -r '[.checks[]? | select(.status == "warn")] | length' <<< "$shortcut_status" 2>/dev/null || echo 0)"
    check EMU12 "Desktop AppImage launchers clean" WARN "${shortcut_warns} issue(s); run: linux/pz emulation shortcuts repair"
fi
performance_status="$(bash "$PZ_ROOT/linux/emulation/performance.sh" status 2>/dev/null || echo '{}')"
if jq -e '.configValid == true and .runtimeInstalled == true and .profiles.switch.lsfg == "auto" and .profiles.ps3.lsfg == "auto" and .profiles.ps4.lsfg == "auto"' <<< "$performance_status" >/dev/null 2>&1; then
    check EMU13 "Adaptive emulator profiles" PASS "Switch/PS3/PS4 auto profiles active"
else
    check EMU13 "Adaptive emulator profiles" WARN "run: linux/pz emulation performance apply"
fi
if jq -e '.lsfg.ready == true' <<< "$performance_status" >/dev/null 2>&1; then
    check EMU14 "LSFG Vulkan frame generation" PASS "verified local layer ready"
elif jq -e '.lsfg.deckyPluginInstalled == true and .lsfg.losslessScalingInstalled == true' <<< "$performance_status" >/dev/null 2>&1; then
    check EMU14 "LSFG Vulkan frame generation" WARN "run: linux/pz emulation performance prepare-lsfg"
else
    check EMU14 "LSFG Vulkan frame generation" INFO "optional; needs Decky LSFG-VK plus owned Lossless Scaling"
fi

header "Lua Runtime"
command -v lua >/dev/null 2>&1 && check LUA01 "Lua installed" PASS "$(lua -v 2>&1 | head -1)" || check LUA01 "Lua installed" WARN "run: linux/pz emulation lua install"
command -v lua5.4 >/dev/null 2>&1 && check LUA02 "Lua 5.4 installed" PASS "$(lua5.4 -v 2>&1 | head -1)" || check LUA02 "Lua 5.4 installed" WARN "run: linux/pz emulation lua install"
command -v luajit >/dev/null 2>&1 && check LUA03 "LuaJIT installed" PASS "$(luajit -v 2>&1 | head -1)" || check LUA03 "LuaJIT installed" WARN "run: linux/pz emulation lua install"
command -v luarocks >/dev/null 2>&1 && check LUA04 "LuaRocks installed" PASS "$(luarocks --version 2>/dev/null | head -1 | xargs)" || check LUA04 "LuaRocks installed" WARN "run: linux/pz emulation lua install"

header "Steam Tools"
command -v protontricks >/dev/null 2>&1 && check ST01 "Protontricks installed" PASS "$(command -v protontricks)" || check ST01 "Protontricks installed" WARN "run: linux/pz emulation steam-tools install"
command -v protonup-qt >/dev/null 2>&1 && check ST02 "ProtonUp-Qt installed" PASS "$(command -v protonup-qt)" || check ST02 "ProtonUp-Qt installed" WARN "run: linux/pz emulation steam-tools install"
if command -v retroarch >/dev/null 2>&1; then
    check ST03 "RetroArch installed" PASS "$(command -v retroarch)"
elif command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1; then
    check ST03 "RetroArch installed" PASS "flatpak"
else
    check ST03 "RetroArch installed" WARN "run: linux/pz emulation steam-tools install"
fi
if command -v ludusavi >/dev/null 2>&1; then
    check ST04 "Ludusavi available" PASS "$(command -v ludusavi)"
elif command -v flatpak >/dev/null 2>&1 && flatpak info com.github.mtkennerly.ludusavi >/dev/null 2>&1; then
    check ST04 "Ludusavi available" PASS "flatpak"
else
    check ST04 "Ludusavi available" INFO "optional save backup tool"
fi
if command -v steam-rom-manager >/dev/null 2>&1 || find "$applications_dir" -maxdepth 1 -iname '*steam*rom*manager*.AppImage' -type f -perm -u+x 2>/dev/null | grep -q .; then
    check ST05 "Steam ROM Manager available" PASS "found"
else
    check ST05 "Steam ROM Manager available" INFO "optional; EmuDeck may manage SRM internally"
fi
if command -v boilr >/dev/null 2>&1 || find "$applications_dir" -maxdepth 1 -iname '*boilr*.AppImage' -type f -perm -u+x 2>/dev/null | grep -q .; then
    check ST06 "BoilR available" PASS "found"
else
    check ST06 "BoilR available" INFO "optional non-Steam importer"
fi
command -v steamtinkerlaunch >/dev/null 2>&1 && check ST07 "SteamTinkerLaunch available" PASS "$(command -v steamtinkerlaunch)" || check ST07 "SteamTinkerLaunch available" INFO "optional Proton/Wine per-game tool"

header "SteamOS Boot"
boot_status="$(bash "$PZ_ROOT/linux/steamdeck/install-steamos-boot.sh" status 2>/dev/null || true)"
boot_entry_state="$(awk -F': ' '$1 == "grub_cfg_entry" {print $2; exit}' <<< "$boot_status")"
if [ -x /usr/local/lib/phasezero/steamos-boot-prepare ] && [ -x /etc/grub.d/42_phasezero_steamos ] && [ "$boot_entry_state" = "present" ]; then
    check BOOT01 "PhaseZero SteamOS GRUB entry installed" PASS "one-shot boot ready"
elif [ -x /usr/local/lib/phasezero/steamos-boot-prepare ] && [ -x /etc/grub.d/42_phasezero_steamos ] && [ "$boot_entry_state" = "unknown-permission" ]; then
    check BOOT01 "PhaseZero SteamOS GRUB entry installed" INFO "installed; run sudo linux/steamdeck/install-steamos-boot.sh status to verify grub.cfg"
elif [ -x /usr/local/lib/phasezero/steamos-boot-prepare ] && [ -x /etc/grub.d/42_phasezero_steamos ]; then
    check BOOT01 "PhaseZero SteamOS GRUB entry installed" WARN "grub_cfg_entry=${boot_entry_state:-unknown}; run: sudo linux/steamdeck/install-steamos-boot.sh install"
else
    check BOOT01 "PhaseZero SteamOS GRUB entry installed" INFO "optional: sudo linux/steamdeck/install-steamos-boot.sh install"
fi
boot_recovery_status="$(bash "$PZ_ROOT/linux/boot/recovery.sh" status 2>/dev/null || true)"
boot_recovery_card="$(awk -F': ' '$1 ~ /recovery_card$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_phasezero_efi="$(awk -F': ' '$1 ~ /phasezero_efi$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_active_efi="$(awk -F': ' '$1 ~ /active_efi$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_active_efi_prefix="$(awk -F': ' '$1 ~ /active_efi_prefix$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_safe_menu_profile="$(awk -F': ' '$1 ~ /safe_menu_profile$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_safe_menu_timeout="$(awk -F': ' '$1 ~ /safe_menu_timeout$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_emergency_entry="$(awk -F': ' '$1 ~ /emergency_shell_entry$/ {print $2; exit}' <<< "$boot_recovery_status")"
if [ -n "$boot_recovery_card" ] && [ "$boot_recovery_card" != "missing" ]; then
    check BOOT02 "GRUB rescue card available" PASS "$boot_recovery_card"
else
    check BOOT02 "GRUB rescue card available" INFO "optional: sudo linux/pz boot install-card"
fi
if [[ "$boot_phasezero_efi" == permission-denied* ]]; then
    check BOOT03 "PhaseZero standalone EFI fallback available" INFO "permission denied; verify with: sudo linux/pz boot status"
elif [ -n "$boot_phasezero_efi" ] && [ "$boot_phasezero_efi" != "missing" ]; then
    check BOOT03 "PhaseZero standalone EFI fallback available" PASS "$boot_phasezero_efi"
else
    check BOOT03 "PhaseZero standalone EFI fallback available" INFO "optional: sudo linux/pz boot install-efi-fallback"
fi
case "$boot_active_efi_prefix" in
    safe) check BOOT05 "Active EFI GRUB prefix safe" PASS "$boot_active_efi" ;;
    dangerous) check BOOT05 "Active EFI GRUB prefix safe" FAIL "dangerous disk-order prefix in $boot_active_efi; run: sudo linux/pz boot install-efi-fallback --active --fallback" ;;
    permission-denied) check BOOT05 "Active EFI GRUB prefix safe" INFO "permission denied; verify with: sudo linux/pz boot status" ;;
    *) check BOOT05 "Active EFI GRUB prefix safe" INFO "unknown; verify with: sudo linux/pz boot status" ;;
esac
case "$boot_safe_menu_profile" in
    installed*) check BOOT06 "GRUB menu visible with safe timeout" PASS "${boot_safe_menu_timeout:-installed}" ;;
    permission-denied*) check BOOT06 "GRUB menu visible with safe timeout" INFO "permission denied; verify with: sudo linux/pz boot status" ;;
    *) check BOOT06 "GRUB menu visible with safe timeout" WARN "run: sudo linux/pz boot install-safe-menu" ;;
esac
if [ "$boot_emergency_entry" = "installed" ]; then
    check BOOT04 "Emergency shell GRUB entry inactive" WARN "temporary entry installed; clear after use: sudo linux/pz boot emergency-shell clear"
else
    check BOOT04 "Emergency shell GRUB entry inactive" PASS "not installed"
fi

header "Security"
systemctl is-active ufw &>/dev/null && check SEC01 "UFW firewall active" PASS "" || check SEC01 "UFW firewall active" WARN "inactive"
systemctl is-active sshd &>/dev/null && check SEC02 "SSH server running" PASS "" || check SEC02 "SSH server running" INFO "disabled (ok if not needed)"

header "Containers"
timeout 5 docker ps &>/dev/null && check DOCKER01 "Docker daemon accessible" PASS "" || check DOCKER01 "Docker daemon accessible" FAIL ""
docker_compose_ver=$(timeout 5 docker compose version 2>/dev/null | head -1) && check DOCKER02 "Docker Compose" PASS "${docker_compose_ver:-installed}" || check DOCKER02 "Docker Compose" FAIL ""

header "Development"
tool_path() {
    local tool="$1"
    command -v "$tool" 2>/dev/null || {
        [ -x "$HOME/.cargo/bin/$tool" ] && echo "$HOME/.cargo/bin/$tool" && return 0
        [ -x "$HOME/go/bin/$tool" ] && echo "$HOME/go/bin/$tool" && return 0
        return 1
    }
}
for tool in node npm python3 rustc cargo go jq git gh; do
    tool_bin="$(tool_path "$tool" || true)"
    if [ -n "$tool_bin" ]; then
        case "$tool" in
            go) ver=$("$tool_bin" version 2>/dev/null | head -1) ;;
            *) ver=$("$tool_bin" --version 2>/dev/null | head -1) ;;
        esac
        [ -n "$ver" ] && check "DEV_$tool" "$tool installed" PASS "$ver" || check "DEV_$tool" "$tool installed" FAIL "$tool_bin"
    else
        check "DEV_$tool" "$tool installed" FAIL ""
    fi
done
if command -v git-lfs >/dev/null 2>&1; then
    check DEV_git-lfs "git-lfs installed" PASS "$(git-lfs --version 2>/dev/null | head -1)"
else
    check DEV_git-lfs "git-lfs installed" WARN ""
fi

header "AI Tools"
ai_status="$(bash "$PZ_ROOT/linux/ai/status.sh" 2>/dev/null || echo '{}')"
for tool in codex claude opencode hermes openclaw ollama; do
    if jq -e --arg tool "$tool" '.clis[$tool].available == true' <<< "$ai_status" >/dev/null 2>&1; then
        ai_path="$(jq -r --arg tool "$tool" '.clis[$tool].path' <<< "$ai_status")"
        check "AI_$tool" "$tool installed" PASS "$ai_path"
    else
        case "$tool" in
            codex) check "AI_$tool" "$tool installed" INFO "optional; install Codex CLI through its official flow" ;;
            *) check "AI_$tool" "$tool installed" WARN "run: linux/pz ai setup $tool" ;;
        esac
    fi
done
if jq -e '.desktopApps.claudeDesktop.installed == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CLAUDE_DESKTOP "Claude Desktop installed" PASS "$(jq -r '.desktopApps.claudeDesktop.version' <<< "$ai_status")"
else
    check AI_CLAUDE_DESKTOP "Claude Desktop installed" WARN "run: linux/pz ai desktop install-claude"
fi
if jq -e '.desktopApps.codexDesktop.updateStatus != "failed"' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CODEX_DESKTOP_UPDATE "Codex Desktop updater healthy" PASS "$(jq -r '.desktopApps.codexDesktop.updateStatus' <<< "$ai_status")"
else
    check AI_CODEX_DESKTOP_UPDATE "Codex Desktop updater healthy" FAIL "run: linux/pz ai desktop repair-codex"
fi
if jq -e '.desktopApps.codexDesktop.guardEnabled == true and .desktopApps.updater.timerEnabled == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_DESKTOP_UPDATE_TIMER "AI desktop automatic updates enabled" PASS "user timer + Codex guard"
else
    check AI_DESKTOP_UPDATE_TIMER "AI desktop automatic updates enabled" WARN "run: linux/pz ai desktop install-services"
fi
if jq -e '.github.installed == true and .github.authenticated == true' <<< "$ai_status" >/dev/null 2>&1; then
    check DEV_GITHUB_AUTH "GitHub CLI authenticated" PASS "gh auth status"
elif jq -e '.github.installed == true' <<< "$ai_status" >/dev/null 2>&1; then
    check DEV_GITHUB_AUTH "GitHub CLI authenticated" INFO "optional: gh auth login"
else
    check DEV_GITHUB_AUTH "GitHub CLI authenticated" WARN "run: sudo pacman -S github-cli"
fi
if jq -e '.agentConfigs.hermes.mcpServerCount > 0' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_HERMES_MCP "Hermes MCP configured" PASS "$(jq -r '.agentConfigs.hermes.path' <<< "$ai_status")"
else
    check AI_HERMES_MCP "Hermes MCP configured" WARN "run: linux/pz ai setup hermes"
fi
if jq -e '.agentConfigs.openclaw.mcpServerCount > 0' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_OPENCLAW_MCP "OpenClaw MCP configured" PASS "$(jq -r '.agentConfigs.openclaw.path' <<< "$ai_status")"
else
    check AI_OPENCLAW_MCP "OpenClaw MCP configured" WARN "run: linux/pz ai setup openclaw"
fi
if jq -e '.services.openclaw.active == true or .services["openclaw-gateway"].active == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_OPENCLAW_DAEMON "OpenClaw daemon active" PASS "user service"
else
    check AI_OPENCLAW_DAEMON "OpenClaw daemon active" INFO "optional: linux/ai/setup-openclaw.sh daemon"
fi
if jq -e '.memory.installed == true' <<< "$ai_status" >/dev/null 2>&1; then
    jq -e '.memory.serverReachable == true or .memory.configuredMarker == true or .memory.userServiceActive == true' <<< "$ai_status" >/dev/null 2>&1 &&
        check AI_MEMORY "ai-memory configured" PASS "$(jq -r '.memory.serverUrl' <<< "$ai_status")" ||
        check AI_MEMORY "ai-memory configured" WARN "run: linux/pz ai setup memory"
else
    check AI_MEMORY "ai-memory installed" WARN "run: linux/pz ai setup memory"
fi
if jq -e '.compatibility.rtkAvailable == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_RTK "RTK available" PASS "$(jq -r '.clis.rtk.path' <<< "$ai_status")"
else
    check AI_RTK "RTK available" WARN "run: linux/pz ai setup rtk"
fi
if jq -e '.agentCompat.tools.caveman.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CAVEMAN "Caveman/PhaseZero rules configured" PASS "$(jq -r '.agentCompat.rules.files | length' <<< "$ai_status") files"
else
    check AI_CAVEMAN "Caveman/PhaseZero rules configured" WARN "run: linux/pz ai setup caveman"
fi
if jq -e '.agentCompat.tools.headroom.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_HEADROOM "Headroom available" PASS "$(jq -r '.agentCompat.tools.headroom.path' <<< "$ai_status")"
else
    check AI_HEADROOM "Headroom available" WARN "run: linux/pz ai setup headroom"
fi
if jq -e '.agentCompat.tools.aiContextFrugality.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CONTEXT_FRUGALITY "AI context frugality pack configured" PASS ".codex/ai-context"
else
    check AI_CONTEXT_FRUGALITY "AI context frugality pack configured" WARN "run: linux/pz ai setup frugality"
fi
if jq -e '.adminBridge.ready == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_ADMIN_BRIDGE "Admin escalation bridge ready" PASS "$(jq -r '.adminBridge.backend' <<< "$ai_status")"
else
    check AI_ADMIN_BRIDGE "Admin escalation bridge ready" WARN "run: linux/pz ai setup admin"
fi
if jq -e '.agentCompat.tools.ponytail.status == "active"' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_PONYTAIL "Ponytail workspace rules" PASS "active"
else
    check AI_PONYTAIL "Ponytail workspace rules" INFO "inactive; only applied in Ponytail workspaces"
fi
if jq -e '.agentCompat.tools.graphify.placeholder == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_GRAPHIFY "Graphify placeholder" INFO "not configured; safe placeholder"
fi
if jq -e '.mcp.definitions | length > 0' <<< "$ai_status" >/dev/null 2>&1; then
    mcp_defs="$(jq -r '.mcp.definitions | length' <<< "$ai_status")"
    mcp_targets="$(jq -r '[.mcp.targets[]?.count // 0] | add // 0' <<< "$ai_status")"
    [ "$mcp_targets" -gt 0 ] 2>/dev/null &&
        check AI_MCP "MCP definitions synced" PASS "definitions=${mcp_defs} installed=${mcp_targets}" ||
        check AI_MCP "MCP definitions synced" WARN "run: linux/pz ai mcp sync"
else
    check AI_MCP "MCP definitions available" WARN "assets/mcp/servers missing"
fi
if jq -e '.ides | [.[] | select(.available == true)] | length > 0' <<< "$ai_status" >/dev/null 2>&1; then
    ide_count="$(jq -r '.ides | [.[] | select(.available == true)] | length' <<< "$ai_status")"
    check AI_IDE "AI-capable IDE/editor available" PASS "${ide_count} detected"
else
    check AI_IDE "AI-capable IDE/editor available" WARN "install VS Code/Cursor/Windsurf/Zed/Neovim"
fi

footer
echo
echo "Results JSON:"
printf '%s\n' "${RESULTS[@]}" | jq -R . | jq -s .
