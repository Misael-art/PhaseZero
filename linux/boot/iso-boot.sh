#!/usr/bin/env bash
# iso-boot.sh - managed ISO loopback, removable EFI and optional grubfm entries
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ESCALATION_ARGS=()
ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target-root)
            [ -n "${2:-}" ] || { pz_error "--target-root requires a path"; exit 2; }
            export PZ_BOOT_TARGET_ROOT="$2"
            ESCALATION_ARGS+=("--target-root" "$2")
            shift 2
            ;;
        --target-root=*)
            export PZ_BOOT_TARGET_ROOT="${1#*=}"
            ESCALATION_ARGS+=("$1")
            shift
            ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

DOMAIN="${1:-summary}"
[ "$#" -gt 0 ] && shift || true
SUBCOMMAND="${1:-status}"
[ "$#" -gt 0 ] && shift || true
REST=("$@")

CONFIG="${PZ_ISO_BOOT_CONFIG:-$(pz_boot_path /etc/phasezero/boot-isos.json)}"
ARTIFACTS="${PZ_ISO_BOOT_ARTIFACTS:-$(pz_boot_path /var/lib/phasezero/boot/iso-artifacts.json)}"
ISO_SCRIPT="${PZ_ISO_GRUB_SCRIPT:-$(pz_boot_path /etc/grub.d/46_phasezero_iso_loopback)}"
USB_SCRIPT="${PZ_USB_GRUB_SCRIPT:-$(pz_boot_path /etc/grub.d/47_phasezero_removable_efi)}"
GRUBFM_SCRIPT="${PZ_GRUBFM_GRUB_SCRIPT:-$(pz_boot_path /etc/grub.d/48_phasezero_grubfm)}"
GRUB_CFG="$(pz_boot_path /boot/grub/grub.cfg)"
ESP_DIR="$(pz_boot_esp_dir)"
GRUBFM_EFI="$ESP_DIR/EFI/PhaseZero/grubfm/grubfmx64.efi"

default_manifest() {
    printf '%s\n' '{"schemaVersion":1,"entries":[]}'
}

manifest_json() {
    if [ -r "$CONFIG" ]; then
        jq -e 'type == "object" and .schemaVersion == 1 and (.entries | type == "array")' "$CONFIG" >/dev/null || {
            pz_error "invalid ISO boot manifest: $CONFIG"
            return 1
        }
        cat "$CONFIG"
    else
        default_manifest
    fi
}

need_root() {
    [ "$EUID" -eq 0 ] && return 0
    if command -v phasezero-admin >/dev/null 2>&1; then
        exec phasezero-admin bash "$0" "${ESCALATION_ARGS[@]}" "$DOMAIN" "$SUBCOMMAND" "${REST[@]}"
    elif command -v bigsudo >/dev/null 2>&1; then
        exec bigsudo bash "$0" "${ESCALATION_ARGS[@]}" "$DOMAIN" "$SUBCOMMAND" "${REST[@]}"
    fi
    pz_error "root required; run: linux/pz ai setup admin"
    return 77
}

safe_title() {
    local value="${1:-}"
    [ -n "$value" ] && [ "${#value}" -le 120 ] || return 1
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *"'"* && "$value" != *'{'* && "$value" != *'}'* ]]
}

slugify() {
    local value
    value="$(printf '%s' "${1:-entry}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' | cut -c1-48)"
    [ -n "$value" ] || value=entry
    printf '%s\n' "$value"
}

iso_listing() {
    local path="$1"
    command -v bsdtar >/dev/null 2>&1 || { pz_error "bsdtar missing"; return 1; }
    bsdtar -tf "$path" 2>/dev/null | sed 's#^\./##'
}

