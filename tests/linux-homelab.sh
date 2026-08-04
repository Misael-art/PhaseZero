#!/usr/bin/env bash
# Smoke tests for Linux Homelab + CasaOS UX.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_STATE_HOME="$TMP/state"
export PZ_HOMELAB_STATE="$TMP/homelab"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$PZ_HOMELAB_STATE"

echo "=== syntax ==="
bash -n "$REPO_ROOT/linux/server/homelab-stack.sh"
bash -n "$REPO_ROOT/linux/server/casaos.sh"
bash -n "$REPO_ROOT/linux/server/apply-common.sh"
bash -n "$REPO_ROOT/linux/pz"
echo "  syntax ok"

echo "=== server profile argument integrity ==="
apply_capture="$TMP/apply-common.args"
(
    # shellcheck source=../linux/server/apply-common.sh
    source "$REPO_ROOT/linux/server/apply-common.sh"
    # shellcheck disable=SC2329,SC2317 # stubs invoked indirectly via sourced functions
    bash() { printf '%s\n' "$*" >> "$apply_capture"; }
    # shellcheck disable=SC2329,SC2317
    pz_info() { :; }
    # shellcheck disable=SC2329,SC2317
    pz_warn() { :; }
    PZ_SERVER_INSTALL_BOOT=0 pz_server_apply --homelab --extras --no-boot
)
grep -Fq "$REPO_ROOT/linux/server/homelab-stack.sh up --extras" "$apply_capture"
test "$(wc -l < "$apply_capture")" -eq 1
echo "  profile args ok"

echo "=== compose has pinned tags and safe binds ==="
if rg -n ':latest' "$REPO_ROOT/assets/home-server/docker-compose."*.yml; then
    echo "FAIL: compose uses latest tag"
    exit 1
fi
rg -q 'HOMELAB_ADMIN_BIND_ADDR' "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml"
rg -q 'HOMELAB_PUBLIC_BIND_ADDR' "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml"
rg -q 'HOMELAB_ADMIN_BIND_ADDR' "$REPO_ROOT/assets/home-server/docker-compose.extras.yml"
echo "  compose pins/binds ok"

echo "=== missing .env blocks sensitive services ==="
"$REPO_ROOT/linux/pz" server homelab plan --json --extras | jq -e '
  .status == "blocked"
  and (.blockers | any(test("VW_ADMIN_TOKEN")))
  and (.blockers | any(test("NEXTCLOUD_DB_PASSWORD")))
' >/dev/null
echo "  missing secrets blockers ok"

echo "=== repair generates secure .env without printing secrets ==="
repair_out="$("$REPO_ROOT/linux/pz" server homelab repair --access local --json)"
test "$(stat -c '%a' "$PZ_HOMELAB_STATE/.env")" = "600"
echo "$repair_out" | jq -e '
  .action == "repair"
  and .after.stack.env.exists == true
  and (.after.stack.env.secrets | all(.present == true))
  and .after.stack.access.effective == "local"
  and .after.stack.access.adminBind == "127.0.0.1"
' >/dev/null
if echo "$repair_out" | rg -q '[a-f0-9]{64}'; then
    echo "FAIL: secret value leaked in JSON"
    exit 1
fi
echo "  secure env ok"

echo "=== compose config core/extras ==="
if docker compose version >/dev/null 2>&1; then
    docker compose --env-file "$PZ_HOMELAB_STATE/.env" -p phasezero-homelab-test \
        -f "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml" config --services |
        sort | jq -R . | jq -cs 'index("portainer") and index("vaultwarden") and index("jellyfin")' >/dev/null
    docker compose --env-file "$PZ_HOMELAB_STATE/.env" -p phasezero-homelab-test \
        -f "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml" \
        -f "$REPO_ROOT/assets/home-server/docker-compose.extras.yml" config --services |
        sort | jq -R . | jq -cs 'index("nextcloud") and index("grafana") and index("paperless") and index("n8n")' >/dev/null
    echo "  compose config ok"
else
    echo "  docker compose unavailable; skipped"
fi

echo "=== tailscale logged-out blocker ==="
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tailscale" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  status) echo "Logged out" >&2; exit 1 ;;
  ip) exit 0 ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$FAKEBIN/tailscale"
PATH="$FAKEBIN:$PATH" "$REPO_ROOT/linux/pz" server homelab plan --json --access tailscale |
    jq -e '.access.effective == "blocked" and (.blockers | any(test("tailscale logged out")))' >/dev/null
echo "  tailscale blocker ok"

