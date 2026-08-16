#!/usr/bin/env bash
# windows-vm-session.sh - SDDM session launcher for PhaseZero Windows VM
set -euo pipefail

ENV_FILE="${PZ_WINDOWS_VM_ENV_FILE:-/etc/phasezero/windows-vm.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

CONFIGURED_REPO="${PZ_WINDOWS_VM_REPO:-}"
PZ_WINDOWS_VM_REPO_FALLBACK="${PZ_WINDOWS_VM_REPO_FALLBACK:-/mnt/sdcard/Projects/PhaseZero}"
RUNTIME_LAUNCHER="${PZ_WINDOWS_VM_RUNTIME_LAUNCHER:-/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/windows-vm.sh}"
DISPLAY_SESSION_HELPER="${PZ_DISPLAY_SESSION_HELPER:-/usr/local/lib/phasezero/display-session}"
RETRY_SECONDS="${PZ_WINDOWS_VM_SESSION_RETRY_SECONDS:-5}"
DESKTOP_FALLBACK="${PZ_WINDOWS_VM_DESKTOP_FALLBACK:-0}"
LAUNCHER_KIND=""
LAUNCHER_ARGS=()

load_display_session_helper() {
    local candidate source_tree_helper
    source_tree_helper="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/steamdeck/display-session.sh"
    if [ -n "${PZ_DISPLAY_SYSFS_ROOT:-}" ] && [ -r "$source_tree_helper" ]; then
        # Fixture/dev runs must exercise the helper from the same source tree.
        # Production has no sysfs override and keeps preferring installed runtime.
        # shellcheck disable=SC1090
        . "$source_tree_helper"
        return 0
    fi
    for candidate in \
        "$DISPLAY_SESSION_HELPER" \
        "$CONFIGURED_REPO/linux/steamdeck/display-session.sh" \
        "$PZ_WINDOWS_VM_REPO_FALLBACK/linux/steamdeck/display-session.sh" \
        "$source_tree_helper"; do
        [ -n "$candidate" ] || continue
        if [ -r "$candidate" ]; then
            # shellcheck disable=SC1090
            . "$candidate"
            return 0
        fi
    done

    pz_display_profile() { printf '%s\n' "generic"; }
    pz_display_external_connectors_csv() { printf '%s\n' ""; }
    pz_display_gamescope_orientation() { printf '%s\n' "${PZ_STEAMDECK_LCD_ORIENTATION:-right}"; }
    pz_display_gamescope_width() { printf '%s\n' "${PZ_STEAMDECK_LCD_LOGICAL_WIDTH:-1280}"; }
    pz_display_gamescope_height() { printf '%s\n' "${PZ_STEAMDECK_LCD_LOGICAL_HEIGHT:-800}"; }
    pz_display_resolved_session_vars() {
        printf '%s\n%s\n%s\n%s\n' \
            "${PZ_STEAMDECK_LCD_LOGICAL_WIDTH:-1280}" \
            "${PZ_STEAMDECK_LCD_LOGICAL_HEIGHT:-800}" '*,eDP-1' 60000
    }
    pz_display_shell_join() {
        local out="" arg
        for arg in "$@"; do
            printf -v arg '%q' "$arg"
            out="${out:+$out }$arg"
        done
        printf '%s\n' "$out"
    }
}

# A arvore runtime so serve se estiver completa. Um common.sh sem ledger.sh /
# desktop.sh aborta o launcher em todo retry e o boot GRUB fica em tela preta;
# nesse caso e melhor cair para o repo completo (deb ou checkout).
runtime_tree_usable() {
    local root dep
    [ -x "$RUNTIME_LAUNCHER" ] || return 1
    root="${RUNTIME_LAUNCHER%/linux/windows-vm/windows-vm.sh}"
    [ "$root" != "$RUNTIME_LAUNCHER" ] || return 0
    for dep in linux/lib/common.sh linux/lib/ledger.sh linux/lib/desktop.sh; do
        [ -r "$root/$dep" ] || return 1
    done
}

