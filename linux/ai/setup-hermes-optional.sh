#!/usr/bin/env bash
# setup-hermes-optional.sh - best-effort Hermes step for broad profiles.
#
# PZ-AUD-021: Hermes is experimental (unapproved distribution, host-workload
# gate). A default profile must not abort silently NOR fail loudly because
# of it: gate blocks become an explained skip, real errors still propagate.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

rc=0
bash "$PZ_ROOT/linux/ai/setup-hermes.sh" "$@" || rc=$?
if [ "$rc" -eq 69 ]; then
    echo "SKIP: Hermes is experimental and blocked on this host (missing host-workload release or unapproved distribution)." >&2
    echo "SKIP: continue without Hermes; run 'pz ai hermes doctor' for the maturity checklist." >&2
    exit 0
fi
exit "$rc"