inspect_iso_json() {
    local path="$1" requested="${2:-auto}" real listing profile kernel initrd label matches=0 candidate
    [ -f "$path" ] || { pz_error "ISO not found: $path"; return 1; }
    real="$(realpath -e -- "$path")"
    listing="$(iso_listing "$real")" || { pz_error "could not read ISO: $real"; return 1; }

    if [ "$requested" = auto ]; then
        profile=""
        for candidate in systemrescue archiso ubuntu-casper debian-live grml; do
            case "$candidate" in
                systemrescue) grep -Eq '^sysresccd/boot/x86_64/vmlinuz$' <<< "$listing" || continue ;;
                archiso) grep -Eq '^arch/boot/x86_64/vmlinuz-linux$' <<< "$listing" || continue ;;
                ubuntu-casper) grep -Eq '^casper/vmlinuz' <<< "$listing" || continue ;;
                debian-live) grep -Eq '^live/vmlinuz' <<< "$listing" || continue ;;
                grml) grep -Eq '^boot/grml[^/]*/vmlinuz' <<< "$listing" || continue ;;
            esac
            profile="$candidate"
            matches=$((matches + 1))
        done
        [ "$matches" -eq 1 ] || { pz_error "ISO profile auto-detection expected one match, got $matches"; return 1; }
    else
        profile="$requested"
    fi

    case "$profile" in
        archiso)
            kernel="arch/boot/x86_64/vmlinuz-linux"
            initrd="$(grep -E '^arch/boot/x86_64/initramfs-linux\.img$' <<< "$listing" | head -1)"
            ;;
        systemrescue)
            kernel="sysresccd/boot/x86_64/vmlinuz"
            initrd="$(grep -E '^sysresccd/boot/x86_64/sysresccd\.img$' <<< "$listing" | head -1)"
            ;;
        ubuntu-casper)
            kernel="$(grep -E '^casper/vmlinuz([^/]*)$' <<< "$listing" | head -1)"
            initrd="$(grep -E '^casper/initrd([^/]*)$' <<< "$listing" | head -1)"
            ;;
        debian-live)
            kernel="$(grep -E '^live/vmlinuz([^/]*)$' <<< "$listing" | head -1)"
            initrd="$(grep -E '^live/initrd([^/]*)$' <<< "$listing" | head -1)"
            ;;
        grml)
            kernel="$(grep -E '^boot/grml[^/]*/vmlinuz([^/]*)$' <<< "$listing" | head -1)"
            initrd="$(grep -E '^boot/grml[^/]*/initrd([^/]*)$' <<< "$listing" | head -1)"
            ;;
        *) pz_error "unsupported ISO profile: $profile"; return 2 ;;
    esac
    [ -n "$kernel" ] && [ -n "$initrd" ] || { pz_error "profile $profile kernel/initrd missing"; return 1; }
    label="$(blkid -p -s LABEL -o value "$real" 2>/dev/null || true)"
    jq -n --arg profile "$profile" --arg kernelPath "/$kernel" --arg initrdPath "/$initrd" --arg isoLabel "$label" \
        '{profile:$profile,kernelPath:$kernelPath,initrdPath:$initrdPath,isoLabel:$isoLabel}'
}

iso_entry_json() {
    local path="$1" profile="$2" id="$3" title="$4" identity inspection sha size mtime
    pz_boot_valid_id "$id" || { pz_error "invalid entry id: $id"; return 2; }
    safe_title "$title" || { pz_error "unsafe entry title"; return 2; }
    identity="$(pz_boot_resolve_file_identity "$path")"
    inspection="$(inspect_iso_json "$path" "$profile")"
    sha="$(sha256sum -- "$path" | awk '{print $1}')"
    size="$(stat -c %s -- "$path")"; mtime="$(stat -c %Y -- "$path")"
    jq -n --arg id "$id" --arg title "$title" --arg sha256 "$sha" --argjson size "$size" --argjson mtime "$mtime" \
        --argjson identity "$identity" --argjson inspection "$inspection" \
        '$identity + $inspection + {id:$id,title:$title,kind:"iso",sha256:$sha256,size:$size,mtime:$mtime,enabled:true}'
}

render_iso_script() {
    local manifest="$1" row id title uuid module path kernel initrd profile label qtitle qpath qkernel qinitrd
    cat <<'EOF'
#!/usr/bin/env bash
exec tail -n +3 "$0"
# PhaseZero managed ISO loopback entries. Use: linux/pz boot iso status
EOF
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        id="$(jq -r '.id' <<< "$row")"; title="$(jq -r '.title' <<< "$row")"
        uuid="$(jq -r '.fsUuid' <<< "$row")"; module="$(jq -r '.fsModule' <<< "$row")"
        path="$(jq -r '.grubPath' <<< "$row")"; kernel="$(jq -r '.kernelPath' <<< "$row")"
        initrd="$(jq -r '.initrdPath' <<< "$row")"; profile="$(jq -r '.profile' <<< "$row")"
        label="$(jq -r '.isoLabel // ""' <<< "$row")"
        qtitle="$(pz_boot_grub_dquote "$title")"; qpath="$(pz_boot_grub_dquote "$path")"
        qkernel="$(pz_boot_grub_dquote "(loop)$kernel")"; qinitrd="$(pz_boot_grub_dquote "(loop)$initrd")"
        printf "menuentry %s --id='phasezero-iso-%s' --class recovery --class iso {\n" "$qtitle" "$id"
        printf '    insmod part_gpt\n    insmod part_msdos\n    insmod %s\n    insmod loopback\n' "$module"
        printf '    search --no-floppy --fs-uuid --set=iso_dev %s\n' "$uuid"
        printf '    if [ -f ($iso_dev)%s ]; then\n' "$qpath"
        printf '        loopback loop ($iso_dev)%s\n' "$qpath"
        case "$profile" in
            archiso)
                printf '        linux %s %s %s archisobasedir=arch earlymodules=loop\n' "$qkernel" \
                    "$(pz_boot_grub_dquote "img_dev=/dev/disk/by-uuid/$uuid")" "$(pz_boot_grub_dquote "img_loop=$path")"
                ;;
            systemrescue)
                printf '        linux %s %s %s archisobasedir=sysresccd earlymodules=loop\n' "$qkernel" \
                    "$(pz_boot_grub_dquote "img_dev=/dev/disk/by-uuid/$uuid")" "$(pz_boot_grub_dquote "img_loop=$path")"
                ;;
            ubuntu-casper)
                printf '        linux %s boot=casper %s quiet splash ---\n' "$qkernel" "$(pz_boot_grub_dquote "iso-scan/filename=$path")"
                ;;
            debian-live)
                printf '        linux %s boot=live components %s\n' "$qkernel" "$(pz_boot_grub_dquote "findiso=$path")"
                ;;
            grml)
                printf '        linux %s boot=live %s %s\n' "$qkernel" "$(pz_boot_grub_dquote "findiso=$path")" \
                    "$(pz_boot_grub_dquote "iso-scan/filename=$path")"
                ;;
        esac
        [ -z "$label" ] || printf '        set iso_label=%s\n' "$(pz_boot_grub_dquote "$label")"
        printf '        initrd %s\n' "$qinitrd"
        printf "    else\n        echo 'PhaseZero ISO unavailable or filesystem UUID changed.'\n        sleep 5\n    fi\n}\n"
    done < <(jq -c '.entries[] | select(.kind == "iso" and .enabled == true)' "$manifest")
}

