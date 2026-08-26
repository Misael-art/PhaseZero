#!/usr/bin/env bash
# Smoke tests for Linux Homelab + CasaOS UX.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# boot-prepare resolves its runtime from an installed package first; force
# the checkout so hermetic runs never depend on (or collide with) a host
# installation.
export PZ_ROOT="$REPO_ROOT"

export HOME="$TMP/home"
export XDG_STATE_HOME="$TMP/state"
export PZ_HOMELAB_STATE="$TMP/homelab"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$PZ_HOMELAB_STATE"

# Pin the WinVM contract boundary to a stub so the suite never touches the
# real WinVM (or the host `pz`) and stays deterministic on every runner.
export PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm.status"
printf '%s\n' '{"libvirtState":"shut off","currentMarker":"no","bootRuntimeStale":false}' > "$PZ_HOMELAB_WINVM_STATUS_FILE"

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
# every service block must carry no-new-privileges and a memory cap
for f in "$REPO_ROOT/assets/home-server/docker-compose."*.yml; do
    svcs="$(rg -c '^  [a-z0-9-]+:$' "$f")"
    [ "$(rg -c 'no-new-privileges' "$f")" -eq "$svcs" ] || { echo "FAIL: missing no-new-privileges in $f"; exit 1; }
    [ "$(rg -c 'mem_limit:' "$f")" -eq "$svcs" ] || { echo "FAIL: missing mem_limit in $f"; exit 1; }
done
jq -e '.schemaVersion == 1 and (.images | length == 13) and all(.images[]; (test(":latest") | not))' \
    "$REPO_ROOT/assets/home-server/docker-compose.lock.json" >/dev/null
echo "  compose pins/binds/hardening ok"

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
        sort | jq -R . | jq -cs 'index("vaultwarden") and index("jellyfin") and index("syncthing") and (index("portainer") | not)' >/dev/null
    docker compose --env-file "$PZ_HOMELAB_STATE/.env" -p phasezero-homelab-test \
        -f "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml" \
        -f "$REPO_ROOT/assets/home-server/docker-compose.extras.yml" config --services |
        sort | jq -R . | jq -cs 'index("nextcloud") and index("grafana") and index("paperless") and index("n8n") and index("portainer")' >/dev/null
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
status_json="$("$REPO_ROOT/linux/pz" server homelab status --json 2>/dev/null)"; status_rc=$?
# A valid diagnostic is a success even when the stack is not configured:
# readiness lives in the fields (ready/state/reasons), never in the exit code.
[ "$status_rc" -eq 0 ] || { echo "FAIL: homelab status must exit 0 with a valid report"; exit 1; }
echo "$status_json" | jq -e '
  .schemaVersion == "1"
  and .tool == "homelab-status"
  and .ready == false
  and (.reasons | length > 0)
  and (.state | type == "string" and length > 0)
  and (.summary | type == "string" and length > 0)
  and (.nextAction == null or (.nextAction | type == "string"))
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
op_id="$("$REPO_ROOT/linux/server/homelab-operations.sh" start backup profile=assistant-private)"
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
printf '%s\n' "$profile_list" | jq -e --argjson keys '["ai-studio","assistant-multichannel","assistant-private","automation","developer","edge"]' \
  '.schemaVersion == 1 and (.profiles|length) == 6 and ([.profiles[].key] | sort) == ($keys|sort) and .default == "edge" and all(.profiles[]; (.title|length>0) and (.services|type=="array") and (.class|length>0) and (.maturity|length>0))' >/dev/null
echo "  registry 6 profiles ok"
"$REPO_ROOT/linux/server/homelab-governor.sh" weights | jq -e '.weightsMB.jellyfin == 2048 and .weightsMB.ollama == 2048 and (.weightsMB|length) == 27' >/dev/null
echo "  weights ok"
if PZ_HOMELAB_RAM_TOTAL_OVERRIDE=3000 "$REPO_ROOT/linux/server/homelab-governor.sh" check ai-studio >/dev/null 2>&1; then
    echo "FAIL: overcommit check passed"; exit 1
fi
echo "  overcommit fails closed ok"
if PZ_HOMELAB_RAM_TOTAL_OVERRIDE=0 "$REPO_ROOT/linux/server/homelab-governor.sh" check edge >/dev/null 2>&1; then
    echo "FAIL: zero-RAM check passed"; exit 1
