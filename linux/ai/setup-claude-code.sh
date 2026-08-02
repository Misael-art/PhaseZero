#!/usr/bin/env bash
# Transactional Claude Code + Bonsai + proxy manager.
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$#" -eq 0 ]; then
    set -- install
fi
exec python3 "$PZ_ROOT/linux/ai/claude_code_manager.py" "$@"
