#!/usr/bin/env bash
# nsz.sh - safe, atomic NSZ to NSP conversion workflow
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
shift || true

NSZ_VERSION="${PZ_NSZ_VERSION:-4.6.1}"
NSZ_SPEC="nsz==$NSZ_VERSION"
NSZ_OUTPUT_DIR="${PZ_NSZ_OUTPUT_DIR:-$PZ_EMULATION_ROOT/roms/switch/nsp}"
NSZ_MANIFEST_DIR="${PZ_NSZ_MANIFEST_DIR:-$PZ_EMULATION_ROOT/metadata/switch/nsz-conversions}"
NSZ_STAGING_ROOT="${PZ_NSZ_STAGING_ROOT:-$NSZ_OUTPUT_DIR/.phasezero-staging/nsz-to-nsp}"
NSZ_VENV="${PZ_NSZ_VENV:-${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/tools/nsz}"
NSZ_RESERVE_BYTES="${PZ_NSZ_RESERVE_BYTES:-5368709120}"
NSZ_EXPANSION_RATIO="${PZ_NSZ_EXPANSION_RATIO:-4}"
NSZ_THREADS="${PZ_NSZ_THREADS:-1}"
NSZ_WRAPPER="$PZ_LOCAL_BIN/phasezero-nsz"
NSZ_LOCK_FILE="$PZ_EMULATION_STATE/nsz-conversion.lock"
NSZ_QUARANTINE_DIR="${PZ_NSZ_QUARANTINE_DIR:-$PZ_EMULATION_ROOT/.phasezero/quarantine/nsz}"

SOURCE=""
OUTPUT_DIR="$NSZ_OUTPUT_DIR"
KEYS_FILE="${PZ_NSZ_KEYS:-}"
DELETE_SOURCE=0
OVERWRITE=0
JSON_OUT=0
DRY_RUN=0
YES=0
DEDUPE=0
CURRENT_STAGE=""
DUPLICATE_COUNT=0
DUPLICATE_BYTES=0
DUPLICATE_CONFLICTS=0

usage() {
    cat <<EOF
Usage:
  pz emulation nsz status [--json]
  pz emulation nsz install
  pz emulation nsz plan [source] [--output DIR] [--json]
  pz emulation nsz convert SOURCE [--output DIR] [--delete-source --yes]
  pz emulation nsz apply [source] --yes
  pz emulation nsz clean [--output DIR]

Safety:
  - local .nsz files only
  - one conversion at a time
  - staging and final output share a filesystem
  - upstream verification plus NSP PFS0 header validation
  - atomic publication; existing output preserved unless --overwrite
  - source retained by default
  - destructive cleanup requires --yes
  - apply confirms normalized duplicates by SHA-256 before deletion
  - apply moves failed sources to reversible hidden quarantine
  - sources removed only after verified output and manifest

Environment:
  PZ_NSZ_KEYS             Explicit prod.keys path
  PZ_NSZ_OUTPUT_DIR       Default output directory
  PZ_NSZ_RESERVE_BYTES    Free-space reserve (default: 5 GiB)
  PZ_NSZ_EXPANSION_RATIO  Conservative staging estimate (default: 4)
EOF
}

parse_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --output)
                [ "$#" -ge 2 ] || { pz_error "--output requires a directory"; return 1; }
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --output=*) OUTPUT_DIR="${1#*=}"; shift ;;
            --keys)
                [ "$#" -ge 2 ] || { pz_error "--keys requires a file"; return 1; }
                KEYS_FILE="$2"
                shift 2
                ;;
            --keys=*) KEYS_FILE="${1#*=}"; shift ;;
            --delete-source) DELETE_SOURCE=1; shift ;;
            --dedupe) DEDUPE=1; shift ;;
            --yes) YES=1; shift ;;
            --overwrite) OVERWRITE=1; shift ;;
            --json) JSON_OUT=1; shift ;;
            --dry-run|-n) DRY_RUN=1; shift ;;
            --help|-h) usage; exit 0 ;;
            --*) pz_error "unknown option: $1"; return 1 ;;
            *)
                [ -z "$SOURCE" ] || { pz_error "only one source path is accepted"; return 1; }
                SOURCE="$1"
                shift
                ;;
        esac
    done
}