resolve_launcher() {
    local candidate
    if runtime_tree_usable; then
        PZ_WINDOWS_VM_REPO=""
        PZ_BIN="$RUNTIME_LAUNCHER"
        LAUNCHER_KIND="runtime"
        LAUNCHER_ARGS=(launch --fullscreen)
        return 0
    fi
    for candidate in \
        "$CONFIGURED_REPO" \
        "$PZ_WINDOWS_VM_REPO_FALLBACK" \
        "$HOME/Projects/PhaseZero" \
        "$HOME/PhaseZero"; do
        [ -n "$candidate" ] || continue
        if [ -x "$candidate/linux/pz" ]; then
            PZ_WINDOWS_VM_REPO="$candidate"
            PZ_BIN="$candidate/linux/pz"
            LAUNCHER_KIND="dispatcher"
            LAUNCHER_ARGS=(windows-vm launch --fullscreen)
            return 0
        fi
    done
    if command -v pz >/dev/null 2>&1; then
        PZ_WINDOWS_VM_REPO=""
        PZ_BIN="$(command -v pz)"
        LAUNCHER_KIND="dispatcher"
        LAUNCHER_ARGS=(windows-vm launch --fullscreen)
        return 0
    fi
    PZ_WINDOWS_VM_REPO="$CONFIGURED_REPO"
    PZ_BIN="${CONFIGURED_REPO:+$CONFIGURED_REPO/linux/pz}"
    return 1
}

PZ_BIN=""
resolve_launcher || true
load_display_session_helper

# Older installed/custom helpers return only geometry. Keep their safe 60 Hz
# default until the matching runtime is updated atomically.
if ! declare -F pz_display_refresh_hz >/dev/null 2>&1; then
    pz_display_refresh_hz() {
        local value="${1:-60000}"
        case "$value" in ""|*[!0-9]*) value=60000 ;; esac
        printf '%d.%03d\n' "$((value / 1000))" "$((value % 1000))"
    }
fi

DISPLAY_WIDTH=1280
DISPLAY_HEIGHT=800
DISPLAY_SELECTOR='*,eDP-1'
DISPLAY_CONNECTOR=eDP-1
DISPLAY_REFRESH_MILLIHZ=60000
DISPLAY_REFRESH_HZ=60.000
GAMESCOPE_ARGS=()

resolve_display_target() {
    local -a session_vars=()
    mapfile -t session_vars < <(pz_display_resolved_session_vars 2>/dev/null || true)
    DISPLAY_WIDTH="${session_vars[0]:-1280}"
    DISPLAY_HEIGHT="${session_vars[1]:-800}"
    DISPLAY_SELECTOR="${session_vars[2]:-*,eDP-1}"
    DISPLAY_REFRESH_MILLIHZ="${session_vars[3]:-60000}"
    case "$DISPLAY_WIDTH" in ""|*[!0-9]*) DISPLAY_WIDTH=1280 ;; esac
    case "$DISPLAY_HEIGHT" in ""|*[!0-9]*) DISPLAY_HEIGHT=800 ;; esac
    [ "$DISPLAY_WIDTH" -ge 320 ] && [ "$DISPLAY_WIDTH" -le 16384 ] || DISPLAY_WIDTH=1280
    [ "$DISPLAY_HEIGHT" -ge 320 ] && [ "$DISPLAY_HEIGHT" -le 16384 ] || DISPLAY_HEIGHT=800
    DISPLAY_CONNECTOR="${DISPLAY_SELECTOR#*,}"
    case "$DISPLAY_CONNECTOR" in
        ""|*[!A-Za-z0-9_.:-]*) DISPLAY_CONNECTOR=eDP-1 ;;
    esac
    case "$DISPLAY_REFRESH_MILLIHZ" in ""|*[!0-9]*) DISPLAY_REFRESH_MILLIHZ=60000 ;; esac
    [ "$DISPLAY_REFRESH_MILLIHZ" -ge 10000 ] && [ "$DISPLAY_REFRESH_MILLIHZ" -le 1000000 ] \
        || DISPLAY_REFRESH_MILLIHZ=60000
    DISPLAY_REFRESH_HZ="$(pz_display_refresh_hz "$DISPLAY_REFRESH_MILLIHZ")"
}

build_gamescope_args() {
    GAMESCOPE_ARGS=(
        --backend drm
        --expose-wayland
        -O "$DISPLAY_CONNECTOR"
    )
    if [ "$(display_profile)" = "steamdeck-lcd-handheld" ]; then
        GAMESCOPE_ARGS+=(--force-orientation "$(pz_display_gamescope_orientation)")
    fi
    GAMESCOPE_ARGS+=(
        -W "$DISPLAY_WIDTH"
        -H "$DISPLAY_HEIGHT"
        -w "$DISPLAY_WIDTH"
        -h "$DISPLAY_HEIGHT"
        -r "$DISPLAY_REFRESH_HZ"
        --force-windows-fullscreen
    )
}

launcher_command() {
    pz_display_shell_join "$PZ_BIN" "${LAUNCHER_ARGS[@]}"
}

display_profile() {
    pz_display_profile
}

