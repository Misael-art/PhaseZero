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
    # shellcheck disable=SC2329 # stubs invoked indirectly via sourced functions
    bash() { printf '%s\n' "$*" >> "$apply_capture"; }
    # shellcheck disable=SC2329
    pz_info() { :; }
    # shellcheck disable=SC2329
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
  .env.exists == true
  and (.env.secrets | all(.present == true))
  and .access.effective == "local"
  and .access.adminBind == "127.0.0.1"
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

echo "=== Homelab smoke ok ==="
