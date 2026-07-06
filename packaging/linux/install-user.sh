#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"

install -d "$BIN_HOME" "$APP_DIR" "$ICON_DIR"
ln -sfn "$ROOT/packaging/linux/phasezero-control-center" \
    "$BIN_HOME/phasezero-control-center"
# Absolute Exec: desktop launchers don't always have ~/.local/bin on PATH.
sed "s|^Exec=.*|Exec=$BIN_HOME/phasezero-control-center|" \
    "$ROOT/packaging/linux/io.phasezero.ControlCenter.desktop" \
    > "$APP_DIR/io.phasezero.ControlCenter.desktop"
chmod 644 "$APP_DIR/io.phasezero.ControlCenter.desktop"
install -m644 "$ROOT/packaging/linux/io.phasezero.ControlCenter.svg" \
    "$ICON_DIR/io.phasezero.ControlCenter.svg"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "PhaseZero instalado para usuário."
echo "Comando: $BIN_HOME/phasezero-control-center"
echo "Desktop: $APP_DIR/io.phasezero.ControlCenter.desktop"