render_usb_script() {
    local manifest="$1" row id title uuid module efi qtitle qefi
    cat <<'EOF'
#!/usr/bin/env bash
exec tail -n +3 "$0"
# PhaseZero managed removable EFI entries. Use: linux/pz boot usb status
EOF
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        id="$(jq -r '.id' <<< "$row")"; title="$(jq -r '.title' <<< "$row")"
        uuid="$(jq -r '.fsUuid' <<< "$row")"; module="$(jq -r '.fsModule' <<< "$row")"
        efi="$(jq -r '.efiPath' <<< "$row")"; qtitle="$(pz_boot_grub_dquote "$title")"; qefi="$(pz_boot_grub_dquote "$efi")"
        printf "menuentry %s --id='phasezero-removable-%s' --class usb --class efi {\n" "$qtitle" "$id"
        printf '    insmod part_gpt\n    insmod part_msdos\n    insmod %s\n    insmod chain\n' "$module"
        printf '    search --no-floppy --fs-uuid --set=removable %s\n' "$uuid"
        printf '    if [ -f ($removable)%s ]; then\n        chainloader ($removable)%s\n    else\n' "$qefi" "$qefi"
        printf "        echo 'PhaseZero removable EFI unavailable.'\n        sleep 5\n    fi\n}\n"
    done < <(jq -c '.entries[] | select(.kind == "removable-efi" and .enabled == true)' "$manifest")
}

render_grubfm_script() {
    local esp_uuid esp_fstype module rel qrel
    cat <<'EOF'
#!/usr/bin/env bash
exec tail -n +3 "$0"
# PhaseZero managed experimental grubfm entry.
EOF
    [ -f "$GRUBFM_EFI" ] || return 0
    esp_uuid="$(findmnt -no UUID -T "$ESP_DIR" 2>/dev/null | head -1 || true)"
    esp_fstype="$(findmnt -no FSTYPE -T "$ESP_DIR" 2>/dev/null | head -1 || true)"
    module="$(pz_boot_fs_module_for_fstype "$esp_fstype")"
    rel="/EFI/PhaseZero/grubfm/grubfmx64.efi"; qrel="$(pz_boot_grub_dquote "$rel")"
    cat <<EOF
menuentry "PhaseZero ISO Explorer (experimental)" --id='phasezero-grubfm' --class recovery --class efi {
    insmod part_gpt
    insmod $module
    insmod chain
    search --no-floppy --fs-uuid --set=phasezero_esp $esp_uuid
    if [ -f (\$phasezero_esp)$qrel ]; then
        chainloader (\$phasezero_esp)$qrel
    else
        echo 'PhaseZero grubfm payload unavailable.'
        sleep 5
    fi
}
EOF
}

restore_file() {
    local backup="$1" target="$2"
    if [ -f "$backup" ]; then install -m "$(stat -c %a "$backup")" "$backup" "$target"; else rm -f "$target"; fi
}

