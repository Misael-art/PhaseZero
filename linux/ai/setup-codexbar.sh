#!/usr/bin/env bash
# setup-codexbar.sh - CodexBar usage CLI + KodexBar Plasma 6 applet
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai"
STATE_FILE="$STATE_DIR/codexbar.json"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/codexbar"
CONFIG_FILE="${CODEXBAR_CONFIG:-$CONFIG_DIR/config.json}"
LEGACY_CONFIG_FILE="$HOME/.codexbar/config.json"
# Respect existing user-owned legacy config. PhaseZero-owned legacy files migrate to XDG.
if [ -z "${CODEXBAR_CONFIG:-}" ] && [ ! -e "$CONFIG_FILE" ] && [ -f "$LEGACY_CONFIG_FILE" ] \
    && ! grep -q '"_managedBy"[[:space:]]*:[[:space:]]*"phasezero"' "$LEGACY_CONFIG_FILE"; then
    CONFIG_DIR="$(dirname "$LEGACY_CONFIG_FILE")"
    CONFIG_FILE="$LEGACY_CONFIG_FILE"
fi
CONFIG_TEMPLATE="$PZ_ROOT/linux/ai/templates/codexbar-config.json"
CODEXBAR_REPO_API="${PZ_CODEXBAR_REPO_API:-https://api.github.com/repos/steipete/CodexBar/releases/latest}"
KODEXBAR_REPO_URL="${PZ_KODEXBAR_REPO_URL:-https://github.com/tylxr59/KodexBar.git}"
PLASMOID_ID_DEFAULT="org.kde.plasma.kodexbar"
PLASMA_LAYOUT="${XDG_CONFIG_HOME:-$HOME/.config}/plasma-org.kde.plasma.desktop-appletsrc"

first_line() {
    timeout 8 "$@" 2>/dev/null | head -1 | tr -d '\r' || true
}

tool_path() {
    local name="$1"
    command -v "$name" 2>/dev/null || {
        [ -x "$LOCAL_BIN/$name" ] && echo "$LOCAL_BIN/$name" && return 0
        return 1
    }
}

bool_json() {
    [ "$1" = "true" ] && printf 'true' || printf 'false'
}

ensure_dirs() {
    mkdir -p "$LOCAL_BIN" "$STATE_DIR"
}

state_merge() {
    local key="$1" json="$2" tmp
    mkdir -p "$STATE_DIR"
    tmp="$(mktemp)"
    if [ -f "$STATE_FILE" ] && jq empty "$STATE_FILE" 2>/dev/null; then
        jq --argjson v "$json" ".${key} = \$v" "$STATE_FILE" > "$tmp"
    else
        jq -n --argjson v "$json" "{schemaVersion:1} | .${key} = \$v" > "$tmp"
    fi
    mv "$tmp" "$STATE_FILE"
}

state_plasmoid_id() {
    local id=""
    [ -f "$STATE_FILE" ] && id="$(jq -r '.plasmoid.id // empty' "$STATE_FILE" 2>/dev/null || true)"
    [ -n "$id" ] && printf '%s' "$id" || printf '%s' "$PLASMOID_ID_DEFAULT"
}

codexbar_arch_regex() {
    case "$(uname -m)" in
        x86_64|amd64) echo 'x86_64|amd64' ;;
        aarch64|arm64) echo 'aarch64|arm64' ;;
        *) return 1 ;;
    esac
}

