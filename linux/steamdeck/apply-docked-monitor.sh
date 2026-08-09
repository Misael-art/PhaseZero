#!/usr/bin/env bash
# apply-docked-monitor.sh - apply docked monitor mode config
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/common.sh"
steamdeck_apply_docked_monitor