apply_manifest_file() {
    local proposed="$1" rollback tmpdir iso_tmp usb_tmp fm_tmp config_old iso_old usb_old fm_old rc=0
    need_root
    pz_boot_require_current_root_target
    pz_boot_preflight_grub
    pz_boot_validate_active_efi_safe
    jq -e '.schemaVersion == 1 and (.entries | type == "array")' "$proposed" >/dev/null
    pz_boot_backup_bundle "dynamic-iso-boot"
    tmpdir="$(pz_tempfile -d)"; rollback="$tmpdir/rollback"; install -d "$rollback"
    config_old="$rollback/config"; iso_old="$rollback/iso"; usb_old="$rollback/usb"; fm_old="$rollback/grubfm"
    [ -f "$CONFIG" ] && cp -a "$CONFIG" "$config_old"
    [ -f "$ISO_SCRIPT" ] && cp -a "$ISO_SCRIPT" "$iso_old"
    [ -f "$USB_SCRIPT" ] && cp -a "$USB_SCRIPT" "$usb_old"
    [ -f "$GRUBFM_SCRIPT" ] && cp -a "$GRUBFM_SCRIPT" "$fm_old"
    iso_tmp="$tmpdir/46"; usb_tmp="$tmpdir/47"; fm_tmp="$tmpdir/48"
    render_iso_script "$proposed" > "$iso_tmp"
    render_usb_script "$proposed" > "$usb_tmp"
    render_grubfm_script > "$fm_tmp"
    chmod 0755 "$iso_tmp" "$usb_tmp" "$fm_tmp"
    pz_boot_atomic_install "$proposed" "$CONFIG" 0644
    pz_boot_atomic_install "$iso_tmp" "$ISO_SCRIPT" 0755
    pz_boot_atomic_install "$usb_tmp" "$USB_SCRIPT" 0755
    pz_boot_atomic_install "$fm_tmp" "$GRUBFM_SCRIPT" 0755
    pz_boot_refresh_grub_config "$GRUB_CFG" || rc=$?
    if [ "$rc" -eq 0 ]; then
        pz_boot_validate_grub_cfg_safe "$GRUB_CFG" || rc=$?
    fi
    if [ "$rc" -eq 0 ] && grep -Eq '\(hd[0-9]+,gpt[0-9]+' "$ISO_SCRIPT" "$USB_SCRIPT" "$GRUBFM_SCRIPT"; then
        pz_error "generated PhaseZero entry contains disk ordinal"
        rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        pz_warn "dynamic boot transaction failed; restoring previous files"
        restore_file "$config_old" "$CONFIG"
        restore_file "$iso_old" "$ISO_SCRIPT"
        restore_file "$usb_old" "$USB_SCRIPT"
        restore_file "$fm_old" "$GRUBFM_SCRIPT"
        pz_boot_refresh_grub_config "$GRUB_CFG" || true
        rm -rf "$tmpdir"
        return "$rc"
    fi
    pz_boot_validate_active_efi_safe
    rm -rf "$tmpdir"
    pz_info "dynamic ISO boot configuration installed"
}

manifest_with_entry() {
    local entry="$1" current
    current="$(manifest_json)"
    jq --argjson entry "$entry" '.entries = ([.entries[] | select(.id != $entry.id)] + [$entry])' <<< "$current"
}

manifest_without_entry() {
    local id="$1"
    manifest_json | jq --arg id "$id" '.entries = [.entries[] | select(.id != $id)]'
}

entry_state_json() {
    local row="$1" kind path sha actual expected_size expected_mtime actual_size actual_mtime available=false reason=missing
    kind="$(jq -r '.kind' <<< "$row")"
    if [ "$kind" = iso ]; then
        path="$(jq -r '.hostPath' <<< "$row")"; sha="$(jq -r '.sha256' <<< "$row")"
        if [ -f "$path" ]; then
            expected_size="$(jq -r '.size // empty' <<< "$row")"; expected_mtime="$(jq -r '.mtime // empty' <<< "$row")"
            if [ -n "$expected_size" ] && [ -n "$expected_mtime" ]; then
                actual_size="$(stat -c %s -- "$path")"; actual_mtime="$(stat -c %Y -- "$path")"
                if [ "$actual_size" = "$expected_size" ] && [ "$actual_mtime" = "$expected_mtime" ]; then available=true; reason=ready; else reason=metadata-mismatch; fi
            else
                actual="$(sha256sum -- "$path" | awk '{print $1}')"
                if [ "$actual" = "$sha" ]; then available=true; reason=ready; else reason=hash-mismatch; fi
            fi
        fi
    else
        if blkid -U "$(jq -r '.fsUuid' <<< "$row")" >/dev/null 2>&1; then available=true; reason=present; fi
    fi
    jq --argjson available "$available" --arg reason "$reason" '. + {available:$available,reason:$reason}' <<< "$row"
}

status_json() {
    local kind="$1" manifest entries='[]' row state script
    manifest="$(manifest_json)"
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        state="$(entry_state_json "$row")"
        entries="$(jq --argjson item "$state" '. + [$item]' <<< "$entries")"
    done < <(jq -c --arg kind "$kind" '.entries[] | select(.kind == $kind)' <<< "$manifest")
    case "$kind" in iso) script="$ISO_SCRIPT" ;; removable-efi) script="$USB_SCRIPT" ;; esac
    jq -n --arg kind "$kind" --arg script "$script" --argjson installed "$([ -x "$script" ] && echo true || echo false)" \
        --argjson entries "$entries" '{schemaVersion:1,kind:$kind,installed:$installed,script:$script,entries:$entries}'
}

