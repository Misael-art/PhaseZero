#!/usr/bin/env bash
# controller-desktop.sh - drive the KDE Plasma desktop with the Deck controller.
#
# The kernel's hid-steam driver ships "lizard mode", which already emits a
# mouse from the right trackpad and a few keys. That is all it emits: ABXY,
# the back paddles and the shoulder chords carry nothing, so a desktop map
# needs a userspace mapper. sc-controller opens the native Valve HID device
# and re-emits through uinput, which is why it can reach controls that never
# appear on the evdev nodes lizard mode publishes.
#
# Taking that device over switches lizard mode off (the driver re-asserts the
# unlizard command on an interval). If the daemon then dies with the profile
# half-applied, a Deck with no keyboard attached has no working pointer left.
# Every start therefore arms a revert timer that stops the daemon unless
# `confirm` runs first.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

PROFILE_NAME="${PZ_CONTROLLER_PROFILE_NAME:-PhaseZero-Desktop}"
PROFILE_SRC="$DIR/profiles/$PROFILE_NAME.sccprofile"
SCC_CONFIG_DIR="${PZ_SCC_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/scc}"
PROFILE_DIR="$SCC_CONFIG_DIR/profiles"
PROFILE_DEST="$PROFILE_DIR/$PROFILE_NAME.sccprofile"
REVERT_SECONDS="${PZ_CONTROLLER_REVERT_SECONDS:-90}"
REVERT_PIDFILE="$SCC_CONFIG_DIR/phasezero-revert.pid"
DAEMON_PIDFILE="$SCC_CONFIG_DIR/daemon.pid"

# Overridable so the suite can exercise the missing-mapper path without
# uninstalling the package on the machine running the tests.
scc_daemon_bin() {
    if [ -n "${PZ_SCC_DAEMON_BIN+x}" ]; then
        printf '%s\n' "$PZ_SCC_DAEMON_BIN"
        return 0
    fi
    command -v scc-daemon 2>/dev/null
}

