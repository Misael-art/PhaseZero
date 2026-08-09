#!/usr/bin/env bash
# detect-mode.sh - display mode detection for Steam Deck
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/common.sh"
steamdeck_detect_mode