print_status() {
    local kind="$1" json
    json="$(status_json "$kind")"
    echo "PhaseZero $kind boot status"
    echo "  installed: $(jq -r '.installed' <<< "$json")"
    echo "  entries: $(jq -r '.entries | length' <<< "$json")"
    jq -r '.entries[] | "  \(.id): \(.reason) [\(.profile // .fsType // "efi")]"' <<< "$json"
}

cmd_iso() {
    local sub="$SUBCOMMAND" json=0 path profile=auto id="" title="" dry=0 arg entry proposed
    case "$sub" in
        status)
            [ "${REST[0]:-}" = --json ] && json=1
            [ "$json" -eq 1 ] && status_json iso || print_status iso
            ;;
        inspect)
            path="${REST[0]:-}"; [ -n "$path" ] || { pz_error "usage: boot iso inspect PATH [--profile PROFILE]"; return 2; }
            profile=auto
            for arg in "${REST[@]:1}"; do case "$arg" in --profile=*) profile="${arg#*=}" ;; esac; done
            inspect_iso_json "$path" "$profile"
            ;;
        scan)
            path="${REST[0]:-/boot/iso}"
            find "$path" -maxdepth 2 -type f -iname '*.iso' -print0 2>/dev/null | while IFS= read -r -d '' arg; do
                inspect_iso_json "$arg" auto 2>/dev/null | jq --arg path "$arg" '. + {path:$path}' || true
            done | jq -s '{schemaVersion:1,images:.}'
            ;;
        add)
            path="${REST[0]:-}"; [ -n "$path" ] || { pz_error "usage: boot iso add PATH [--profile PROFILE] [--id ID] [--title TITLE] [--dry-run]"; return 2; }
            for arg in "${REST[@]:1}"; do
                case "$arg" in --profile=*) profile="${arg#*=}" ;; --id=*) id="${arg#*=}" ;; --title=*) title="${arg#*=}" ;; --dry-run|-n) dry=1 ;; *) pz_error "unknown option: $arg"; return 2 ;; esac
            done
            [ -n "$id" ] || id="$(slugify "$(basename "${path%.iso}")")"
            [ -n "$title" ] || title="ISO: $(basename "$path")"
            entry="$(iso_entry_json "$path" "$profile" "$id" "$title")"
            proposed="$(pz_tempfile)"; manifest_with_entry "$entry" > "$proposed"
            if [ "$dry" -eq 1 ]; then jq . "$proposed"; rm -f "$proposed"; else apply_manifest_file "$proposed"; rm -f "$proposed"; fi
            ;;
        remove)
            id="${REST[0]:-}"; [ -n "$id" ] || { pz_error "usage: boot iso remove ID [--dry-run]"; return 2; }
            [ "${REST[1]:-}" = --dry-run ] && dry=1
            proposed="$(pz_tempfile)"; manifest_without_entry "$id" > "$proposed"
            if [ "$dry" -eq 1 ]; then jq . "$proposed"; rm -f "$proposed"; else apply_manifest_file "$proposed"; rm -f "$proposed"; fi
            ;;
        verify)
            id="${REST[0]:-}"; [ -n "$id" ] || { pz_error "usage: boot iso verify ID"; return 2; }
            entry="$(manifest_json | jq -c --arg id "$id" '.entries[] | select(.id == $id and .kind == "iso")' | head -1)"
            [ -n "$entry" ] || { pz_error "ISO entry not registered: $id"; return 1; }
            path="$(jq -r '.hostPath' <<< "$entry")"; profile="$(jq -r '.profile' <<< "$entry")"
            [ -f "$path" ] || { pz_error "ISO unavailable: $path"; return 1; }
            arg="$(sha256sum -- "$path" | awk '{print $1}')"
            [ "$arg" = "$(jq -r '.sha256' <<< "$entry")" ] || { pz_error "ISO SHA-256 mismatch: $id"; return 1; }
            inspect_iso_json "$path" "$profile" | jq --arg id "$id" --arg sha256 "$arg" '. + {id:$id,sha256:$sha256,verified:true}'
            ;;
        refresh)
            id="${REST[0]:-}"; [ -n "$id" ] || { pz_error "usage: boot iso refresh ID [--dry-run]"; return 2; }
            entry="$(manifest_json | jq -c --arg id "$id" '.entries[] | select(.id == $id and .kind == "iso")' | head -1)"
            [ -n "$entry" ] || { pz_error "ISO entry not registered: $id"; return 1; }
            path="$(jq -r '.hostPath' <<< "$entry")"; profile="$(jq -r '.profile' <<< "$entry")"; title="$(jq -r '.title' <<< "$entry")"
            [ "${REST[1]:-}" = --dry-run ] && dry=1
            entry="$(iso_entry_json "$path" "$profile" "$id" "$title")"
            proposed="$(pz_tempfile)"; manifest_with_entry "$entry" > "$proposed"
            if [ "$dry" -eq 1 ]; then jq . "$proposed"; rm -f "$proposed"; else apply_manifest_file "$proposed"; rm -f "$proposed"; fi
            ;;
        install)
            [ "${REST[0]:-}" = --dry-run ] && { manifest_json; return 0; }
            proposed="$(pz_tempfile)"; manifest_json > "$proposed"; apply_manifest_file "$proposed"; rm -f "$proposed"
            ;;
        next)
            id="${REST[0]:-}"; schedule_next iso "$id" "${REST[@]:1}"
            ;;
        *) pz_error "usage: boot iso (status|inspect|scan|add|verify|refresh|remove|install|next)"; return 2 ;;
    esac
}