install_cli_release() {
    ensure_dirs
    local existing=""
    existing="$(tool_path codexbar || true)"
    if [ -n "$existing" ] && [ "${PZ_CODEXBAR_FORCE:-0}" != "1" ]; then
        pz_info "codexbar already installed: $existing"
        return 0
    fi

    pz_check_deps curl jq tar sha256sum >/dev/null
    local arch_re release tag asset_name asset_url checksum_url work archive expected actual extract bin_found binary_checksum
    arch_re="$(codexbar_arch_regex)" || {
        pz_warn "unsupported CodexBar Linux architecture: $(uname -m)"
        return 1
    }
    work="$(mktemp -d)"
    trap 'rm -rf -- "${work:?}"; trap - RETURN' RETURN
    release="$(curl -fsSL "$CODEXBAR_REPO_API")"
    tag="$(jq -r '.tag_name // empty' <<< "$release")"
    asset_name="$(jq -r --arg re "$arch_re" \
        '[.assets[]? | select(.name | test("(?i)linux")) | select(.name | test($re)) | select(.name | test("(?i)checksum|sha256") | not) | .name] | first // empty' \
        <<< "$release")"
    asset_url="$(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .browser_download_url' <<< "$release" | head -1)"
    local checksum_scope="global"
    checksum_url="$(jq -r --arg n "$asset_name.sha256" '[.assets[]? | select(.name == $n) | .browser_download_url] | first // empty' <<< "$release")"
    if [ -n "$checksum_url" ]; then
        checksum_scope="asset"
    else
        checksum_url="$(jq -r '[.assets[]? | select(.name | test("(?i)^(checksums?(\\.txt)?|sha256sums(\\.txt)?)$")) | .browser_download_url] | first // empty' <<< "$release")"
    fi
    [ -n "$tag" ] && [ -n "$asset_name" ] && [ -n "$asset_url" ] || {
        pz_warn "CodexBar Linux release asset not found (tag=${tag:-none}); check $CODEXBAR_REPO_API"
        return 1
    }

    archive="$work/$asset_name"
    curl -fL "$asset_url" -o "$archive"
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    if [ -n "$checksum_url" ]; then
        curl -fsSL "$checksum_url" -o "$work/checksums.txt"
        expected="$(awk -v asset="$asset_name" '$2 == asset || $2 == "*" asset || $2 == "./" asset {print $1; exit}' "$work/checksums.txt")"
        if [ -z "$expected" ] && [ "$checksum_scope" = "asset" ]; then
            expected="$(awk 'NF >= 1 {print $1; exit}' "$work/checksums.txt")"
        fi
        [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || {
            pz_warn "CodexBar checksum entry missing/invalid for $asset_name (source: $checksum_url)"
            return 1
        }
        [ "$actual" = "$expected" ] || {
            pz_error "CodexBar checksum mismatch. expected=$expected actual=$actual"
            return 1
        }
    else
        pz_warn "CodexBar release has no checksum asset; pinning computed sha256 in state"
    fi

    extract="$work/extract"
    mkdir -p "$extract"
    case "$asset_name" in
        *.tar.gz|*.tgz) tar -xzf "$archive" -C "$extract" ;;
        *.zip)
            pz_check_deps unzip >/dev/null
            unzip -q "$archive" -d "$extract"
            ;;
        *) cp "$archive" "$extract/codexbar" ;;
    esac
    bin_found="$(find "$extract" -type f \( -name codexbar -o -name 'codexbar-*' -o -name 'CodexBarCLI*' \) ! -name '*.txt' -print -quit 2>/dev/null || true)"
    [ -n "$bin_found" ] || {
        pz_warn "CodexBar artifact extracted, but CLI binary not found"
        return 1
    }
    install -m 0755 "$bin_found" "$LOCAL_BIN/codexbar"
    binary_checksum="$(sha256sum "$LOCAL_BIN/codexbar" | awk '{print $1}')"
    state_merge cli "$(jq -cn \
        --arg tag "$tag" \
        --arg asset "$asset_name" \
        --arg source "$asset_url" \
        --arg assetChecksum "$actual" \
        --arg binaryChecksum "$binary_checksum" \
        --arg path "$LOCAL_BIN/codexbar" \
        --arg installedAt "$(date -Iseconds)" \
        --argjson verified "$(bool_json "$([ -n "$checksum_url" ] && echo true || echo false)")" \
        '{releaseTag:$tag,asset:$asset,source:$source,sha256:$binaryChecksum,binarySha256:$binaryChecksum,assetSha256:$assetChecksum,checksumVerified:$verified,path:$path,installedAt:$installedAt}')"
    pz_info "CodexBar CLI installed: $LOCAL_BIN/codexbar ($tag)"
}

record_fallback_cli() {
    local path="$1" source="$2" version checksum
    version="$(first_line "$path" --version)"
    checksum="$(sha256sum "$path" | awk '{print $1}')"
    state_merge cli "$(jq -cn --arg source "$source" --arg version "$version" \
        --arg checksum "$checksum" --arg path "$path" --arg installedAt "$(date -Iseconds)" \
        '{releaseTag:$version,asset:"package-manager",source:$source,sha256:$checksum,binarySha256:$checksum,assetSha256:"",checksumVerified:false,path:$path,installedAt:$installedAt}')"
}

install_cli() {
    if install_cli_release; then
        return 0
    fi
    [ "${PZ_CODEXBAR_NO_FALLBACK:-0}" = 1 ] && return 1
    pz_warn "CodexBar verified release install failed; trying package-manager fallbacks"
    if command -v brew >/dev/null 2>&1; then
        if brew install steipete/tap/codexbar >/dev/null 2>&1 || brew upgrade steipete/tap/codexbar >/dev/null 2>&1; then
            local brew_bin
            brew_bin="$(command -v codexbar || true)"
            if [ -n "$brew_bin" ] && [ -x "$brew_bin" ]; then
                record_fallback_cli "$brew_bin" "homebrew:steipete/tap/codexbar"
                pz_info "CodexBar CLI installed through Homebrew: $brew_bin"
                return 0
            fi
        fi
        pz_warn "Homebrew fallback failed"
    fi
    if command -v cargo >/dev/null 2>&1; then
        if cargo install --locked codexbar-cli >/dev/null 2>&1; then
            local cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin/codexbar"
            if [ -x "$cargo_bin" ]; then
                record_fallback_cli "$cargo_bin" "cargo:codexbar-cli"
                pz_info "CodexBar CLI installed through Cargo: $cargo_bin"
                return 0
            fi
        fi
        pz_warn "Cargo fallback failed"
    fi
    pz_error "CodexBar CLI unavailable: verified release, Homebrew and Cargo failed"
    return 1
}

kodexbar_latest_tag() {
    git ls-remote --tags --sort=-v:refname "$KODEXBAR_REPO_URL" 2>/dev/null \
        | awk -F/ '{print $NF}' | grep -v '\^{}' | head -1 || true
}

