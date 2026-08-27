#!/usr/bin/env bash
# homelab-hosts.sh — admin-side host registry + SSH bridge (--host).
#
# Lives on the admin/consumer machine. Never stores private keys, passwords
# or app tokens. JSON on stdout, logs on stderr.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

SCHEMA_VERSION="1"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
REG_DIR="${PZ_HOMELAB_HOSTS_DIR:-$CONFIG_HOME/phasezero}"
REG_FILE="${PZ_HOMELAB_HOSTS_FILE:-$REG_DIR/homelab-hosts.json}"
LOCK_FILE="${PZ_HOMELAB_HOSTS_LOCK:-$REG_DIR/homelab-hosts.lock}"
SSH_BIN="${PZ_HOMELAB_SSH_BIN:-ssh}"
SSH_TIMEOUT="${PZ_HOMELAB_SSH_TIMEOUT:-8}"
# Floor, not "equal to this checkout". A 1.18 admin must still talk to a
# 1.17.4 appliance. Override with PZ_HOMELAB_REMOTE_MIN_VERSION for tests.
MIN_VERSION="${PZ_HOMELAB_REMOTE_MIN_VERSION:-1.17.4}"

SUB="${1:-list}"
shift 2>/dev/null || true

JSON_OUTPUT=0
ALIAS=""
TARGET=""
POSITIONAL=()

usage() {
    cat <<EOF
Usage:
  homelab-hosts.sh add <alias> <user@host[:port]> [--json]
  homelab-hosts.sh list [--json]
  homelab-hosts.sh remove <alias> [--json]
  homelab-hosts.sh ping <alias> [--json]
  homelab-hosts.sh exec <alias> -- <homelab-args...>
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) JSON_OUTPUT=1 ;;
        --help|-h) usage; exit 0 ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            pz_error "unexpected flag: $1"
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done

empty_registry() {
    jq -cn --argjson schemaVersion 1 --arg tool "homelab-hosts" \
        '{schemaVersion:$schemaVersion, tool:$tool, hosts:[]}'
}

read_registry() {
    if [ ! -f "$REG_FILE" ]; then
        empty_registry
        return 0
    fi
    local raw
    raw="$(cat "$REG_FILE" 2>/dev/null || true)"
    if ! jq -e '.schemaVersion == 1 and .tool == "homelab-hosts" and (.hosts | type == "array")' \
        <<< "$raw" >/dev/null 2>&1; then
        pz_error "hosts registry corrupt: $REG_FILE"
        return 1
    fi
    if jq -e '
        .hosts[]
        | select(
            (.privateKey != null) or (.password != null) or (.token != null)
            or (.identityFile != null) or (.secret != null)
          )
    ' <<< "$raw" >/dev/null 2>&1; then
        pz_error "hosts registry contains private material: $REG_FILE"
        return 1
    fi
    printf '%s\n' "$raw"
}

hosts_lock() {
    mkdir -p "$REG_DIR"
    chmod 0700 "$REG_DIR" 2>/dev/null || true
    exec 8>"$LOCK_FILE"
    if ! flock -w 10 8; then
        pz_error "another homelab hosts operation is running"
        return 1
    fi
}

hosts_unlock() {
    flock -u 8 2>/dev/null || true
}

write_registry() {
    local json="$1" tmp
    mkdir -p "$REG_DIR"
    chmod 0700 "$REG_DIR" 2>/dev/null || true
    if ! jq -e '.schemaVersion == 1 and (.hosts | type == "array")' <<< "$json" >/dev/null 2>&1; then
        pz_error "refusing to write invalid hosts registry"
        return 1
    fi
    tmp="$(pz_tempfile)"
    printf '%s\n' "$json" > "$tmp"
    install -m 0600 "$tmp" "$REG_FILE"
    rm -f "$tmp"
}

local_version() {
    printf '%s\n' "$MIN_VERSION"
}

version_ge() {
    local have="$1" need="$2" first
    first="$(printf '%s\n%s\n' "$have" "$need" | sort -V | head -1)"
    [ "$first" = "$need" ]
}