mount_device_ro() {
    local device="$1" mountpoint="$2"
    mount -o ro "$device" "$mountpoint"
}

usb_entry_json() {
    local input="$1" id="$2" title="$3" source uuid fstype module root tmp="" efi hash host_esp_uuid
    pz_boot_valid_id "$id" || { pz_error "invalid entry id: $id"; return 2; }
    safe_title "$title" || { pz_error "unsafe entry title"; return 2; }
    if [ -d "$input" ]; then
        root="$(realpath -e "$input")"; source="$(findmnt -no SOURCE -T "$root" | head -1)"
        uuid="$(findmnt -no UUID -T "$root" | head -1)"; fstype="$(findmnt -no FSTYPE -T "$root" | head -1)"
    elif [ -b "$input" ]; then
        source="$(realpath -e "$input")"; uuid="$(blkid -s UUID -o value "$source")"; fstype="$(blkid -s TYPE -o value "$source")"
        tmp="$(pz_tempfile -d)"; mount_device_ro "$source" "$tmp"; root="$tmp"
    else
        pz_error "USB source must be mounted directory or block partition: $input"; return 2
    fi
    host_esp_uuid="$(findmnt -no UUID -T "$ESP_DIR" 2>/dev/null | head -1 || true)"
    if [ "$uuid" = "$host_esp_uuid" ]; then [ -z "$tmp" ] || { umount "$tmp"; rmdir "$tmp"; }; pz_error "refusing host ESP as removable target"; return 1; fi
    module="$(pz_boot_fs_module_for_fstype "$fstype" 2>/dev/null || true)"
    [ -n "$module" ] && pz_boot_grub_module_available "$module" || {
        [ -z "$tmp" ] || { umount "$tmp"; rmdir "$tmp"; }; pz_error "unsupported removable filesystem: $fstype"; return 1;
    }
    efi="$root/EFI/BOOT/BOOTX64.EFI"
    [ -f "$efi" ] || { [ -z "$tmp" ] || { umount "$tmp"; rmdir "$tmp"; }; pz_error "missing /EFI/BOOT/BOOTX64.EFI on $input"; return 1; }
    hash="$(sha256sum "$efi" | awk '{print $1}')"
    [ -z "$tmp" ] || { umount "$tmp"; rmdir "$tmp"; }
    jq -n --arg id "$id" --arg title "$title" --arg fsUuid "$uuid" --arg fsType "$fstype" --arg fsModule "$module" \
        --arg sha256 "$hash" '{id:$id,title:$title,kind:"removable-efi",fsUuid:$fsUuid,fsType:$fsType,fsModule:$fsModule,efiPath:"/EFI/BOOT/BOOTX64.EFI",sha256:$sha256,enabled:true}'
}