external_connectors() {
    pz_display_external_connectors_csv
}

resolve_display_target
build_gamescope_args
export PZ_WINDOWS_VM_DISPLAY_WIDTH="$DISPLAY_WIDTH"
export PZ_WINDOWS_VM_DISPLAY_HEIGHT="$DISPLAY_HEIGHT"
export PZ_WINDOWS_VM_DISPLAY_CONNECTOR="$DISPLAY_CONNECTOR"
export PZ_WINDOWS_VM_DISPLAY_REFRESH_MILLIHZ="$DISPLAY_REFRESH_MILLIHZ"
export PZ_WINDOWS_VM_DISPLAY_REFRESH_HZ="$DISPLAY_REFRESH_HZ"

session_has_display() {
    [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ] || [ "${PZ_WINDOWS_VM_INSIDE_COMPOSITOR:-0}" = "1" ]
}

compositor_kind() {
    local requested="${PZ_WINDOWS_VM_COMPOSITOR:-auto}" profile
    session_has_display && { printf '%s\n' "existing-session"; return 0; }
    [ "$requested" = "0" ] && { printf '%s\n' "none"; return 0; }
    profile="$(display_profile)"

    case "$requested" in
        gamescope)
            command -v gamescope >/dev/null 2>&1 && printf '%s\n' "gamescope" || printf '%s\n' "missing-gamescope"
            return 0
            ;;
        kwin|kwin_wayland)
            command -v kwin_wayland >/dev/null 2>&1 && printf '%s\n' "kwin" || printf '%s\n' "missing-kwin"
            return 0
            ;;
        cage)
            command -v cage >/dev/null 2>&1 && printf '%s\n' "cage" || printf '%s\n' "missing-cage"
            return 0
            ;;
    esac

    if [ "$profile" = "steamdeck-lcd-handheld" ] || [ "$profile" = "steamdeck-docked" ]; then
        if command -v gamescope >/dev/null 2>&1; then
            printf '%s\n' "gamescope"
        elif command -v kwin_wayland >/dev/null 2>&1; then
            printf '%s\n' "kwin"
        elif { [ "$profile" = "steamdeck-docked" ] || [ "${PZ_STEAMDECK_HANDHELD_ALLOW_CAGE:-0}" = "1" ]; } \
            && command -v cage >/dev/null 2>&1; then
            printf '%s\n' "cage"
        else
            printf '%s\n' "none"
        fi
        return 0
    fi

    if command -v cage >/dev/null 2>&1; then
        printf '%s\n' "cage"
    elif command -v kwin_wayland >/dev/null 2>&1; then
        printf '%s\n' "kwin"
    else
        printf '%s\n' "none"
    fi
}

compositor_reason() {
    case "$1" in
        existing-session) printf '%s\n' "display-already-present" ;;
        gamescope)
            if [ "$(display_profile)" = "steamdeck-docked" ]; then
                printf '%s\n' "steamdeck-docked-explicit-output"
            else
                printf '%s\n' "steamdeck-lcd-handheld-landscape"
            fi
            ;;
        kwin) printf '%s\n' "fallback-kwin-wayland" ;;
        cage)
            if [ "$(display_profile)" = "steamdeck-lcd-handheld" ]; then
                printf '%s\n' "explicit-handheld-cage-fallback"
            else
                printf '%s\n' "default-kiosk-compositor"
            fi
            ;;
        missing-*) printf '%s\n' "requested-compositor-missing" ;;
        none) printf '%s\n' "no-compositor-wrap" ;;
        *) printf '%s\n' "unknown" ;;
    esac
}

compositor_command() {
    local kind="$1"
    case "$kind" in
        gamescope)
            pz_display_shell_join \
                dbus-run-session -- env PZ_WINDOWS_VM_INSIDE_COMPOSITOR=1 gamescope \
                "${GAMESCOPE_ARGS[@]}" \
                -- "$0"
            ;;
        cage)
            pz_display_shell_join dbus-run-session -- env PZ_WINDOWS_VM_INSIDE_COMPOSITOR=1 cage -- "$0"
            ;;
        kwin)
            pz_display_shell_join dbus-run-session -- env PZ_WINDOWS_VM_INSIDE_COMPOSITOR=1 \
                kwin_wayland --no-lockscreen --no-global-shortcuts --xwayland --exit-with-session "$0"
            ;;
        *) printf '%s\n' "" ;;
    esac
}