parse_target() {
    local spec="$1" user host port=22 rest
    case "$spec" in
        */*|*[[:space:]]*|*'|'*)
            pz_error "invalid host target (path or whitespace not allowed)"
            return 2
            ;;
    esac
    case "$spec" in
        *@*) ;;
        *)
            pz_error "target must be user@host[:port]"
            return 2
            ;;
    esac
    user="${spec%%@*}"
    rest="${spec#*@}"
    case "$rest" in
        *:*)
            host="${rest%:*}"
            port="${rest##*:}"
            ;;
        *) host="$rest" ;;
    esac
    if ! [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        pz_error "invalid user"
        return 2
    fi
    if ! [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]; then
        pz_error "invalid host"
        return 2
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        pz_error "invalid port"
        return 2
    fi
    printf '%s %s %s\n' "$user" "$host" "$port"
}

valid_alias() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

host_record() {
    local alias="$1" reg
    reg="$(read_registry)" || return $?
    jq -c --arg a "$alias" '.hosts[] | select(.alias == $a)' <<< "$reg" | head -1
}

make_id() {
    local alias="$1"
    printf 'hlh-%s\n' "$(printf '%s' "$alias" | sha256sum | awk '{print substr($1,1,12)}')"
}

ssh_base_args() {
    local port="$1"
    printf '%s\n' \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=no \
        -p "$port"
}

run_ssh() {
    local user="$1" host="$2" port="$3"
    shift 3
    local -a opts=()
    mapfile -t opts < <(ssh_base_args "$port")
    "$SSH_BIN" "${opts[@]}" "$user@$host" "$@"
}

cmd_list() {
    local reg
    reg="$(read_registry)" || return $?
    local payload
    payload="$(jq -c --arg schemaVersion "$SCHEMA_VERSION" \
        '. + {schemaVersion:$schemaVersion, action:"list"}' <<< "$reg")"
    if [ "$JSON_OUTPUT" = "1" ]; then
        printf '%s\n' "$payload"
        return 0
    fi
    echo "$payload" | jq -r '
        "PhaseZero Homelab hosts",
        (if (.hosts|length)==0 then "  (none)" else (.hosts[] | "  - \(.alias)\t\(.user)@\(.host):\(.port)") end)
    '
}

cmd_add() {
    local alias="${POSITIONAL[0]:-}" spec="${POSITIONAL[1]:-}"
    if [ -z "$alias" ] || [ -z "$spec" ]; then
        pz_error "usage: hosts add <alias> <user@host[:port]>"
        return 2
    fi
    valid_alias "$alias" || { pz_error "invalid alias"; return 2; }
    local user host port
    read -r user host port < <(parse_target "$spec") || return $?
    hosts_lock || return 1
    local reg rec id
    reg="$(read_registry)" || { hosts_unlock; return 1; }
    rec="$(jq -c --arg a "$alias" '.hosts[] | select(.alias == $a)' <<< "$reg" | head -1 || true)"
    id="$(make_id "$alias")"
    if [ -n "$rec" ]; then
        if ! jq -e --arg u "$user" --arg h "$host" --argjson p "$port" \
            '.user == $u and .host == $h and .port == $p' <<< "$rec" >/dev/null 2>&1; then
            hosts_unlock
            pz_error "alias $alias already registered to a different target"
            return 1
        fi
        hosts_unlock
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "add" --argjson ok true --argjson already true --argjson host "$rec" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, already:$already, host:$host}'
        return 0
    fi
    local now new_host new_reg
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    new_host="$(jq -cn --arg id "$id" --arg alias "$alias" --arg user "$user" \
        --arg host "$host" --argjson port "$port" --arg addedAt "$now" \
        '{id:$id, alias:$alias, user:$user, host:$host, port:$port, addedAt:$addedAt}')"
    new_reg="$(jq -c --argjson h "$new_host" '.hosts += [$h]' <<< "$reg")"
    write_registry "$new_reg" || { hosts_unlock; return 1; }
    hosts_unlock
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "add" --argjson ok true --argjson already false --argjson host "$new_host" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, already:$already, host:$host}'
}

cmd_remove() {
    local alias="${POSITIONAL[0]:-}"
    [ -n "$alias" ] || { pz_error "usage: hosts remove <alias>"; return 2; }
    hosts_lock || return 1
    local reg rec
    reg="$(read_registry)" || { hosts_unlock; return 1; }
    rec="$(jq -c --arg a "$alias" '.hosts[] | select(.alias == $a)' <<< "$reg" | head -1 || true)"
    if [ -z "$rec" ]; then
        hosts_unlock
        pz_error "unknown host alias: $alias"
        return 2
    fi
    write_registry "$(jq -c --arg a "$alias" '.hosts |= map(select(.alias != $a))' <<< "$reg")" \
        || { hosts_unlock; return 1; }
    hosts_unlock
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "remove" --argjson ok true --arg alias "$alias" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, alias:$alias}'
}

extract_version() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

cmd_ping() {
    local alias="${POSITIONAL[0]:-}" rec
    [ -n "$alias" ] || { pz_error "usage: hosts ping <alias>"; return 2; }
    rec="$(host_record "$alias")" || return $?
    if [ -z "$rec" ]; then
        pz_error "unknown host alias: $alias"
        return 2
    fi
    local user host port out rc=0 ver="" err=""
    user="$(jq -r '.user' <<< "$rec")"
    host="$(jq -r '.host' <<< "$rec")"
    port="$(jq -r '.port' <<< "$rec")"
    local errf
    errf="$(pz_tempfile)"
    set +e
    out="$(run_ssh "$user" "$host" "$port" pz --version 2>"$errf")"
    rc=$?
    set -e
    err="$(tr -d '\0' < "$errf" 2>/dev/null | tail -1 || true)"
    rm -f "$errf"
    ver="$(printf '%s' "$out" | extract_version || true)"
    if [ "$rc" -ne 0 ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "ping" --arg hostAlias "$alias" --argjson ok false \
            --argjson reachable false --argjson rc "$rc" --arg error "${err:-host unreachable}" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              ok:$ok, reachable:$reachable, rc:$rc, error:$error, remoteVersion:null}'
        return 1
    fi
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "ping" --arg hostAlias "$alias" --argjson ok true \
        --argjson reachable true --arg remoteVersion "$ver" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
          ok:$ok, reachable:$reachable, rc:0, error:null, remoteVersion:$remoteVersion}'
}

cmd_exec() {
    local alias="${POSITIONAL[0]:-}"
    [ -n "$alias" ] || { pz_error "usage: hosts exec <alias> -- <args>"; return 2; }
    local rec
    rec="$(host_record "$alias")" || return $?
    if [ -z "$rec" ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "exec" --arg hostAlias "$alias" --argjson rc 2 \
            --arg error "unknown host alias: $alias" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              rc:$rc, payload:null, error:$error}'
        return 2
    fi
    local -a inner=("${POSITIONAL[@]:1}")
    local user host port
    user="$(jq -r '.user' <<< "$rec")"
    host="$(jq -r '.host' <<< "$rec")"
    port="$(jq -r '.port' <<< "$rec")"
    local need ver out rc=0 err="" payload="null"
    need="$(local_version)"
    local errf
    errf="$(pz_tempfile)"
    set +e
    out="$(run_ssh "$user" "$host" "$port" pz --version 2>"$errf")"
    rc=$?
    set -e
    err="$(tr -d '\0' < "$errf" 2>/dev/null | tail -1 || true)"
    rm -f "$errf"
    if [ "$rc" -ne 0 ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "exec" --arg hostAlias "$alias" --argjson rc "$rc" \
            --arg error "${err:-host unreachable (ssh fail-closed)}" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              rc:$rc, payload:null, error:$error}'
        return 1
    fi
    ver="$(printf '%s' "$out" | extract_version || true)"
    if [ -z "$ver" ] || ! version_ge "$ver" "$need"; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "exec" --arg hostAlias "$alias" --argjson rc 69 \
            --arg error "remote PhaseZero $ver is older than required $need" \
            --arg remoteVersion "$ver" --arg required "$need" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              rc:$rc, payload:null, error:$error, remoteVersion:$remoteVersion, requiredVersion:$required}'
        return 69
    fi
    if [ "${#inner[@]}" -eq 0 ]; then
        inner=(status --json)
    fi
    local stdout rc2=0 errf2
    errf2="$(pz_tempfile)"
    set +e
    stdout="$(run_ssh "$user" "$host" "$port" pz server homelab "${inner[@]}" 2>"$errf2")"
    rc2=$?
    set -e
    err="$(tr '\n' ' ' < "$errf2" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    rm -f "$errf2"
    if printf '%s' "$stdout" | jq -e . >/dev/null 2>&1; then
        payload="$(printf '%s' "$stdout" | jq -c .)"
    elif [ -n "$stdout" ]; then
        err="${err:-remote stdout was not JSON}"
    fi
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "exec" --arg hostAlias "$alias" --argjson rc "$rc2" \
        --argjson payload "$payload" --arg error "$err" --arg remoteVersion "$ver" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
          rc:$rc, payload:$payload, error:(if $error == "" then null else $error end),
          remoteVersion:$remoteVersion}'
    [ "$rc2" -eq 0 ]
}

case "$SUB" in
    list) cmd_list ;;
    add) cmd_add ;;
    remove) cmd_remove ;;
    ping) cmd_ping ;;
    exec) cmd_exec ;;
    *)
        usage >&2
        exit 2
        ;;
esac
