#!/usr/bin/env bash
# flatpak.sh - PhaseZero Flatpak remote/override management library
set -euo pipefail

PZ_FLATPAK_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/flatpak"

pz_flatpak_require() {
    if ! command -v flatpak &>/dev/null; then
        pz_error "flatpak not installed"
        return 1
    fi
}

pz_flatpak_has_remote() {
    local name="$1"
    flatpak remote-list --columns=name 2>/dev/null | grep -qxF "$name"
}

pz_flatpak_remote_url() {
    local name="$1"
    flatpak remote-info --show-url "$name" 2>/dev/null || true
}

pz_flatpak_remote_prio() {
    local name="$1"
    flatpak remote-list --columns=name,priority 2>/dev/null |
        awk -v r="$name" '$1 == r {print $2; exit}' || echo ""
}

pz_flatpak_ensure_remote() {
    local name="$1" url="$2"
    shift 2
    local prio="${PZ_FLATPAK_DEFAULT_PRIO:-10}"

    pz_flatpak_require || return 1

    if pz_flatpak_has_remote "$name"; then
        local existing_url
        existing_url=$(pz_flatpak_remote_url "$name")
        if [ "$existing_url" != "$url" ]; then
            pz_warn "remote '$name' exists with diff URL: $existing_url != $url"
            pz_info "skip. use --force to reconfigure"
            return 1
        fi
        pz_info "remote '$name' ok"
        return 0
    fi

    pz_info "adding flatpak remote: $name"
    flatpak remote-add --if-not-exists "$name" "$url"
    pz_rollback_register "flatpak-remote" "$name" ""
    pz_info "remote '$name' added"
}

pz_flatpak_remove_remote() {
    local name="$1"
    pz_flatpak_require || return 1
    if pz_flatpak_has_remote "$name"; then
        pz_info "removing flatpak remote: $name"
        flatpak remote-delete "$name"
    else
        pz_info "remote '$name' not present"
    fi
}

pz_flatpak_override_gaming() {
    local app="${1:-}" scope="${2:-user}"
    shift 2 2>/dev/null || true
    local extras=("$@")

    pz_flatpak_require || return 1

    local base_overrides=(
        --device=dri
        --device=shm
        --device=all
        --filesystem=host:ro
        --filesystem=~/.local/share/Steam:ro
        --filesystem=~/.var/app:ro
        --share=network
        --share=ipc
        --socket=pulseaudio
        --socket=x11
        --socket=wayland
        --socket=fallback-x11
        --env=DXVK_HUD=0
        --env=MANGOHUD=0
        --env=GAMESCOPE_WAYLAND_DISPLAY=1
    )

    if [ -z "$app" ]; then
        pz_info "applying global gaming flatpak overrides ($scope)"
        flatpak override --"$scope" "${base_overrides[@]}" "${extras[@]}"
        return 0
    fi

    if ! flatpak info "$app" &>/dev/null; then
        pz_warn "app $app not installed, skip override"
        return 1
    fi

    pz_info "applying gaming overrides for $app ($scope)"
    flatpak override --"$scope" "${base_overrides[@]}" "${extras[@]}" "$app"
}

pz_flatpak_override_steamdeck() {
    local app="${1:-}" scope="${2:-user}"
    shift 2 2>/dev/null || true

    pz_flatpak_override_gaming "$app" "$scope" \
        --env=STEAM_GAMESCOPE_ENABLED=1 \
        --env=STEAM_DISABLE_MANGOAPP=0 \
        --env=GAMESCOPE_LIMIT=60 \
        "${@}"
}

pz_flatpak_remove_overrides() {
    local app="${1:-}" scope="${2:-user}"
    pz_flatpak_require || return 1

    local reset=(
        --device=
        --filesystem=
        --share=
        --socket=
        --env=
        --unset-env=DXVK_HUD
        --unset-env=MANGOHUD
        --unset-env=GAMESCOPE_WAYLAND_DISPLAY
        --unset-env=STEAM_GAMESCOPE_ENABLED
        --unset-env=STEAM_DISABLE_MANGOAPP
        --unset-env=GAMESCOPE_LIMIT
    )

    if [ -z "$app" ]; then
        pz_info "removing global gaming flatpak overrides ($scope)"
        flatpak override --"$scope" "${reset[@]}"
        return 0
    fi

    pz_info "removing overrides for $app ($scope)"
    flatpak override --"$scope" "${reset[@]}" "$app"
}

