#!/usr/bin/env bash
# auth-registry.sh - redacted inventory for AI accounts, sessions and gateways
set -euo pipefail
umask 077

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps jq >/dev/null

ACTION="${1:-status}"
case "$ACTION" in
    status|doctor) ;;
    *) pz_error "usage: pz ai auth (status|doctor)"; exit 2 ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

(
    bash "$PZ_ROOT/linux/ai/proxy-suite.sh" auth all > "$tmp_dir/proxies.json" 2>/dev/null ||
        jq -cn '[]' > "$tmp_dir/proxies.json"
) &
pid_proxies=$!
(
    bash "$PZ_ROOT/linux/ai/9router-manager.sh" status > "$tmp_dir/router.json" 2>/dev/null ||
        jq -cn '{installed:false,healthy:false,providers:{active:0,total:0}}' > "$tmp_dir/router.json"
) &
pid_router=$!
(
    bash "$PZ_ROOT/linux/ai/9router-manager.sh" provider status > "$tmp_dir/providers.json" 2>/dev/null ||
        jq -cn '{connections:[]}' > "$tmp_dir/providers.json"
) &
pid_providers=$!
(
    bash "$PZ_ROOT/linux/ai/setup-claude-code.sh" status > "$tmp_dir/claude.json" 2>/dev/null ||
        jq -cn '{claude:{installed:false,auth:{loggedIn:false}},bonsai:{installed:false,authenticated:false}}' > "$tmp_dir/claude.json"
) &
pid_claude=$!
(
    python3 "$PZ_ROOT/linux/ai/opencode_9router_manager.py" status > "$tmp_dir/opencode.json" 2>/dev/null ||
        jq -cn '{cli:{installed:false},configuration:{configured:false},credential:{secure:false},router:{healthy:false}}' > "$tmp_dir/opencode.json"
) &
pid_opencode=$!
(
    bash "$PZ_ROOT/linux/ai/setup-hermes.sh" status > "$tmp_dir/hermes.json" 2>/dev/null ||
        jq -cn '{installed:false,configured:false,ready:false,auth:{configured:false}}' > "$tmp_dir/hermes.json"
) &
pid_hermes=$!
(
    bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" status > "$tmp_dir/odysseus.json" 2>/dev/null ||
        jq -cn '{installed:false,configured:false,ready:false,routerCredential:{configured:false}}' > "$tmp_dir/odysseus.json"
) &
pid_odysseus=$!

for pid in "$pid_proxies" "$pid_router" "$pid_providers" "$pid_claude" \
    "$pid_opencode" "$pid_hermes" "$pid_odysseus"; do
    wait "$pid" || true
done

observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