fi
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 "$REPO_ROOT/linux/server/homelab-governor.sh" budget assistant-private | jq -e '.verdict == "pass" and .budgetMB == 4224' >/dev/null
echo "  in-budget pass ok"
# CCS-014: budget-active usa o perfil ativo real; sem perfil, falha fechado
# com a lista de perfis públicos.
gov_state="$PZ_HOMELAB_STATE"
if PZ_HOMELAB_STATE="$gov_state/no-active" PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 \
    "$REPO_ROOT/linux/server/homelab-governor.sh" budget-active > "$gov_state/budget-empty.json" 2>/dev/null; then
    echo "FAIL: budget-active sem perfil ativo deveria falhar"; exit 1
fi
jq -e '.error == "no-active-profile" and (.profiles | index("edge"))' "$gov_state/budget-empty.json" >/dev/null
mkdir -p "$gov_state/with-profile"
printf 'assistant-private\n' > "$gov_state/with-profile/profile.active"
PZ_HOMELAB_STATE="$gov_state/with-profile" PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 \
    "$REPO_ROOT/linux/server/homelab-governor.sh" budget-active | \
    jq -e '.profile == "assistant-private" and .verdict == "pass"' >/dev/null
echo "  budget-active real profile ok"
# "core" nunca é chave pública de perfil appliance
if "$REPO_ROOT/linux/server/homelab-governor.sh" check core >/dev/null 2>&1; then
    echo "FAIL: 'core' aceito como perfil appliance"; exit 1
fi
if "$REPO_ROOT/linux/server/homelab-governor.sh" check bogus >/dev/null 2>&1; then
    echo "FAIL: unknown profile accepted"; exit 1
fi
echo "  unknown profile rejected ok"
if "$REPO_ROOT/linux/server/homelab-operations.sh" start apply profile=bogus >/dev/null 2>&1; then
    echo "FAIL: ops accepted bogus profile"; exit 1
fi
echo "  ops profile validation ok"
"$REPO_ROOT/linux/pz" server homelab profile list | jq -e '.profiles|length == 6' >/dev/null
"$REPO_ROOT/linux/pz" server homelab profile set assistant-private >/dev/null
test "$(cat "$PZ_HOMELAB_STATE/profile.active")" = "assistant-private"
echo "  profile set ok"
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 "$REPO_ROOT/linux/pz" server homelab status --json >/tmp/ps.json 2>&1 || true
jq -e '.profile == "assistant-private" and (.resourceBudget|type=="object") and .resourceBudget.verdict == "pass"' /tmp/ps.json >/dev/null
echo "  status budget wiring ok"
if "$REPO_ROOT/linux/pz" server homelab profile set bogus >/dev/null 2>&1; then
    echo "FAIL: pz set accepted bogus profile"; exit 1
fi
echo "  pz set validation ok"
if PZ_DRY_RUN=1 PZ_HOMELAB_RAM_TOTAL_OVERRIDE=512 \
    "$REPO_ROOT/linux/pz" server homelab up --profile ai-studio >/dev/null 2>&1; then
    echo "FAIL: up accepted overcommit profile"; exit 1
fi
echo "  up profile gate ok"

echo "=== winvm contract: status boundary, graceful suspend, resume ==="
jq -e '.winvmMB == 2048' "$REPO_ROOT/assets/home-server/homelab-profiles.json" >/dev/null
echo "  winvm weight registered ok"
"$REPO_ROOT/linux/server/homelab-governor.sh" winvm-status | jq -e '.status == "idle" and .active == false and .weightMB == 2048' >/dev/null
echo "  winvm idle detection ok"
# Unconfigured budget is a reportable state (rc 0 + envelope), not a failure.
PZ_HOMELAB_PROFILES_FILE="$TMP/registry-ausente.json" "$REPO_ROOT/linux/server/homelab-governor.sh" winvm-status \
    | jq -e '.state == "needs-config" and .weightMB == null and (.nextAction | type == "string")' >/dev/null
echo "  winvm unconfigured envelope ok"
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=12288 "$REPO_ROOT/linux/server/homelab-governor.sh" budget ai-studio | jq -e '.winvmActive == false and .verdict == "pass"' >/dev/null
echo "  heavy profile passes when winvm idle ok"
printf '%s\n' '{"libvirtState":"running","currentMarker":"no","bootRuntimeStale":false}' > "$PZ_HOMELAB_WINVM_STATUS_FILE"
"$REPO_ROOT/linux/server/homelab-governor.sh" winvm-status | jq -e '.status == "active"' >/dev/null
echo "  winvm active detection ok"
if PZ_HOMELAB_RAM_TOTAL_OVERRIDE=12288 "$REPO_ROOT/linux/server/homelab-governor.sh" check ai-studio >/dev/null 2>&1; then
    echo "FAIL: heavy profile passed while winvm active"; exit 1