cmd_usb() {
    local sub="$SUBCOMMAND" input id="" title="" dry=0 arg entry proposed
    case "$sub" in
        status) [ "${REST[0]:-}" = --json ] && status_json removable-efi || print_status removable-efi ;;
        discover)
            lsblk -J -o PATH,TYPE,FSTYPE,UUID,LABEL,MOUNTPOINTS,RM,HOTPLUG,TRAN | jq '{schemaVersion:1,devices:[.. | objects | select(.type? == "part" and (.uuid? != null) and ((.rm? == true) or (.hotplug? == true) or (.tran? == "mmc")))]}'
            ;;
        add)
            input="${REST[0]:-}"; [ -n "$input" ] || { pz_error "usage: boot usb add DEVICE_OR_MOUNT [--id ID] [--title TITLE] [--dry-run]"; return 2; }
            for arg in "${REST[@]:1}"; do case "$arg" in --id=*) id="${arg#*=}" ;; --title=*) title="${arg#*=}" ;; --dry-run|-n) dry=1 ;; *) pz_error "unknown option: $arg"; return 2 ;; esac; done
            [ -n "$id" ] || id="$(slugify "$(basename "$input")")"
            [ -n "$title" ] || title="Removable EFI: $(basename "$input")"
            [ "$dry" -eq 1 ] || need_root
            entry="$(usb_entry_json "$input" "$id" "$title")"
            proposed="$(pz_tempfile)"; manifest_with_entry "$entry" > "$proposed"
            if [ "$dry" -eq 1 ]; then jq . "$proposed"; rm -f "$proposed"; else apply_manifest_file "$proposed"; rm -f "$proposed"; fi
            ;;
        remove)
            id="${REST[0]:-}"; [ -n "$id" ] || { pz_error "usage: boot usb remove ID [--dry-run]"; return 2; }
            [ "${REST[1]:-}" = --dry-run ] && dry=1
            proposed="$(pz_tempfile)"; manifest_without_entry "$id" > "$proposed"
            if [ "$dry" -eq 1 ]; then jq . "$proposed"; rm -f "$proposed"; else apply_manifest_file "$proposed"; rm -f "$proposed"; fi
            ;;
        install) proposed="$(pz_tempfile)"; manifest_json > "$proposed"; [ "${REST[0]:-}" = --dry-run ] && cat "$proposed" || apply_manifest_file "$proposed"; rm -f "$proposed" ;;
        next) id="${REST[0]:-}"; schedule_next removable-efi "$id" "${REST[@]:1}" ;;
        *) pz_error "usage: boot usb (status|discover|add|remove|install|next)"; return 2 ;;
    esac
}

grubfm_status_json() {
    local state=missing sha="" secure
    secure="$(pz_boot_secure_boot_state)"
    if [ -f "$GRUBFM_EFI" ]; then state=installed; sha="$(sha256sum "$GRUBFM_EFI" | awk '{print $1}')"; fi
    jq -n --arg state "$state" --arg path "$GRUBFM_EFI" --arg sha256 "$sha" --arg secureBoot "$secure" \
        '{schemaVersion:1,state:$state,path:$path,sha256:$sha256,secureBoot:$secureBoot,experimental:true,upstreamArchived:true}'
}

inspect_grubfm() {
    local path="$1" expected="${2:-}" actual file_type
    [ -f "$path" ] || { pz_error "grubfm EFI not found: $path"; return 1; }
    actual="$(sha256sum "$path" | awk '{print $1}')"
    [ -z "$expected" ] || [ "$actual" = "$expected" ] || { pz_error "grubfm SHA-256 mismatch"; return 1; }
    file_type="$(file -b "$path")"
    grep -Eqi 'PE32\+.*EFI application.*x86-64|PE32\+.*x86-64.*EFI application' <<< "$file_type" || {
        pz_error "not an x86_64 EFI application: $file_type"; return 1;
    }
    jq -n --arg path "$(realpath -e "$path")" --arg sha256 "$actual" --arg fileType "$file_type" \
        '{schemaVersion:1,path:$path,sha256:$sha256,fileType:$fileType,experimental:true,upstreamArchived:true}'
}

cmd_grubfm() {
    local sub="$SUBCOMMAND" source="" expected="" dry=0 arg inspection tmp manifest secure
    case "$sub" in
        status) [ "${REST[0]:-}" = --json ] && grubfm_status_json || grubfm_status_json | jq -r '"PhaseZero grubfm: \(.state) secureBoot=\(.secureBoot) experimental=true upstreamArchived=true"' ;;
        inspect)
            source="${REST[0]:-}"; [ -n "$source" ] || { pz_error "usage: boot grubfm inspect PATH [--sha256 HEX]"; return 2; }
            for arg in "${REST[@]:1}"; do case "$arg" in --sha256=*) expected="${arg#*=}" ;; esac; done
            inspect_grubfm "$source" "$expected"
            ;;
        install)
            for arg in "${REST[@]}"; do case "$arg" in --source=*) source="${arg#*=}" ;; --sha256=*) expected="${arg#*=}" ;; --dry-run|-n) dry=1 ;; *) pz_error "unknown option: $arg"; return 2 ;; esac; done
            [ -n "$source" ] && [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { pz_error "usage: boot grubfm install --source=PATH --sha256=HEX [--dry-run]"; return 2; }
            inspection="$(inspect_grubfm "$source" "${expected,,}")"
            secure="$(pz_boot_secure_boot_state)"
            [ "$secure" = disabled ] || { pz_error "Secure Boot must be confirmed disabled before grubfm install (state=$secure)"; return 1; }
            [ "$dry" -eq 0 ] || { jq --arg secureBoot "$secure" '. + {secureBoot:$secureBoot,wouldInstall:true}' <<< "$inspection"; return 0; }
            need_root; pz_boot_require_current_root_target; pz_boot_preflight_grub; pz_boot_backup_bundle "grubfm-install"
            tmp="$(pz_tempfile)"; install -m 0644 "$source" "$tmp"; pz_boot_atomic_install "$tmp" "$GRUBFM_EFI" 0644; rm -f "$tmp"
            install -d "$(dirname "$ARTIFACTS")"
            jq --arg installedAt "$(date -Iseconds)" '. + {installedAt:$installedAt}' <<< "$inspection" > "$ARTIFACTS"
            chmod 0644 "$ARTIFACTS"
            manifest="$(pz_tempfile)"; manifest_json > "$manifest"; apply_manifest_file "$manifest"; rm -f "$manifest"
            ;;
        remove)
            [ "${REST[0]:-}" = --dry-run ] && { grubfm_status_json | jq '. + {wouldRemove:true}'; return 0; }
            need_root; pz_boot_backup_bundle "grubfm-remove"; rm -f "$GRUBFM_EFI" "$ARTIFACTS"
            manifest="$(pz_tempfile)"; manifest_json > "$manifest"; apply_manifest_file "$manifest"; rm -f "$manifest"
            ;;
        next) schedule_next grubfm "" "${REST[@]}" ;;
        *) pz_error "usage: boot grubfm (status|inspect|install|remove|next)"; return 2 ;;
    esac
}

