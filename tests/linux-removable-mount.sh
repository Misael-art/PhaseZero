#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export XDG_STATE_HOME="$TMP_ROOT/state"

bash -n "$REPO_ROOT/linux/steamdeck/install-removable-mount.sh"
bash -n "$REPO_ROOT/linux/steamdeck/removable-mount-helper.sh"
plan="$("$REPO_ROOT/linux/steamdeck/install-removable-mount.sh" dry-run --target-user "$(id -un)")"
grep -q "mount root: /run/media/$(id -un)" <<< "$plan"
# shellcheck disable=SC2016  # Verify literal runtime expansion in installed helper.
grep -q 'runuser -u "$TARGET_USER"' "$REPO_ROOT/linux/steamdeck/removable-mount-helper.sh"
grep -q 'DBUS_SESSION_BUS_ADDRESS=' "$REPO_ROOT/linux/steamdeck/removable-mount-helper.sh"

set +e
PZ_TARGET_USER="$(id -un)" "$REPO_ROOT/linux/steamdeck/removable-mount-helper.sh" '../../unsafe' >/dev/null 2>&1
rc=$?
set -e
test "$rc" -ne 0

echo "linux removable mount tests passed"