fi
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=12288 "$REPO_ROOT/linux/server/homelab-governor.sh" budget ai-studio \
    | jq -e '.winvmActive == true and .winvmWeightMB == 2048 and (.reasons | any(. | test("winvm active")))' >/dev/null
echo "  winvm conflict impact plan ok"
suspend_out="$("$REPO_ROOT/linux/server/homelab-governor.sh" winvm-suspend --dry-run)"
printf '%s\n' "$suspend_out" | jq -e '.winvmSuspendRequested == true and .method == "graceful-qga" and .dryRun == true and .killUsed == "never"' >/dev/null
echo "  graceful suspend plan ok"
SUSPEND_CAPTURE="$TMP/suspend.capture"
PZ_HOMELAB_WINVM_SUSPEND_CMD="printf suspend-called > '$SUSPEND_CAPTURE' && echo ok" \
    "$REPO_ROOT/linux/server/homelab-governor.sh" winvm-suspend | jq -e '.applied == true and .killUsed == "never"' >/dev/null
grep -Fq 'suspend-called' "$SUSPEND_CAPTURE"
echo "  graceful suspend executes configured command ok"
printf '%s\n' '{"libvirtState":"shut off","currentMarker":"no","bootRuntimeStale":false}' > "$PZ_HOMELAB_WINVM_STATUS_FILE"
"$REPO_ROOT/linux/server/homelab-governor.sh" winvm-suspend --dry-run | jq -e '.winvmSuspendRequested == false and .status == "idle"' >/dev/null
echo "  suspend no-op when idle ok"
"$REPO_ROOT/linux/server/homelab-governor.sh" winvm-resume | jq -e '.winvmReleased == true and .status == "idle"' >/dev/null
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=12288 "$REPO_ROOT/linux/server/homelab-governor.sh" check ai-studio >/dev/null
echo "  resume after winvm end ok"

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
if ! rg -q '^--access$' "$RUNUSER_CAPTURE" || ! rg -q '^local$' "$RUNUSER_CAPTURE"; then
    echo "FAIL: stack not invoked with up --access local"; exit 1
fi
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

echo "=== backup: manifest + checksums + verify + restore ==="
BKT="$TMP/backup-root"
VM="$TMP/vol-mounts"
mkdir -p "$VM/vaultwarden_data" "$VM/syncthing_data"
echo "secret-password-1" > "$VM/vaultwarden_data/db.sqlite"
echo "file-a" > "$VM/syncthing_data/a.txt"
BENV="PZ_HOMELAB_STATE=$PZ_HOMELAB_STATE PZ_HOMELAB_BACKUP_ROOT=$BKT PZ_HOMELAB_VOLUMES_OVERRIDE='vaultwarden_data syncthing_data' PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE=$VM"
bk_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab backup --dest '$BKT/bk1' 2>/dev/null" | grep -v '^INFO:')"
echo "$bk_out" | jq -e '.ok == true and (.volumes|length) == 2' >/dev/null
test -f "$BKT/bk1/manifest.json"
test -f "$BKT/bk1/vaultwarden_data.tgz"
test -f "$BKT/last.json"
jq -e '.schemaVersion == "2" and .tool == "homelab-backup" and (.volumes|length) == 2 and (.volumes[] | has("sha256") and has("sizeBytes")) and .verified == false' "$BKT/bk1/manifest.json" >/dev/null
echo "  backup manifest ok"
eval "$BENV '$REPO_ROOT/linux/pz' server homelab backup verify --source '$BKT/bk1' 2>/dev/null" | grep -v '^INFO:' | jq -e '.action == "verify-backup" and .verified == true and (.checks|length) == 0' >/dev/null
echo "  verify pass ok"
# verify on a dir without manifest must fail closed
mkdir -p "$TMP/backup-nomanifest"; touch "$TMP/backup-nomanifest/data.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab backup verify --source '$TMP/backup-nomanifest'" >/dev/null 2>&1; then
    echo "FAIL: verify accepted dir without manifest"; exit 1
fi
echo "  verify missing-manifest fails closed ok"
# restore --plan: verify + impacto, zero escrita (CCS-004)
plan_before="$(find "$BKT" -mindepth 1 | sort)"
plan_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --plan 2>/dev/null" | grep -v '^INFO:')"
printf '%s\n' "$plan_out" | jq -e '.action == "restore" and .plan == true and .verified == true and .requiresConfirmation == true and (.volumesAffected | index("vaultwarden_data"))' >/dev/null
plan_after="$(find "$BKT" -mindepth 1 | sort)"
test "$plan_before" = "$plan_after" || { echo "FAIL: restore --plan escreveu arquivos"; exit 1; }
# plan de backup adulterado mostra verified:false e falha fechado
cp "$BKT/bk1/vaultwarden_data.tgz" "$BKT/bk1/vaultwarden_data.tgz.bak"
printf 'tamper' >> "$BKT/bk1/vaultwarden_data.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --plan" >/dev/null 2>&1; then
    echo "FAIL: restore --plan aceitou backup adulterado"; exit 1
