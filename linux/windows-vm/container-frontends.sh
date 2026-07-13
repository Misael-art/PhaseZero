#!/usr/bin/env bash
# container-frontends.sh - verified WinBoat/WinPodX AppImages and rootless Podman profile.
set -euo pipefail

PZ_ROOT="${PZ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$PZ_ROOT/linux/lib/common.sh"

LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
APP_ROOT="${PZ_WINDOWS_APPS_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/windows-frontends}"
APP_CACHE="${PZ_WINDOWS_APPS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/phasezero/windows-frontends}"
WINBOAT_API="${PZ_WINBOAT_API_URL:-https://api.github.com/repos/TibixDev/winboat/releases/latest}"
WINPODX_API="${PZ_WINPODX_API_URL:-https://api.github.com/repos/kernalix7/winpodx/releases/latest}"
WINBOAT_CONFIG="${PZ_WINBOAT_CONFIG:-$HOME/.winboat/winboat.config.json}"
WINPODX_CONFIG="${PZ_WINPODX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/winpodx/winpodx.toml}"
WINPODX_STORAGE="${PZ_WINPODX_STORAGE:-${XDG_DATA_HOME:-$HOME/.local/share}/winpodx/storage}"
WINPODX_CLI="${PZ_WINPODX_CLI:-$LOCAL_BIN/winpodx}"

usage() {
    cat <<'EOF'
Usage: container-frontends.sh <action>

Actions:
  status             Print AppImage, Podman, KVM, RDP and pod status JSON
  install-winboat    Install/update official WinBoat AppImage
  install-winpodx    Install/update official WinPodX AppImage
  configure          Apply Steam Deck-safe Podman profiles; does not provision Windows
  setup              Install both apps and configure profiles
  doctor             Validate complete host integration
  launch-winboat     Launch WinBoat
  launch-winpodx     Launch WinPodX
EOF
}

bool_json() { "$@" >/dev/null 2>&1 && printf true || printf false; }
file_sha256() { sha256sum "$1" | awk '{print $1}'; }
freerdp_available() { command -v xfreerdp3 >/dev/null 2>&1 || command -v sdl-freerdp3 >/dev/null 2>&1; }

download_atomic() {
    local url="$1" target="$2" tmp
    tmp="${target}.part.$$"
    mkdir -p "$(dirname "$target")"
    rm -f "$tmp"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 "$url" -o "$tmp"
    mv -f "$tmp" "$target"
}

verify_size_hash() {
    local file="$1" expected_size="$2" expected_hash="$3" actual_size actual_hash
    actual_size="$(stat -c %s "$file")"
    [ "$actual_size" = "$expected_size" ] || {
        pz_error "size mismatch for $file: expected $expected_size, got $actual_size"
        return 1
    }
    actual_hash="$(file_sha256 "$file")"
    [ "${actual_hash,,}" = "${expected_hash,,}" ] || {
        pz_error "SHA-256 mismatch for $file"
        return 1
    }
}

release_metadata() {
    local app="$1" api="$2" json asset expected_prefix
    json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        -H 'Accept: application/vnd.github+json' "$api")"
    case "$app" in
        winboat)
            asset="$(jq -ce '.assets[] | select(.name | test("^winboat-[0-9].*-x86_64\\.AppImage$")) | select(.state == "uploaded")' <<< "$json" | head -n1)"
            expected_prefix="https://github.com/TibixDev/winboat/releases/download/"
            ;;
        winpodx)
            asset="$(jq -ce '.assets[] | select(.name == "winpodx-x86_64.AppImage" and .state == "uploaded")' <<< "$json")"
            expected_prefix="https://github.com/kernalix7/winpodx/releases/download/"
            ;;
        *) pz_error "unknown frontend: $app"; return 1 ;;
    esac
    [ -n "$asset" ] || { pz_error "official $app AppImage missing"; return 1; }
    local name url size digest
    name="$(jq -r '.name' <<< "$asset")"
    url="$(jq -r '.browser_download_url' <<< "$asset")"
    size="$(jq -r '.size' <<< "$asset")"
    digest="$(jq -r '.digest // empty' <<< "$asset")"
    [[ "$url" == "$expected_prefix"*"/$name" ]] || {
        pz_error "unexpected $app release URL: $url"
        return 1
    }
    [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]] || {
        pz_error "$app release has no trusted SHA-256 digest"
        return 1
    }
    jq -cn --arg app "$app" --arg version "$(jq -r '.tag_name' <<< "$json")" \
        --arg publishedAt "$(jq -r '.published_at // empty' <<< "$json")" \
        --arg name "$name" --arg url "$url" --arg size "$size" \
        --arg sha256 "${BASH_REMATCH[1],,}" \
        '{app:$app,version:$version,publishedAt:$publishedAt,name:$name,url:$url,size:($size|tonumber),sha256:$sha256}'
}