pz_flatpak_audit() {
    pz_flatpak_require || return 1

    echo "=== Flatpak Audit ==="

    local conflicts=0

    echo "--- Remotes ---"
    flatpak remote-list --columns=name,url,options,priority 2>/dev/null | sort

    local flathub_url
    flathub_url=$(pz_flatpak_remote_url "flathub" 2>/dev/null || true)
    if [ -n "$flathub_url" ] && [ "$flathub_url" != "https://dl.flathub.org/repo/" ]; then
        echo "WARN: flathub URL != expected (https://dl.flathub.org/repo/): $flathub_url"
        conflicts=$((conflicts + 1))
    fi

    echo "--- Runtimes ---"
    flatpak list --runtime --columns=application,branch,origin 2>/dev/null | sort -u

    local runtimes
    runtimes=$(flatpak list --runtime --columns=application,branch 2>/dev/null | awk '{print $1, $2}' | sort -u)
    local dupes
    dupes=$(echo "$runtimes" | awk 'NR>1 {print $1}' | sort | uniq -d)
    if [ -n "$dupes" ]; then
        echo "WARN: duplicate runtime branches:"
        echo "$dupes" | while read -r app; do
            echo "  $app"
            conflicts=$((conflicts + 1))
        done
    fi

    echo "--- Overrides ---"
    local user_overrides
    user_overrides=$(flatpak override --user --show 2>/dev/null || echo "(none)")
    echo "user: $user_overrides"
    local system_overrides
    system_overrides=$(flatpak override --system --show 2>/dev/null || echo "(none)")
    echo "system: $system_overrides"

    echo "--- Install Scope ---"
    local system_apps user_apps
    system_apps=$(flatpak list --system --columns=application 2>/dev/null | grep -v '^$' | wc -l)
    user_apps=$(flatpak list --user --columns=application 2>/dev/null | grep -v '^$' | wc -l)
    echo "system: $system_apps apps, user: $user_apps apps"
    if [ "$system_apps" -gt 0 ] && [ "$user_apps" -gt 0 ]; then
        echo "WARN: apps installed in both system and user scopes"
        conflicts=$((conflicts + 1))
    fi

    if [ "$conflicts" -gt 0 ]; then
        echo "---"
        echo "FOUND $conflicts conflict(s). use 'pz flatpak audit --repair' to fix"
    else
        echo "---"
        echo "OK: no conflicts detected"
    fi

    return "$conflicts"
}

pz_flatpak_audit_repair() {
    pz_flatpak_require || return 1
    pz_flatpak_audit
    local rc=$?

    if [ "$rc" -eq 0 ]; then
        return 0
    fi

    local flathub_url
    flathub_url=$(pz_flatpak_remote_url "flathub" 2>/dev/null || true)
    if [ -n "$flathub_url" ] && [ "$flathub_url" != "https://dl.flathub.org/repo/" ]; then
        pz_info "repair: reconfiguring flathub remote"
        flatpak remote-modify flathub --url=https://dl.flathub.org/repo/ 2>/dev/null || {
            flatpak remote-delete flathub 2>/dev/null || true
            flatpak remote-add flathub https://flathub.org/repo/flathub.flatpakrepo
        }
    fi

    pz_info "removing unused flatpak runtimes"
    flatpak uninstall --unused -y 2>/dev/null || true

    pz_info "audit repair complete"
}

pz_flatpak_steamdeck_compat() {
    local dry_run="${PZ_DRY_RUN:-0}"

    pz_flatpak_require || return 1

    pz_info "configuring steamdeck flatpak compat"

    [ "$dry_run" = "1" ] && pz_info "dry-run: would add flathub" || \
        pz_flatpak_ensure_remote \
            "flathub" \
            "https://dl.flathub.org/repo/flathub.flatpakrepo"

    [ "$dry_run" = "1" ] && pz_info "dry-run: would add flathub-beta" || \
        pz_flatpak_ensure_remote \
            "flathub-beta" \
            "https://flathub.org/beta-repo/flathub-beta.flatpakrepo"

    if [ "$dry_run" = "1" ]; then
        pz_info "dry-run: would apply gaming overrides"
        return 0
    fi

    local installed
    installed=$(flatpak list --columns=application 2>/dev/null)
    local gaming_apps=(
        "com.valvesoftware.Steam"
        "org.libretro.RetroArch"
        "net.lutris.Lutris"
        "com.heroicgameslauncher.hgl"
        "org.prismlauncher.PrismLauncher"
    )
    for app in "${gaming_apps[@]}"; do
        if echo "$installed" | grep -qxF "$app"; then
            pz_flatpak_override_steamdeck "$app"
        fi
    done

    pz_flatpak_override_gaming "" "user"
}

