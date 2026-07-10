#!/usr/bin/env bash
# common.sh - PhaseZero Linux shared library
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PZ_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero"
PZ_MANIFEST="$PZ_STATE/manifest.json"
PZ_LOG="$PZ_STATE/pz.log"

mkdir -p "$PZ_STATE"

pz_log() {
    local level="$1" msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$PZ_LOG"
    case "$level" in
        ERROR) echo >&2 "ERROR: $msg" ;;
        WARN)  echo >&2 "WARN:  $msg" ;;
        INFO)  echo "INFO:  $msg" ;;
        *)     echo "$msg" ;;
    esac
}

pz_info() { pz_log INFO "$*"; }
pz_warn() { pz_log WARN "$*"; }
pz_error() { pz_log ERROR "$*"; }

pz_can_sudo_noninteractive() {
    command -v sudo &>/dev/null && sudo -n true &>/dev/null
}

pz_admin_run() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then
        phasezero-admin "$@"
    elif command -v bigsudo >/dev/null 2>&1; then
        bigsudo "$@"
    elif [ "${PZ_USE_SUDO:-0}" = "1" ] && pz_can_sudo_noninteractive; then
        sudo -n "$@"
    else
        pz_error "admin bridge required; run: linux/pz ai setup admin"
        return 77
    fi
}

pz_write_managed_file() {
    local path="$1" scope="${2:-user}"
    local dir tmp backup
    dir="$(dirname "$path")"
    tmp="$(mktemp)"
    cat > "$tmp"

    if [ "$scope" = "root" ] && [ "$EUID" -ne 0 ]; then
        if command -v phasezero-admin >/dev/null 2>&1 || command -v bigsudo >/dev/null 2>&1 || { [ "${PZ_USE_SUDO:-0}" = "1" ] && pz_can_sudo_noninteractive; }; then
            backup="${path}.bak.$(date +%s).$$.${RANDOM:-0}"
            [ -f "$path" ] && pz_admin_run cp "$path" "$backup" 2>/dev/null || true
            pz_admin_run install -d "$dir"
            pz_admin_run install -m 0644 "$tmp" "$path"
            rm -f "$tmp"
            pz_info "wrote $path"
            return 0
        fi

        rm -f "$tmp"
        pz_warn "$path requires root; skipped non-interactive write"
        return 77
    fi

    mkdir -p "$dir"
    [ -f "$path" ] && cp "$path" "${path}.bak.$(date +%s).$$.${RANDOM:-0}" 2>/dev/null || true
    install -m 0644 "$tmp" "$path"
    rm -f "$tmp"
    pz_info "wrote $path"
}

pz_check_deps() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        pz_error "missing dependencies: ${missing[*]}"
        echo "Install: sudo pacman -S ${missing[*]}"
        return 1
    fi
}

pz_require_root() {
    if [ "$EUID" -ne 0 ]; then
        if command -v phasezero-admin &>/dev/null; then
            exec phasezero-admin "$0" "$@"
        elif command -v bigsudo &>/dev/null; then
            exec bigsudo "$0" "$@"
        else
            pz_error "root required; run: linux/pz ai setup admin"
            return 77
        fi
    fi
}

pz_boot_target_root() {
    local root="${PZ_BOOT_TARGET_ROOT:-/}"
    [ -n "$root" ] || root="/"
    if command -v realpath >/dev/null 2>&1 && [ -e "$root" ]; then
        realpath -m "$root"
    else
        printf '%s\n' "$root"
    fi
}

pz_boot_path() {
    local rel="${1:-/}" target
    target="$(pz_boot_target_root)"
    rel="/${rel#/}"
    if [ "$target" = "/" ]; then
        printf '%s\n' "$rel"
    else
        printf '%s%s\n' "${target%/}" "$rel"
    fi
}

pz_boot_require_current_root_target() {
    local target
    target="$(pz_boot_target_root)"
    if [ "$target" != "/" ]; then
        pz_error "target-root mutation must run inside target chroot. use: arch-chroot $target"
        return 1
    fi
}

pz_boot_mount_value() {
    local field="$1" target
    target="$(pz_boot_target_root)"
    findmnt -no "$field" -T "$target" 2>/dev/null | head -1
}

pz_boot_root_uuid() {
    pz_boot_mount_value UUID
}

