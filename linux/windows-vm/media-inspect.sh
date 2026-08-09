#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

# Listing tool for UDF/ISO images: 7z family first, then bsdtar. Both read
# UDF without root or loop devices (mount/losetup need privileges and fail on
# UDF without libisofs support; isoinfo cannot traverse UDF payloads).
listing_tool() {
    for t in 7z 7za 7zr bsdtar; do
        command -v "$t" >/dev/null 2>&1 && { printf '%s\n' "$t"; return 0; }
    done
    return 1
}

# Normalized lowercase member list from an ISO (paths like /SOURCES/INSTALL.WIM;1
# -> sources/install.wim). Empty on failure; never aborts under pipefail (the
# listing tool may exit non-zero on non-archive input — partial stdout is still
# captured and normalized, nothing leaks to the script's stdout).
iso_members() {
    local iso="$1" tool members=""
    tool="$(listing_tool)" || { echo ""; return 0; }
    case "$tool" in
        7z|7za|7zr)
            members="$("$tool" l -ba "$iso" 2>/dev/null | awk '{print $NF}' || true)"
            ;;
        bsdtar)
            members="$(bsdtar -tf "$iso" 2>/dev/null || true)"
            ;;
    esac
    echo "$members" | sed 's/^\/\+//' | sed 's/;1$//' | tr '[:upper:]' '[:lower:]' | sort -u
}

# 1 if any listed member matches the given lowercase pattern.
iso_has() {
    local members="$1" pattern="$2"
    grep -qE "^${pattern}$" <<< "$members" && echo 1 || echo 0
}

# ── WIM payload introspection (bounded streaming, zero full extraction) ──
# install.wim/esd can be 7+ GB. Instead of extracting it, the 208-byte WIM
# container header and the XML resource it points to are streamed from the ISO
# with capped reads; the archive tool is SIGPIPE-stopped as soon as the needed
# bytes arrived. Decompression is bounded to the requested region.
#
# WIM header layout (all little-endian): signature "WIM\0" @0, image count u32
# @48, XML resource offset u64 @76, XML resource size u64 @84.

# Stream the first N bytes of the WIM payload into a file.
wim_stream_prefix() {
    local tool="$1" iso="$2" wim_name="$3" nbytes="$4" out="$5"
    case "$tool" in
        7z|7za|7zr)
            "$tool" e -so "$iso" "*${wim_name}*" 2>/dev/null | dd bs=1 count="$nbytes" of="$out" 2>/dev/null
            ;;
        bsdtar)
            bsdtar -xOf "$iso" "$wim_name" 2>/dev/null | dd bs=1 count="$nbytes" of="$out" 2>/dev/null
            ;;
        *) return 1 ;;
    esac
    return 0
}

# Stream XML resource (offset..offset+size) of the WIM payload into a file.
wim_stream_region() {
    local tool="$1" iso="$2" wim_name="$3" off="$4" size="$5" out="$6"
    case "$tool" in
        7z|7za|7zr)
            "$tool" e -so "$iso" "*${wim_name}*" 2>/dev/null | tail -c +"$((off + 1))" | head -c "$size" > "$out" 2>/dev/null
            ;;
        bsdtar)
            bsdtar -xOf "$iso" "$wim_name" 2>/dev/null | tail -c +"$((off + 1))" | head -c "$size" > "$out" 2>/dev/null
            ;;
    esac
    return 0
}