controller_present() {
    local dev vendor product
    for dev in "${PZ_CONTROLLER_SYSFS_ROOT:-/sys/bus/usb/devices}"/*; do
        vendor="$(cat "$dev/idVendor" 2>/dev/null || true)"
        product="$(cat "$dev/idProduct" 2>/dev/null || true)"
        [ "$vendor" = "28de" ] && [ "$product" = "1205" ] && return 0
    done
    return 1
}

# Steam Input claims the same device and expects to own it. Two mappers on one
# controller produce doubled input, not a merged map, so the desktop profile
# stays out of the way whenever Steam or a gamescope session is up.
conflicting_session() {
    pgrep -x steam >/dev/null 2>&1 && { printf 'steam\n'; return 0; }
    pgrep -f steamwebhelper >/dev/null 2>&1 && { printf 'steam\n'; return 0; }
    pgrep -x gamescope >/dev/null 2>&1 && { printf 'gamescope\n'; return 0; }
    return 1
}

# sc-controller writes its own pidfile; trust that over a process-name match.
# `pgrep -f scc-daemon` also matches any shell whose command line merely
# mentions the string - including this script's own helpers - so it reports a
# daemon that is not there. The socket alone is no better: it survives the
# process that created it.
daemon_pid() {
    local pid
    [ -f "$DAEMON_PIDFILE" ] || return 1
    pid="$(cat "$DAEMON_PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

daemon_running() { daemon_pid >/dev/null 2>&1; }

install_profile() {
    local content
    [ -f "$PROFILE_SRC" ] || { pz_error "perfil ausente: $PROFILE_SRC"; return 1; }
    # The shell() bindings need an absolute path, and the repo can live
    # anywhere (/usr/lib/phasezero when packaged, a checkout when developing).
    content="$(sed "s|PZ_ROOT|$PZ_ROOT|g" "$PROFILE_SRC")"

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: escreveria $PROFILE_DEST"
        return 0
    fi

    install -d "$PROFILE_DIR"
    pz_backup_file "$PROFILE_DEST" user >/dev/null 2>&1 || true
    printf '%s\n' "$content" >"$PROFILE_DEST"
    pz_info "perfil instalado: $PROFILE_DEST"
}

arm_revert() {
    [ "${PZ_DRY_RUN:-0}" = "1" ] && return 0
    [ "$REVERT_SECONDS" -gt 0 ] 2>/dev/null || return 0
    # setsid detaches the timer from this shell; a plain background subshell
    # dies with the terminal that ran `start`, taking the safety net with it.
    #
    # The timer kills the daemon by its recorded pid, never by pattern. A
    # pattern kill matches this very timer, whose own command line contains the
    # daemon name - it would take itself down before reverting anything, which
    # is exactly how the first version failed.
    #
    # $! after setsid is the wrapper, which exits as soon as it forks, so the
    # timer records its own pid from inside the child.
    setsid bash -c "
        printf '%s\n' \"\$\$\" >'$REVERT_PIDFILE'
        sleep $REVERT_SECONDS
        # confirm removes the pidfile; its absence means the operator came
        # back and kept the profile.
        [ -f '$REVERT_PIDFILE' ] || exit 0
        if [ -f '$DAEMON_PIDFILE' ]; then
            kill \"\$(cat '$DAEMON_PIDFILE' 2>/dev/null)\" >/dev/null 2>&1 || true
        fi
        rm -f '$REVERT_PIDFILE'
    " >/dev/null 2>&1 &
    # Give the child a moment to claim the pidfile so `status` and `confirm`
    # never read the wrapper pid.
    sleep 0.3
    pz_warn "reversão automática em ${REVERT_SECONDS}s; rode 'pz steamdeck controller confirm' para manter"
}

cmd_start() {
    local conflict bin
    bin="$(scc_daemon_bin)" || true

    # A dry run reports intent, so it must work on a machine that has neither
    # the mapper nor a controller attached - which is every CI runner. Only a
    # real start insists on both.
    if [ "${PZ_DRY_RUN:-0}" != "1" ]; then
        [ -n "$bin" ] || { pz_error "sc-controller ausente; instale o pacote sc-controller"; return 1; }
        if conflict="$(conflicting_session)"; then
            pz_error "$conflict está ativo e também mapeia o controle; feche antes de aplicar o perfil desktop"
            return 1
        fi
        controller_present || { pz_error "controle do Deck (28de:1205) não encontrado"; return 1; }
    else
        [ -n "$bin" ] || pz_warn "dry-run: sc-controller ausente; um start real falharia aqui"
        conflict="$(conflicting_session || true)"
        [ -n "$conflict" ] && pz_warn "dry-run: $conflict ativo; um start real seria recusado"
        controller_present || pz_warn "dry-run: controle do Deck não encontrado"
    fi

    install_profile || return 1

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: iniciaria scc-daemon com $PROFILE_NAME"
        return 0
    fi

    # The daemon takes the profile as a positional argument, so a fresh start
    # comes up already mapped; set-profile only covers the case where a daemon
    # was left running from an earlier session.
    if daemon_running; then
        scc set-profile "$PROFILE_NAME" >/dev/null 2>&1 ||
            pz_warn "não consegui trocar o perfil no daemon já ativo; verifique com 'status'"
    else
        "$bin" "$PROFILE_DEST" start >/dev/null 2>&1 || true
        sleep 1
    fi
    arm_revert
    pz_info "perfil desktop ativo"
}

cmd_confirm() {
    if [ -f "$REVERT_PIDFILE" ]; then
        local pid
        pid="$(cat "$REVERT_PIDFILE" 2>/dev/null || true)"
        [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
        rm -f "$REVERT_PIDFILE"
        pz_info "reversão automática cancelada; perfil mantido"
    else
        pz_info "nenhuma reversão pendente"
    fi
}

cmd_stop() {
    rm -f "$REVERT_PIDFILE"
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: pararia scc-daemon"
        return 0
    fi
    local pid
    scc-daemon stop >/dev/null 2>&1 || true
    # `scc-daemon stop` reports success even when it finds no pidfile, so it
    # cannot be the only step. Fall back to the recorded pid, not a pattern.
    if pid="$(daemon_pid)"; then
        kill "$pid" >/dev/null 2>&1 || true
    fi
    pz_info "perfil desktop desativado; lizard mode volta a valer"
}

cmd_status() {
    local conflict=""
    conflict="$(conflicting_session || true)"
    printf '{"profile":"%s","profileInstalled":%s,"controllerPresent":%s,"daemonRunning":%s,"conflictingSession":"%s","revertPending":%s}\n' \
        "$PROFILE_NAME" \
        "$([ -f "$PROFILE_DEST" ] && echo true || echo false)" \
        "$(controller_present && echo true || echo false)" \
        "$(daemon_running && echo true || echo false)" \
        "$conflict" \
        "$([ -f "$REVERT_PIDFILE" ] && echo true || echo false)"
}

case "${1:-status}" in
    start|install|apply) cmd_start ;;
    confirm|keep)        cmd_confirm ;;
    stop|disable)        cmd_stop ;;
    status)              cmd_status ;;
    dry-run)             PZ_DRY_RUN=1 cmd_start ;;
    *)
        pz_error "usage: controller-desktop.sh (start|confirm|stop|status|dry-run)"
        exit 1
        ;;
esac