pz_boot_root_subvol() {
    pz_boot_mount_value OPTIONS | tr ',' '\n' | awk -F= '$1 == "subvol" {print $2; exit}'
}

pz_boot_root_fstype() {
    pz_boot_mount_value FSTYPE
}

pz_boot_latest_kernel_version() {
    local boot_dir
    boot_dir="$(pz_boot_path /boot)"
    find "$boot_dir" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null |
        sort -V | tail -1 | sed 's/^vmlinuz-//'
}

pz_boot_grub_relpath() {
    local target fstype subvol
    target="$(pz_boot_target_root)"
    fstype="$(pz_boot_root_fstype || true)"
    subvol="$(pz_boot_root_subvol || true)"
    if [ "$target" = "/" ] && command -v grub-mkrelpath >/dev/null 2>&1 && [ -d /boot/grub ]; then
        grub-mkrelpath /boot/grub
        return 0
    fi
    if [ "$fstype" = "btrfs" ] && [ -n "$subvol" ]; then
        printf '%s\n' "${subvol%/}/boot/grub"
    else
        printf '%s\n' "/boot/grub"
    fi
}

pz_boot_file_relpath() {
    local rel="${1:-}" target fstype subvol
    rel="/${rel#/}"
    target="$(pz_boot_target_root)"
    fstype="$(pz_boot_root_fstype || true)"
    subvol="$(pz_boot_root_subvol || true)"
    if [ "$target" = "/" ] && command -v grub-mkrelpath >/dev/null 2>&1 && [ -e "$rel" ]; then
        grub-mkrelpath "$rel"
        return 0
    fi
    if [ "$fstype" = "btrfs" ] && [ -n "$subvol" ]; then
        printf '%s\n' "${subvol%/}$rel"
    else
        printf '%s\n' "$rel"
    fi
}

pz_boot_esp_dir() {
    pz_boot_path "${PZ_BOOT_ESP_DIR:-/boot/efi}"
}

pz_boot_file_state() {
    local path="$1" parent
    if [ -e "$path" ]; then
        echo present
        return 0
    fi
    parent="$(dirname "$path")"
    while [ "$parent" != "/" ] && [ ! -e "$parent" ]; do
        parent="$(dirname "$parent")"
    done
    if [ -e "$parent" ] && [ ! -x "$parent" ]; then
        echo permission-denied
    else
        echo missing
    fi
}