write_launcher() {
    local app="$1" title="$2" binary
    binary="$APP_ROOT/$app/current/app.AppImage"
    mkdir -p "$LOCAL_BIN" "$APPLICATIONS_DIR"
    pz_write_managed_file "$LOCAL_BIN/$app" <<EOF
#!/usr/bin/env bash
set -euo pipefail
binary="$binary"
if [ ! -x "\$binary" ]; then
    echo "$title not installed. Run: $PZ_ROOT/linux/pz windows-vm apps install-$app" >&2
    exit 1
fi
export ELECTRON_OZONE_PLATFORM_HINT="\${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
if [ ! -e /dev/fuse ]; then export APPIMAGE_EXTRACT_AND_RUN=1; fi
exec "\$binary" "\$@"
EOF
    chmod 0755 "$LOCAL_BIN/$app"
    pz_write_managed_file "$APPLICATIONS_DIR/$app.desktop" <<EOF
[Desktop Entry]
Name=$title
Comment=Windows applications through rootless Podman and KVM
Exec=$LOCAL_BIN/$app %U
Icon=computer
Type=Application
StartupNotify=true
Categories=System;Emulator;
Keywords=Windows;Podman;KVM;RDP;
EOF
    chmod 0644 "$APPLICATIONS_DIR/$app.desktop"
}

install_app() {
    local app="$1" api="$2" title="$3" metadata version name url size sha cache stage final link
    pz_check_deps curl jq sha256sum
    [ "$(uname -m)" = x86_64 ] || { pz_error "$title AppImage supports x86_64 only"; return 1; }
    metadata="$(release_metadata "$app" "$api")"
    version="$(jq -r '.version' <<< "$metadata")"
    name="$(jq -r '.name' <<< "$metadata")"
    url="$(jq -r '.url' <<< "$metadata")"
    size="$(jq -r '.size' <<< "$metadata")"
    sha="$(jq -r '.sha256' <<< "$metadata")"
    cache="$APP_CACHE/$name"
    mkdir -p "$APP_CACHE" "$APP_ROOT/$app/versions"
    if [ -f "$cache" ] && ! verify_size_hash "$cache" "$size" "$sha"; then rm -f "$cache"; fi
    if [ ! -f "$cache" ]; then
        pz_info "downloading official $title $version"
        download_atomic "$url" "$cache"
    fi
    verify_size_hash "$cache" "$size" "$sha"
    stage="$APP_ROOT/$app/versions/.${sha:0:16}.stage.$$"
    final="$APP_ROOT/$app/versions/${sha:0:16}"
    rm -rf "$stage"
    mkdir -p "$stage"
    install -m 0755 "$cache" "$stage/app.AppImage"
    jq --arg installedAt "$(date -Iseconds)" '. + {installedAt:$installedAt,userScoped:true}' \
        <<< "$metadata" > "$stage/manifest.json"
    rm -rf "$final"
    mv "$stage" "$final"
    link="$APP_ROOT/$app/.current.$$"
    ln -s "versions/${sha:0:16}" "$link"
    mv -Tf "$link" "$APP_ROOT/$app/current"
    cp "$final/manifest.json" "$APP_ROOT/$app/state.json"
    chmod 0600 "$APP_ROOT/$app/state.json"
    write_launcher "$app" "$title"
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    pz_info "$title installed: $version"
}

