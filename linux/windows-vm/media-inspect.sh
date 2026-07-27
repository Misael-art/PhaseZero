#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

media_inspect() {
    local iso="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --iso) iso="${2:-}"; shift 2 ;;
            --iso=*) iso="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown media-inspect option: $1"; return 1 ;;
        esac
    done

    [ -n "$iso" ] || { pz_error "--iso required"; return 1; }
    [ -f "$iso" ] || { pz_error "ISO not found: $iso"; return 1; }

    local sha256 arch uefi_boot wiminfo_cmd
    sha256="$(sha256sum "$iso" | cut -d' ' -f1)"

    arch="x64"
    uefi_boot=0
    if command -v fdisk >/dev/null 2>&1; then
        if fdisk -l "$iso" 2>/dev/null | grep -qi 'EFI'; then
            uefi_boot=1
        fi
    fi
    if [ "$uefi_boot" = "0" ] && command -v isoinfo >/dev/null 2>&1; then
        isoinfo -J -l -i "$iso" 2>/dev/null | grep -qi 'efi' && uefi_boot=1
    fi

    local size_mb
    size_mb="$(stat -c%s "$iso" 2>/dev/null || echo 0)"
    size_mb=$((size_mb / 1048576))

    local images_json="[]"
    if command -v wiminfo >/dev/null 2>&1; then
        local mount_dir tmp_wim
        tmp_wim="$(mktemp -d)"
        if command -v mount >/dev/null 2>&1 && command -v losetup >/dev/null 2>&1; then
            local loop_dev
            loop_dev="$(losetup --show -f "$iso" 2>/dev/null || true)"
            if [ -n "$loop_dev" ]; then
                mkdir -p "$tmp_wim/mount"
                mount -o ro "$loop_dev" "$tmp_wim/mount" 2>/dev/null || true
                local wim_path=""
                for path in "$tmp_wim/mount/sources/install.wim" "$tmp_wim/mount/sources/install.esd"; do
                    [ -f "$path" ] && { wim_path="$path"; break; }
                done
                if [ -n "$wim_path" ]; then
                    images_json="$(parse_wim_images "$wim_path")"
                    arch="$(wiminfo "$wim_path" 1 2>/dev/null | grep -i '^Architecture:' | head -1 | awk '{print $2}' || echo "$arch")"
                fi
                umount "$tmp_wim/mount" 2>/dev/null || true
                losetup -d "$loop_dev" 2>/dev/null || true
            fi
        fi
        rm -rf "$tmp_wim"
    fi

    local label=""
    command -v isoinfo >/dev/null 2>&1 && label="$(isoinfo -d -i "$iso" 2>/dev/null | grep -i 'Volume id' | head -1 | cut -d: -f2- | xargs || true)"

    local valid=true
    if command -v file >/dev/null 2>&1; then
        if ! file -b "$iso" 2>/dev/null | grep -qi 'ISO 9660\|DOS/MBR'; then
            valid=false
        fi
    fi
    local has_wim=false
    if [ "$images_json" != "[]" ] && [ "$(echo "$images_json" | jq '. | length')" -gt 0 ]; then
        has_wim=true
    elif command -v isoinfo >/dev/null 2>&1; then
        isoinfo -f -i "$iso" 2>/dev/null | grep -qE 'sources/install\.(wim|esd)' && has_wim=true
    fi
    [ "$has_wim" = false ] && valid=false

    if [ "$json" = "1" ]; then
        jq -n \
            --arg path "$iso" \
            --arg sha256 "$sha256" \
            --arg arch "$arch" \
            --argjson uefi $uefi_boot \
            --arg sizeMb "$size_mb" \
            --arg label "$label" \
            --argjson images "$images_json" \
            --argjson valid "$valid" \
            '{
                valid: $valid,
                path: $path,
                sha256: $sha256,
                arch: $arch,
                uefiBoot: $uefi,
                sizeMb: ($sizeMb|tonumber),
                label: $label,
                imageCount: ($images|length),
                images: $images
            }'
    else
        echo "ISO: $iso"
        echo "Valid: $valid"
        echo "SHA-256: $sha256"
        echo "Architecture: $arch"
        echo "UEFI bootable: $([ "$uefi_boot" = "1" ] && echo yes || echo no)"
        echo "Size: ${size_mb}MB"
        label="${label:-unknown}" && echo "Label: $label"
        echo "Images:"
        echo "$images_json" | jq -r '.[] | "  [#\(.index)] \(.name) - \(.edition)"' 2>/dev/null || echo "  (unable to parse WIM)"
        if [ "$valid" = false ]; then
            pz_error "ISO validation failed: not a valid Windows installation image"
        fi
    fi
}

parse_wim_images() {
    local wim="$1"
    local count
    count="$(wiminfo "$wim" 2>/dev/null | grep -c '^Index:' || true)"
    [ "$count" -lt 1 ] && count="$(wiminfo "$wim" 2>/dev/null | grep -c '^Index ' || true)"
    [ "$count" -lt 1 ] && { echo '[]'; return 0; }

    local images=()
    for ((i=1; i<=count; i++)); do
        local info name edition display_desc
        info="$(wiminfo "$wim" "$i" 2>/dev/null || true)"
        name="$(echo "$info" | grep -i '^Description:' | head -1 | sed 's/^Description:\s*//' || echo "Windows $i")"
        edition="$(echo "$info" | grep -i '^DisplayName:' | head -1 | sed 's/^DisplayName:\s*//' || echo "$name")"
        display_desc="$(echo "$info" | grep -i '^DisplayDescription:' | head -1 | sed 's/^DisplayDescription:\s*//' || echo "")"
        images+=("$(jq -n \
            --argjson index "$i" \
            --arg name "$name" \
            --arg edition "$edition" \
            --arg displayDescription "$display_desc" \
            '{index: $index, name: $name, edition: $edition, displayDescription: $displayDescription}')")
    done

    local sep=""; echo -n "["
    for img in "${images[@]}"; do
        echo -n "$sep$img"; sep=","
    done
    echo "]"
}

case "${1:-inspect}" in
    inspect) shift; media_inspect "$@" ;;
    *) echo "usage: media-inspect inspect --iso <windows.iso> [--json]"; exit 1 ;;
esac
