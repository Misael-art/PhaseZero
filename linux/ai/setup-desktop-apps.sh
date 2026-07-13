#!/usr/bin/env bash
# setup-desktop-apps.sh - install supported AI desktop apps and update services.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-claude
bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-qwen
bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-services