# Little-endian unsigned field read from a header file (hex bytes), capped at
# 2^31 so bogus offsets cannot drive giant reads.
wim_le() {
    local hdr="$1" off="$2" n="$3"
    local hex=""
    hex="$(od -An -v -tx1 -j "$off" -N "$n" "$hdr" 2>/dev/null)"
    local byte val=0 i=0
    for byte in $hex; do
        val=$((val + 16#$byte * 256 ** i))
        [ "$val" -gt 2147483647 ] && { echo 2147483647; return 0; }
        i=$((i + 1))
    done
    echo "$val"
}

# Parse XML resource lines (already split on '<') into a JSON image array.
wim_images_from_xml_lines() {
    local line index="" name="" edition="" desc="" in_image=0 out="" sep=""
    while IFS= read -r line; do
        case "$line" in
            'IMAGE INDEX='*)
                in_image=1; name=""; edition=""; desc=""
                index="${line#IMAGE INDEX=}"
                index="${index%>}"
                index="${index#\"}"; index="${index%\"}"
                index="${index#\'}"; index="${index%\'}"
                ;;
            'NAME>'*)
                [ "$in_image" = "1" ] && name="${line#NAME>}"
                ;;
            'DISPLAYNAME>'*)
                [ "$in_image" = "1" ] && edition="${line#DISPLAYNAME>}"
                ;;
            'DISPLAYDESCRIPTION>'*)
                [ "$in_image" = "1" ] && desc="${line#DISPLAYDESCRIPTION>}"
                ;;
            '/IMAGE'*)
                [ "$in_image" = "1" ] || continue
                in_image=0
                out+="${sep}$(jq -n \
                    --argjson index "$((10#${index:-0}))" \
                    --arg name "${name:-Windows ${index:-0}}" \
                    --arg edition "${edition:-$name}" \
                    --arg displayDescription "$desc" \
                    '{index: $index, name: $name, edition: $edition, displayDescription: $displayDescription}')"
                sep=","
                ;;
        esac
    done
    printf '[%s]\n' "$out"
}

