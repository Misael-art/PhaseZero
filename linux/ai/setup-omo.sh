#!/usr/bin/env bash
# setup-omo.sh - install/configure oh-my-openagent (OMO) for OpenCode.
#
# OMO (https://github.com/code-yeongyu/oh-my-openagent, formerly oh-my-opencode)
# is a batteries-included OpenCode plugin: multi-model orchestration, parallel
# background sub-agents (Prometheus/Sisyphus/Oracle/...), LSP+AST tools and
# built-in MCPs (websearch, context7, grep_app, lsp). The Ultimate edition (the
# OpenCode plugin) requires Bun for its lifecycle scripts and OpenCode >= 1.4.
#
# Design notes:
#  - Invoked via `bunx oh-my-openagent` only (upstream forbids global installs).
#  - Provider-agnostic by default: no subscription is forced, so no provider ToS
#    is engaged until the user opts in (pass PZ_OMO_* / PZ_OMO_INSTALL_ARGS).
#    Autonomous long-loop agents generate heavy API traffic; enable a provider
#    deliberately and mind each provider's rate/usage policy.
#  - Telemetry off by default (OMO_DISABLE_POSTHOG=1); set PZ_OMO_TELEMETRY=1 to
#    keep the upstream default.
#  - `disable` unregisters the plugin so idle background agents cannot burn
#    tokens while a human is doing long manual testing.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
OPENCODE_JSONC="$OPENCODE_DIR/opencode.jsonc"
OPENCODE_JSON="$OPENCODE_DIR/opencode.json"
OMO_CONFIG="$OPENCODE_DIR/oh-my-openagent.json"
OMO_CONFIG_LEGACY="$OPENCODE_DIR/oh-my-opencode.json"
OMO_VERSION="${PZ_OMO_VERSION:-latest}"
OMO_SPEC="oh-my-openagent@${OMO_VERSION}"
OMO_PLUGIN_PREFIX="oh-my-openagent"

# Provider flags default to "no" -> provider-agnostic install. Override any of
# them, or replace the whole set with PZ_OMO_INSTALL_ARGS.
OMO_CLAUDE="${PZ_OMO_CLAUDE:-no}"
OMO_OPENAI="${PZ_OMO_OPENAI:-no}"
OMO_GEMINI="${PZ_OMO_GEMINI:-no}"
OMO_COPILOT="${PZ_OMO_COPILOT:-no}"

omo_env() {
    # Run "$@" with telemetry opted out unless the user explicitly keeps it on.
    if [ "${PZ_OMO_TELEMETRY:-0}" = "1" ]; then
        "$@"
    else
        OMO_DISABLE_POSTHOG=1 OMO_SEND_ANONYMOUS_TELEMETRY=0 "$@"
    fi
}

admin_run() {
    if pz_can_sudo_noninteractive; then
        sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then
        phasezero-admin "$@"
    else
        return 127
    fi
}

opencode_version() {
    command -v opencode >/dev/null 2>&1 || return 1
    opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

opencode_version_ok() {
    local v major minor
    v="$(opencode_version || true)"
    [ -n "$v" ] || return 1
    major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
    [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 4 ]; }
}

ensure_bun() {
    local installer="" size=0 rc=1
    command -v bun >/dev/null 2>&1 && return 0
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would install bun (OMO Ultimate requires it)"
        return 0
    fi
    if command -v pacman >/dev/null 2>&1; then
        pz_info "installing bun (required by OMO Ultimate/OpenCode)"
        if admin_run pacman -S --needed --noconfirm bun; then
            command -v bun >/dev/null 2>&1 && return 0
        fi
    fi
    # Fall back to the official user-space installer (no root).
    if command -v curl >/dev/null 2>&1; then
        pz_info "installing bun via official installer into ~/.bun"
        export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
        installer="$(pz_tempfile "${TMPDIR:-/tmp}/phasezero-bun.XXXXXX")"
        if curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
            --connect-timeout 15 --max-time 120 https://bun.sh/install -o "$installer"; then
            size="$(wc -c < "$installer")"
            if [ "$size" -ge 256 ] && [ "$size" -le 1048576 ] && head -n 1 "$installer" | grep -q '^#!'; then
                if bash "$installer" >/dev/null 2>&1; then rc=0; else rc=$?; fi
            else
                pz_warn "Bun installer failed content validation (size=$size)"
            fi
        fi
        rm -f -- "$installer"
        export PATH="$BUN_INSTALL/bin:$PATH"
        [ "$rc" -eq 0 ] && command -v bun >/dev/null 2>&1 && return 0
    fi
    pz_error "bun is required and could not be installed; install it and re-run"
    return 1
}