echo "=== open/logical urls and backup/restore dry-runs ==="
"$REPO_ROOT/linux/pz" server homelab open jellyfin --json | jq -e '.url == "http://127.0.0.1:8096"' >/dev/null
"$REPO_ROOT/linux/pz" server homelab backup --dry-run --extras | jq -e '.dryRun == true and (.volumes | index("vaultwarden_data")) and (.volumes | index("nextcloud_data"))' >/dev/null
mkdir -p "$TMP/backup"
touch "$TMP/backup/vaultwarden_data.tgz"
"$REPO_ROOT/linux/pz" server homelab restore --source "$TMP/backup" --dry-run | jq -e '.requiresConfirmation == true and (.archives | index("vaultwarden_data.tgz"))' >/dev/null
echo "  dry-runs ok"

echo "=== CasaOS compatibility gate ==="
cat > "$TMP/ubuntu-os-release" <<'EOF'
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu Test"
EOF
PZ_CASAOS_OS_RELEASE="$TMP/ubuntu-os-release" "$REPO_ROOT/linux/pz" server casaos plan --json |
    jq -e '.status == "available" and .compatibility.compatible == true and (.compatibility.blockers | length == 0)' >/dev/null
PZ_DRY_RUN=1 PZ_CASAOS_OS_RELEASE="$TMP/ubuntu-os-release" \
    "$REPO_ROOT/linux/pz" server casaos install --yes |
    jq -e '.dryRun == true and .download[0] == "curl" and .execute == ["bash", "<temporary>"] and (.download | index("=https"))' >/dev/null
if PZ_DRY_RUN=1 PZ_CASAOS_OS_RELEASE="$TMP/ubuntu-os-release" PZ_CASAOS_INSTALL_URL='http://example.invalid/install.sh' \
    "$REPO_ROOT/linux/pz" server casaos install --yes >/dev/null 2>&1; then
    echo "FAIL: CasaOS accepted non-HTTPS installer URL"
    exit 1
fi

cat > "$TMP/arch-os-release" <<'EOF'
ID=arch
ID_LIKE=arch
PRETTY_NAME="Arch Test"
EOF
PZ_CASAOS_OS_RELEASE="$TMP/arch-os-release" "$REPO_ROOT/linux/pz" server casaos plan --json |
    jq -e '.status == "blocked" and .compatibility.compatible == false and (.compatibility.blockers | length > 0)' >/dev/null
echo "  casaos gate ok"

echo "=== aggregate status schemaVersion + ready proofs ==="
status_json="$("$REPO_ROOT/linux/pz" server homelab status --json 2>/dev/null)" || true
echo "$status_json" | jq -e '
  .schemaVersion == "1"
  and .tool == "homelab-status"
  and .ready == false
  and (.reasons | length > 0)
  and .degraded == false
  and .securityState.redaction == true
  and (.lastOperation | type == "object")
  and (.resume | has("resumed"))
  and (.versions.phasezero.version | length > 0)
' >/dev/null || { echo "FAIL: aggregate status schema invalid"; echo "$status_json" | jq -c '{ready,reasons,degraded,sec:.securityState}' 2>/dev/null; exit 1; }
echo "  status schema ok"
# verify before any persisted status: must not be verified
fresh_status() {
    rm -f "$PZ_HOMELAB_STATE/status.json"
    local v
    v="$("$REPO_ROOT/linux/pz" server homelab verify --json 2>/dev/null)" || true
    printf '%s\n' "$v" | jq -e '
      .action == "verify" and .verified == false and (.checks | length > 0)
    ' >/dev/null
}
fresh_status || { echo "FAIL: verify with no persisted status"; exit 1; }
echo "  fresh verify ok"
# verify after status persisted: consistent -> verified
"$REPO_ROOT/linux/pz" server homelab status --json >/dev/null 2>&1 || true
v2="$("$REPO_ROOT/linux/pz" server homelab verify --json 2>/dev/null)" || true
printf '%s\n' "$v2" | jq -e '
  .action == "verify" and .verified == true and (.checks | length == 0)
' >/dev/null
echo "  consistent verify ok"
echo "  verify ok"
test -s "$PZ_HOMELAB_STATE/status.json"
echo "  status persisted ok"

echo "=== operations: registry flow ==="
OPS="$PZ_HOMELAB_STATE/operations"
op_id="$("$REPO_ROOT/linux/server/homelab-operations.sh" start backup profile=assistant)"
echo "$op_id" | rg -q '^[0-9TZ]+-[0-9]+-[0-9]+$'
jq -e '.schemaVersion == 1 and .status == "running" and .action == "backup" and .rollbackAvailable == false' "$OPS/$op_id.json" >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" step "$op_id" dump-volumes
jq -e '.step == "dump-volumes" and .status == "running"' "$OPS/$op_id.json" >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" finish "$op_id" succeeded --rollback-available
jq -e '.status == "succeeded" and .rollbackAvailable == true' "$OPS/$op_id.json" >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" last | jq -e '.operationId == "'"$op_id"'"' >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" list --json | jq -e --arg id "$op_id" 'any(.operationId == $id)' >/dev/null
echo "  operation registry ok"