# JSON image array from a WIM payload inside the ISO. Runs in a subshell so
# temp files are cleaned by the subshell's own EXIT trap (no local-variable
# scope traps). Returns '[]' whenever the payload is unreadable — structural
# validation (has_boot/has_wim) is independent of image parsing.
wim_payload_images() {
    local tool="$1" iso="$2" wim_name="$3"
    (
        local hdr_tmp xml_tmp
        hdr_tmp="$(pz_tempfile "pz-wim-hdr.XXXXXX")"
        xml_tmp="$(pz_tempfile "pz-wim-xml.XXXXXX")"
        wim_stream_prefix "$tool" "$iso" "$wim_name" 208 "$hdr_tmp" || true
        [ -s "$hdr_tmp" ] || { echo '[]'; exit 0; }
        local sig
        sig="$(od -An -v -tx1 -N3 "$hdr_tmp" 2>/dev/null | tr -d ' ')"
        [ "$sig" = "57494d" ] || { echo '[]'; exit 0; }
        local xml_off xml_size
        xml_off="$(wim_le "$hdr_tmp" 76 8)"
        xml_size="$(wim_le "$hdr_tmp" 84 8)"
        [ "$xml_off" -ge 208 ] || { echo '[]'; exit 0; }
        [ "$xml_size" -gt 0 ] || { echo '[]'; exit 0; }
        [ "$xml_size" -le 4194304 ] || { echo '[]'; exit 0; }
        [ "$xml_off" -le 8388608 ] || { echo '[]'; exit 0; }
        wim_stream_region "$tool" "$iso" "$wim_name" "$xml_off" "$xml_size" "$xml_tmp" || true
        local xml=""
        xml="$(cat "$xml_tmp" 2>/dev/null || true)"
        [ -n "$xml" ] || { echo '[]'; exit 0; }
        printf '%s' "$xml" | tr '<' '\n' | wim_images_from_xml_lines
    )
}

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

    local sha256 arch uefi_boot members
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

    members="$(iso_members "$iso")"
    if [ "$uefi_boot" = "0" ] && [ -n "$members" ]; then
        [ "$(iso_has "$members" 'efi/boot/bootx64\.efi')" = "1" ] && uefi_boot=1
        [ "$(iso_has "$members" 'efi/microsoft/boot/bootmgfw\.efi')" = "1" ] && uefi_boot=1
    fi

    local size_mb
    size_mb="$(stat -c%s "$iso" 2>/dev/null || echo 0)"
    size_mb=$((size_mb / 1048576))

    # Structural validity: BOTH a boot chain AND a Windows payload must exist.
    # setup.exe alone is NOT a boot chain — it is present on any installer
    # media and proves nothing about bootability.
    local has_boot=0 has_wim=0 wim_name="" tool=""
    if [ -n "$members" ]; then
        has_boot="$(iso_has "$members" 'bootmgr')"
        [ "$has_boot" = "1" ] || has_boot="$(iso_has "$members" 'bootmgr\.efi')"
        [ "$has_boot" = "1" ] || has_boot="$(iso_has "$members" 'efi/boot/bootx64\.efi')"
        [ "$has_boot" = "1" ] || has_boot="$(iso_has "$members" 'efi/microsoft/boot/bootmgfw\.efi')"
        [ "$has_boot" = "1" ] || has_boot="$uefi_boot"
        has_wim="$(iso_has "$members" 'sources/install\.(wim|esd)')"
        if [ "$(iso_has "$members" 'sources/install\.wim')" = "1" ]; then
            wim_name="sources/install.wim"
        elif [ "$(iso_has "$members" 'sources/install\.esd')" = "1" ]; then
            wim_name="sources/install.esd"
        fi
    elif command -v isoinfo >/dev/null 2>&1; then
        isoinfo -f -i "$iso" 2>/dev/null | grep -qE 'sources/install\.(wim|esd)' && has_wim=1
        isoinfo -f -i "$iso" 2>/dev/null | grep -qiE 'bootmgr' && has_boot=1
        [ "$has_boot" = "1" ] || isoinfo -f -i "$iso" 2>/dev/null | grep -qiE 'efi[/\\]boot[/\\]bootx64\.efi' && has_boot=1
    fi

    local images_json="[]"
    if [ "$has_boot" = "1" ] && [ "$has_wim" = "1" ] && [ -n "$wim_name" ]; then
        tool="$(listing_tool)" || true
        if [ -n "$tool" ]; then
            images_json="$(wim_payload_images "$tool" "$iso" "$wim_name")"
        fi
    fi

    # valid=true ONLY when all three independent gates pass: the medium is a
    # real ISO/UDF image, a Windows boot chain exists, and an install payload
    # exists. No gate substitutes another; a missing `file` binary means the
    # format cannot be confirmed, so valid degrades to false.
    local format_ok=0
    if command -v file >/dev/null 2>&1; then
        if file -b "$iso" 2>/dev/null | grep -qi 'ISO 9660\|UDF'; then
            format_ok=1
        fi
    fi

    local valid=false
    [ "$format_ok" = "1" ] && [ "$has_boot" = "1" ] && [ "$has_wim" = "1" ] && valid=true

    # The payload lives only inside the ISO (it is never extracted): when the
    # streamed WIM header yields no images, report imageCount=0 with an
    # explicit note instead of pretending the payload was parsed.
    local payload_note=""
    if [ "$has_wim" = "1" ] && [ "$(echo "$images_json" | jq 'length' 2>/dev/null || echo 0)" = "0" ]; then
        payload_note="install payload present but WIM images not parseable from ISO (payload only inside ISO)"
    fi

    local label=""
    command -v isoinfo >/dev/null 2>&1 && label="$(isoinfo -d -i "$iso" 2>/dev/null | grep -i 'Volume id' | head -1 | cut -d: -f2- | xargs || true)"
    [ -z "$label" ] && command -v blkid >/dev/null 2>&1 && label="$(blkid -o value -s LABEL "$iso" 2>/dev/null | head -1 || true)"

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
            --arg payloadNote "$payload_note" \
            '{
                valid: $valid,
                path: $path,
                sha256: $sha256,
                arch: $arch,
                uefiBoot: $uefi,
                sizeMb: ($sizeMb|tonumber),
                label: $label,
                imageCount: ($images|length),
                images: $images,
                payloadNote: $payloadNote
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
        if [ "$has_wim" = "1" ] && [ "$(echo "$images_json" | jq 'length' 2>/dev/null || echo 0)" = "0" ]; then
            pz_warn "install payload present but WIM images not parseable from ISO (payload only inside ISO)"
        fi
        if [ "$valid" = false ]; then
            pz_error "ISO validation failed: not a valid Windows installation image"
        fi
    fi
}

case "${1:-inspect}" in
    inspect) shift; media_inspect "$@" ;;
    *) echo "usage: media-inspect inspect --iso <windows.iso> [--json]"; exit 1 ;;
esac