if [ "${1:-}" = "--validate" ]; then
    kind="$(compositor_kind)"
    if [ -z "$PZ_BIN" ] || [ ! -x "$PZ_BIN" ] || [ -z "$LAUNCHER_KIND" ]; then
        printf 'windows_vm_session_ready=no configured_repo=%s display_profile=%s external_connectors=%s compositor=%s reason=%s\n' \
            "${CONFIGURED_REPO:-missing}" "$(display_profile)" "$(external_connectors)" "$kind" "$(compositor_reason "$kind")"
        exit 1
    fi
    printf 'windows_vm_session_ready=yes repo=%s launcher=%s launcher_kind=%s command=%s display_profile=%s external_connectors=%s display_width=%s display_height=%s display_connector=%s display_refresh_millihz=%s display_refresh_hz=%s compositor=%s compositor_command=%s reason=%s\n' \
        "${PZ_WINDOWS_VM_REPO:-runtime}" "$PZ_BIN" "$LAUNCHER_KIND" "$(launcher_command)" \
        "$(display_profile)" "$(external_connectors)" "$DISPLAY_WIDTH" "$DISPLAY_HEIGHT" "$DISPLAY_CONNECTOR" \
        "$DISPLAY_REFRESH_MILLIHZ" "$DISPLAY_REFRESH_HZ" \
        "$kind" "$(compositor_command "$kind")" "$(compositor_reason "$kind")"
    exit 0
fi

export PZ_WINDOWS_VM_FULLSCREEN="${PZ_WINDOWS_VM_FULLSCREEN:-1}"
export PZ_WINDOWS_VM_BOOT_SESSION=1
export PZ_WINDOWS_VM_OPTIMIZE="${PZ_WINDOWS_VM_OPTIMIZE:-0}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm"
LOG_FILE="$STATE_DIR/session.log"
install -d "$STATE_DIR"
# Uma sessao presa em retry escreve algumas linhas por segundo; sem rotacao o
# log cresce sem limite ate o proximo boot bem-sucedido.
if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
fi
exec >>"$LOG_FILE" 2>&1
printf '%s starting Windows VM boot session\n' "$(date -Iseconds)"

# SDDM Wayland sessions start without a compositor; spicy/virt-viewer/QEMU-gtk
# need one or they die with "gtk initialization failed" (black screen).
# Gamescope receives the resolved output and physical mode. Steam Deck LCD also
# needs rotation because its panel is portrait.
kind="$(compositor_kind)"
printf '%s display_profile=%s external_connectors=%s compositor=%s reason=%s command=%s\n' \
    "$(date -Iseconds)" "$(display_profile)" "$(external_connectors)" "$kind" \
    "$(compositor_reason "$kind")" "$(compositor_command "$kind")"
case "$kind" in
    gamescope)
        exec dbus-run-session -- env PZ_WINDOWS_VM_INSIDE_COMPOSITOR=1 gamescope \
            "${GAMESCOPE_ARGS[@]}" \
            -- "$0"
        ;;
    cage)
        exec dbus-run-session -- env PZ_WINDOWS_VM_INSIDE_COMPOSITOR=1 cage -- "$0"
        ;;
    kwin)
        exec dbus-run-session -- env PZ_WINDOWS_VM_INSIDE_COMPOSITOR=1 \
            kwin_wayland --no-lockscreen --no-global-shortcuts --xwayland --exit-with-session "$0"
        ;;
    missing-*)
        printf '%s requested compositor unavailable: %s\n' "$(date -Iseconds)" "$kind"
        ;;
esac

if [ -n "$CONFIGURED_REPO" ] && [ "$CONFIGURED_REPO" != "${PZ_WINDOWS_VM_REPO:-}" ]; then
    printf '%s stale configured repo %s; using %s\n' \
        "$(date -Iseconds)" "$CONFIGURED_REPO" "${PZ_WINDOWS_VM_REPO:-$LAUNCHER_KIND}"
fi

case "$RETRY_SECONDS" in
    ""|*[!0-9]*) RETRY_SECONDS=5 ;;
esac
[ "$RETRY_SECONDS" -ge 1 ] || RETRY_SECONDS=1

# Source rescue wizard for non-loop exit on missing disk
PZ_WINDOWS_VM_SESSION_MAX_RETRIES="${PZ_WINDOWS_VM_SESSION_MAX_RETRIES:-3}"
PZ_WINDOWS_VM_SESSION_STABLE_SECONDS="${PZ_WINDOWS_VM_SESSION_STABLE_SECONDS:-30}"
# shellcheck disable=SC2015 # cd/pwd fallback: empty dir acceptable when dirname fails
_RESCUE_SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
for _rescue_sh in \
    "${_RESCUE_SESSION_DIR}/rescue.sh" \
    "/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/rescue.sh"; do
    [ -f "$_rescue_sh" ] && source "$_rescue_sh" 2>/dev/null && break