ensure_kpackagetool() {
    command -v kpackagetool6 >/dev/null 2>&1 && return 0
    if ! command -v plasmashell >/dev/null 2>&1; then
        pz_warn "KDE Plasma not detected; skipping KodexBar plasmoid"
        return 77
    fi
    pz_warn "kpackagetool6 missing; attempting plasma-sdk install"
    if command -v pacman >/dev/null 2>&1; then
        pz_admin_run pacman -S --needed --noconfirm plasma-sdk || true
    fi
    command -v kpackagetool6 >/dev/null 2>&1 || {
        pz_error "kpackagetool6 unavailable; install plasma-sdk manually"
        return 1
    }
}

plasmoid_instance_present() {
    [ -f "$PLASMA_LAYOUT" ] && grep -qE '^plugin=org\.kde\.plasma\.kodexbar$' "$PLASMA_LAYOUT"
}

backup_plasma_layout() {
    [ -f "$PLASMA_LAYOUT" ] || return 0
    local backup="${PLASMA_LAYOUT}.phasezero-codexbar.$(date +%Y%m%d%H%M%S).bak"
    cp -p -- "$PLASMA_LAYOUT" "$backup"
    find "$(dirname "$PLASMA_LAYOUT")" -maxdepth 1 -type f -name 'plasma-org.kde.plasma.desktop-appletsrc.phasezero-codexbar.*.bak' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | awk 'NR>3{sub(/^[^ ]+ /, ""); print}' | xargs -r rm -f --
    printf '%s\n' "$backup"
}

remove_plasmoid_instances() {
    local id="${1:-$(state_plasmoid_id)}" backup="" dbus="" removed=""
    plasmoid_instance_present || return 0
    backup="$(backup_plasma_layout)"
    dbus="$(command -v qdbus6 || command -v qdbus || true)"
    [ -n "$dbus" ] || {
        pz_error "cannot safely remove active KodexBar: Plasma DBus tool missing; layout backup: $backup"
        return 1
    }
    local script
    script="var n=0; var c=desktops().concat(panels()); for (var i=0;i<c.length;i++){var w=c[i].widgets();for(var j=w.length-1;j>=0;j--){if(w[j].type=='$id'){w[j].remove();n++;}}} print(String(n));"
    removed="$("$dbus" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$script" 2>/dev/null || true)"
    [[ "$removed" =~ ^[0-9]+$ ]] || {
        pz_error "Plasma rejected safe KodexBar removal; layout preserved and backup: $backup"
        return 1
    }
    if [ "$removed" -eq 0 ] && plasmoid_instance_present; then
        command -v kwriteconfig6 >/dev/null 2>&1 || {
            pz_error "KodexBar layout entry is orphaned and kwriteconfig6 is missing; backup: $backup"
            return 1
        }
        local header containment applet
        while IFS= read -r header; do
            if [[ "$header" =~ ^\[Containments\]\[([0-9]+)\]\[Applets\]\[([0-9]+)\]$ ]]; then
                containment="${BASH_REMATCH[1]}"
                applet="${BASH_REMATCH[2]}"
                kwriteconfig6 --file "$PLASMA_LAYOUT" --group Containments --group "$containment" \
                    --group Applets --group "$applet" --key plugin --delete '' --notify
            fi
        done < <(awk 'BEGIN{h=""} /^\[/{h=$0} /^plugin=org\.kde\.plasma\.kodexbar$/{print h}' "$PLASMA_LAYOUT")
    fi
    local i
    for i in {1..10}; do
        plasmoid_instance_present || break
        sleep 1
    done
    plasmoid_instance_present && {
        pz_error "KodexBar instance still active; package not removed. Layout backup: $backup"
        return 1
    }
    pz_info "KodexBar removed from Plasma layout; backup: $backup"
}