echo "=== operations: cross-process lock ==="
# outer subshell holds fd9 flock (bg), inner attempt must time out
(
    exec 9>"$PZ_HOMELAB_STATE/homelab.lock"
    flock 9
    sleep 3 &
    SLEEPPID=$!
    wait "$SLEEPPID"
) &
LOCKPID=$!
sleep 0.3
if PZ_HOMELAB_SO_LOCK=1 PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" \
    "$REPO_ROOT/linux/server/homelab-operations.sh" lock --wait 1 >/dev/null 2>&1; then
    echo "FAIL: lock acquired while held"
    exit 1
fi
wait "$LOCKPID"
echo "  lock ok"

echo "=== operations: crash -> resume -> cancel ==="
crash_op="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" "$REPO_ROOT/linux/server/homelab-operations.sh" start apply profile=edge)"
"$REPO_ROOT/linux/server/homelab-operations.sh" step "$crash_op" pull-images
"$REPO_ROOT/linux/server/homelab-operations.sh" abort "$crash_op"
"$REPO_ROOT/linux/server/homelab-operations.sh" resume-info | jq -e '.resumable == true and .operationId == "'"$crash_op"'" and .lastStep == "pull-images"' >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" abort "$crash_op" cancelled
"$REPO_ROOT/linux/server/homelab-operations.sh" resume-info | jq -e '.resumable == false and .status == "cancelled"' >/dev/null
echo "  crash/resume/cancel ok"

echo "=== operations: idempotent re-entry + corrupted state fail-closed ==="
re2="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" "$REPO_ROOT/linux/server/homelab-operations.sh" start apply profile=edge)"
test "$re2" != "$crash_op"
echo 'garbage{{not-json' > "$OPS/zz-corrupt.json"
corrupt_json="$("$REPO_ROOT/linux/pz" server homelab status --json 2>/dev/null)" || true
if printf '%s\n' "$corrupt_json" | jq -e '.reasons | any(test("corrupted"))' >/dev/null; then
    echo "  corrupted conflict reason ok"
else
    echo "FAIL: corrupted op registry did not fail closed"
    exit 1
fi
rm -f "$OPS/zz-corrupt.json"
echo "  idempotency/corrupt ok"

echo "=== profiles: registry + resource governor ==="
profile_list="$("$REPO_ROOT/linux/server/homelab-governor.sh" list)"
printf '%s\n' "$profile_list" | jq -e --argjson keys '["core","media","cloud","assistant","monitoring","edge"]' \
  '.schemaVersion == 1 and (.profiles|length) == 6 and ([.profiles[].key] | sort) == ($keys|sort) and .default == "core" and all(.profiles[]; (.title|length>0) and (.services|type=="array"))' >/dev/null
echo "  registry 6 profiles ok"
"$REPO_ROOT/linux/server/homelab-governor.sh" weights | jq -e '.weightsMB.jellyfin == 2048 and (.weightsMB|length) == 12' >/dev/null
echo "  weights ok"
if PZ_HOMELAB_RAM_TOTAL_OVERRIDE=3000 "$REPO_ROOT/linux/server/homelab-governor.sh" check media >/dev/null 2>&1; then
    echo "FAIL: overcommit check passed"; exit 1
fi
echo "  overcommit fails closed ok"
if PZ_HOMELAB_RAM_TOTAL_OVERRIDE=0 "$REPO_ROOT/linux/server/homelab-governor.sh" check core >/dev/null 2>&1; then
    echo "FAIL: zero-RAM check passed"; exit 1
fi
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 "$REPO_ROOT/linux/server/homelab-governor.sh" budget media | jq -e '.verdict == "pass" and .budgetMB == 3072' >/dev/null
echo "  in-budget pass ok"
if "$REPO_ROOT/linux/server/homelab-governor.sh" check bogus >/dev/null 2>&1; then
    echo "FAIL: unknown profile accepted"; exit 1
fi
echo "  unknown profile rejected ok"
if "$REPO_ROOT/linux/server/homelab-operations.sh" start apply profile=bogus >/dev/null 2>&1; then
    echo "FAIL: ops accepted bogus profile"; exit 1
fi
echo "  ops profile validation ok"
"$REPO_ROOT/linux/pz" server homelab profile list | jq -e '.profiles|length == 6' >/dev/null
"$REPO_ROOT/linux/pz" server homelab profile set media >/dev/null
test "$(cat "$PZ_HOMELAB_STATE/profile.active")" = "media"
echo "  profile set ok"
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 "$REPO_ROOT/linux/pz" server homelab status --json >/tmp/ps.json 2>&1 || true
jq -e '.profile == "media" and (.resourceBudget|type=="object") and .resourceBudget.verdict == "pass"' /tmp/ps.json >/dev/null
echo "  status budget wiring ok"
if "$REPO_ROOT/linux/pz" server homelab profile set bogus >/dev/null 2>&1; then
    echo "FAIL: pz set accepted bogus profile"; exit 1
