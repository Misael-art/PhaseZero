# Linux SteamOS-like UX Expansion Plan

**Goal:** expand PhaseZero on Linux without regressing Windows. First slice: handheld/Steam Deck style experience on this Linux host: mode detection, keyboard shortcuts, virtual keyboard, Steam Gamepad UI, and gaming performance tuning.

## Evaluation

Done before this session:

- `linux/pz` entrypoint exists.
- Shared JSON profiles exist under `profiles/*.json`.
- Linux Steam Deck mode scripts exist under `linux/steamdeck/`.
- Linux tuning scripts exist for gaming, dev, and browser hardening.
- Linux doctor/support/repair scripts exist.

Gaps found:

- Steam Deck Linux mode detection only checked `card1-DP-1`, so docks using other DRM connector names were missed.
- Mode watcher applied immediately without debounce/cooldown.
- No Linux equivalent for Windows `SteamDeckHotkeys.ahk`.
- No CLI action for virtual keyboard.
- No CLI action for Steam Big Picture/Gamepad UI session.
- No dedicated Linux Steam Deck profile.
- Doctor did not audit SteamOS-like UX readiness.

## First Slice Implemented

- `linux/steamdeck/common.sh`
  - generic external DRM connector detection;
  - TV/monitor classification by EDID hints;
  - mode watcher debounce/cooldown via environment variables;
  - TDP conversion no longer hard-requires `bc` for integer watts.
  - privileged sysfs writes skip safely in user services unless `PZ_STEAMDECK_USE_SUDO=1`.

- `linux/steamdeck/input-actions.sh`
  - virtual keyboard toggle;
  - Steam overlay keyboard request when Steam is running;
  - fallback keyboards: `wvkbd-mobintl`, `wvkbd`, `onboard`, `maliit-keyboard`;
  - Steam Gamepad UI launcher;
  - console/dev session helpers.

- `linux/steamdeck/install-hotkeys.sh`
  - installs `Ctrl+Alt+F1..F6` mappings:
    - F1 handheld;
    - F2 docked monitor;
    - F3 docked TV;
    - F4 virtual keyboard;
    - F5 Steam Gamepad UI;
    - F6 dev session;
  - writes `sxhkd` and `swhkd` configs;
  - writes desktop entries;
  - writes KDE Plasma native global shortcuts through `.desktop` `X-KDE-Shortcuts` and `kglobalshortcutsrc`;
  - enables user `sxhkd` service only when `sxhkd` exists;
  - supports `dry-run` and `status`.

- `profiles/steamdeck-linux.json`
  - opt-in Linux-only SteamOS-like profile;
  - Windows package lists empty.

- `linux/audit/doctor.sh`
  - audits Steam, Gamescope, MangoHud, GameMode, virtual keyboard, hotkey configs, hotkey service, and mode watcher service.
  - ignores ephemeral AppImage mounts such as `/tmp/.mount_*` in disk checks.

- `linux/steamdeck/install-mode-watcher.sh`
  - writes a user systemd service with the current workspace path;
  - supports `install`, `enable`, `start`, `stop`, `restart`, `status`, and `dry-run`;
  - avoids the old hardcoded `~/.local/share/phasezero-linux` `ExecStart` path.

- `linux/steamdeck/privileged-control.sh` and `install-privileged-controls.sh`
  - add a constrained root bridge for TDP/GPU writes;
  - validate modes before touching `ryzenadj` or AMDGPU sysfs;
  - install exact sudoers entries for `apply handheld`, `apply docked-tv`, and `apply docked-monitor`;
  - add a user systemd drop-in enabling `PZ_STEAMDECK_USE_SUDO=1` only after bridge installation.

- `linux/pz install <profile> --dry-run`
  - plans packages, scripts, system services, user services, and sysctl tuning without mutating the host.

- `linux/tuning/gaming-tweaks.sh`
  - applies user-level MangoHud/CoreCtrl configs without root;
  - skips `/etc` and service writes cleanly when sudo is not available.

- `linux/audit/repair-plan.sh`
  - fixed `set -e`/`pipefail` breakage when no package updates exist;
  - filters non-actionable `systemctl --failed` summary rows;
  - emits concrete SteamOS UX repair commands for MangoHud, `ryzenadj`, watcher, and KDE shortcuts.

## Next Steps

1. Add GNOME compositor-native shortcut emitter. KDE Plasma 6 is implemented and verified on this host.
2. Expand Linux test runner with compositor-specific assertions where a desktop session exists.
3. Keep optional GRUB path documented and reversible:
   - `linux/pz steamdeck boot status`
   - `sudo linux/steamdeck/install-steamos-boot.sh remove`
4. Validate user journey after future package/config changes:
   - `linux/pz doctor`
   - `linux/pz repair-plan`

## Host Validation 2026-07-01

- `mangohud`, `lib32-mangohud`, `goverlay`, `ryzenadj`: installed by user.
- SteamOS UX doctor checks pass for Steam, Gamescope, MangoHud, GameMode, virtual keyboard, KDE shortcuts, watcher, TDP tool and privileged bridge.
- GRUB `PhaseZero SteamOS Console` installed and audited as PASS.
- LuaRocks, Protontricks and ProtonUp-Qt installed and audited as PASS.

## Regression Boundary

- Do not modify Windows `.ps1`, `.bat`, `.ahk`, or existing Windows profile behavior for this Linux slice.
- Keep Linux profiles opt-in.
- Keep Windows arrays present but empty in Linux-only profiles when schema expects them.