install_plasmoid() {
    pz_check_deps git jq >/dev/null
    local kp_rc=0
    ensure_kpackagetool || kp_rc=$?
    [ "$kp_rc" -eq 77 ] && return 0
    [ "$kp_rc" -eq 0 ] || return "$kp_rc"

    plasmoid_instance_present && {
        pz_error "KodexBar already active in Plasma. Live package replacement is blocked because it can blank the desktop. Remove the widget first: pz ai codexbar plasmoid-remove"
        return 1
    }

    local work tag meta pkg_dir id action="installed" commit
    work="$(mktemp -d)"
    trap 'rm -rf -- "${work:?}"; trap - RETURN' RETURN
    tag="$(kodexbar_latest_tag)"
    if [ -n "$tag" ]; then
        git clone --quiet --depth 1 --branch "$tag" "$KODEXBAR_REPO_URL" "$work/KodexBar"
    else
        git clone --quiet --depth 1 "$KODEXBAR_REPO_URL" "$work/KodexBar"
        pz_warn "KodexBar has no release tags; installing from main HEAD"
    fi
    meta="$(find "$work/KodexBar" -maxdepth 3 -name metadata.json -print -quit 2>/dev/null || true)"
    [ -n "$meta" ] || {
        pz_error "KodexBar metadata.json not found in clone"
        return 1
    }
    pkg_dir="$(dirname "$meta")"
    id="$(jq -r '.KPlugin.Id // empty' "$meta" 2>/dev/null || true)"
    [ -n "$id" ] || id="$PLASMOID_ID_DEFAULT"
    [ "$id" = "$PLASMOID_ID_DEFAULT" ] || {
        pz_error "unexpected KodexBar plugin id: $id"
        return 1
    }
    jq -e '.KPlugin.Id == "org.kde.plasma.kodexbar" and (."X-Plasma-API-Minimum-Version" | tostring | startswith("6"))' "$meta" >/dev/null || {
        pz_error "KodexBar metadata is incompatible with Plasma 6"
        return 1
    }
    [ -f "$pkg_dir/contents/ui/main.qml" ] || {
        pz_error "KodexBar main QML missing"
        return 1
    }
    if command -v qmllint >/dev/null 2>&1; then
        qmllint "$pkg_dir/contents/ui/main.qml" >/dev/null 2>&1 || {
            pz_error "KodexBar QML validation failed; package not installed"
            return 1
        }
    fi
    commit="$(git -C "$work/KodexBar" rev-parse HEAD)"

    if kpackagetool6 -t Plasma/Applet -s "$id" >/dev/null 2>&1; then
        kpackagetool6 -t Plasma/Applet -u "$pkg_dir" >/dev/null
        action="updated"
    else
        kpackagetool6 -t Plasma/Applet -i "$pkg_dir" >/dev/null
    fi
    state_merge plasmoid "$(jq -cn \
        --arg id "$id" \
        --arg tag "$tag" \
        --arg source "$KODEXBAR_REPO_URL" \
        --arg commit "$commit" \
        --arg installedAt "$(date -Iseconds)" \
        '{id:$id,tag:(if $tag == "" then "main" else $tag end),source:$source,commit:$commit,installedAt:$installedAt,autoAdd:false}')"
    pz_info "KodexBar plasmoid $action: $id${tag:+ ($tag)}"
    pz_info "Package installed but not activated. Add KodexBar manually only after saving Plasma layout."
}

CODEXBAR_HELP=""

codexbar_bin() {
    tool_path codexbar
}

codexbar_help_cache() {
    [ -n "$CODEXBAR_HELP" ] && return 0
    local bin
    bin="$(codexbar_bin || true)"
    [ -n "$bin" ] || return 1
    CODEXBAR_HELP="$(timeout 8 "$bin" --help 2>&1 || true)"
    [ -n "$CODEXBAR_HELP" ]
}

codexbar_supports() {
    codexbar_help_cache || return 1
    grep -qw "$1" <<< "$CODEXBAR_HELP"
}

codexbar_config_supports() {
    local bin help
    bin="$(codexbar_bin || true)"
    [ -n "$bin" ] || return 1
    help="$(timeout 8 "$bin" config --help 2>&1 || true)"
    grep -qw "$1" <<< "$help"
}

codex_session_present() {
    [ -s "$HOME/.codex/auth.json" ]
}

claude_session_present() {
    [ -s "$HOME/.claude/.credentials.json" ] && return 0
    [ -s "$HOME/.claude.json" ] && jq -e '.oauthAccount // .userID // empty' "$HOME/.claude.json" >/dev/null 2>&1 && return 0
    return 1
}