schedule_next() {
    local kind="$1" id="$2" reboot=0 entry_id row
    shift 2 || true
    [ "${1:-}" = --reboot ] && reboot=1
    case "$kind" in
        iso|removable-efi)
            [ -n "$id" ] || { pz_error "entry id required"; return 2; }
            row="$(manifest_json | jq -c --arg id "$id" --arg kind "$kind" '.entries[] | select(.id == $id and .kind == $kind)' | head -1)"
            [ -n "$row" ] || { pz_error "boot entry not registered: $kind/$id"; return 1; }
            [ "$(entry_state_json "$row" | jq -r '.available')" = true ] || { pz_error "boot entry unavailable: $kind/$id"; return 1; }
            [ "$kind" = iso ] && entry_id="phasezero-iso-$id" || entry_id="phasezero-removable-$id"
            ;;
        grubfm)
            [ -f "$GRUBFM_EFI" ] || { pz_error "grubfm not installed"; return 1; }
            entry_id=phasezero-grubfm
            ;;
    esac
    need_root
    command -v grub-reboot >/dev/null 2>&1 || { pz_error "grub-reboot missing"; return 1; }
    grep -Fq -- "--id='$entry_id'" "$GRUB_CFG" || { pz_error "entry missing from generated grub.cfg: $entry_id"; return 1; }
    grub-reboot "$entry_id"
    pz_info "one-shot boot set: $entry_id"
    [ "$reboot" -eq 0 ] || systemctl reboot
}

catalog_json() {
    local choices='[]' row state key title desc
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        state="$(entry_state_json "$row")"; key="$(jq -r 'if .kind == "iso" then "iso:"+.id else "usb:"+.id end' <<< "$row")"
        title="$(jq -r '.title' <<< "$row")"; desc="$(jq -r 'if .available then "Pronto para boot one-shot." else "Indisponível: "+.reason end' <<< "$state")"
        choices="$(jq --arg key "$key" --arg title "$title" --arg description "$desc" --argjson available "$(jq '.available' <<< "$state")" \
            '. + [{key:$key,title:$title,description:$description,available:$available}]' <<< "$choices")"
    done < <(manifest_json | jq -c '.entries[]')
    if [ -f "$GRUBFM_EFI" ]; then
        choices="$(jq '. + [{key:"grubfm",title:"Explorador de ISOs",description:"GRUB2 File Manager experimental; upstream arquivado.",available:true,experimental:true}]' <<< "$choices")"
    fi
    jq -n --argjson choices "$choices" '{schemaVersion:1,choices:$choices}'
}

summary() {
    local iso usb fm
    iso="$(manifest_json | jq '[.entries[] | select(.kind == "iso")] | length')"
    usb="$(manifest_json | jq '[.entries[] | select(.kind == "removable-efi")] | length')"
    fm="$([ -f "$GRUBFM_EFI" ] && echo installed || echo missing)"
    echo "PhaseZero dynamic ISO boot"
    echo "  iso_entries: $iso"
    echo "  usb_entries: $usb"
    echo "  grubfm: $fm"
    echo "  secure_boot: $(pz_boot_secure_boot_state)"
}

if [ "${PZ_ISO_BOOT_LIBRARY_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

case "$DOMAIN" in
    iso) cmd_iso ;;
    usb|removable) cmd_usb ;;
    grubfm) cmd_grubfm ;;
    catalog) catalog_json ;;
    summary|status) summary ;;
    *) pz_error "usage: iso-boot.sh (summary|catalog|iso|usb|grubfm) ..."; exit 2 ;;
esac
