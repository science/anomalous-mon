#!/usr/bin/env bash
# stale-files-monitor.sh — Weekly scan for large files that haven't been
# modified in a long time. Surfaces them as candidates for review/deletion.
#
# Public API:
#   stale_files_check  REPORT_FILE LAST_SCAN_FILE ACK_FILE
#   stale_files_scan   REPORT_FILE LAST_SCAN_FILE
#   stale_files_status REPORT_FILE LAST_SCAN_FILE ACK_FILE
#   stale_files_report REPORT_FILE
#   stale_files_ack    ACK_FILE PATH
#   stale_files_unack  ACK_FILE PATH
#
# Test seams (override these functions to mock):
#   _STALE_FILES_SCAN_CMD  — emits "size_bytes<TAB>mtime_epoch<TAB>path" per line
#   _STALE_FINDMNT_CMD     — emits "target<SPACE>fstype" per line
#
# State files (caller-controlled paths):
#   REPORT_FILE      — human-readable report (regenerated each scan)
#   LAST_SCAN_FILE   — single epoch timestamp
#   ACK_FILE         — "<epoch>\t<path>" per line; user-acked paths suppressed
#                       until ACK_TTL days have passed.

# Default sampler: find under each scan root. Emits one line per match:
#   "size_bytes\tmtime_epoch\tpath"
# Roots, size threshold, age threshold, and fstype exclude list come from the
# config-loaded variables in the caller's environment.
_stale_files_scan_cmd() {
    local root
    for root in "${STALE_FILES_ROOTS[@]:-}"; do
        [[ -z "$root" || ! -d "$root" ]] && continue

        local prune_expr
        _stale_build_prune_clauses "$root" prune_expr

        local find_args=( "$root" -xdev )
        if [[ -n "$prune_expr" ]]; then
            # Build the prune group using eval — the prune_expr is constructed
            # from controlled mountpoint strings + literal-prefix ignores.
            eval "find_args+=( \\( $prune_expr -prune \\) -o )"
        fi
        find_args+=(
            -type f
            -size "+${STALE_FILES_MIN_SIZE_GB}G"
            -mtime "+${STALE_FILES_AGE_DAYS}"
            -printf '%s\t%T@\t%p\n'
        )

        LC_ALL=C nice -n 19 ionice -c 3 find "${find_args[@]}" 2>/dev/null
    done
}

