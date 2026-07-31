#!/usr/bin/env bash
# apply-docked-tv.sh - apply docked TV mode config
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/common.sh"
steamdeck_apply_docked_tv