fi
tampered_raw="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --plan 2>/dev/null")" || true
jq -e '.plan == true and .verified == false' < <(grep -v '^INFO:' <<< "$tampered_raw") >/dev/null
mv "$BKT/bk1/vaultwarden_data.tgz.bak" "$BKT/bk1/vaultwarden_data.tgz"
# --plan não combina com --yes/--dry-run
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --plan --yes" >/dev/null 2>&1; then
    echo "FAIL: restore aceitou --plan junto de --yes"; exit 1
fi
echo "  restore --plan zero-write ok"
# tamper: modify an archive, verify must fail closed
cp "$BKT/bk1/vaultwarden_data.tgz" "$BKT/bk1/vaultwarden_data.tgz.bak"
printf 'tamper' >> "$BKT/bk1/vaultwarden_data.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab backup verify --source '$BKT/bk1'" >/dev/null 2>&1; then
    echo "FAIL: tampered backup verified"; exit 1
fi
mv "$BKT/bk1/vaultwarden_data.tgz.bak" "$BKT/bk1/vaultwarden_data.tgz"
echo "  tamper fails closed ok"
# restore without --yes must refuse; with --yes must apply
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1'" >/dev/null 2>&1; then
    echo "FAIL: restore without --yes accepted"; exit 1
fi
# corrupt the restore target to prove restore writes
rm -f "$VM/vaultwarden_data/db.sqlite"
rest_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --yes 2>/dev/null" | grep -v '^INFO:')"
printf '%s\n' "$rest_out" | jq -e '.ok == true and .preRestore != null' >/dev/null
grep -q 'secret-password-1' "$VM/vaultwarden_data/db.sqlite"
test -f "$BKT/bk1.pre-restore/manifest.json"
jq -e '.tool == "homelab-restore-pre" and (.volumes | length) == 2' "$BKT/bk1.pre-restore/manifest.json" >/dev/null
echo "  restore verify-then-apply ok"

# CCS-004 evolutivo: arquivo de confirmação (jornada da Central) equivale a
# --yes, desde que a frase exata — vinculada à origem — esteja presente.
rm -f "$VM/vaultwarden_data/db.sqlite"
printf 'FRASE ERRADA\n' > "$TMP/confirm.txt"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --confirm-file '$TMP/confirm.txt'" >/dev/null 2>&1; then
    echo "FAIL: confirm-file com frase errada foi aceito"; exit 1
fi
printf 'RESTAURAR bk1\n' > "$TMP/confirm.txt"
conf_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --confirm-file '$TMP/confirm.txt' 2>/dev/null" | grep -v '^INFO:')"
printf '%s\n' "$conf_out" | jq -e '.ok == true and .preRestore != null' >/dev/null
grep -q 'secret-password-1' "$VM/vaultwarden_data/db.sqlite"
echo "  restore --confirm-file ok"
# restore from a tampered backup must be refused before applying
cp "$BKT/bk1/vaultwarden_data.tgz" "$BKT/bk1/vaultwarden_data.tgz.bak"
printf 'tamper' >> "$BKT/bk1/vaultwarden_data.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --yes" >/dev/null 2>&1; then
    echo "FAIL: restore applied tampered backup"; exit 1
fi
mv "$BKT/bk1/vaultwarden_data.tgz.bak" "$BKT/bk1/vaultwarden_data.tgz"
echo "  restore tampered refused ok"
# restore from a non-manifest dir must be refused
mkdir -p "$TMP/backup-legacy"; touch "$TMP/backup-legacy/x.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$TMP/backup-legacy' --yes" >/dev/null 2>&1; then
    echo "FAIL: legacy backup restored without manifest"; exit 1
fi
echo "  legacy refused ok"
# partial restore failure must roll back to the pre-restore state
echo "changed-after-backup" > "$VM/vaultwarden_data/db.sqlite"
echo "fresh-b" > "$VM/syncthing_data/b.txt"
# poison the second volume so extraction fails mid-restore
rm -rf "$VM/syncthing_data" && touch "$VM/syncthing_data"
rb_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --yes 2>/dev/null" | grep -v '^INFO:' || true)"
printf '%s\n' "$rb_out" | jq -e '.ok == false and .rollbackApplied == true and .failedVolume == "syncthing_data"' >/dev/null
if printf '%s\n' "$rb_out" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "FAIL: restore with poisoned volume succeeded"; exit 1
fi
rm -rf "$VM/syncthing_data" && mkdir -p "$VM/syncthing_data" && echo "file-a" > "$VM/syncthing_data/a.txt"
grep -q 'changed-after-backup' "$VM/vaultwarden_data/db.sqlite" \
    || { echo "FAIL: rollback did not restore pre-restore state"; exit 1; }
