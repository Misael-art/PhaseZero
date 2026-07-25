#!/usr/bin/env bash
# Auto-applier for the apply-server-llm-homelab profile (run with no args by pz_run_profile).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply-common.sh"
pz_server_apply --llm --homelab
