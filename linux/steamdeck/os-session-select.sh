#!/usr/bin/env bash
# PhaseZero managed: Steam/SteamOS session selection hook for gamescope-session-plus.
set -uo pipefail

target="${1:-desktop}"
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phasezero-steamos"
target_file="$runtime_dir/session-target"

install -d "$runtime_dir"

case "$target" in
    plasma|desktop)
        printf 'desktop\n' > "$target_file"
        ;;
    gamepadui|steam)
        printf 'gamepadui\n' > "$target_file"
        ;;
    reboot)
        printf 'reboot\n' > "$target_file"
        ;;
    shutdown|poweroff)
        printf 'shutdown\n' > "$target_file"
        ;;
    *)
        printf 'desktop\n' > "$target_file"
        ;;
esac

if [ "${PZ_STEAMOS_SKIP_STEAM_SHUTDOWN:-0}" != "1" ]; then
    steam -shutdown >/dev/null 2>&1 || true
fi

# Steam occasionally acknowledges shutdown but leaves the gamescope unit alive.
if [ "${PZ_STEAMOS_SKIP_STEAM_SHUTDOWN:-0}" != "1" ]; then
    nohup bash -c 'sleep 5; systemctl --user stop gamescope-session-plus@steam-plus.service gamescope-session-plus@steam.service >/dev/null 2>&1 || true' \
        >/dev/null 2>&1 &
fi

exit 0