configure_winboat() {
    pz_check_deps jq
    local dir tmp version="0.9.0"
    dir="$(dirname "$WINBOAT_CONFIG")"
    mkdir -p "$dir"
    chmod 0700 "$dir"
    [ -f "$APP_ROOT/winboat/state.json" ] &&
        version="$(jq -r '.version | sub("^v"; "")' "$APP_ROOT/winboat/state.json")"
    tmp="${WINBOAT_CONFIG}.tmp.$$"
    if [ -s "$WINBOAT_CONFIG" ] && jq empty "$WINBOAT_CONFIG" 2>/dev/null; then
        jq --arg version "$version" '. + {
          scale:125, scaleDesktop:125, smartcardEnabled:false,
          rdpMonitoringEnabled:true, passedThroughDevices:(.passedThroughDevices // []),
          customApps:(.customApps // []), experimentalFeatures:false,
          advancedFeatures:false, multiMonitor:0, rdpArgs:(.rdpArgs // []),
          disableAnimations:true, containerRuntime:"Podman",
          versionData:(.versionData // {previous:$version,current:$version})
        }' "$WINBOAT_CONFIG" > "$tmp"
    else
        jq -n --arg version "$version" '{
          scale:125,scaleDesktop:125,smartcardEnabled:false,rdpMonitoringEnabled:true,
          passedThroughDevices:[],customApps:[],experimentalFeatures:false,
          advancedFeatures:false,multiMonitor:0,rdpArgs:[],disableAnimations:true,
          containerRuntime:"Podman",versionData:{previous:$version,current:$version}
        }' > "$tmp"
    fi
    mv "$tmp" "$WINBOAT_CONFIG"
    chmod 0600 "$WINBOAT_CONFIG"
}

configure_winpodx() {
    [ -x "$WINPODX_CLI" ] || { pz_error "WinPodX not installed"; return 1; }
    pz_check_deps podman
    mkdir -p "$WINPODX_STORAGE" "$(dirname "$WINPODX_CONFIG")"
    chmod 0700 "$(dirname "$WINPODX_CONFIG")" "$WINPODX_STORAGE"
    local key value
    while IFS='|' read -r key value; do
        "$WINPODX_CLI" config set "$key" "$value" >/dev/null
    done <<EOF
pod.backend|podman
pod.cpu_cores|4
pod.ram_gb|4
pod.max_sessions|8
pod.auto_start|false
pod.idle_timeout|1800
pod.idle_action|stop
pod.storage_path|$WINPODX_STORAGE
pod.disk_size|64G
pod.ssd|true
pod.language|Portuguese
pod.region|pt-BR
pod.keyboard|pt-BR
pod.timezone|America/Sao_Paulo
pod.tuning_profile|auto
pod.usb_live|true
rdp.scale|135
rdp.dpi|0
rdp.multimon|off
rdp.freerdp_source|native
rdp.extra_flags|+multitouch
reverse_open.enabled|true
desktop.mime_associations|true
EOF
    chmod 0600 "$WINPODX_CONFIG"
}

configure_all() {
    command -v podman >/dev/null 2>&1 || { pz_error "podman missing"; return 1; }
    command -v podman-compose >/dev/null 2>&1 || { pz_error "podman-compose missing"; return 1; }
    command -v xfreerdp3 >/dev/null 2>&1 || command -v sdl-freerdp3 >/dev/null 2>&1 || {
        pz_error "FreeRDP 3 missing"
        return 1
    }
    [ -e /dev/kvm ] || { pz_error "/dev/kvm missing"; return 1; }
    configure_winboat
    configure_winpodx
    systemctl --user enable --now podman.socket >/dev/null 2>&1 ||
        pz_warn "podman.socket not enabled; CLI backend remains usable"
    pz_info "WinBoat + WinPodX configured for rootless Podman; guests remain stopped"
}

app_state_json() {
    local app="$1" state version="" sha=""
    state="$APP_ROOT/$app/state.json"
    [ -f "$state" ] && version="$(jq -r '.version // empty' "$state" 2>/dev/null || true)"
    [ -f "$state" ] && sha="$(jq -r '.sha256 // empty' "$state" 2>/dev/null || true)"
    jq -cn --arg version "$version" --arg sha256 "$sha" \
        --arg binary "$APP_ROOT/$app/current/app.AppImage" --arg launcher "$LOCAL_BIN/$app" \
        --argjson installed "$([ -x "$APP_ROOT/$app/current/app.AppImage" ] && echo true || echo false)" \
        '{installed:$installed,version:$version,sha256:$sha256,binary:$binary,launcher:$launcher}'
}

container_state() {
    local name="$1"
    podman inspect --format '{{.State.Status}}' "$name" 2>/dev/null || printf missing
}

status_json() {
    local winboat winpodx active_windows=0 libvirt_running=false
    winboat="$(app_state_json winboat)"
    winpodx="$(app_state_json winpodx)"
    if command -v podman >/dev/null 2>&1; then
        active_windows="$(podman ps --format '{{.Names}}' 2>/dev/null | awk 'tolower($0) ~ /(winboat|winpodx|windows)/{n++} END{print n+0}')"
    fi
    command -v virsh >/dev/null 2>&1 &&
        virsh -c qemu:///system list --state-running --name 2>/dev/null | grep -Eqi 'windows|win11|win10' && libvirt_running=true
    jq -cn --argjson winboat "$winboat" --argjson winpodx "$winpodx" \
        --arg winboatConfig "$WINBOAT_CONFIG" --arg winpodxConfig "$WINPODX_CONFIG" \
        --arg winboatContainer "$(container_state WinBoat)" \
        --arg winpodxContainer "$(container_state winpodx-windows)" \
        --argjson podman "$(bool_json command -v podman)" \
        --argjson compose "$(bool_json command -v podman-compose)" \
        --argjson freerdp "$(bool_json freerdp_available)" \
        --argjson kvm "$([ -r /dev/kvm ] && [ -w /dev/kvm ] && echo true || echo false)" \
        --argjson socket "$(bool_json systemctl --user is-active podman.socket)" \
        --argjson activeWindows "$active_windows" --argjson libvirtRunning "$libvirt_running" \
        '{schemaVersion:1,winboat:($winboat + {config:$winboatConfig,containerState:$winboatContainer}),
          winpodx:($winpodx + {config:$winpodxConfig,containerState:$winpodxContainer}),
          host:{podman:$podman,podmanCompose:$compose,freeRdp3:$freerdp,kvm:$kvm,podmanSocket:$socket},
          concurrency:{activePodmanWindows:$activeWindows,libvirtWindowsRunning:$libvirtRunning,
            safe:($activeWindows == 0 and ($libvirtRunning|not)),policy:"one-windows-guest-at-a-time"},
          provisioning:{complete:false,reason:"windows-eula-credentials-and-large-download-require-frontend-first-run"}}'
}

doctor() {
    local status
    status="$(status_json)"
    jq '. + {healthy:(.winboat.installed and .winpodx.installed and .host.podman and .host.podmanCompose and .host.freeRdp3 and .host.kvm),
      problems:[
        if .winboat.installed then empty else "winboat-not-installed" end,
        if .winpodx.installed then empty else "winpodx-not-installed" end,
        if .host.podmanCompose then empty else "podman-compose-missing" end,
        if .host.freeRdp3 then empty else "freerdp3-missing" end,
        if .host.kvm then empty else "kvm-unavailable" end,
        if .concurrency.safe then empty else "windows-guest-already-running" end
      ]}' <<< "$status"
}

launch_app() {
    local app="$1" state
    state="$(status_json)"
    jq -e '.concurrency.safe' <<< "$state" >/dev/null || {
        pz_error "another Windows guest is active; stop it before launching $app"
        return 1
    }
    nohup "$LOCAL_BIN/$app" >"${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/$app.log" 2>&1 &
    disown || true
    pz_info "$app launched"
}

main() {
    case "${1:-status}" in
        status) status_json ;;
        doctor) doctor ;;
        install-winboat) install_app winboat "$WINBOAT_API" WinBoat ;;
        install-winpodx) install_app winpodx "$WINPODX_API" WinPodX ;;
        configure) configure_all ;;
        setup)
            install_app winboat "$WINBOAT_API" WinBoat
            install_app winpodx "$WINPODX_API" WinPodX
            configure_all
            ;;
        launch-winboat) launch_app winboat ;;
        launch-winpodx) launch_app winpodx ;;
        help|-h|--help) usage ;;
        *) pz_error "unknown Windows frontend action: ${1:-}"; usage; return 1 ;;
    esac
}

main "$@"