ensure_ast_grep() {
    # Optional: OMO's /refactor skill uses ast-grep. Non-fatal if unavailable.
    command -v ast-grep >/dev/null 2>&1 && return 0
    [ "${PZ_DRY_RUN:-0}" = "1" ] && { pz_info "dry-run: would install ast-grep (OMO /refactor)"; return 0; }
    command -v pacman >/dev/null 2>&1 || return 0
    pz_info "installing ast-grep (optional, powers OMO /refactor)"
    admin_run pacman -S --needed --noconfirm ast-grep >/dev/null 2>&1 ||
        pz_warn "ast-grep not installed; /refactor will be degraded (sudo pacman -S ast-grep)"
}

# --- opencode config helpers (opencode reads opencode.jsonc/json as strict JSON
#     in this project; mcp-manager.sh already relies on that) --------------------

active_opencode_config() {
    # Prefer the file OMO/opencode actually load; jsonc wins when both exist.
    if [ -f "$OPENCODE_JSONC" ]; then printf '%s\n' "$OPENCODE_JSONC"; return 0; fi
    if [ -f "$OPENCODE_JSON" ]; then printf '%s\n' "$OPENCODE_JSON"; return 0; fi
    return 1
}

plugin_registered() {
    local cfg
    cfg="$(active_opencode_config)" || return 1
    jq -e --arg p "$OMO_PLUGIN_PREFIX" \
        '(.plugin // []) | map(tostring) | any(startswith($p))' \
        "$cfg" >/dev/null 2>&1
}

unregister_plugin_file() {
    local cfg="$1" tmp
    [ -f "$cfg" ] || return 0
    jq . "$cfg" >/dev/null 2>&1 || { pz_warn "skip $cfg (not strict JSON)"; return 0; }
    tmp="$(pz_tempfile)"
    jq --arg p "$OMO_PLUGIN_PREFIX" '
        if has("plugin") then
            .plugin |= (map(select((tostring | startswith($p)) | not)))
            | (if (.plugin | length) == 0 then del(.plugin) else . end)
        else . end' "$cfg" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    pz_backup_file "$cfg" user >/dev/null
    mv "$tmp" "$cfg"
}

register_plugin_file() {
    local cfg="$1" tmp
    [ -f "$cfg" ] || return 0
    jq . "$cfg" >/dev/null 2>&1 || { pz_warn "skip $cfg (not strict JSON)"; return 0; }
    tmp="$(pz_tempfile)"
    jq --arg spec "$OMO_SPEC" --arg p "$OMO_PLUGIN_PREFIX" '
        .plugin = ((.plugin // []) | map(select((tostring | startswith($p)) | not)) + [$spec])
    ' "$cfg" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    pz_backup_file "$cfg" user >/dev/null
    mv "$tmp" "$cfg"
}

backup_opencode_config() {
    local f
    for f in "$OPENCODE_JSONC" "$OPENCODE_JSON"; do
        pz_backup_file "$f" user >/dev/null
    done
    return 0
}

# --- subcommands -------------------------------------------------------------

do_install() {
    pz_check_deps node npm jq curl
    if ! command -v opencode >/dev/null 2>&1; then
        pz_error "opencode not found; run: linux/pz ai setup opencode"
        return 1
    fi
    if ! opencode_version_ok; then
        pz_warn "opencode $(opencode_version || echo '?') is below the recommended >= 1.4"
    fi
    ensure_bun || return 1
    ensure_ast_grep

    local -a args
    if [ -n "${PZ_OMO_INSTALL_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        args=(--no-tui --platform=opencode $PZ_OMO_INSTALL_ARGS)
    else
        args=(--no-tui --platform=opencode
              --claude="$OMO_CLAUDE" --openai="$OMO_OPENAI"
              --gemini="$OMO_GEMINI" --copilot="$OMO_COPILOT")
    fi

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would run: bunx $OMO_SPEC install ${args[*]}"
        return 0
    fi

    backup_opencode_config
    pz_info "installing OMO plugin for OpenCode (bunx $OMO_SPEC)"
    if ! omo_env bunx "$OMO_SPEC" install "${args[@]}"; then
        pz_error "OMO installer failed"
        return 1
    fi
    # The installer registers the plugin itself; make sure it stuck.
    plugin_registered || {
        pz_warn "plugin not detected in config; registering manually"
        register_plugin_file "$(active_opencode_config)"
    }
    pz_info "OMO installed. Run 'linux/pz ai omo doctor' to verify."
    pz_info "No provider is enabled by default; authenticate one in opencode, then re-run with e.g. PZ_OMO_OPENAI=yes to wire models."
}

do_doctor() {
    if ! command -v bun >/dev/null 2>&1; then
        pz_error "bun missing; run: linux/pz ai setup omo"
        return 1
    fi
    local -a flags=(doctor --platform=opencode)
    case "${1:-}" in
        --json) flags+=(--json) ;;
        --status) flags+=(--status) ;;
        --verbose) flags+=(--verbose) ;;
    esac
    omo_env bunx "$OMO_SPEC" "${flags[@]}"
}