nsz_bin() {
    if [ -n "${PZ_NSZ_BIN:-}" ] && [ -x "$PZ_NSZ_BIN" ]; then
        printf '%s\n' "$PZ_NSZ_BIN"
        return 0
    fi
    if command -v nsz >/dev/null 2>&1; then
        command -v nsz
        return 0
    fi
    if [ -x "$PZ_LOCAL_BIN/nsz" ]; then
        printf '%s\n' "$PZ_LOCAL_BIN/nsz"
        return 0
    fi
    if [ -x "$NSZ_VENV/bin/nsz" ]; then
        printf '%s\n' "$NSZ_VENV/bin/nsz"
        return 0
    fi
    return 1
}

nsz_installed_version() {
    local executable interpreter
    executable="$(nsz_bin 2>/dev/null || true)"
    [ -n "$executable" ] || return 1
    interpreter="$(head -n 1 "$executable" 2>/dev/null | sed -n 's/^#!//p')"
    if [ -x "$interpreter" ]; then
        "$interpreter" -c 'import importlib.metadata; print(importlib.metadata.version("nsz"))' 2>/dev/null
        return
    fi
    if command -v uv >/dev/null 2>&1; then
        uv tool list 2>/dev/null | awk '$1 == "nsz" {sub(/^v/, "", $2); print $2; exit}'
    fi
}

find_keys() {
    local candidate
    if [ -n "$KEYS_FILE" ]; then
        [ -s "$KEYS_FILE" ] || { pz_error "configured keys file missing or empty"; return 1; }
        realpath -e "$KEYS_FILE"
        return 0
    fi
    for candidate in \
        "$PZ_EMULATION_ROOT/firmware/switch/keys/prod.keys" \
        "$HOME/.switch/prod.keys" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/nsz/prod.keys" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/Ryujinx/keys/prod.keys" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/Ryujinx/system/prod.keys" \
        "$HOME/.var/app/org.ryujinx.Ryujinx/config/Ryujinx/system/prod.keys" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/eden/keys/prod.keys" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/citron/keys/prod.keys"; do
        if [ -s "$candidate" ]; then
            realpath -e "$candidate"
            return 0
        fi
    done
    return 1
}

file_size() {
    stat -Lc '%s' "$1"
}

available_bytes() {
    df -PB1 "$1" | awk 'NR == 2 {print $4}'
}

existing_parent() {
    local path="$1"
    while [ ! -e "$path" ]; do
        [ "$path" != "/" ] || break
        path="$(dirname "$path")"
    done
    printf '%s\n' "$path"
}

source_inventory() {
    local source="${1:-$PZ_EMULATION_ROOT/roms/switch}"
    if [ -f "$source" ]; then
        case "${source,,}" in
            *.nsz) printf '%s\0' "$source" ;;
        esac
        return 0
    fi
    [ -d "$source" ] || return 0
    find "$source" \
        -path "$NSZ_OUTPUT_DIR" -prune -o \
        -path '*/.phasezero-staging/*' -prune -o \
        -type f -iname '*.nsz' -print0
}

inventory_json() {
    local source="${1:-$PZ_EMULATION_ROOT/roms/switch}" count=0 bytes=0 max_bytes=0 file size
    while IFS= read -r -d '' file; do
        size="$(file_size "$file")"
        count=$((count + 1))
        bytes=$((bytes + size))
        [ "$size" -le "$max_bytes" ] || max_bytes="$size"
    done < <(source_inventory "$source")
    jq -n --argjson count "$count" --argjson bytes "$bytes" --argjson maxBytes "$max_bytes" \
        '{count: $count, bytes: $bytes, maxBytes: $maxBytes}'
}

valid_nsp() {
    local file="$1"
    [ -f "$file" ] || return 1
    [ "$(file_size "$file")" -gt 16 ] || return 1
    [ "$(LC_ALL=C head -c 4 "$file" 2>/dev/null || true)" = "PFS0" ]
}

