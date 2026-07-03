#!/usr/bin/env bash
# support-bundle.sh - generate diagnostic tarball
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps jq tar

BUNDLE_DIR=$(mktemp -d)
BUNDLE_NAME="phasezero-support-$(hostname -s)-$(date +%Y%m%d-%H%M%S)"
BUNDLE_PATH="/tmp/${BUNDLE_NAME}.tar.gz"

pz_info "collecting support bundle..."

# Create bundle structure
mkdir -p "$BUNDLE_DIR"/{system,configs,services,doctor,steamdeck,docker,steamos-ux,windows-vm,waydroid,emulation,ai}

redact_to() {
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    sed -E \
        -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1<redacted>/g' \
        -e 's/("(api[_-]?key|token|authorization|auth_token|password)"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/Ig' \
        -e 's/^([[:space:]]*(api[_-]?key|token|authorization|auth_token|password)[[:space:]]*:[[:space:]]*).+/\1<redacted>/Ig' \
        -e 's/((OPENAI|ANTHROPIC|OPENROUTER|DEEPSEEK|GEMINI|GOOGLE|GITHUB|SENTRY|BONSAI|FIRECRAWL|CONTEXT7)[A-Z0-9_]*=).+/\1<redacted>/g' \
        "$src" > "$dst"
}

# System info
uname -a > "$BUNDLE_DIR/system/uname.txt"
cat /etc/os-release > "$BUNDLE_DIR/system/os-release.txt" 2>/dev/null || true
lscpu > "$BUNDLE_DIR/system/lscpu.txt" 2>/dev/null || true
lsusb > "$BUNDLE_DIR/system/lsusb.txt" 2>/dev/null || true
lspci > "$BUNDLE_DIR/system/lspci.txt" 2>/dev/null || true
lsblk > "$BUNDLE_DIR/system/lsblk.txt" 2>/dev/null || true
df -h > "$BUNDLE_DIR/system/df.txt" 2>/dev/null || true
free -h > "$BUNDLE_DIR/system/free.txt" 2>/dev/null || true
uptime > "$BUNDLE_DIR/system/uptime.txt" 2>/dev/null || true
dmesg | tail -200 > "$BUNDLE_DIR/system/dmesg.txt" 2>/dev/null || true
journalctl -n 500 --no-pager > "$BUNDLE_DIR/system/journal.txt" 2>/dev/null || true
pacman -Qe > "$BUNDLE_DIR/system/packages-explicit.txt" 2>/dev/null || true
pacman -Q > "$BUNDLE_DIR/system/packages-all.txt" 2>/dev/null || true

# Config files
for cfg in "$PZ_ROOT/version.json" "$PZ_ROOT/profiles/"*.json; do
    [ -f "$cfg" ] && cp "$cfg" "$BUNDLE_DIR/configs/"
done
mkdir -p "$BUNDLE_DIR/configs/user"
[ -f ~/.bashrc ] && cp ~/.bashrc "$BUNDLE_DIR/configs/user/"
[ -f ~/.config/opencode/opencode.jsonc ] && redact_to ~/.config/opencode/opencode.jsonc "$BUNDLE_DIR/configs/user/opencode.jsonc"

# Services
systemctl list-units --type=service --state=running --no-pager > "$BUNDLE_DIR/services/running.txt" 2>/dev/null || true
systemctl list-units --type=service --state=failed --no-pager > "$BUNDLE_DIR/services/failed.txt" 2>/dev/null || true

# Doctor output
bash "$PZ_ROOT/linux/audit/doctor.sh" > "$BUNDLE_DIR/doctor/doctor.txt" 2>&1 || true

# Steam Deck
if [ -f /sys/devices/virtual/dmi/id/product_name ]; then
    cat /sys/devices/virtual/dmi/id/product_name > "$BUNDLE_DIR/steamdeck/product.txt"
fi
[ -d /sys/class/drm ] && ls -la /sys/class/drm/card1-*/status > "$BUNDLE_DIR/steamdeck/display-status.txt" 2>/dev/null || true
cat /sys/class/power_supply/*/uevent > "$BUNDLE_DIR/steamdeck/power.txt" 2>/dev/null || true

# SteamOS-like UX
command -v steam > "$BUNDLE_DIR/steamos-ux/steam-path.txt" 2>/dev/null || true
command -v gamescope > "$BUNDLE_DIR/steamos-ux/gamescope-path.txt" 2>/dev/null || true
command -v mangohud > "$BUNDLE_DIR/steamos-ux/mangohud-path.txt" 2>/dev/null || true
command -v gamemoderun > "$BUNDLE_DIR/steamos-ux/gamemoderun-path.txt" 2>/dev/null || true
systemctl --user status phasezero-steamdeck-hotkeys.service --no-pager > "$BUNDLE_DIR/steamos-ux/hotkeys-service.txt" 2>/dev/null || true
systemctl --user status phasezero-steamdeck-mode-watcher.service --no-pager > "$BUNDLE_DIR/steamos-ux/mode-watcher-service.txt" 2>/dev/null || true
bash "$PZ_ROOT/linux/steamdeck/install-privileged-controls.sh" status > "$BUNDLE_DIR/steamos-ux/privileged-controls.txt" 2>/dev/null || true
bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" status > "$BUNDLE_DIR/steamos-ux/virtual-keyboard.json" 2>/dev/null || true
bash "$PZ_ROOT/linux/steamdeck/plugins.sh" status > "$BUNDLE_DIR/steamos-ux/decky-plugins.json" 2>/dev/null || true
systemctl --user status plugin_loader.service --no-pager > "$BUNDLE_DIR/steamos-ux/decky-user-service.txt" 2>/dev/null || true
systemctl status plugin_loader.service --no-pager > "$BUNDLE_DIR/steamos-ux/decky-system-service.txt" 2>/dev/null || true
ss -ltnp 'sport = :8080 or sport = :1337' > "$BUNDLE_DIR/steamos-ux/decky-ports.txt" 2>/dev/null || true
[ -f ~/.config/sxhkd/sxhkdrc ] && cp ~/.config/sxhkd/sxhkdrc "$BUNDLE_DIR/steamos-ux/sxhkdrc"
[ -f ~/.config/swhkd/swhkdrc ] && cp ~/.config/swhkd/swhkdrc "$BUNDLE_DIR/steamos-ux/swhkdrc"
[ -f ~/.config/gamescope-session-plus/sessions.d/steam-plus ] && cp ~/.config/gamescope-session-plus/sessions.d/steam-plus "$BUNDLE_DIR/steamos-ux/steam-plus-fallback"
[ -f "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/steamos/session.log" ] && cp "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/steamos/session.log" "$BUNDLE_DIR/steamos-ux/session.log"
[ -f ~/.config/systemd/user/phasezero-steamdeck-mode-watcher.service ] && cp ~/.config/systemd/user/phasezero-steamdeck-mode-watcher.service "$BUNDLE_DIR/steamos-ux/mode-watcher.service"
ls -la ~/.local/share/applications/phasezero-*.desktop > "$BUNDLE_DIR/steamos-ux/desktop-entries.txt" 2>/dev/null || true

# Emulation
bash "$PZ_ROOT/linux/emulation/bios.sh" status > "$BUNDLE_DIR/emulation/status.json" 2>&1 || true
bash "$PZ_ROOT/linux/emulation/hydra.sh" status > "$BUNDLE_DIR/emulation/hydra-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/emulation/srm.sh" status > "$BUNDLE_DIR/emulation/srm-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/emulation/ps3.sh" status > "$BUNDLE_DIR/emulation/ps3-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/emulation/performance.sh" status > "$BUNDLE_DIR/emulation/performance-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/emulation/lua.sh" status > "$BUNDLE_DIR/emulation/lua-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/emulation/steam-tools.sh" status > "$BUNDLE_DIR/emulation/steam-tools-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/emulation/fixes.sh" list > "$BUNDLE_DIR/emulation/fixes.json" 2>&1 || true
python3 "$PZ_ROOT/linux/emulation/steam-shortcut.py" status --app-name Hydra > "$BUNDLE_DIR/emulation/hydra-steam-shortcut.txt" 2>&1 || true
find "${PZ_EMULATION_ROOT:-$HOME/Emulation}" -maxdepth 3 -type d > "$BUNDLE_DIR/emulation/layout.txt" 2>/dev/null || true
ls -la "${PZ_APPLICATIONS_DIR:-$HOME/Applications}"/EmuDeck.AppImage "${PZ_APPLICATIONS_DIR:-$HOME/Applications}"/Eden*.AppImage "${PZ_APPLICATIONS_DIR:-$HOME/Applications}"/Hydra.AppImage > "$BUNDLE_DIR/emulation/appimages.txt" 2>/dev/null || true
mkdir -p "$BUNDLE_DIR/emulation/hydra-config"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/config.json" ] && cp "${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/config.json" "$BUNDLE_DIR/emulation/hydra-config/config.json"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/emulators_config.json" ] && cp "${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/emulators_config.json" "$BUNDLE_DIR/emulation/hydra-config/emulators_config.json"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/emulation/hydra-policy.json" ] && cp "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/emulation/hydra-policy.json" "$BUNDLE_DIR/emulation/hydra-config/hydra-policy.json"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/emulation-performance.json" ] && cp "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/emulation-performance.json" "$BUNDLE_DIR/emulation/performance-config.json"
mkdir -p "$BUNDLE_DIR/emulation/srm-config"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/steam-rom-manager/userData/userSettings.json" ] && cp "${XDG_CONFIG_HOME:-$HOME/.config}/steam-rom-manager/userData/userSettings.json" "$BUNDLE_DIR/emulation/srm-config/userSettings.json"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/steam-rom-manager/userData/userConfigurations.json" ] && jq '[.[] | {configTitle, romDirectory, steamDirectory, executable: .executable.path, disabled}]' "${XDG_CONFIG_HOME:-$HOME/.config}/steam-rom-manager/userData/userConfigurations.json" > "$BUNDLE_DIR/emulation/srm-config/userConfigurations-summary.json" 2>/dev/null || true
bash "$PZ_ROOT/linux/steamdeck/install-steamos-boot.sh" status > "$BUNDLE_DIR/steamos-ux/steamos-boot-status.txt" 2>&1 || true

# Windows VM
bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" status > "$BUNDLE_DIR/windows-vm/status.json" 2>&1 || true
bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" boot status > "$BUNDLE_DIR/windows-vm/boot-status.txt" 2>&1 || true
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/windows-vm.conf" ] && cp "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/windows-vm.conf" "$BUNDLE_DIR/windows-vm/windows-vm.conf"
[ -f "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/session.log" ] && cp "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/session.log" "$BUNDLE_DIR/windows-vm/session.log"
virsh -c qemu:///system list --all > "$BUNDLE_DIR/windows-vm/libvirt-domains.txt" 2>&1 || true
winvm_domain="$(jq -r '.libvirt.domain // empty' "$BUNDLE_DIR/windows-vm/status.json" 2>/dev/null || true)"
[ -n "$winvm_domain" ] && virsh -c qemu:///system dominfo "$winvm_domain" > "$BUNDLE_DIR/windows-vm/libvirt-domain.txt" 2>&1 || true

# Waydroid
bash "$PZ_ROOT/linux/waydroid/waydroid.sh" status > "$BUNDLE_DIR/waydroid/status.json" 2>&1 || true
bash "$PZ_ROOT/linux/waydroid/waydroid.sh" boot status > "$BUNDLE_DIR/waydroid/boot-status.txt" 2>&1 || true
command -v waydroid > "$BUNDLE_DIR/waydroid/waydroid-path.txt" 2>/dev/null || true
systemctl status waydroid-container --no-pager > "$BUNDLE_DIR/waydroid/container-service.txt" 2>&1 || true
ls -la /dev/binder* /dev/binderfs /dev/vndbinder /dev/hwbinder > "$BUNDLE_DIR/waydroid/binder-devices.txt" 2>&1 || true
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/waydroid.conf" ] && cp "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/waydroid.conf" "$BUNDLE_DIR/waydroid/waydroid.conf"
[ -f "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/waydroid/session.log" ] && cp "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/waydroid/session.log" "$BUNDLE_DIR/waydroid/session.log"

# AI
bash "$PZ_ROOT/linux/ai/status.sh" > "$BUNDLE_DIR/ai/status.json" 2>&1 || true
bash "$PZ_ROOT/linux/ai/mcp-manager.sh" status > "$BUNDLE_DIR/ai/mcp-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/ai/setup-memory.sh" status > "$BUNDLE_DIR/ai/ai-memory-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/ai/setup-ides.sh" status > "$BUNDLE_DIR/ai/ides-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/ai/setup-hermes.sh" status > "$BUNDLE_DIR/ai/hermes-status.json" 2>&1 || true
bash "$PZ_ROOT/linux/ai/setup-openclaw.sh" status > "$BUNDLE_DIR/ai/openclaw-status.json" 2>&1 || true
command -v codex > "$BUNDLE_DIR/ai/codex-path.txt" 2>/dev/null || true
command -v claude > "$BUNDLE_DIR/ai/claude-path.txt" 2>/dev/null || true
command -v opencode > "$BUNDLE_DIR/ai/opencode-path.txt" 2>/dev/null || true
command -v hermes > "$BUNDLE_DIR/ai/hermes-path.txt" 2>/dev/null || true
command -v openclaw > "$BUNDLE_DIR/ai/openclaw-path.txt" 2>/dev/null || true
command -v ai-memory > "$BUNDLE_DIR/ai/ai-memory-path.txt" 2>/dev/null || true
command -v ai-usagebar > "$BUNDLE_DIR/ai/ai-usagebar-path.txt" 2>/dev/null || true
mkdir -p "$BUNDLE_DIR/ai/configs"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/claude/claude.json" ] && redact_to "${XDG_CONFIG_HOME:-$HOME/.config}/claude/claude.json" "$BUNDLE_DIR/ai/configs/claude.json"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" ] && redact_to "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" "$BUNDLE_DIR/ai/configs/opencode.json"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc" ] && redact_to "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc" "$BUNDLE_DIR/ai/configs/opencode.jsonc"
[ -f "$HOME/.hermes/config.yaml" ] && redact_to "$HOME/.hermes/config.yaml" "$BUNDLE_DIR/ai/configs/hermes-config.yaml"
[ -f "$HOME/.openclaw/config.json" ] && redact_to "$HOME/.openclaw/config.json" "$BUNDLE_DIR/ai/configs/openclaw-config.json"
[ -f "$HOME/.openclaw/openclaw.json" ] && redact_to "$HOME/.openclaw/openclaw.json" "$BUNDLE_DIR/ai/configs/openclaw-gateway.json"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai/hermes.env" ] && redact_to "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai/hermes.env" "$BUNDLE_DIR/ai/configs/hermes.env"
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai/openclaw.env" ] && redact_to "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai/openclaw.env" "$BUNDLE_DIR/ai/configs/openclaw.env"
[ -f "$HOME/.codex/config.toml" ] && redact_to "$HOME/.codex/config.toml" "$BUNDLE_DIR/ai/configs/codex-config.toml"
[ -f "$PZ_ROOT/.vscode/mcp.json" ] && redact_to "$PZ_ROOT/.vscode/mcp.json" "$BUNDLE_DIR/ai/configs/vscode-mcp.json"

# Docker
docker ps -a > "$BUNDLE_DIR/docker/containers.txt" 2>/dev/null || true
docker images > "$BUNDLE_DIR/docker/images.txt" 2>/dev/null || true
docker info > "$BUNDLE_DIR/docker/info.txt" 2>/dev/null || true

# Compress
tar -czf "$BUNDLE_PATH" -C "$(dirname "$BUNDLE_DIR")" "$(basename "$BUNDLE_DIR")"
rm -rf "$BUNDLE_DIR"

echo "Support bundle: $BUNDLE_PATH"
echo "Size: $(du -h "$BUNDLE_PATH" | cut -f1)"
