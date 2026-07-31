#!/usr/bin/env bash
# install-plugins.sh - install Decky Loader, curated plugins, and CSS Loader themes
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/plugins.sh" install