done
unset _RESCUE_SESSION_DIR

fallback_desktop() {
    local force="${1:-0}"
    [ "$force" = "1" ] || [ "$DESKTOP_FALLBACK" = "1" ] || return 1
    printf '%s desktop fallback (force=%s)\n' "$(date -Iseconds)" "$force"
    if command -v startplasma-wayland >/dev/null 2>&1; then
        exec startplasma-wayland
    fi
    if command -v startplasma-x11 >/dev/null 2>&1; then
        exec startplasma-x11
    fi
    return 1
}

attempt=0
rescue_attempted=0
compat_attempted=0
while :; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$PZ_WINDOWS_VM_SESSION_MAX_RETRIES" ] && [ "$rescue_attempted" -eq 0 ]; then
        rescue_attempted=1
        if ! type vm_rescue_run >/dev/null 2>&1; then
            printf '%s max retries reached and rescue wizard unavailable\n' "$(date -Iseconds)"
        else
            printf '%s max retries reached; launching rescue wizard\n' "$(date -Iseconds)"
            if vm_rescue_run; then
                printf '%s rescue wizard succeeded; resetting retry counter\n' "$(date -Iseconds)"
                attempt=0
            else
                printf '%s rescue wizard declined or failed\n' "$(date -Iseconds)"
            fi
        fi
        sleep "$RETRY_SECONDS"
        continue
    fi
    # Resgate ja tentado e ainda falhando: parar de girar. Um loop infinito
    # dentro de um compositor vazio e exatamente a tela preta que o usuario ve.
    if [ "$attempt" -gt "$PZ_WINDOWS_VM_SESSION_MAX_RETRIES" ] && [ "$rescue_attempted" -eq 1 ]; then
        printf '%s giving up after %s attempts; leaving Windows VM boot session\n' \
            "$(date -Iseconds)" "$attempt"
        fallback_desktop 1 || true
        printf '%s no desktop session available; exiting so the display manager can recover\n' \
            "$(date -Iseconds)"
        exit 1
    fi
    if [ -n "$PZ_BIN" ] && [ -x "$PZ_BIN" ] && [ -n "$LAUNCHER_KIND" ]; then
        printf '%s launching Windows VM attempt=%s kind=%s command=%s\n' \
            "$(date -Iseconds)" "$attempt" "$LAUNCHER_KIND" "$(launcher_command)"
        launch_started="$SECONDS"
        set +e
        "$PZ_BIN" "${LAUNCHER_ARGS[@]}"
        rc=$?
        set -e
        launch_elapsed=$((SECONDS - launch_started))
        if [ "$rc" -eq 0 ]; then
            printf '%s Windows VM ended normally after %ss; closing boot session\n' \
                "$(date -Iseconds)" "$launch_elapsed"
            exit 0
        fi
        if [ "$launch_elapsed" -ge "$PZ_WINDOWS_VM_SESSION_STABLE_SECONDS" ]; then
            printf '%s Windows VM failed after stable runtime=%ss rc=%s; refusing automatic relaunch\n' \
                "$(date -Iseconds)" "$launch_elapsed" "$rc"
            fallback_desktop 1 || true
            exit "$rc"
        fi
        if [ "$compat_attempted" -eq 0 ]; then
            compat_attempted=1
            printf '%s accelerated launch failed quickly rc=%s; trying compat once\n' \
                "$(date -Iseconds)" "$rc"
            set +e
            "$PZ_BIN" "${LAUNCHER_ARGS[@]}" --graphics compat
            compat_rc=$?
            set -e
            if [ "$compat_rc" -eq 0 ]; then
                printf '%s compat Windows VM ended normally; closing boot session\n' "$(date -Iseconds)"
                exit 0
            fi
            printf '%s compat launch failed rc=%s; continuing bounded recovery\n' \
                "$(date -Iseconds)" "$compat_rc"
        fi
        printf '%s Windows VM launcher exited rc=%s attempt=%s; retrying in %ss\n' \
            "$(date -Iseconds)" "$rc" "$attempt" "$RETRY_SECONDS"
    else
        rc=127
        printf '%s Windows VM launcher missing attempt=%s configured_repo=%s; retrying in %ss\n' \
            "$(date -Iseconds)" "$attempt" "${CONFIGURED_REPO:-missing}" "$RETRY_SECONDS"
    fi
    fallback_desktop || true
    sleep "$RETRY_SECONDS"
done