fi
echo "  pz set validation ok"
if PZ_DRY_RUN=1 PZ_HOMELAB_RAM_TOTAL_OVERRIDE=512 \
    "$REPO_ROOT/linux/pz" server homelab up --profile media >/dev/null 2>&1; then
    echo "FAIL: up accepted overcommit profile"; exit 1
fi
echo "  up profile gate ok"

echo "=== boot-prepare identity: marker absent is a no-op ==="
"$REPO_ROOT/linux/server/homelab-boot-prepare.sh" 2>&1 | rg -q 'nothing to do'
echo "  marker-absent ok"

echo "=== boot-prepare bring-up as target user, no root/real-home writes ==="
FB="$TMP/bootbin"
mkdir -p "$FB"
cat > "$FB/systemctl" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
    start) exit 0 ;;
    *) exit 0 ;;
esac
EOS
cat > "$FB/runuser" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RUNUSER_CAPTURE"
for a in "$@"; do
    case "$a" in
        HOME=*) echo "$a" | sed 's/^HOME=//' > "$RUNUSER_HOME_CAPTURE" ;;
        XDG_STATE_HOME=*) echo "$a" | sed 's/^XDG_STATE_HOME=//' > "$RUNUSER_XDG_CAPTURE" ;;
    esac
done
exit 0
EOS
chmod +x "$FB/systemctl" "$FB/runuser"
export RUNUSER_CAPTURE="$TMP/runuser.capture" RUNUSER_HOME_CAPTURE="$TMP/runuser.home" RUNUSER_XDG_CAPTURE="$TMP/runuser.xdg"
rm -f "$RUNUSER_CAPTURE" "$RUNUSER_HOME_CAPTURE" "$RUNUSER_XDG_CAPTURE"
BOOTSTATE="$TMP/boot-test-state"
PATH="$FB:$PATH" PZ_BOOT_MARKER=1 PZ_SERVER_USER=testuser PZ_SERVER_HOMELAB=1 \
    PZ_SERVER_LLM=0 PZ_SERVER_HERMES=0 PZ_STATE_ROOT="$TMP/boot-state-root" \
    PZ_HOMELAB_STATE="$BOOTSTATE" "$REPO_ROOT/linux/server/homelab-boot-prepare.sh" >/dev/null 2>&1
grep -Fq 'bash' "$RUNUSER_CAPTURE"
rg -q 'homelab-stack\.sh' "$RUNUSER_CAPTURE" \
    || { echo "FAIL: stack not invoked"; exit 1; }
rg -q '^--access$' "$RUNUSER_CAPTURE" && rg -q '^local$' "$RUNUSER_CAPTURE" \
    || { echo "FAIL: stack not invoked with up --access local"; exit 1; }
test "$(cat "$RUNUSER_HOME_CAPTURE")" != "/root"
test "$(cat "$RUNUSER_XDG_CAPTURE")" = "$TMP/boot-state-root"
test ! -e /root/.local/state/phasezero/homelab/degraded.json
test -f "$BOOTSTATE/degraded.json" && { echo "FAIL: degraded marker on success"; exit 1; }
echo "  identity ok"

echo "=== boot-prepare essential failure marks degraded and fails unit ==="
cat > "$FB/systemctl" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
    start) [ "$2" = "docker" ] && exit 1 || exit 0 ;;
    *) exit 0 ;;
esac
EOS
if PATH="$FB:$PATH" PZ_BOOT_MARKER=1 PZ_SERVER_USER=testuser PZ_SERVER_HOMELAB=1 \
    PZ_SERVER_LLM=0 PZ_SERVER_HERMES=0 PZ_STATE_ROOT="$TMP/boot-state-root" \
    PZ_HOMELAB_STATE="$BOOTSTATE" "$REPO_ROOT/linux/server/homelab-boot-prepare.sh" >/dev/null 2>&1; then
    echo "FAIL: essential bring-up failure did not fail the unit"
    exit 1
fi
jq -e '.reasons | any(.reason == "docker service failed to start")' "$BOOTSTATE/degraded.json" >/dev/null
echo "  degraded/fail ok"

echo "=== access mode persists in homelab env ==="
"$REPO_ROOT/linux/pz" server homelab repair --access tailscale >/dev/null 2>&1 || true
rg -q '^HOMELAB_ACCESS_MODE=tailscale$' "$PZ_HOMELAB_STATE/.env"
"$REPO_ROOT/linux/pz" server homelab repair --access local >/dev/null 2>&1 || true
echo "  access persistence ok"

echo "=== Homelab smoke ok ==="