do_disable() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would unregister OMO plugin from opencode config"
        return 0
    fi
    unregister_plugin_file "$OPENCODE_JSONC"
    unregister_plugin_file "$OPENCODE_JSON"
    unregister_plugin_file "$OPENCODE_DIR/tui.json"
    pz_info "OMO plugin unregistered (config files kept). Re-enable: linux/pz ai omo enable"
}

do_enable() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would register OMO plugin into opencode config"
        return 0
    fi
    local cfg
    cfg="$(active_opencode_config)" || { pz_error "no opencode config found"; return 1; }
    register_plugin_file "$cfg"
    pz_info "OMO plugin registered in $cfg"
}

do_uninstall() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would unregister plugin and remove OMO config files"
        return 0
    fi
    do_disable
    if command -v bun >/dev/null 2>&1; then
        omo_env bunx "$OMO_SPEC" cleanup >/dev/null 2>&1 || true
    fi
    local f
    for f in "$OMO_CONFIG" "$OMO_CONFIG_LEGACY" "$OPENCODE_DIR/tui.json"; do
        [ -f "$f" ] && { pz_backup_file "$f" user >/dev/null; rm -f "$f"; pz_info "removed $f"; }
    done
    pz_info "OMO uninstalled from OpenCode"
}

do_status() {
    local bun_ver="" oc_ver="" cfg=""
    command -v bun >/dev/null 2>&1 && bun_ver="$(bun --version 2>/dev/null)"
    oc_ver="$(opencode_version || true)"
    cfg="$(active_opencode_config || true)"
    jq -n \
        --arg tool "omo" \
        --arg spec "$OMO_SPEC" \
        --arg bun "$bun_ver" \
        --arg opencode "$oc_ver" \
        --arg config "$cfg" \
        --argjson bunPresent "$(command -v bun >/dev/null 2>&1 && echo true || echo false)" \
        --argjson opencodeOk "$(opencode_version_ok && echo true || echo false)" \
        --argjson registered "$(plugin_registered && echo true || echo false)" \
        --argjson omoConfig "$([ -f "$OMO_CONFIG" ] || [ -f "$OMO_CONFIG_LEGACY" ] && echo true || echo false)" \
        --argjson telemetryOff "$([ "${PZ_OMO_TELEMETRY:-0}" = "1" ] && echo false || echo true)" \
        '{
            tool: $tool,
            spec: $spec,
            bun: {present: $bunPresent, version: $bun},
            opencode: {version: $opencode, versionOk: $opencodeOk, config: $config},
            plugin: {registered: $registered, omoConfigPresent: $omoConfig},
            telemetryOff: $telemetryOff
        }'
}

case "${1:-setup}" in
    setup|install) do_install ;;
    doctor) shift || true; do_doctor "${1:-}" ;;
    disable) do_disable ;;
    enable) do_enable ;;
    uninstall|cleanup) do_uninstall ;;
    status) do_status ;;
    dry-run) PZ_DRY_RUN=1 do_install ;;
    *)
        pz_error "usage: setup-omo.sh (setup|doctor [--json|--status|--verbose]|enable|disable|uninstall|status|dry-run)"
        exit 1
        ;;
esac
