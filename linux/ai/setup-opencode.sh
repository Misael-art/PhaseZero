#!/usr/bin/env bash
# setup-opencode.sh - configure OpenCode with MCPs, secrets and Steam Deck desktop UX
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.jsonc"
NPM_PREFIX="${PZ_NPM_PREFIX:-$HOME/.local/share/npm}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

# Terminals whose OSC 52 clipboard write works out of the box, preference order.
# kitty first: it also implements text-input-v3, which KWin needs to surface the
# Maliit virtual keyboard for a terminal. Konsole is deliberately absent: it
# ignores OSC 52, so OpenCode's copy silently fails inside it (OpenCode has no
# wl-copy/xclip fallback).
OSC52_TERMINALS=(kitty ghostty foot wezterm alacritty)

admin_run() {
    if pz_can_sudo_noninteractive; then
        sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then
        phasezero-admin "$@"
    else
        return 127
    fi
}

opencode_npm_managed() {
    [ -x "$NPM_PREFIX/bin/opencode" ]
}

install_or_update_opencode() {
    if opencode_npm_managed; then
        pz_info "updating npm-managed opencode in $NPM_PREFIX"
        npm install -g --prefix "$NPM_PREFIX" opencode-ai@latest
    elif command -v opencode >/dev/null 2>&1; then
        pz_info "opencode managed outside npm prefix ($(command -v opencode)); update it via the system package manager"
    else
        mkdir -p "$NPM_PREFIX"
        pz_info "installing opencode-ai into user npm prefix: $NPM_PREFIX"
        npm install -g --prefix "$NPM_PREFIX" opencode-ai@latest
        export PATH="$NPM_PREFIX/bin:$PATH"
        command -v opencode &>/dev/null || pz_warn "opencode installed but not on PATH; add $NPM_PREFIX/bin"
    fi
}

link_managed_bin() {
    local command_name="$1" source_path="$2"
    [ -x "$source_path" ] || return 0
    mkdir -p "$LOCAL_BIN"
    ln -sfn "$source_path" "$LOCAL_BIN/$command_name"
    pz_info "linked $command_name into $LOCAL_BIN"
}

find_osc52_terminal() {
    local term
    if [ -n "${PZ_OPENCODE_TERMINAL:-}" ] && command -v "$PZ_OPENCODE_TERMINAL" >/dev/null 2>&1; then
        printf '%s\n' "$PZ_OPENCODE_TERMINAL"
        return 0
    fi
    for term in "${OSC52_TERMINALS[@]}"; do
        if command -v "$term" >/dev/null 2>&1; then
            printf '%s\n' "$term"
            return 0
        fi
    done
    return 1
}

ensure_clipboard_stack() {
    local missing=()
    command -v wl-copy >/dev/null 2>&1 || missing+=(wl-clipboard)
    find_osc52_terminal >/dev/null || missing+=(kitty)

    [ ${#missing[@]} -gt 0 ] || return 0

    if ! command -v pacman >/dev/null 2>&1; then
        pz_warn "OpenCode clipboard needs: ${missing[*]}; install them manually"
        return 0
    fi

    pz_info "installing OpenCode clipboard stack: ${missing[*]}"
    if admin_run pacman -S --needed --noconfirm "${missing[@]}"; then
        pz_info "clipboard stack installed"
    else
        pz_warn "could not install ${missing[*]} automatically; run: sudo pacman -S ${missing[*]}"
    fi
}

write_deck_launcher() {
    mkdir -p "$LOCAL_BIN"
    pz_write_managed_file "$LOCAL_BIN/opencode-deck" <<EOF
#!/usr/bin/env bash
# opencode-deck - run OpenCode in an OSC52-capable terminal with the Steam Deck
# virtual keyboard. Konsole ignores OSC 52, so OpenCode copy fails inside it.
set -euo pipefail
PZ_ROOT="$PZ_ROOT"

TERMINAL="\${PZ_OPENCODE_TERMINAL:-}"
if [ -z "\$TERMINAL" ]; then
    for term in ${OSC52_TERMINALS[*]}; do
        if command -v "\$term" >/dev/null 2>&1; then
            TERMINAL="\$term"
            break
        fi
    done
fi
if [ -z "\$TERMINAL" ]; then
    TERMINAL="konsole"
    echo "warn: no OSC52-capable terminal found; copy inside OpenCode will not reach the clipboard (run: pz ai setup opencode)" >&2
fi

# Surface the virtual keyboard for touch typing on the Deck itself. It must be
# requested AFTER the terminal is focused: KWin only shows Maliit while a
# text-input client (e.g. kitty) holds focus.
if [ "\${PZ_OPENCODE_NO_KEYBOARD:-0}" != "1" ] &&
    [ "\$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)" = "Jupiter" ] &&
    [ -f "\$PZ_ROOT/linux/steamdeck/input-actions.sh" ]; then
    ( sleep 2; bash "\$PZ_ROOT/linux/steamdeck/input-actions.sh" open >/dev/null 2>&1 ) &
fi

case "\$TERMINAL" in
    wezterm) exec wezterm start -- opencode "\$@" ;;
    kitty|foot) exec "\$TERMINAL" opencode "\$@" ;;
    *) exec "\$TERMINAL" -e opencode "\$@" ;;
