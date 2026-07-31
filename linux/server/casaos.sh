#!/usr/bin/env bash
# casaos.sh - CasaOS/ZimaOS compatibility gate for PhaseZero.
#
# CasaOS is not installed by default. This helper detects support and keeps real
# installation behind explicit opt-in on Linux distributions supported upstream.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
shift 2>/dev/null || true

JSON_OUTPUT=0
YES=0
OS_RELEASE="${PZ_CASAOS_OS_RELEASE:-/etc/os-release}"
INSTALL_URL="${PZ_CASAOS_INSTALL_URL:-https://get.casaos.io}"

usage() {
    cat <<EOF
Usage:
  casaos.sh status [--json]
  casaos.sh plan [--json]
  casaos.sh install --yes

CasaOS install is opt-in. Officially supported targets are Debian, Ubuntu and
Raspberry Pi OS families on amd64/arm64/armv7. Arch/Steam Deck/BigLinux remain
unsupported by this helper.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) JSON_OUTPUT=1 ;;
        --yes|-y) YES=1 ;;
        --help|-h) usage; exit 0 ;;
        *) pz_error "unexpected argument: $1"; usage; exit 2 ;;
    esac
    shift
done

os_value() {
    local key="$1"
    [ -f "$OS_RELEASE" ] || return 0
    awk -F= -v k="$key" '
        $1 == k {
            v = $2
            gsub(/^"/, "", v)
            gsub(/"$/, "", v)
            print v
            exit
        }
    ' "$OS_RELEASE"
}

arch_normalized() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l|armv7*) echo armv7 ;;
        *) uname -m ;;
    esac
}

array_json() {
    local -n values_ref="$1"
    [ "${#values_ref[@]}" -gt 0 ] || { echo '[]'; return 0; }
    printf '%s\n' "${values_ref[@]}" | jq -R . | jq -cs .
}

installed_json_bool() {
    if command -v casaos-cli >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^casaos'; then
        echo true
    else
        echo false
    fi
}

validate_install_url() {
    case "$INSTALL_URL" in
        https://*) return 0 ;;
        *) pz_error "CasaOS installer URL must use HTTPS: $INSTALL_URL"; return 2 ;;
    esac
}

compat_json() {
    local id id_like pretty arch compatible=true blockers=() warnings=()
    id="$(os_value ID)"
    id_like="$(os_value ID_LIKE)"
    pretty="$(os_value PRETTY_NAME)"
    arch="$(arch_normalized)"
    [ -n "$pretty" ] || pretty="$id"

    case " $id $id_like " in
        *" debian "*|*" ubuntu "*|*" raspbian "*) ;;
        *)
            compatible=false
            blockers+=("unsupported distribution: ${pretty:-unknown}; CasaOS supported path is Debian/Ubuntu/Raspberry Pi OS")
            ;;
    esac

    case "$id" in
        arch|steamos|holo|biglinux|manjaro)
            compatible=false
            blockers+=("Arch/Steam Deck family is unsupported for CasaOS install; use PhaseZero Homelab stack")
            ;;
    esac

    case "$arch" in
        amd64|arm64|armv7) ;;
        *)
            compatible=false
            blockers+=("unsupported architecture: $arch")
            ;;
    esac

    [ "$compatible" = true ] || warnings+=("CasaOS real remains opt-in; default PhaseZero path is Docker Compose + Portainer")

    jq -n \
        --arg id "$id" --arg idLike "$id_like" --arg pretty "$pretty" --arg arch "$arch" \
        --argjson compatible "$compatible" \
        --argjson blockers "$(array_json blockers)" \
        --argjson warnings "$(array_json warnings)" \
        '{os:{id:$id,idLike:$idLike,pretty:$pretty,arch:$arch}, compatible:$compatible, blockers:$blockers, warnings:$warnings}'
}

status_json() {
    local compat installed
    compat="$(compat_json)"
    installed="$(installed_json_bool)"
    jq -n \
        --arg installUrl "$INSTALL_URL" \
        --argjson installed "$installed" \
        --argjson compat "$compat" \
        '{
          tool:"casaos",
          status:(if $installed then "installed" elif $compat.compatible then "available" else "blocked" end),
          installed:$installed,
          optInRequired:true,
          installUrl:$installUrl,
          compatibility:$compat,
          defaultRecommendation:"PhaseZero Homelab stack (Docker Compose + Portainer)",
          actions:{
            status:"pz server casaos status",
            plan:"pz server casaos plan",
            install:"phasezero-admin linux/pz server casaos install --yes"
          }
        }'
}

cmd_status() {
    status_json
}

cmd_plan() {
    local data
    data="$(status_json)"
    if [ "$JSON_OUTPUT" = "1" ]; then
        printf '%s\n' "$data"
        return 0
    fi
    echo "$data" | jq -r '
        "CasaOS plan",
        "  status: \(.status)",
        "  installed: \(.installed)",
        "  compatible: \(.compatibility.compatible)",
        "  os: \(.compatibility.os.pretty) (\(.compatibility.os.arch))",
        "  default: \(.defaultRecommendation)",
        "  blockers:",
        (if (.compatibility.blockers|length)==0 then "    none" else (.compatibility.blockers[] | "    - " + .) end),
        "  warnings:",
        (if (.compatibility.warnings|length)==0 then "    none" else (.compatibility.warnings[] | "    - " + .) end)
    '
}

cmd_install() {
    local data compatible installed
    data="$(status_json)"
    compatible="$(echo "$data" | jq -r '.compatibility.compatible')"
    installed="$(echo "$data" | jq -r '.installed')"
    [ "$installed" = "false" ] || { pz_info "CasaOS already installed"; return 0; }
    [ "$compatible" = "true" ] || { echo "$data" | jq -r '.compatibility.blockers[]'; return 1; }
    [ "$YES" = "1" ] || { pz_error "CasaOS install is opt-in; pass --yes after reading plan"; return 2; }
    validate_install_url || return $?
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        jq -n --arg url "$INSTALL_URL" '{
          action:"casaos.install",
          dryRun:true,
          download:["curl","--proto","=https","--tlsv1.2","--fail","--show-error","--location","--retry","3","--output","<temporary>",$url],
          execute:["bash","<temporary>"]
        }'
        return 0
    fi
    if [ "$EUID" -ne 0 ]; then
        pz_error "root required. run: phasezero-admin $PZ_ROOT/linux/pz server casaos install --yes"
        return 1
    fi
    command -v curl >/dev/null 2>&1 || { pz_error "curl missing"; return 1; }
    pz_info "installing CasaOS from official installer ($INSTALL_URL)"
    local installer size rc=0
    installer="$(pz_tempfile "${TMPDIR:-/tmp}/phasezero-casaos.XXXXXX")"
    if ! curl --proto '=https' --tlsv1.2 --fail --show-error --location \
        --retry 3 --retry-all-errors --connect-timeout 15 --max-time 120 \
        --output "$installer" "$INSTALL_URL"; then
        rm -f "$installer"
        pz_error "CasaOS installer download failed"
        return 1
    fi
    size="$(wc -c < "$installer")"
    if [ "$size" -lt 1024 ] || [ "$size" -gt 5242880 ] || ! bash -n "$installer"; then
        rm -f "$installer"
        pz_error "CasaOS installer failed size/syntax validation"
        return 1
    fi
    bash "$installer" || rc=$?
    rm -f "$installer"
    return "$rc"
}

case "$ACTION" in
    status) cmd_status ;;
    plan) cmd_plan ;;
    install) cmd_install ;;
    *) pz_error "usage: casaos.sh (status|plan|install) [--json] [--yes]"; exit 2 ;;
esac