pz_boot_refuse_live_root() {
    local source fstype target
    target="$(pz_boot_target_root)"
    source="$(findmnt -no SOURCE -T "$target" 2>/dev/null | head -1 || true)"
    fstype="$(findmnt -no FSTYPE -T "$target" 2>/dev/null | head -1 || true)"

    if [ "${PZ_ALLOW_LIVE_BOOT_MUTATION:-0}" = "1" ]; then
        pz_warn "PZ_ALLOW_LIVE_BOOT_MUTATION=1 set; live-root boot guard bypassed"
        return 0
    fi

    if [ -d /run/miso/bootmnt ] && { [ -z "$source" ] || [[ "$source" != /dev/* ]]; }; then
        pz_error "refusing GRUB mutation from live/root overlay target: $target. chroot into target root or set PZ_ALLOW_LIVE_BOOT_MUTATION=1"
        return 1
    fi

    case "$fstype" in
        overlay|squashfs|iso9660)
            pz_error "refusing GRUB mutation on live filesystem type: $fstype target=$target"
            return 1
            ;;
    esac
}

pz_boot_preflight_grub() {
    pz_boot_refuse_live_root
    command -v grub-mkrelpath >/dev/null 2>&1 || { pz_error "grub-mkrelpath missing"; return 1; }
    if ! command -v update-grub >/dev/null 2>&1 && ! command -v grub-mkconfig >/dev/null 2>&1; then
        pz_error "update-grub/grub-mkconfig missing"
        return 1
    fi
    [ -d "$(pz_boot_path /boot/grub)" ] || { pz_error "$(pz_boot_path /boot/grub) missing"; return 1; }
    [ -n "$(pz_boot_root_uuid)" ] || { pz_error "could not resolve target root UUID"; return 1; }
    [ -n "$(pz_boot_latest_kernel_version)" ] || { pz_error "could not resolve /boot/vmlinuz-*"; return 1; }
    if [ ! -d "$(pz_boot_esp_dir)" ]; then
        pz_error "ESP not mounted at $(pz_boot_esp_dir)"
        return 1
    fi
}

pz_boot_backup_bundle() {
    local reason="${1:-grub-mutation}" ts base dir target
    ts="$(date '+%Y%m%d-%H%M%S')"
    target="$(pz_boot_target_root)"
    base="$(pz_boot_path /var/lib/phasezero/boot-backups)"
    install -d "$base"
    dir="$(mktemp -d "$base/${ts}.XXXXXX")"
    [ -f "$(pz_boot_path /etc/default/grub)" ] && cp -a "$(pz_boot_path /etc/default/grub)" "$dir/grub.default" 2>/dev/null || true
    [ -d "$(pz_boot_path /etc/default/grub.d)" ] && cp -a "$(pz_boot_path /etc/default/grub.d)" "$dir/grub.d.default" 2>/dev/null || true
    [ -d "$(pz_boot_path /etc/grub.d)" ] && cp -a "$(pz_boot_path /etc/grub.d)" "$dir/grub.d.scripts" 2>/dev/null || true
    [ -f "$(pz_boot_path /boot/grub/grub.cfg)" ] && cp -a "$(pz_boot_path /boot/grub/grub.cfg)" "$dir/grub.cfg" 2>/dev/null || true
    [ -f "$(pz_boot_path /boot/grub/grubenv)" ] && cp -a "$(pz_boot_path /boot/grub/grubenv)" "$dir/grubenv" 2>/dev/null || true
    [ -d "$(pz_boot_esp_dir)/EFI" ] && cp -a "$(pz_boot_esp_dir)/EFI" "$dir/EFI" 2>/dev/null || true
    lsblk -f > "$dir/lsblk-f.txt" 2>&1 || true
    blkid > "$dir/blkid.txt" 2>&1 || true
    findmnt > "$dir/findmnt.txt" 2>&1 || true
    if command -v efibootmgr >/dev/null 2>&1; then
        efibootmgr -v > "$dir/efibootmgr-v.txt" 2>&1 || true
    fi
    printf '%s\n' "$reason" > "$dir/reason.txt"
    printf '%s\n' "$target" > "$dir/target-root.txt"
    pz_info "boot backup bundle: $dir"
}

pz_boot_refresh_grub_config() {
    local cfg="${1:-/boot/grub/grub.cfg}" log log_dir log_target rc=0
    pz_boot_require_current_root_target
    log="$(mktemp)"
    if command -v update-grub >/dev/null 2>&1; then
        update-grub 2>&1 | tee "$log" || rc=$?
    else
        grub-mkconfig -o "$cfg" 2>&1 | tee "$log" || rc=$?
    fi
    log_dir="/var/lib/phasezero/boot-logs"
    install -d "$log_dir" 2>/dev/null || log_dir="$PZ_STATE/boot-logs"
    install -d "$log_dir"
    log_target="$log_dir/grub-refresh-$(date '+%Y%m%d-%H%M%S').log"
    cp "$log" "$log_target" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        pz_error "GRUB config refresh failed rc=$rc log=$log_target"
        rm -f "$log"
        return "$rc"
    fi
    if grep -Eiq '(^|[[:space:]])error:' "$log"; then
        pz_error "GRUB config refresh reported errors log=$log_target"
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
    pz_info "GRUB config refresh log: $log_target"
}

pz_boot_validate_grub_cfg_safe() {
    local cfg="${1:-/boot/grub/grub.cfg}"
    [ -f "$cfg" ] || { pz_error "missing GRUB config: $cfg"; return 1; }
    if grep -Eq 'terminal_input console usb_keyboard at_keyboard|insmod at_keyboard|set gfxmode=800x600,640x480,auto' "$cfg"; then
        pz_error "unsafe global GRUB input/video settings detected in $cfg"
        return 1
    fi
}

pz_boot_efi_has_dangerous_prefix() {
    local path="$1"
    [ -f "$path" ] || return 2
    strings -a "$path" |
        grep -Eq 'hd6,gpt2|\(,gpt[0-9]+\)/@/boot/grub|\(hd[0-9]+,gpt[0-9]+\)/@/boot/grub'
}

pz_boot_validate_efi_safe() {
    local path="$1"
    [ -f "$path" ] || { pz_error "missing EFI binary: $path"; return 1; }
    if pz_boot_efi_has_dangerous_prefix "$path"; then
        pz_error "dangerous disk-order GRUB prefix detected in $path"
        return 1
    fi
}

pz_boot_active_efi_path() {
    local esp boot_current line efi_rel candidate
    esp="$(pz_boot_esp_dir)"
    if command -v efibootmgr >/dev/null 2>&1; then
        boot_current="$(efibootmgr 2>/dev/null | awk '$1 == "BootCurrent:" {print $2; exit}' || true)"
        if [ -n "$boot_current" ]; then
            line="$(efibootmgr -v 2>/dev/null | awk -v entry="Boot${boot_current}" '$1 ~ "^" entry {print; exit}' || true)"
            if [[ "$line" =~ (\\EFI\\[^[:space:]]+\.efi) ]]; then
                efi_rel="${BASH_REMATCH[1]//\\//}"
                printf '%s/%s\n' "${esp%/}" "${efi_rel#/}"
                return 0
            fi
        fi
    fi
    for candidate in "$esp/EFI/BigLinux/grubx64.efi" "$esp/EFI/boot/bootx64.efi" "$esp/EFI/Boot/bootx64.efi"; do
        [ -e "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

pz_boot_efi_prefix_state() {
    local path="$1" state
    state="$(pz_boot_file_state "$path")"
    case "$state" in
        present)
            if pz_boot_efi_has_dangerous_prefix "$path"; then
                echo dangerous
            else
                echo safe
            fi
            ;;
        *) echo "$state" ;;
    esac
}

pz_boot_validate_active_efi_safe() {
    local path state
    path="$(pz_boot_active_efi_path 2>/dev/null || true)"
    if [ -z "$path" ]; then
        pz_warn "active EFI loader path not detected; skipping prefix validation"
        return 0
    fi
    state="$(pz_boot_efi_prefix_state "$path")"
    case "$state" in
        safe) return 0 ;;
        permission-denied)
            pz_warn "active EFI loader requires root/permission for prefix validation: $path"
            return 0
            ;;
        missing)
            pz_warn "active EFI loader path missing: $path"
            return 0
            ;;
        dangerous)
            pz_error "active EFI loader has dangerous disk-order GRUB prefix: $path"
            return 1
            ;;
        *)
            pz_warn "active EFI loader validation inconclusive: $state $path"
            return 0
            ;;
    esac
}

pz_rollback_register() {
    local action="$1" target="$2" backup="$3"
    local entry
    entry=$(jq -n \
        --arg action "$action" \
        --arg target "$target" \
        --arg backup "$backup" \
        --arg ts "$(date -Iseconds)" \
        '{action: $action, target: $target, backup: $backup, timestamp: $ts}')
    if [ -f "$PZ_MANIFEST" ]; then
        jq ". += [$entry]" "$PZ_MANIFEST" > "${PZ_MANIFEST}.tmp" && mv "${PZ_MANIFEST}.tmp" "$PZ_MANIFEST"
    else
        echo "[$entry]" > "$PZ_MANIFEST"
    fi
}

pz_rollback() {
    if [ ! -f "$PZ_MANIFEST" ]; then
        pz_info "nothing to rollback"
        return 0
    fi
    local entries
    entries=$(jq -c 'reverse | .[]' "$PZ_MANIFEST")
    echo "$entries" | while read -r entry; do
        local action target backup
        action=$(echo "$entry" | jq -r '.action')
        target=$(echo "$entry" | jq -r '.target')
        backup=$(echo "$entry" | jq -r '.backup')
        case "$action" in
            file) cp "$backup" "$target" && pz_info "restored $target from $backup" ;;
            package) pz_info "rollback package $target: manual reinstall may be needed" ;;
            service) systemctl disable --now "$target" 2>/dev/null || true ;;
            flatpak-remote)
                command -v flatpak >/dev/null 2>&1 && flatpak remote-delete "$target" 2>/dev/null || true
                ;;
        esac
    done
    rm -f "$PZ_MANIFEST"
    pz_info "rollback complete"
}

pz_run_profile() {
    local profile_file="$1"
    local profile_real profile_dir profile_name parent parent_file call_depth active_before
    if [ ! -f "$profile_file" ]; then
        pz_error "profile not found: $profile_file"
        return 1
    fi
    command -v jq >/dev/null 2>&1 || { pz_error "jq is required to read profiles"; return 69; }
    if ! jq -e 'type == "object" and (.name | type == "string" and length > 0)' "$profile_file" >/dev/null 2>&1; then
        pz_error "invalid profile JSON or missing name: $profile_file"
        return 2
    fi
    if ! jq -e '
        ((.extends // []) | type == "array") and
        ((.packages.linux.pacman // []) | type == "array") and
        ((.packages.linux.yay // []) | type == "array") and
        (((.packages.linux.flatpak // []) | type) as $t | $t == "array" or $t == "object") and
        ((.scripts.linux // []) | type == "array") and
        ((.systemd.linux.enable // []) | type == "array") and
        ((.systemd.linux.user // []) | type == "array") and
        ((.tuning.linux.sysctl // {}) | type == "object")
    ' "$profile_file" >/dev/null 2>&1; then
        pz_error "invalid Linux profile field type: $profile_file"
        return 2
    fi
    if ! jq -e '(.os // ["linux"]) | type == "array" and index("linux") != null' "$profile_file" >/dev/null 2>&1; then
        pz_error "profile does not support Linux: $profile_file"
        return 2
    fi

    profile_real="$(realpath -e "$profile_file" 2>/dev/null || printf '%s' "$profile_file")"
    profile_dir="$(dirname "$profile_real")"
    profile_name="$(jq -r '.name' "$profile_file")"
    call_depth="${PZ_PROFILE_CALL_DEPTH:-0}"
    if [ "$call_depth" -eq 0 ]; then
        PZ_PROFILE_VISITED='|'
        PZ_PROFILE_ACTIVE='|'
    fi
    active_before="${PZ_PROFILE_ACTIVE:-|}"
    case "$active_before" in
        *"|$profile_real|"*)
            pz_error "profile inheritance cycle detected at: $profile_name"
            return 2
            ;;
    esac
    case "${PZ_PROFILE_VISITED:-|}" in
        *"|$profile_real|"*)
            pz_info "profile already applied in composition: $profile_name"
            return 0
            ;;
    esac
    PZ_PROFILE_VISITED="${PZ_PROFILE_VISITED:-|}${profile_real}|"
    PZ_PROFILE_ACTIVE="${active_before}${profile_real}|"
    PZ_PROFILE_CALL_DEPTH=$((call_depth + 1))

    while IFS= read -r parent; do
        [ -n "$parent" ] || continue
        if [[ ! "$parent" =~ ^[A-Za-z0-9._-]+$ ]]; then
            pz_error "invalid parent profile name in $profile_name: $parent"
            PZ_PROFILE_CALL_DEPTH="$call_depth"
            PZ_PROFILE_ACTIVE="$active_before"
            return 2
        fi
        parent_file="$profile_dir/$parent.json"
        if [ ! -f "$parent_file" ]; then
            pz_error "parent profile not found: $parent_file"
            PZ_PROFILE_CALL_DEPTH="$call_depth"
            PZ_PROFILE_ACTIVE="$active_before"
            return 1
        fi
        pz_info "profile $profile_name extends $parent"
        pz_run_profile "$parent_file" || {
            PZ_PROFILE_CALL_DEPTH="$call_depth"
            PZ_PROFILE_ACTIVE="$active_before"
            return 1
        }
    done < <(jq -er '(.extends // []) | if type == "array" then .[] else error("extends must be an array") end' "$profile_file")

    local dry_run="${PZ_DRY_RUN:-0}"
    local packages
    packages=$(jq -r '.packages.linux.pacman // [] | .[]' "$profile_file" 2>/dev/null || true)
    local yay_pkgs
    yay_pkgs=$(jq -r '.packages.linux.yay // [] | .[]' "$profile_file" 2>/dev/null || true)
    local flatpak_pkgs
    flatpak_pkgs=$(jq -r '
      if .packages.linux.flatpak | type == "object"
      then .packages.linux.flatpak.packages // [] | .[]
      else .packages.linux.flatpak // [] | .[]
      end
    ' "$profile_file" 2>/dev/null || true)
    local flatpak_raw
    flatpak_raw=$(jq -r '.packages.linux.flatpak // empty' "$profile_file" 2>/dev/null || true)
    local flatpak_is_object=false
    if [ -n "$flatpak_raw" ]; then
        echo "$flatpak_raw" | jq -e '. | type == "object"' >/dev/null 2>&1 && flatpak_is_object=true
    fi
    local scripts
    scripts=$(jq -r '.scripts.linux // [] | .[]' "$profile_file" 2>/dev/null || true)
    local system_services
    system_services=$(jq -r '.systemd.linux.enable // [] | .[]' "$profile_file" 2>/dev/null || true)
    local user_services
    user_services=$(jq -r '.systemd.linux.user // [] | .[]' "$profile_file" 2>/dev/null || true)
    local sysctl_entries
    sysctl_entries=$(jq -r '.tuning.linux.sysctl // {} | to_entries[] | "\(.key)=\(.value)"' "$profile_file" 2>/dev/null || true)

    if [ -n "$packages" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning pacman packages..." || pz_info "installing pacman packages..."
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install pacman package: $pkg"
                continue
            fi
            pz_admin_run pacman -S --needed --noconfirm "$pkg"
            pz_rollback_register package "$pkg" ""
        done <<< "$packages"
    fi

    if [ -n "$yay_pkgs" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning AUR packages..." || pz_info "installing AUR packages..."
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install AUR package: $pkg"
                continue
            fi
            yay -S --needed --noconfirm "$pkg"
            pz_rollback_register package "$pkg" ""
        done <<< "$yay_pkgs"
    fi

    if [ "$flatpak_is_object" = true ]; then
        source "$PZ_ROOT/linux/lib/flatpak.sh"
        PZ_DRY_RUN="$dry_run" pz_flatpak_setup_from_profile "$profile_file"
    fi

    if [ -n "$flatpak_pkgs" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning flatpak packages..." || pz_info "installing flatpak packages..."
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install flatpak package: $pkg"
                continue
            fi
            local remote_name="flathub"
            if [ "$flatpak_is_object" = true ]; then
                remote_name=$(jq -r '.packages.linux.flatpak.remotes[0].name // "flathub"' "$profile_file" 2>/dev/null || echo "flathub")
            fi
            flatpak install -y "$remote_name" "$pkg"
            pz_rollback_register package "$pkg" ""
        done <<< "$flatpak_pkgs"
    fi

    if [ -n "$scripts" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning setup scripts..." || pz_info "running setup scripts..."
        while IFS= read -r script; do
            [ -z "$script" ] && continue
            if [[ "$script" = /* || "/$script/" = *"/../"* ]]; then
                pz_error "unsafe profile script path rejected: $script"
                PZ_PROFILE_CALL_DEPTH="$call_depth"
                PZ_PROFILE_ACTIVE="$active_before"
                return 2
            fi
            local script_path
            script_path="$(realpath -m "$PZ_ROOT/$script" 2>/dev/null || printf '%s/%s' "$PZ_ROOT" "$script")"
            case "$script_path" in
                "$PZ_ROOT"/*) ;;
                *)
                    pz_error "profile script escapes project root: $script"
                    PZ_PROFILE_CALL_DEPTH="$call_depth"
                    PZ_PROFILE_ACTIVE="$active_before"
                    return 2
                    ;;
            esac
            if [ -f "$script_path" ]; then
                if [ "$dry_run" = "1" ]; then
                    pz_info "would execute $script_path"
                    continue
                fi
                pz_info "executing $script_path"
                bash "$script_path"
            else
                pz_warn "script not found: $script_path"
            fi
        done <<< "$scripts"
    fi

    if [ -n "$system_services" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning system services..." || pz_info "enabling system services..."
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would enable system service: $service"
                continue
            fi
            pz_admin_run systemctl enable --now "$service"
        done <<< "$system_services"
    fi

    if [ -n "$user_services" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning user services..." || pz_info "enabling user services..."
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would enable user service: $service"
                continue
            fi
            systemctl --user enable --now "$service"
        done <<< "$user_services"
    fi

    if [ -n "$sysctl_entries" ]; then
        [ "$dry_run" = "1" ] && pz_info "planning sysctl tuning..." || pz_info "applying sysctl tuning..."
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would set sysctl: $entry"
                continue
            fi
            pz_admin_run sysctl -w "$entry"
        done <<< "$sysctl_entries"
    fi

    pz_info "profile $profile_file complete"
    PZ_PROFILE_CALL_DEPTH="$call_depth"
    PZ_PROFILE_ACTIVE="$active_before"
}