esac
EOF
    chmod +x "$LOCAL_BIN/opencode-deck"

    pz_write_managed_file "$APPLICATIONS_DIR/phasezero-opencode.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OpenCode (Deck)
Comment=OpenCode with working clipboard and virtual keyboard for Steam Deck desktop mode
Exec=$LOCAL_BIN/opencode-deck
Icon=utilities-terminal
Terminal=false
Categories=Development;Utility;
EOF
}

print_dry_run() {
    local terminal=""
    terminal="$(find_osc52_terminal || true)"
    jq -n \
        --arg tool "opencode" \
        --arg terminal "${terminal:-}" \
        --argjson npmManaged "$(opencode_npm_managed && echo true || echo false)" \
        --argjson wlClipboard "$(command -v wl-copy >/dev/null 2>&1 && echo true || echo false)" \
        --argjson installed "$(command -v opencode >/dev/null 2>&1 && echo true || echo false)" \
        '{
            tool: $tool,
            installed: $installed,
            npmManaged: $npmManaged,
            clipboard: {
                wlClipboard: $wlClipboard,
                osc52Terminal: (if $terminal == "" then null else $terminal end)
            },
            launcher: "opencode-deck"
        }'
}

setup_templates() {
    mkdir -p "$(dirname "$OPENCODE_CONFIG")"
    if [ ! -f "$OPENCODE_CONFIG" ]; then
        pz_info "creating default OpenCode config"
        pz_write_managed_file "$OPENCODE_CONFIG" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {}
}
EOF
    fi

    local template_dir="$PZ_ROOT/linux/ai/templates" tmpl name target
    if [ -d "$template_dir" ]; then
        for tmpl in "$template_dir"/*; do
            [ -f "$tmpl" ] || continue
            name=$(basename "$tmpl")
            target="${HOME}/.config/opencode/${name}"
            if [ ! -f "$target" ]; then
                cp "$tmpl" "$target"
                pz_info "installed template: $name"
            fi
        done
    fi
}

case "${1:-setup}" in
    setup)
        pz_check_deps npm jq
        setup_templates
        install_or_update_opencode
        link_managed_bin opencode "$NPM_PREFIX/bin/opencode"
        ensure_clipboard_stack
        write_deck_launcher
        bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync opencode >/dev/null || pz_warn "OpenCode MCP sync failed"
        pz_info "OpenCode setup complete. Config at $OPENCODE_CONFIG"
        ;;
    desktop-integration)
        # launcher + desktop entry only; no package installs, no npm, no MCP sync
        write_deck_launcher
        pz_info "OpenCode desktop integration written (launcher: $LOCAL_BIN/opencode-deck)"
        ;;
    dry-run)
        print_dry_run
        ;;
    *)
        pz_error "usage: setup-opencode.sh (setup|desktop-integration|dry-run)"
        exit 1
        ;;
esac