safe_relative_path() {
    local root="$1" file="$2" relative
    if [ -f "$root" ]; then
        basename "$file"
        return 0
    fi
    relative="${file#"$root"/}"
    [ "$relative" != "$file" ] || { pz_error "source escaped inventory root"; return 1; }
    case "/$relative/" in
        */../*|*/./*) pz_error "unsafe relative source path"; return 1 ;;
    esac
    printf '%s\n' "$relative"
}

normalized_stem() {
    sed -E 's/[[:space:]]+\([0-9]+([.,][0-9]+)?[[:space:]]*(KB|MB|GB|TB)\)$//I' <<< "$1"
}

destination_for() {
    local source_root="$1" source="$2" relative stem dir base
    relative="$(safe_relative_path "$source_root" "$source")"
    stem="${relative%.*}"
    dir="$(dirname "$stem")"
    base="$(normalized_stem "$(basename "$stem")")"
    if [ "$dir" = "." ]; then
        printf '%s/%s.nsp\n' "$OUTPUT_DIR" "$base"
    else
        printf '%s/%s/%s.nsp\n' "$OUTPUT_DIR" "$dir" "$base"
    fi
}

scan_duplicates() {
    local source_root="$1" delete="${2:-0}" file destination keeper size keeper_size
    local digest keeper_digest manifest
    declare -A seen=()
    DUPLICATE_COUNT=0
    DUPLICATE_BYTES=0
    DUPLICATE_CONFLICTS=0

    while IFS= read -r -d '' file; do
        destination="$(destination_for "$source_root" "$file")"
        keeper="${seen[$destination]:-}"
        if [ -z "$keeper" ]; then
            seen["$destination"]="$file"
            continue
        fi
        size="$(file_size "$file")"
        keeper_size="$(file_size "$keeper")"
        if [ "$size" -ne "$keeper_size" ]; then
            DUPLICATE_CONFLICTS=$((DUPLICATE_CONFLICTS + 1))
            pz_warn "normalized-name conflict (different size): $keeper <> $file"
            continue
        fi
        digest="$(sha256sum "$file" | awk '{print $1}')"
        keeper_digest="$(sha256sum "$keeper" | awk '{print $1}')"
        if [ "$digest" != "$keeper_digest" ]; then
            DUPLICATE_CONFLICTS=$((DUPLICATE_CONFLICTS + 1))
            pz_warn "normalized-name conflict (different hash): $keeper <> $file"
            continue
        fi
        DUPLICATE_COUNT=$((DUPLICATE_COUNT + 1))
        DUPLICATE_BYTES=$((DUPLICATE_BYTES + size))
        if [ "$delete" -eq 1 ]; then
            rm -- "$file"
            sync -f "$(dirname "$file")" 2>/dev/null || sync
            install -d "$NSZ_MANIFEST_DIR"
            manifest="$NSZ_MANIFEST_DIR/duplicate-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM.json"
            jq -n \
                --arg status "duplicate-removed" \
                --arg source "$file" \
                --arg keeper "$keeper" \
                --arg destination "$destination" \
                --arg sha256 "$digest" \
                --arg removedAt "$(date -Iseconds)" \
                --argjson bytes "$size" \
                '{status: $status, source: $source, keeper: $keeper, destination: $destination, bytes: $bytes, sha256: $sha256, removedAt: $removedAt}' \
                > "$manifest"
            pz_info "confirmed duplicate removed: $file"
        fi
    done < <(source_inventory "$source_root")
}

write_manifest() {
    local path="$1" status="$2" source="$3" destination="$4" source_size="$5"
    local output_size="$6" source_hash="$7" output_hash="$8" source_removed="$9" log_path="${10}"
    local tmp="${path}.tmp.$$"
    jq -n \
        --arg schema "https://phasezero.local/schemas/nsz-conversion.json" \
        --arg status "$status" \
        --arg source "$source" \
        --arg destination "$destination" \
        --arg sourceSha256 "$source_hash" \
        --arg outputSha256 "$output_hash" \
        --arg log "$log_path" \
        --arg convertedAt "$(date -Iseconds)" \
        --arg tool "nsz" \
        --arg toolVersion "$NSZ_VERSION" \
        --argjson sourceBytes "$source_size" \
        --argjson outputBytes "$output_size" \
        --argjson sourceRemoved "$source_removed" \
        '{
            schema: $schema,
            status: $status,
            source: $source,
            destination: $destination,
            sourceBytes: $sourceBytes,
            outputBytes: $outputBytes,
            sourceSha256: $sourceSha256,
            outputSha256: $outputSha256,
            sourceRemoved: $sourceRemoved,
            tool: {name: $tool, version: $toolVersion},
            log: $log,
            convertedAt: $convertedAt
        }' > "$tmp"
    mv -f "$tmp" "$path"
}

cleanup_current_stage() {
    if [ -n "$CURRENT_STAGE" ] && [ -f "$CURRENT_STAGE/.phasezero-nsz-staging" ]; then
        rm -rf -- "$CURRENT_STAGE"
    fi
    CURRENT_STAGE=""
}

trap cleanup_current_stage EXIT INT TERM

convert_one() {
    local source_root="$1" source="$2" nsz keys relative stem destination destination_dir
    local stage stage_output runtime_config produced source_bytes output_bytes available required reserve source_sig source_sig_after
    local source_hash output_hash destination_hash manifest_name manifest_path log_path source_removed=false

    [ -f "$source" ] || { pz_error "source is not a regular file: $source"; return 1; }
    case "${source,,}" in
        *.nsz) ;;
        *) pz_error "source extension must be .nsz: $source"; return 1 ;;
    esac
    [ ! -L "$source" ] || { pz_error "symbolic-link sources are refused: $source"; return 1; }

    nsz="$(nsz_bin)" || { pz_error "nsz missing; run: pz emulation nsz install"; return 1; }
    keys="$(find_keys)" || {
        pz_error "prod.keys not found; import your own dump with: pz emulation switch import-keys PATH"
        return 1
    }

    relative="$(safe_relative_path "$source_root" "$source")"
    stem="${relative%.*}"
    destination="$(destination_for "$source_root" "$source")"
    destination_dir="$(dirname "$destination")"
    install -d "$destination_dir" "$NSZ_MANIFEST_DIR/logs"

    if [ -e "$destination" ] && [ "$OVERWRITE" -ne 1 ]; then
        if valid_nsp "$destination" && [ "$DELETE_SOURCE" -eq 0 ]; then
            pz_info "verified destination already exists; skipped: $destination"
            return 0
        fi
        if ! valid_nsp "$destination"; then
            pz_error "destination exists but is invalid; use --overwrite after review: $destination"
            return 1
        fi
    fi

    source_bytes="$(file_size "$source")"
    available="$(available_bytes "$destination_dir")"
    reserve="$NSZ_RESERVE_BYTES"
    required=$((source_bytes * NSZ_EXPANSION_RATIO + reserve))
    if [ "$available" -lt "$required" ]; then
        pz_error "insufficient free space: available=$available required=$required source=$source_bytes"
        return 1
    fi

    source_sig="$(stat -Lc '%d:%i:%s:%Y' "$source")"
    source_hash="$(sha256sum "$source" | awk '{print $1}')"
    manifest_name="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
    manifest_path="$NSZ_MANIFEST_DIR/$manifest_name.json"
    log_path="$NSZ_MANIFEST_DIR/logs/$manifest_name.log"
    stage="$(mktemp -d "$NSZ_STAGING_ROOT/.run.XXXXXX")"
    CURRENT_STAGE="$stage"
    : > "$stage/.phasezero-nsz-staging"
    stage_output="$stage/output"
    runtime_config="$stage/home"
    install -d "$stage_output"
    install -d -m 0700 "$runtime_config/.switch"
    ln -s "$keys" "$runtime_config/.switch/prod.keys"

    pz_info "converting: $source"
    if ! HOME="$runtime_config" "$nsz" -D -V --threads "$NSZ_THREADS" --output "$stage_output" "$source" > "$log_path" 2>&1; then
        tail -n 30 "$log_path" >&2 || true
        pz_error "NSZ decompression failed; source preserved"
        return 1
    fi

    produced="$stage_output/$(basename "$stem").nsp"
    if [ ! -f "$produced" ]; then
        mapfile -d '' -t produced_files < <(find "$stage_output" -maxdepth 1 -type f -iname '*.nsp' -print0)
        [ "${#produced_files[@]}" -eq 1 ] || {
            pz_error "expected exactly one staged NSP; source preserved"
            return 1
        }
        produced="${produced_files[0]}"
    fi

    valid_nsp "$produced" || { pz_error "staged output lacks valid NSP PFS0 header; source preserved"; return 1; }
    if ! HOME="$runtime_config" "$nsz" -V "$produced" >> "$log_path" 2>&1; then
        tail -n 30 "$log_path" >&2 || true
        pz_error "upstream NSP verification failed; source preserved"
        return 1
    fi

    output_bytes="$(file_size "$produced")"
    output_hash="$(sha256sum "$produced" | awk '{print $1}')"
    source_sig_after="$(stat -Lc '%d:%i:%s:%Y' "$source")"
    [ "$source_sig" = "$source_sig_after" ] || {
        pz_error "source changed during conversion; output not published"
        return 1
    }

    if [ -e "$destination" ]; then
        [ -f "$destination" ] || { pz_error "destination is not a regular file"; return 1; }
        if [ "$OVERWRITE" -ne 1 ]; then
            destination_hash="$(sha256sum "$destination" | awk '{print $1}')"
            [ "$destination_hash" = "$output_hash" ] || {
                pz_error "destination differs from verified staged output; both preserved"
                return 1
            }
            rm -- "$produced"
        else
            mv -f "$produced" "$destination"
        fi
    else
        mv "$produced" "$destination"
    fi
    sync -f "$destination" 2>/dev/null || sync
    write_manifest "$manifest_path" verified "$source" "$destination" "$source_bytes" "$output_bytes" "$source_hash" "$output_hash" false "$log_path"

    if [ "$DELETE_SOURCE" -eq 1 ]; then
        source_sig_after="$(stat -Lc '%d:%i:%s:%Y' "$source")"
        [ "$source_sig" = "$source_sig_after" ] || {
            pz_error "source changed before cleanup; verified output kept, source preserved"
            return 1
        }
        rm -- "$source"
        sync -f "$(dirname "$source")" 2>/dev/null || sync
        source_removed=true
        write_manifest "$manifest_path" completed "$source" "$destination" "$source_bytes" "$output_bytes" "$source_hash" "$output_hash" true "$log_path"
    fi

    cleanup_current_stage
    pz_info "conversion complete: $destination sourceRemoved=$source_removed"
}

cmd_status() {
    local tool="" keys="" inventory staging_bytes=0 version=""
    tool="$(nsz_bin 2>/dev/null || true)"
    keys="$(find_keys 2>/dev/null || true)"
    inventory="$(inventory_json)"
    if [ -d "$NSZ_STAGING_ROOT" ]; then
        staging_bytes="$(du -sb "$NSZ_STAGING_ROOT" 2>/dev/null | awk '{print $1}' || echo 0)"
    fi
    if [ -n "$tool" ]; then
        version="$NSZ_VERSION"
    fi
    jq -n \
        --arg tool "$tool" \
        --arg version "$version" \
        --arg outputDir "$OUTPUT_DIR" \
        --arg manifestDir "$NSZ_MANIFEST_DIR" \
        --arg wrapper "$NSZ_WRAPPER" \
        --argjson inventory "$inventory" \
        --argjson keyAvailable "$([ -n "$keys" ] && echo true || echo false)" \
        --argjson wrapperInstalled "$([ -x "$NSZ_WRAPPER" ] && echo true || echo false)" \
        --argjson stagingBytes "$staging_bytes" \
        --argjson freeBytes "$(available_bytes "$(existing_parent "$OUTPUT_DIR")")" \
        '{
            installed: ($tool != ""),
            executable: $tool,
            version: $version,
            keyAvailable: $keyAvailable,
            source: $inventory,
            outputDir: $outputDir,
            manifestDir: $manifestDir,
            wrapper: {path: $wrapper, installed: $wrapperInstalled},
            stagingBytes: $stagingBytes,
            freeBytes: $freeBytes,
            policy: "local-user-owned-content-only"
        }'
}

cmd_plan() {
    local inventory source_path keys="" free base_required
    source_path="${SOURCE:-$PZ_EMULATION_ROOT/roms/switch}"
    if [ -n "$SOURCE" ] && [ ! -e "$source_path" ]; then
        pz_error "source not found: $source_path"
        return 1
    fi
    inventory="$(inventory_json "$source_path")"
    keys="$(find_keys 2>/dev/null || true)"
    free="$(available_bytes "$(existing_parent "$OUTPUT_DIR")")"
    base_required="$(jq -r --argjson ratio "$NSZ_EXPANSION_RATIO" --argjson reserve "$NSZ_RESERVE_BYTES" '.maxBytes * $ratio + $reserve' <<< "$inventory")"
    if [ -e "$source_path" ]; then
        scan_duplicates "$(realpath -e "$source_path")" 0
    fi
    jq -n \
        --arg source "$source_path" \
        --arg outputDir "$OUTPUT_DIR" \
        --argjson inventory "$inventory" \
        --argjson keyAvailable "$([ -n "$keys" ] && echo true || echo false)" \
        --argjson deleteSource "$([ "$DELETE_SOURCE" -eq 1 ] && echo true || echo false)" \
        --argjson freeBytes "$free" \
        --argjson conservativePeakBytes "$base_required" \
        --argjson confirmedDuplicates "$DUPLICATE_COUNT" \
        --argjson duplicateBytes "$DUPLICATE_BYTES" \
        --argjson duplicateConflicts "$DUPLICATE_CONFLICTS" \
        '{
            source: $source,
            outputDir: $outputDir,
            files: $inventory.count,
            sourceBytes: $inventory.bytes,
            freeBytes: $freeBytes,
            conservativePeakBytes: $conservativePeakBytes,
            confirmedDuplicates: $confirmedDuplicates,
            duplicateBytes: $duplicateBytes,
            duplicateConflicts: $duplicateConflicts,
            keyAvailable: $keyAvailable,
            deleteSourceAfterVerification: $deleteSource,
            execution: "sequential",
            sourcePolicy: "preserve-by-default"
        }'
}

cmd_convert() {
    local source_root file failure_manifest quarantine_path="" found=0 failures=0
    [ -n "$SOURCE" ] || { pz_error "usage: pz emulation nsz convert SOURCE"; return 1; }
    if { [ "$DELETE_SOURCE" -eq 1 ] || [ "$DEDUPE" -eq 1 ]; } && [ "$YES" -ne 1 ]; then
        pz_error "destructive cleanup requires --yes"
        return 1
    fi
    pz_emulation_require_local_source "$SOURCE"
    [ -f "$SOURCE" ] || [ -d "$SOURCE" ] || { pz_error "source must be a file or directory"; return 1; }
    if [ "$DELETE_SOURCE" -eq 1 ] || [ "$DEDUPE" -eq 1 ]; then
        pz_emulation_abort_if_frontend_running
    fi
    install -d "$PZ_EMULATION_STATE"
    exec 9>"$NSZ_LOCK_FILE"
    flock -n 9 || { pz_error "another NSZ conversion is active"; return 1; }
    install -d "$OUTPUT_DIR" "$NSZ_STAGING_ROOT" "$NSZ_MANIFEST_DIR/logs"
    if [ "$DRY_RUN" -eq 1 ]; then
        cmd_plan
        return 0
    fi
    source_root="$(realpath -e "$SOURCE")"
    if [ "$DEDUPE" -eq 1 ]; then
        scan_duplicates "$source_root" 1
        [ "$DUPLICATE_CONFLICTS" -eq 0 ] || {
            pz_error "normalized-name conflicts found; conflicting sources preserved"
            return 1
        }
    fi
    while IFS= read -r -d '' file; do
        found=1
        if ! convert_one "$source_root" "$file"; then
            failures=$((failures + 1))
            quarantine_path=""
            if [ "$ACTION" = "apply" ] && [ -f "$file" ]; then
                install -d "$NSZ_QUARANTINE_DIR"
                quarantine_path="$NSZ_QUARANTINE_DIR/$(basename "$file")"
                if [ -e "$quarantine_path" ]; then
                    quarantine_path="$NSZ_QUARANTINE_DIR/$(sha256sum "$file" | cut -c1-12)-$(basename "$file")"
                fi
                mv -- "$file" "$quarantine_path"
                sync -f "$NSZ_QUARANTINE_DIR" 2>/dev/null || sync
                pz_warn "failed source quarantined: $quarantine_path"
            fi
            failure_manifest="$NSZ_MANIFEST_DIR/failed-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM.json"
            jq -n \
                --arg status "failed-verification" \
                --arg source "$file" \
                --arg quarantine "$quarantine_path" \
                --arg failedAt "$(date -Iseconds)" \
                --arg reason "NSZ decompression or NSP verification failed; source preserved" \
                '{status: $status, source: $source, quarantine: (if $quarantine == "" then null else $quarantine end), sourcePreserved: true, reason: $reason, failedAt: $failedAt}' \
                > "$failure_manifest"
            cleanup_current_stage
            pz_warn "conversion failed; source preserved, continuing: $file"
        fi
    done < <(source_inventory "$source_root")
    [ "$found" -eq 1 ] || { pz_error "no .nsz files found"; return 1; }
    [ "$failures" -eq 0 ]
}

cmd_clean() {
    local dir removed=0
    [ -d "$NSZ_STAGING_ROOT" ] || { pz_info "no NSZ staging data"; return 0; }
    install -d "$PZ_EMULATION_STATE"
    exec 9>"$NSZ_LOCK_FILE"
    flock -n 9 || { pz_error "another NSZ conversion is active"; return 1; }
    while IFS= read -r -d '' dir; do
        if [ -f "$dir/.phasezero-nsz-staging" ]; then
            rm -rf -- "$dir"
            removed=$((removed + 1))
        fi
    done < <(find "$NSZ_STAGING_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)
    find "$NSZ_STAGING_ROOT" -depth -type d -empty -delete 2>/dev/null || true
    pz_info "stale NSZ staging directories removed: $removed"
}

cmd_install() {
    local quoted_pz installed_version
    installed_version="$(nsz_installed_version 2>/dev/null || true)"
    if [ "$installed_version" = "$NSZ_VERSION" ]; then
        pz_info "NSZ already installed: $installed_version"
    elif command -v uv >/dev/null 2>&1; then
        uv tool install --force "$NSZ_SPEC"
    else
        command -v python3 >/dev/null 2>&1 || { pz_error "uv/python3 missing"; return 1; }
        python3 -m venv "$NSZ_VENV"
        "$NSZ_VENV/bin/python" -m pip install --upgrade "$NSZ_SPEC"
    fi
    nsz_bin >/dev/null || { pz_error "NSZ installation completed but executable is unavailable"; return 1; }
    pz_emulation_ensure_layout
    install -d "$PZ_LOCAL_BIN"
    quoted_pz="$(printf '%q' "$PZ_ROOT/linux/pz")"
    pz_emulation_write_file "$NSZ_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec $quoted_pz emulation nsz "\$@"
EOF
    pz_info "NSZ converter installed: $NSZ_WRAPPER"
    cmd_status
}

parse_options "$@"

case "$ACTION" in
    status) cmd_status ;;
    install|setup) cmd_install ;;
    plan|dry-run) cmd_plan ;;
    convert|decompress) cmd_convert ;;
    apply)
        SOURCE="${SOURCE:-$PZ_EMULATION_ROOT/roms/switch}"
        DELETE_SOURCE=1
        DEDUPE=1
        [ "$YES" -eq 1 ] || { pz_error "apply requires --yes"; exit 1; }
        cmd_convert
        ;;
    clean) cmd_clean ;;
    help|--help|-h) usage ;;
    *) pz_error "usage: nsz.sh (status|install|plan|convert|apply|clean)"; exit 1 ;;
esac