test "$(cat "$VM/vaultwarden_data/db.sqlite")" = "changed-after-backup" \
    || { echo "FAIL: rollback restored backup instead of pre-restore state"; exit 1; }
echo "  restore partial failure rolls back to pre-restore ok"
# status surfaces lastBackup + verified
PZ_HOMELAB_BACKUP_ROOT="$BKT" "$REPO_ROOT/linux/pz" server homelab status --json >/tmp/bkst.json 2>&1 || true
jq -e '.backupState.backups == ["bk1"] and .backupState.lastBackup.latest != null and .backupState.verified == false' /tmp/bkst.json >/dev/null
echo "  status backup state ok"

echo "=== ai policy broker + hardened adapters ==="
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" status | jq -e '.conservative == true and (.deniedActions | index("ollama-pull")) and (.deniedActions | index("hermes-install"))' >/dev/null
echo "  policy conservative default ok"
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check ollama-pull | jq -e '.allow == false' >/dev/null
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check openclaw-install version=0.9.4 | jq -e '.allow == true' >/dev/null
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check hermes-install | jq -e '.allow == false' >/dev/null
hcksum="$(printf 'a%.0s' {1..64})"
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check hermes-install checksum="$hcksum" | jq -e '.allow == true' >/dev/null
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check codex-install | jq -e '.allow == true' >/dev/null
echo "  broker action checks ok"
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" set permissive >/dev/null
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" status | jq -e '.mode == "permissive" and .conservative == false' >/dev/null
echo "  policy set ok"
# invalid mode must be rejected and leave the current mode untouched
if PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" set bogus >/dev/null 2>&1; then
    echo "FAIL: broker accepted bogus mode"; exit 1
fi
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" status | jq -e '.mode == "permissive"' >/dev/null
echo "  policy invalid mode rejected ok"
# unknown action must fail closed (deny), never allow
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check mystery-action | jq -e '.allow == false and (.reasons | length) == 1' >/dev/null
echo "  policy unknown action denied ok"
# hardened adapters: no latest, no auto-pull, no unchecksummed remotes, pinned tags
if rg -q 'openclaw@latest|@openai/codex@latest' "$REPO_ROOT/linux/ai/setup-openclaw.sh" "$REPO_ROOT/linux/ai/setup-codex.sh"; then
    echo "FAIL: versionless install found in openclaw/codex setup"; exit 1
fi
if rg -q 'ollama pull llama3.1|nohup ollama pull' "$REPO_ROOT/linux/ai/setup-ollama.sh"; then
    echo "FAIL: auto-pull found in ollama setup"; exit 1
fi
if rg -q 'PZ_HERMES_INSTALL_SHA256' "$REPO_ROOT/linux/ai/setup-hermes.sh"; then
    echo "FAIL: arbitrary Hermes installer checksum bypass found"; exit 1
fi
rg -q 'PZ_HERMES_ACCEPT_UNAUDITED_COMMIT' "$REPO_ROOT/linux/ai/setup-hermes.sh"
rg -q 'hermes-distribution-audit.json' "$REPO_ROOT/linux/ai/setup-hermes.sh"
if rg -q -- '--network host' "$REPO_ROOT/linux/ai/setup-memory.sh"; then
    echo "FAIL: --network host found in setup-memory"; exit 1
fi
if rg -q 'ai-memory:latest' "$REPO_ROOT/linux/ai/setup-memory.sh"; then
    echo "FAIL: ai-memory:latest found in setup-memory"; exit 1
fi
rg -q 'AI_MEMORY_VERSION=.*1\.31\.1' "$REPO_ROOT/linux/ai/setup-memory.sh"
rg -q 'AI_MEMORY_SHA256_X86_64=' "$REPO_ROOT/linux/ai/setup-memory.sh"
rg -q 'install_native_release' "$REPO_ROOT/linux/ai/setup-memory.sh"
echo "  adapters hardened ok"
# status now carries a real policy
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/pz" server homelab status --json >/tmp/pol.json 2>&1 || true
jq -e '.securityState.policyActive == false and .securityState.policy.mode == "permissive"' /tmp/pol.json >/dev/null
echo "  status policy wiring ok"

echo "=== Homelab smoke ok ==="