pz_flatpak_setup_from_profile() {
    local profile_file="$1"
    local dry_run="${PZ_DRY_RUN:-0}"

    pz_flatpak_require 2>/dev/null || return 0

    local flatpak_raw
    flatpak_raw=$(jq -r '.packages.linux.flatpak // empty' "$profile_file" 2>/dev/null || true)
    [ -z "$flatpak_raw" ] && return 0

    local is_object=false
    echo "$flatpak_raw" | jq -e '. | type == "object"' >/dev/null 2>&1 && is_object=true

    if [ "$is_object" = true ]; then
        local remotes packages overrides
        remotes=$(jq -r '.packages.linux.flatpak.remotes // [] | .[] | "\(.name)\t\(.url)\t\(.required // true)"' "$profile_file" 2>/dev/null || true)
        packages=$(jq -r '.packages.linux.flatpak.packages // [] | .[]' "$profile_file" 2>/dev/null || true)
        overrides=$(jq -r '.packages.linux.flatpak.overrides // {}' "$profile_file" 2>/dev/null || true)

        if [ -n "$remotes" ]; then
            [ "$dry_run" = "1" ] && pz_info "planning flatpak remotes..." || pz_info "configuring flatpak remotes..."
            echo "$remotes" | while IFS=$'\t' read -r name url required; do
                [ -z "$name" ] || [ -z "$url" ] && continue
                if [ "$dry_run" = "1" ]; then
                    pz_info "  would add remote: $name -> $url"
                    continue
                fi
                pz_flatpak_ensure_remote "$name" "$url" || {
                    [ "$required" = "true" ] && pz_warn "required remote '$name' failed"
                }
            done
        fi

        if [ -n "$packages" ] && [ "$dry_run" = "1" ]; then
            pz_info "planning flatpak packages from profile..."
            echo "$packages" | while IFS= read -r pkg; do
                [ -z "$pkg" ] && continue
                pz_info "  would install: $pkg"
            done
        fi

        if [ -n "$overrides" ] && [ "$overrides" != "{}" ]; then
            local override_type
            override_type=$(echo "$overrides" | jq -r 'keys[]' 2>/dev/null || true)
            for ot in $override_type; do
                [ "$dry_run" = "1" ] && pz_info "  would apply $ot overrides" || {
                    case "$ot" in
                        gaming) pz_flatpak_override_gaming "" "user" ;;
                        steamdeck) pz_flatpak_override_steamdeck "" "user" ;;
                        *) pz_info "unknown override type: $ot" ;;
                    esac
                }
            done
        fi
    fi
}

pz_flatpak_status() {
    pz_flatpak_require 2>/dev/null || { echo '{"flatpak":false}'; return 0; }

    local remotes runtimes apps user_apps system_apps
    remotes=$(flatpak remote-list --columns=name,url 2>/dev/null | wc -l)
    runtimes=$(flatpak list --runtime --columns=application 2>/dev/null | grep -v '^$' | wc -l)
    apps=$(flatpak list --app --columns=application 2>/dev/null | grep -v '^$' | wc -l)
    user_apps=$(flatpak list --user --app --columns=application 2>/dev/null | grep -v '^$' | wc -l)
    system_apps=$(flatpak list --system --app --columns=application 2>/dev/null | grep -v '^$' | wc -l)

    jq -n \
        --argjson flatpak true \
        --argjson remotes "$remotes" \
        --argjson runtimes "$runtimes" \
        --argjson apps "$apps" \
        --argjson user_apps "$user_apps" \
        --argjson system_apps "$system_apps" \
        '{flatpak: $flatpak, remotes: $remotes, runtimes: $runtimes, apps: $apps, user_apps: $user_apps, system_apps: $system_apps}'
}

pz_flatpak_rollback() {
    if [ ! -f "$PZ_MANIFEST" ]; then return 0; fi
    local entries
    entries=$(jq -c 'reverse | .[] | select(.action == "flatpak-remote")' "$PZ_MANIFEST" 2>/dev/null || true)
    [ -z "$entries" ] && return 0
    echo "$entries" | while read -r entry; do
        local name
        name=$(echo "$entry" | jq -r '.target')
        pz_flatpak_remove_remote "$name"
    done
}