# Prints "key<TAB>region" for the first zcode provider holding a key
# (enabled providers first). Never log the key value.
zai_credential_from_zcode() {
    local cfg="$HOME/.zcode/v2/config.json" out
    [ -f "$cfg" ] || return 1
    out="$(jq -r '
        [.provider // {} | to_entries[] | .value | select((.options.apiKey // "") != "")]
        | (map(select(.enabled == true)) + .) | first // empty
        | [.options.apiKey, (if (.options.baseURL // "") | test("bigmodel") then "bigmodel-cn" else "global" end)]
        | @tsv' "$cfg" 2>/dev/null || true)"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

config_set_provider() {
    local prov="$1" enabled="$2" region="${3:-}" source="${4:-}" tmp
    [ -f "$CONFIG_FILE" ] || configure_config
    config_is_managed || {
        pz_warn "unmanaged $CONFIG_FILE; provider '$prov' left untouched"
        return 0
    }
    tmp="$(mktemp)"
    jq --arg p "$prov" --argjson e "$(bool_json "$enabled")" --arg r "$region" --arg s "$source" '
        (({enabled:$e})
          + (if $r != "" then {region:$r} else {} end)
          + (if $s != "" then {source:$s} else {} end)) as $change
        | .providers = (
            if any(.providers[]?; .id == $p) then
              [.providers[] | if .id == $p then . + $change else . end]
            else
              (.providers // []) + [({id:$p} + $change)]
            end
          )
    ' "$CONFIG_FILE" > "$tmp" && install -m 0600 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
}

enrich_config() {
    codex_session_present && config_set_provider codex true
    # Linux CLI auto probes browser cookies before OAuth and can stall headless health checks.
    claude_session_present && config_set_provider claude true "" oauth
    local cred=""
    cred="$(zai_credential_from_zcode || true)"
    [ -n "$cred" ] && config_set_provider zai true "${cred#*$'\t'}" api
    return 0
}

codexbar_cli_set_key() {
    local prov="$1" key="$2" bin
    bin="$(codexbar_bin || true)"
    [ -n "$bin" ] || return 1
    codexbar_config_supports "set-api-key" || return 1
    printf '%s' "$key" | timeout 10 "$bin" config set-api-key --provider "$prov" --stdin >/dev/null 2>&1
}

cmd_auth() {
    local provider_filter="all" headless=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --provider) shift; provider_filter="${1:-all}" ;;
            --provider=*) provider_filter="${1#*=}" ;;
            --headless) headless=true ;;
            *) pz_warn "unknown auth flag: $1" ;;
        esac
        shift 2>/dev/null || true
    done

    local codex_state="skipped" claude_state="skipped" zai_state="skipped" zai_region=""
    auth_wanted() { [ "$provider_filter" = "all" ] || [ "$provider_filter" = "$1" ]; }

    if auth_wanted codex; then
        if codex_session_present; then
            config_set_provider codex true
            codex_state="authenticated"
        else
            codex_state="login-required"
            pz_warn "Codex session missing; run: codex login"
        fi
    fi
    if auth_wanted claude; then
        if claude_session_present; then
            config_set_provider claude true "" oauth
            claude_state="authenticated"
        else
            claude_state="login-required"
            pz_warn "Claude Code session missing; run: claude (and finish login)"
        fi
    fi
    if auth_wanted zai; then
        local cred="" key=""
        cred="$(zai_credential_from_zcode || true)"
        if [ -z "$cred" ] && [ "$headless" = "true" ] && [ -t 0 ]; then
            printf 'Paste Z.ai API key (input hidden): ' >&2
            IFS= read -rs key
            echo >&2
            [ -n "$key" ] && cred="${key}"$'\t'"global"
        fi
        if [ -n "$cred" ]; then
            key="${cred%%$'\t'*}"
            zai_region="${cred#*$'\t'}"
            config_set_provider zai true "$zai_region" api
            if codexbar_cli_set_key zai "$key"; then
                zai_state="authenticated"
            else
                zai_state="enabled-key-not-wired"
                pz_warn "codexbar CLI does not expose set-api-key; zai enabled, key stays in zcode config"
            fi
        else
            zai_state="key-missing"
            pz_warn "no Z.ai key found in ~/.zcode/v2/config.json"
        fi
        key=""
        cred=""
    fi

    jq -cn \
        --arg filter "$provider_filter" \
        --arg codex "$codex_state" \
        --arg claude "$claude_state" \
        --arg zai "$zai_state" \
        --arg zaiRegion "$zai_region" \
        --argjson headless "$(bool_json "$headless")" \
        '{schemaVersion:1,action:"auth",filter:$filter,headless:$headless,
          providers:{codex:{state:$codex},claude:{state:$claude},zai:{state:$zai,region:$zaiRegion}}}'
}

configure_config() {
    [ -f "$CONFIG_TEMPLATE" ] || {
        pz_error "missing template: $CONFIG_TEMPLATE"
        return 1
    }
    # Migrate only PhaseZero-owned legacy config. Preserve arbitrary user config.
    if [ "$CONFIG_FILE" != "$LEGACY_CONFIG_FILE" ] && [ ! -e "$CONFIG_FILE" ] \
        && [ -f "$LEGACY_CONFIG_FILE" ] && jq -e '._managedBy == "phasezero"' "$LEGACY_CONFIG_FILE" >/dev/null 2>&1; then
        mkdir -p "$CONFIG_DIR"
        cp -p "$LEGACY_CONFIG_FILE" "${LEGACY_CONFIG_FILE}.phasezero-invalid.$(date +%s).bak"
        rm -f "$LEGACY_CONFIG_FILE"
    fi
    if [ -f "$CONFIG_FILE" ] && ! config_is_managed; then
        if [ "${PZ_CODEXBAR_FORCE:-0}" != "1" ]; then
            pz_warn "existing user config kept: $CONFIG_FILE (PZ_CODEXBAR_FORCE=1 to overwrite)"
            return 0
        fi
    fi
    pz_write_managed_file "$CONFIG_FILE" < "$CONFIG_TEMPLATE"
    chmod 0600 "$CONFIG_FILE"
    state_merge config "$(jq -cn --arg path "$CONFIG_FILE" --arg updatedAt "$(date -Iseconds)" '{path:$path,managed:true,updatedAt:$updatedAt}')"
    local bin
    bin="$(codexbar_bin || true)"
    if [ -n "$bin" ] && ! timeout 10 "$bin" config validate >/dev/null 2>&1; then
        pz_error "generated CodexBar config failed CLI validation: $CONFIG_FILE"
        return 1
    fi
}

config_is_managed() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '._managedBy == "phasezero"' "$CONFIG_FILE" >/dev/null 2>&1 && return 0
    [ -f "$STATE_FILE" ] && jq -e --arg path "$CONFIG_FILE" '.config.managed == true and .config.path == $path' "$STATE_FILE" >/dev/null 2>&1
}

