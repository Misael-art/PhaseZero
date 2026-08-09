#!/usr/bin/env bash
# apply-handheld.sh - apply handheld mode config
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/common.sh"
steamdeck_apply_handheld