# Return mountpoints under $1 whose fstype matches STALE_FILES_FSTYPE_EXCLUDE.
_stale_excluded_mounts_under() {
    local root="$1"
    local fstype_re="^(${STALE_FILES_FSTYPE_EXCLUDE:-})$"
    [[ "$fstype_re" == "^()\$" ]] && return 0

    local target fstype
    ${_STALE_FINDMNT_CMD:-_stale_findmnt_cmd} 2>/dev/null | while read -r target fstype; do
        [[ -z "$target" || -z "$fstype" ]] && continue
        [[ "$target" == "$root" || "$target" == "$root"/* ]] || continue
        [[ "$fstype" =~ $fstype_re ]] && printf '%s\n' "$target"
    done
}

_stale_findmnt_cmd() {
    findmnt --raw -lo TARGET,FSTYPE 2>/dev/null
}

# Build -path clauses for the find prune group. Combines FUSE/network mount
# exclusions (auto) with literal-prefix ignore entries from STALE_FILES_IGNORE.
# Sets the nameref'd variable to a string suitable for `eval find_args+=( \( $expr -prune \) -o )`.
_stale_build_prune_clauses() {
    local root="$1"
    local -n _out="$2"
    _out=""

    local clauses=()
    local m
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        clauses+=( "$m" )
    done < <(_stale_excluded_mounts_under "$root")

    # Fold literal-prefix ignore entries (no glob metachars) into the prune list
    # so find skips entire subtrees instead of descending and post-filtering.
    local pat
    for pat in "${STALE_FILES_IGNORE[@]:-}"; do
        [[ -z "$pat" ]] && continue
        # Skip if contains glob metachars
        [[ "$pat" == *'*'* || "$pat" == *'?'* || "$pat" == *'['* ]] && continue
        # Only include if it's actually under this root
        [[ "$pat" == "$root" || "$pat" == "$root"/* ]] || continue
        clauses+=( "$pat" )
    done

    if (( ${#clauses[@]} > 0 )); then
        local first=1
        for m in "${clauses[@]}"; do
            if (( first )); then
                _out="-path $(printf '%q' "$m")"
                first=0
            else
                _out+=" -o -path $(printf '%q' "$m")"
            fi
        done
    fi
}

# True if $path matches any glob entry in STALE_FILES_IGNORE.
# Literal-prefix entries are usually pruned at the find layer; this is the
# belt-and-suspenders post-filter for glob entries and for cases where the
# sampler is mocked and prune isn't applied.
_stale_path_ignored() {
    local path="$1"
    local pat
    for pat in "${STALE_FILES_IGNORE[@]:-}"; do
        [[ -z "$pat" ]] && continue
        [[ "$path" == $pat ]] && return 0
        [[ "$path" == $pat/* ]] && return 0
    done
    return 1
}

# Load ack file → _STALE_ACKS[path]=epoch. Skip entries past TTL.
_stale_load_acks() {
    local ack_file="$1"
    local now="$2"
    local ttl_days="$3"
    declare -gA _STALE_ACKS
    _STALE_ACKS=()
    [[ -f "$ack_file" ]] || return 0
    local ttl_secs=$(( ttl_days * 86400 ))
    local ts path
    while IFS=$'\t' read -r ts path; do
        [[ -z "$ts" || -z "$path" ]] && continue
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        (( ts + ttl_secs < now )) && continue
        _STALE_ACKS[$path]="$ts"
    done < "$ack_file" 2>/dev/null
}

_stale_save_acks() {
    local ack_file="$1"
    local tmp="${ack_file}.tmp"
    mkdir -p "$(dirname "$ack_file")" 2>/dev/null || true
    {
        local p
        for p in "${!_STALE_ACKS[@]}"; do
            printf '%s\t%s\n' "${_STALE_ACKS[$p]}" "$p"
        done
    } > "$tmp"
    mv "$tmp" "$ack_file"
}

_stale_path_acked() {
    local path="$1"
    [[ -n "${_STALE_ACKS[$path]:-}" ]]
}

# Human-readable byte size (binary units).
_stale_bytes_human() {
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", u, " ")
        i=1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

# Human-readable age in days from an mtime epoch (fractional accepted).
_stale_age_human() {
    local mtime="$1"
    local now="$2"
    awk -v m="$mtime" -v n="$now" 'BEGIN {
        d = int((n - m) / 86400)
        printf "%dd", d
    }'
}

# Public: run the scan + filter + alert pipeline.
# Args:
#   $1 REPORT_FILE     — where to write the human report
#   $2 LAST_SCAN_FILE  — where to write the scan-completed timestamp
#   $3 ACK_FILE        — persistent ack list
stale_files_check() {
    local report_file="$1"
    local last_scan_file="$2"
    local ack_file="$3"

    local now
    now="$(date +%s)"

    _stale_load_acks "$ack_file" "$now" "${STALE_FILES_ACK_TTL:-90}"

    local sample
    sample="$(${_STALE_FILES_SCAN_CMD:-_stale_files_scan_cmd} || true)"

    # Always update last-scan timestamp, even if nothing found.
    mkdir -p "$(dirname "$last_scan_file")" 2>/dev/null || true
    printf '%s\n' "$now" > "${last_scan_file}.tmp"
    mv "${last_scan_file}.tmp" "$last_scan_file"

    # Save ack file (prunes expired entries in one shot)
    _stale_save_acks "$ack_file"

    if [[ -z "$sample" ]]; then
        # Empty scan: write an empty-but-headered report and return without alerting.
        _stale_write_report "$report_file" "$now" ""
        return 0
    fi

    # Filter sample lines through ignore + ack lists, accumulate totals.
    local filtered=""
    local n=0
    local total_bytes=0
    local size mtime path
    while IFS=$'\t' read -r size mtime path; do
        [[ -z "$path" ]] && continue
        [[ "$size" =~ ^[0-9]+$ ]] || continue
        _stale_path_ignored "$path" && continue
        _stale_path_acked "$path" && continue
        filtered+="${size}	${mtime}	${path}"$'\n'
        n=$((n + 1))
        total_bytes=$(( total_bytes + size ))
    done <<< "$sample"

    _stale_write_report "$report_file" "$now" "$filtered"

    if (( n == 0 )); then
        return 0
    fi

    local total_human
    total_human="$(_stale_bytes_human "$total_bytes")"
    local msg
    msg="Found ${n} large stale files (${total_human} total). Click 'Open report' or run 'anomalous-mon --stale-report'."

    if declare -f send_alert_action >/dev/null; then
        send_alert_action "stale-files" "stale-files:summary" "$msg" \
            "Open report" "xdg-open ${report_file@Q}"
    else
        send_alert "stale-files" "stale-files:summary" "$msg"
    fi
}

# Internal: write the human-readable report file.
# Sorts entries by size desc, caps at STALE_FILES_MAX_REPORT_ENTRIES.
_stale_write_report() {
    local report_file="$1"
    local now="$2"
    local entries="$3"   # may be empty

    local tmp="${report_file}.tmp"
    mkdir -p "$(dirname "$report_file")" 2>/dev/null || true

    local n_entries=0
    local n_acks="${#_STALE_ACKS[@]}"
    local total_bytes=0
    local sorted=""
    if [[ -n "$entries" ]]; then
        sorted="$(printf '%s' "$entries" | sort -t$'\t' -k1,1nr)"
        local size _rest
        while IFS=$'\t' read -r size _rest; do
            [[ "$size" =~ ^[0-9]+$ ]] || continue
            n_entries=$((n_entries + 1))
            total_bytes=$(( total_bytes + size ))
        done <<< "$sorted"
    fi

    {
        local ts_human
        ts_human="$(date -u -d "@$now" '+%Y-%m-%d %H:%M UTC')"
        echo "anomalous-mon stale-files report — ${ts_human}"
        echo "Scan: ${n_entries} files ≥ ${STALE_FILES_MIN_SIZE_GB:-1} GiB, mtime > ${STALE_FILES_AGE_DAYS:-180} days"
        echo "Roots: ${STALE_FILES_ROOTS[*]:-}"
        echo "Acked: ${n_acks} paths (TTL ${STALE_FILES_ACK_TTL:-90}d)"
        echo ""
        if (( n_entries == 0 )); then
            echo "No stale files found."
        else
            printf '  %-10s  %-6s  %s\n' "SIZE" "AGE" "PATH"
            local max="${STALE_FILES_MAX_REPORT_ENTRIES:-50}"
            local emitted=0
            local size mtime path
            while IFS=$'\t' read -r size mtime path; do
                [[ -z "$path" ]] && continue
                (( emitted >= max )) && break
                local human age
                human="$(_stale_bytes_human "$size")"
                age="$(_stale_age_human "$mtime" "$now")"
                printf '  %-10s  %-6s  %s\n' "$human" "$age" "$path"
                emitted=$((emitted + 1))
            done <<< "$sorted"
            if (( n_entries > max )); then
                echo ""
                echo "(showing top ${max} of ${n_entries}; raise STALE_FILES_MAX_REPORT_ENTRIES to see more)"
            fi
        fi
        echo ""
        echo "To silence an entry:  anomalous-mon --ack <path>"
    } > "$tmp"
    mv "$tmp" "$report_file"
}

stale_files_scan() {
    local report_file="$1"
    local last_scan_file="$2"

    local now
    now="$(date +%s)"
    local sample
    sample="$(${_STALE_FILES_SCAN_CMD:-_stale_files_scan_cmd} || true)"

    printf '%s\n' "$now" > "${last_scan_file}.tmp"
    mv "${last_scan_file}.tmp" "$last_scan_file"
    _stale_write_report "$report_file" "$now" "$sample"
}

stale_files_report() {
    local report_file="$1"
    if [[ -f "$report_file" ]]; then
        cat "$report_file"
    else
        echo "No stale-files report yet. Run: anomalous-mon --stale-scan"
    fi
}

stale_files_ack() {
    local ack_file="$1"
    local path="$2"
    local now
    now="$(date +%s)"
    _stale_load_acks "$ack_file" "$now" "${STALE_FILES_ACK_TTL:-90}"
    _STALE_ACKS[$path]="$now"
    _stale_save_acks "$ack_file"
}

stale_files_unack() {
    local ack_file="$1"
    local path="$2"
    local now
    now="$(date +%s)"
    _stale_load_acks "$ack_file" "$now" "${STALE_FILES_ACK_TTL:-90}"
    unset '_STALE_ACKS[$path]'
    _stale_save_acks "$ack_file"
}

stale_files_status() {
    local report_file="$1"
    local last_scan_file="$2"
    local ack_file="$3"

    echo "=== Stale Files State ==="
    echo ""

    if [[ -f "$last_scan_file" ]]; then
        local ts
        ts="$(cat "$last_scan_file" 2>/dev/null)"
        if [[ "$ts" =~ ^[0-9]+$ ]]; then
            local human
            human="$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")"
            echo "  Last scan: ${human}"
        else
            echo "  Last scan: never"
        fi
    else
        echo "  Last scan: never"
    fi

    local n_entries=0
    if [[ -f "$report_file" ]]; then
        # Count entries by looking for the size column pattern lines.
        n_entries=$(grep -cE '^  [0-9]+\.[0-9]+ [KMGT]?i?B  ' "$report_file" 2>/dev/null || echo 0)
    fi
    echo "  Current report entries: ${n_entries}"

    local n_acks=0
    if [[ -f "$ack_file" ]]; then
        n_acks=$(grep -cE '^[0-9]+	' "$ack_file" 2>/dev/null || echo 0)
    fi
    echo "  Active acks: ${n_acks}"
}