health_json() {
    local problems=() verdict="healthy" bin="" expected_sha="" actual_sha="" usage_checked=false config_valid=true

    bin="$(codexbar_bin || true)"
    if [ -z "$bin" ]; then
        problems+=("cli_missing")
    elif [ -f "$STATE_FILE" ]; then
        expected_sha="$(jq -r '.cli.binarySha256 // ""' "$STATE_FILE" 2>/dev/null || true)"
        if [ -n "$expected_sha" ] && [ -x "$LOCAL_BIN/codexbar" ]; then
            actual_sha="$(sha256sum "$LOCAL_BIN/codexbar" | awk '{print $1}')"
            [ "$actual_sha" = "$expected_sha" ] || problems+=("cli_binary_corrupted")
        elif [ -x "$LOCAL_BIN/codexbar" ]; then
            problems+=("cli_integrity_baseline_missing")
        fi
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        problems+=("config_missing")
        config_valid=false
    elif ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        problems+=("config_invalid")
        config_valid=false
    elif [ -n "$bin" ] && ! timeout 10 "$bin" config validate >/dev/null 2>&1; then
        problems+=("config_schema_invalid")
        config_valid=false
    fi

    if [ -n "$bin" ] && [ "$config_valid" = true ] && codexbar_supports usage; then
        usage_checked=true
        local prov data rc kind
        while IFS= read -r prov; do
            [ -n "$prov" ] || continue
            if data="$(timeout 15 "$bin" usage --provider "$prov" --format json --json-only 2>/dev/null)"; then
                rc=0
            else
                rc=$?
            fi
            if [ "$rc" -eq 124 ]; then
                problems+=("${prov}_usage_timeout")
                continue
            fi
            if ! jq -e 'type == "array" and length > 0 and all(.[]; (.error? == null))' <<< "$data" >/dev/null 2>&1; then
                kind="$(jq -r '.[0].error.kind // "unavailable"' <<< "$data" 2>/dev/null | tr -cd '[:alnum:]_-' || true)"
                problems+=("${prov}_usage_${kind:-unavailable}")
            fi
        done < <(jq -r '.providers // [] | .[] | select(.enabled == true) | .id' "$CONFIG_FILE" 2>/dev/null || true)
    fi

    [ "${#problems[@]}" -eq 0 ] || verdict="degraded"
    jq -cn \
        --arg verdict "$verdict" \
        --argjson usageChecked "$(bool_json "$usage_checked")" \
        --argjson problems "$(printf '%s\n' "${problems[@]:-}" | jq -R . | jq -cs 'map(select(length > 0))')" \
        '{schemaVersion:1,verdict:$verdict,problems:$problems,usageChecked:$usageChecked,checkedAt:(now|todate)}'
}

health_notify() {
    local health verdict log="$STATE_DIR/codexbar-health.log"
    mkdir -p "$STATE_DIR"
    health="$(health_json)"
    verdict="$(jq -r '.verdict' <<< "$health")"
    printf '%s %s\n' "$(date -Iseconds)" "$health" >> "$log"
    if [ "$verdict" != "healthy" ]; then
        if command -v phasezero-notify >/dev/null 2>&1; then
            phasezero-notify "CodexBar degraded" "$(jq -r '.problems | join(", ")' <<< "$health")" >/dev/null 2>&1 || true
        elif command -v notify-send >/dev/null 2>&1 && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
            notify-send -a PhaseZero "CodexBar degraded" \
                "$(jq -r '.problems | join(", ")' <<< "$health")" 2>/dev/null || true
        elif command -v zenity >/dev/null 2>&1 && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
            zenity --notification --text="CodexBar degraded: $(jq -r '.problems | join(", ")' <<< "$health")" >/dev/null 2>&1 || true
        fi
    fi
    printf '%s\n' "$health"
}

cmd_repair() {
    local health problems
    health="$(health_json)"
    problems="$(jq -r '.problems[]?' <<< "$health")"
    if [ -z "$problems" ]; then
        pz_info "codexbar healthy; nothing to repair"
        status_json
        return 0
    fi
    if grep -q 'cli_missing\|cli_binary_corrupted\|cli_integrity_baseline_missing' <<< "$problems"; then
        pz_info "repair: reinstalling CodexBar CLI"
        PZ_CODEXBAR_FORCE=1 install_cli || pz_warn "CLI reinstall failed"
    fi
    if grep -q 'config_missing\|config_invalid\|config_schema_invalid' <<< "$problems"; then
        pz_info "repair: regenerating managed config"
        PZ_CODEXBAR_FORCE=1 configure_config || pz_warn "config regeneration failed"
    fi
    if grep -q '_usage_' <<< "$problems"; then
        pz_warn "repair: provider auth may be expired; run: linux/pz ai codexbar auth"
    fi
    pz_info "repair safety: KodexBar plasmoid is never installed or updated automatically"
    status_json
}

SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
WATCHDOG_UNIT="phasezero-codexbar-health"