registry="$(jq -cn \
    --arg observedAt "$observed_at" \
    --slurpfile proxies "$tmp_dir/proxies.json" \
    --slurpfile router "$tmp_dir/router.json" \
    --slurpfile providers "$tmp_dir/providers.json" \
    --slurpfile claude "$tmp_dir/claude.json" \
    --slurpfile opencode "$tmp_dir/opencode.json" \
    --slurpfile hermes "$tmp_dir/hermes.json" \
    --slurpfile odysseus "$tmp_dir/odysseus.json" '
  def label_proxy:
    if . == "kimiproxy" then "Kimi Proxy"
    elif . == "qwenproxy" then "Qwen Proxy"
    elif . == "deepsproxy" then "DeepSeek Proxy"
    elif . == "mimo-ai-proxy" then "Mimo Proxy"
    else . end;
  def proxy_entry:
    . as $p |
    ($p.webValidation.status // "unknown") as $web |
    (($web == "authenticated") or ($web == "configured") or ($web == "dashboard-ready")) as $authenticated |
    (($p.installed == true) and (($p.apiKeyConfigured == true) or $authenticated or ($web == "session-present"))) as $configured |
    (($p.service == "active") and $authenticated) as $ready |
    {
      id:("proxy:" + $p.id),label:($p.id|label_proxy),kind:"proxy-session",scope:"browser-or-env",
      required:false,installed:($p.installed == true),configured:$configured,
      authenticated:$authenticated,ready:$ready,
      status:(if $ready then "ready" elif ($p.installed|not) then "missing" elif $web == "session-present" then "verify-session" elif $web == "missing-credentials" then "action-required" else "attention" end),
      method:($p.webValidation.kind // "unknown"),accountCount:null,
      expiresAt:null,lastVerifiedAt:(if $ready then $observedAt else null end),
      observedAt:$observedAt,nextAction:($p.webValidation.command // "linux/pz ai proxies ensure " + $p.id),
      secretsRedacted:true
    };
  ($router[0] // {}) as $r |
  ($providers[0].connections // []) as $connections |
  ($claude[0] // {}) as $c |
  ($opencode[0] // {}) as $o |
  ($hermes[0] // {}) as $h |
  ($odysseus[0] // {}) as $d |
  ([($proxies[0] // [])[] | select(.id == "kimiproxy" or .id == "qwenproxy" or .id == "deepsproxy" or .id == "mimo-ai-proxy") | proxy_entry]) as $proxyEntries |
  ([$connections | sort_by(.provider) | group_by(.provider)[] |
    . as $accounts | ($accounts[0].provider // "unknown") as $provider |
    ([$accounts[] | select(.active == true)] | length) as $active |
    ([$accounts[] | select(.status == "active")] | length) as $healthy |
    {
      id:("provider:" + $provider),label:($provider | ascii_upcase),kind:"router-provider",scope:"9router",
      required:false,installed:true,configured:($active > 0),authenticated:($healthy > 0),ready:($healthy > 0),
      status:(if $healthy > 0 then "ready" elif $active > 0 then "attention" else "disabled" end),
      method:"9router-managed",accountCount:($accounts|length),activeAccounts:$active,healthyAccounts:$healthy,
      expiresAt:null,lastVerifiedAt:(if $healthy > 0 then $observedAt else null end),observedAt:$observedAt,
      nextAction:"linux/pz ai 9router dashboard",secretsRedacted:true
    }
  ]) as $providerEntries |
  ([{
      id:"gateway:9router",label:"9Router",kind:"gateway",scope:"routing",required:true,
      installed:($r.installed == true),configured:(($r.providers.active // 0) > 0),
      authenticated:(($r.providers.active // 0) > 0),ready:($r.healthy == true),
      status:(if $r.healthy then "ready" elif $r.installed then "attention" else "missing" end),
      method:"provider-vault",accountCount:($r.providers.total // 0),expiresAt:null,
      lastVerifiedAt:(if $r.healthy then $observedAt else null end),observedAt:$observedAt,
      nextAction:"linux/pz ai 9router dashboard",secretsRedacted:true
    },{
      id:"client:opencode",label:"OpenCode",kind:"client",scope:"9router",required:true,
      installed:($o.cli.installed == true),configured:($o.configuration.configured == true),
      authenticated:($o.credential.present == true and $o.credential.secure == true),
      ready:($o.cli.installed == true and $o.configuration.configured == true and $o.credential.secure == true and $o.router.healthy == true),
      status:(if ($o.cli.installed == true and $o.configuration.configured == true and $o.credential.secure == true and $o.router.healthy == true) then "ready" elif $o.cli.installed then "attention" else "missing" end),
      method:"credential-reference",accountCount:null,expiresAt:null,
      lastVerifiedAt:(if $o.router.healthy then $observedAt else null end),observedAt:$observedAt,
      nextAction:"linux/pz ai opencode verify",secretsRedacted:true
    },{
      id:"client:claude",label:"Claude",kind:"client",scope:"first-party",required:false,
      installed:($c.claude.installed == true),configured:($c.claude.installed == true),
      authenticated:($c.claude.auth.loggedIn == true),ready:($c.claude.installed == true and $c.claude.auth.loggedIn == true),
      status:(if ($c.claude.installed == true and $c.claude.auth.loggedIn == true) then "ready" elif $c.claude.installed then "action-required" else "missing" end),
      method:($c.claude.auth.authMethod // "unknown"),accountCount:null,expiresAt:null,
      lastVerifiedAt:(if $c.claude.auth.loggedIn then $observedAt else null end),observedAt:$observedAt,
      nextAction:"linux/pz ai claude status",secretsRedacted:true
    },{
      id:"client:bonsai",label:"Bonsai",kind:"client",scope:"external-provider",required:false,
      installed:($c.bonsai.installed == true),configured:($c.bonsai.credentialStorePresent == true),
      authenticated:($c.bonsai.authenticated == true),ready:($c.bonsai.installed == true and $c.bonsai.authenticated == true and $c.bonsai.credentialStorePermissions.secure == true),
      status:(if ($c.bonsai.installed == true and $c.bonsai.authenticated == true and $c.bonsai.credentialStorePermissions.secure == true) then "ready" elif $c.bonsai.installed then "attention" else "missing" end),
      method:"external-session",accountCount:null,expiresAt:null,
      lastVerifiedAt:(if $c.bonsai.authenticated then $observedAt else null end),observedAt:$observedAt,
      nextAction:"linux/pz ai claude login bonsai",secretsRedacted:true
    },{
      id:"workspace:hermes",label:"Hermes",kind:"workspace",scope:"agent",required:false,
      installed:($h.installed == true),configured:($h.configured == true),authenticated:($h.auth.configured == true),ready:($h.ready == true),
      status:(if $h.ready then "ready" elif $h.installed then "attention" else "missing" end),method:"env-reference",
      accountCount:null,expiresAt:null,lastVerifiedAt:(if $h.ready then $observedAt else null end),observedAt:$observedAt,
      nextAction:"linux/pz ai hermes doctor",secretsRedacted:true
    },{
      id:"workspace:odysseus",label:"Odysseus",kind:"workspace",scope:"agent",required:false,
      installed:($d.installed == true),configured:($d.configured == true),authenticated:($d.routerCredential.configured == true),ready:($d.ready == true),
      status:(if $d.ready then "ready" elif $d.installed then "attention" else "blocked" end),method:"canonical-9router-reference",
      accountCount:null,expiresAt:null,lastVerifiedAt:(if $d.ready then $observedAt else null end),observedAt:$observedAt,
      nextAction:"linux/pz ai workspaces plan",secretsRedacted:true
    }]) as $coreEntries |
  ($coreEntries + $providerEntries + $proxyEntries) as $entries |
  {
    schemaVersion:1,observedAt:$observedAt,entries:$entries,
    summary:{
      total:($entries|length),ready:([$entries[]|select(.ready == true)]|length),
      attention:([$entries[]|select(.installed == true and .ready != true)]|length),
      missingEssential:([$entries[]|select(.required == true and .ready != true)]|length),
      providers:($providerEntries|length),accounts:([$providerEntries[].accountCount // 0]|add // 0)
    },
    secretsRedacted:true
  }
')"

if [ "$ACTION" = "status" ]; then
    printf '%s\n' "$registry"
    exit 0
fi

jq -cn --argjson registry "$registry" '
  ($registry.entries // []) as $entries |
  {
    schemaVersion:1,registry:$registry,
    issues:([
      $entries[] |
      if (.required == true and .ready != true) then
        {severity:"error",component:.id,message:(.label + " essencial não está pronto"),nextAction:.nextAction}
      elif (.required != true and .installed == true and .ready != true) then
        {severity:"warning",component:.id,message:(.label + " precisa de atenção"),nextAction:.nextAction}
      else empty end
    ]),
    nextActions:([$entries[] | select(.ready != true) | .nextAction | select(type == "string" and length > 0)] | unique),
    ready:([$entries[] | select(.required == true and .ready != true)] | length == 0),
    secretsRedacted:true
  }'
