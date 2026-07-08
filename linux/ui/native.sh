#!/usr/bin/env bash
# Launch PhaseZero native Linux control center.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON="${PZ_PYTHON:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "PhaseZero UI: python3 missing" >&2
    exit 127
fi
if ! "$PYTHON" -c 'import PySide6' >/dev/null 2>&1; then
    cat >&2 <<'EOF'
PhaseZero UI: PySide6 missing.
Install package for distro:
  Arch/BigLinux: sudo pacman -S pyside6
  Debian/Ubuntu: sudo apt install python3-pyside6.qtwidgets
  Fedora: sudo dnf install python3-pyside6
EOF
    exit 69
fi

cd "$PZ_ROOT"
exec "$PYTHON" -m linux.ui_native "$@"
