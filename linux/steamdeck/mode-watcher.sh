#!/usr/bin/env bash
# mode-watcher.sh - daemon that watches for display mode changes
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/common.sh"
steamdeck_mode_watcher