watchdog_install() {
    pz_write_managed_file "$SYSTEMD_USER_DIR/$WATCHDOG_UNIT.service" <<EOF
[Unit]
Description=PhaseZero CodexBar health check

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $PZ_ROOT/linux/ai/setup-codexbar.sh health-notify
EOF
    pz_write_managed_file "$SYSTEMD_USER_DIR/$WATCHDOG_UNIT.timer" <<EOF
[Unit]
Description=PhaseZero CodexBar periodic health check

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
    if [ "${PZ_CODEXBAR_WATCHDOG_NO_ENABLE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable --now "$WATCHDOG_UNIT.timer" 2>/dev/null \
            || pz_warn "could not enable $WATCHDOG_UNIT.timer (no user systemd session?)"
    fi
    watchdog_status
}

watchdog_remove() {
    if [ "${PZ_CODEXBAR_WATCHDOG_NO_ENABLE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now "$WATCHDOG_UNIT.timer" 2>/dev/null || true
    fi
    rm -f "$SYSTEMD_USER_DIR/$WATCHDOG_UNIT.service" "$SYSTEMD_USER_DIR/$WATCHDOG_UNIT.timer"
    if [ "${PZ_CODEXBAR_WATCHDOG_NO_ENABLE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    pz_info "codexbar watchdog removed"
    watchdog_status
}

watchdog_status() {
    local unit_exists=false timer_enabled=false timer_active=false
    [ -f "$SYSTEMD_USER_DIR/$WATCHDOG_UNIT.timer" ] && unit_exists=true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user is-enabled "$WATCHDOG_UNIT.timer" >/dev/null 2>&1 && timer_enabled=true
        systemctl --user is-active "$WATCHDOG_UNIT.timer" >/dev/null 2>&1 && timer_active=true
    fi
    jq -cn \
        --arg unit "$WATCHDOG_UNIT.timer" \
        --arg log "$STATE_DIR/codexbar-health.log" \
        --argjson unitExists "$(bool_json "$unit_exists")" \
        --argjson enabled "$(bool_json "$timer_enabled")" \
        --argjson active "$(bool_json "$timer_active")" \
        '{schemaVersion:1,watchdog:{unit:$unit,unitExists:$unitExists,enabled:$enabled,active:$active,log:$log}}'
}

update_all() {
    local latest current=""
    latest="$(curl -fsSL "$CODEXBAR_REPO_API" 2>/dev/null | jq -r '.tag_name // empty' || true)"
    [ -f "$STATE_FILE" ] && current="$(jq -r '.cli.releaseTag // empty' "$STATE_FILE" 2>/dev/null || true)"
    if [ -n "$latest" ] && [ "$latest" = "$current" ] && [ -x "$LOCAL_BIN/codexbar" ]; then
        pz_info "CodexBar CLI already at latest release: $current"
    else
        PZ_CODEXBAR_FORCE=1 install_cli || pz_warn "CodexBar CLI update failed"
    fi
    pz_info "KodexBar plasmoid update skipped; live Plasma package replacement is unsafe"
    status_json
}

remove_all() {
    local id
    id="$(state_plasmoid_id)"
    remove_plasmoid_instances "$id" || return 1
    if command -v kpackagetool6 >/dev/null 2>&1; then
        if kpackagetool6 -t Plasma/Applet -r "$id" >/dev/null 2>&1; then
            pz_info "KodexBar plasmoid removed: $id"
        else
            pz_warn "KodexBar plasmoid not installed or removal failed: $id"
        fi
    fi
    if [ -e "$LOCAL_BIN/codexbar" ]; then
        rm -f "$LOCAL_BIN/codexbar"
        pz_info "removed $LOCAL_BIN/codexbar"
    fi
    if [ -f "$CONFIG_FILE" ] && config_is_managed; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)" 2>/dev/null || true
        rm -f "$CONFIG_FILE"
        pz_info "removed managed config (backup kept next to it)"
    fi
    rm -f "$STATE_FILE"
    status_json
}

status_json() {
    local cli_path="" cli_ver="" tag="" sha="" asset_sha="" verified=false
    local plasmoid_id kpkg=false plasmoid_installed=false plasma_ver=""
    local config_exists=false config_managed=false
    cli_path="$(tool_path codexbar || true)"
    [ -n "$cli_path" ] && cli_ver="$(first_line "$cli_path" --version)"
    if [ -f "$STATE_FILE" ]; then
        tag="$(jq -r '.cli.releaseTag // empty' "$STATE_FILE" 2>/dev/null || true)"
        sha="$(jq -r '.cli.binarySha256 // .cli.sha256 // empty' "$STATE_FILE" 2>/dev/null || true)"
        asset_sha="$(jq -r '.cli.assetSha256 // empty' "$STATE_FILE" 2>/dev/null || true)"
        jq -e '.cli.checksumVerified == true' "$STATE_FILE" >/dev/null 2>&1 && verified=true
    fi
    plasmoid_id="$(state_plasmoid_id)"
    if command -v kpackagetool6 >/dev/null 2>&1; then
        kpkg=true
        kpackagetool6 -t Plasma/Applet -s "$plasmoid_id" >/dev/null 2>&1 && plasmoid_installed=true
    fi
    command -v plasmashell >/dev/null 2>&1 && plasma_ver="$(first_line plasmashell --version)"
    [ -f "$CONFIG_FILE" ] && config_exists=true
    [ "$config_exists" = "true" ] && config_is_managed && config_managed=true
    local providers_json='{}' codex_auth=false claude_auth=false zai_auth=false
    if [ "$config_exists" = "true" ]; then
        providers_json="$(jq -c 'reduce (.providers // [])[] as $p ({}; .[$p.id] = ($p | del(.id, .apiKey, .secretKey, .cookieHeader, .tokenAccounts)))' "$CONFIG_FILE" 2>/dev/null || echo '{}')"
    fi
    codex_session_present && codex_auth=true
    claude_session_present && claude_auth=true
    zai_credential_from_zcode >/dev/null 2>&1 && zai_auth=true
    providers_json="$(jq -c \
        --argjson c "$codex_auth" --argjson cl "$claude_auth" --argjson z "$zai_auth" '
        (if has("codex") then .codex.authenticated = $c else . end)
        | (if has("claude") then .claude.authenticated = $cl else . end)
        | (if has("zai") then .zai.authenticated = $z else . end)' <<< "$providers_json")"
    jq -cn \
        --arg cliPath "$cli_path" \
        --arg cliVersion "$cli_ver" \
        --arg releaseTag "$tag" \
        --arg sha256 "$sha" \
        --arg assetSha256 "$asset_sha" \
        --arg plasmoidId "$plasmoid_id" \
        --arg plasmaVersion "$plasma_ver" \
        --arg configPath "$CONFIG_FILE" \
        --arg stateFile "$STATE_FILE" \
        --argjson cliAvailable "$(bool_json "$([ -n "$cli_path" ] && echo true || echo false)")" \
        --argjson checksumVerified "$(bool_json "$verified")" \
        --argjson kpackagetool "$(bool_json "$kpkg")" \
        --argjson plasmoidInstalled "$(bool_json "$plasmoid_installed")" \
        --argjson configExists "$(bool_json "$config_exists")" \
        --argjson configManaged "$(bool_json "$config_managed")" \
        --argjson providers "$providers_json" \
        '{
          schemaVersion: 1,
          cli: {available:$cliAvailable,path:$cliPath,version:$cliVersion,releaseTag:$releaseTag,sha256:$sha256,binarySha256:$sha256,assetSha256:$assetSha256,checksumVerified:$checksumVerified},
          plasmoid: {installed:$plasmoidInstalled,id:$plasmoidId,kpackagetoolAvailable:$kpackagetool,plasmaVersion:$plasmaVersion},
          config: {path:$configPath,exists:$configExists,managed:$configManaged},
          providers: $providers,
          stateFile: $stateFile
        }'
}

dry_run() {
    jq -cn \
        --arg api "$CODEXBAR_REPO_API" \
        --arg repo "$KODEXBAR_REPO_URL" \
        --arg bin "$LOCAL_BIN/codexbar" \
        --arg config "$CONFIG_FILE" \
        --arg state "$STATE_FILE" \
        '{tool:"codexbar",planned:["download CodexBar CLI Linux release with sha256 verification","keep KodexBar plasmoid opt-in and block live replacement","write managed ~/.codexbar/config.json (no keys)","write install state"],releaseApi:$api,plasmoidRepo:$repo,cliPath:$bin,configPath:$config,statePath:$state}'
}

setup_all() {
    install_cli || pz_warn "CodexBar CLI install failed; continuing"
    configure_config || pz_warn "CodexBar config skipped"
    enrich_config || pz_warn "CodexBar provider enrichment skipped"
    cmd_auth --provider all >/dev/null || pz_warn "CodexBar provider authentication enrichment incomplete"
    pz_info "KodexBar plasmoid skipped by default; install explicitly only after Plasma layout backup"
    status_json
}

case "${1:-setup}" in
    setup|install-all) setup_all ;;
    repair) cmd_repair ;;
    auth) shift; cmd_auth "$@" ;;
    health|check|doctor) health_json ;;
    health-notify) health_notify ;;
    watchdog)
        case "${2:-status}" in
            install|enable) watchdog_install ;;
            remove|disable|uninstall) watchdog_remove ;;
            status) watchdog_status ;;
            *) echo "usage: setup-codexbar.sh watchdog (install|remove|status)" >&2; exit 1 ;;
        esac
        ;;
    enrich) enrich_config; status_json | jq '.providers' ;;
    install-cli|cli|install) install_cli; status_json | jq '.cli' ;;
    install-plasmoid|plasmoid) install_plasmoid; status_json | jq '.plasmoid' ;;
    remove-plasmoid|plasmoid-remove|disable-plasmoid)
        id="$(state_plasmoid_id)"
        remove_plasmoid_instances "$id"
        if command -v kpackagetool6 >/dev/null 2>&1; then
            kpackagetool6 -t Plasma/Applet -r "$id" >/dev/null 2>&1 || true
        fi
        status_json | jq '.plasmoid'
        ;;
    configure|config) configure_config; status_json | jq '.config' ;;
    update|upgrade) update_all ;;
    remove|uninstall) remove_all ;;
    status) status_json ;;
    dry-run|plan) dry_run ;;
    *) echo "usage: setup-codexbar.sh (setup|auth|health|health-notify|watchdog|enrich|install-cli|install-plasmoid|remove-plasmoid|configure|update|remove|repair|status|dry-run)" >&2; exit 1 ;;
esac
