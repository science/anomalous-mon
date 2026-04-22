#!/usr/bin/env bash
# disk-monitor.sh — Disk-space monitoring with WARN/CRITICAL severities
#
# Sourced by anomalous-mon. Provides:
#   disk_check ALERT_STATE_FILE WARN_PCT CRIT_PCT MIN_FREE_GB WARN_COOLDOWN CRIT_COOLDOWN
#   disk_status ALERT_STATE_FILE WARN_PCT CRIT_PCT MIN_FREE_GB
#
# Severity rules (per mount, per tick):
#   - CRITICAL: pcent >= CRIT_PCT (unconditional on % — nags on short cooldown)
#   - WARN:     pcent >= WARN_PCT AND avail < MIN_FREE_GB (long cooldown)
# A CRITICAL for a mount in this tick suppresses WARN for the same mount
# in the same tick.
#
# Per-mount overrides via the associative array DISK_THRESHOLD_OVERRIDES.
# Value format "warn:crit:min_free_gb" — any field may be "-" to inherit
# the default. Example: DISK_THRESHOLD_OVERRIDES=([/boot]="90:97:0.1").
#
# Alert-state file format (one entry per line):
#   disk:<mount>:<severity>:<epoch>
# Parsed the same way as journal-monitor's alert file (key is everything up
# to the last colon; timestamp is the tail).
#
# For testing, set _DISK_SAMPLE_CMD to override the sampler with a function
# that emits lines of "<mount> <fstype> <pcent> <avail_kb>".

# Fstypes to exclude at the sampler level and as a belt-and-suspenders filter
# inside disk_check (in case a future sample source leaks one through).
_DISK_EXCLUDE_FSTYPES="tmpfs devtmpfs squashfs overlay efivarfs fuse.portal fuse.rclone fuse.snapfuse autofs nfs nfs4 cifs smbfs virtiofs"

# Default sampler: df, POSIX output, excluding pseudo/virtual/network fstypes.
# Emits: "<target> <fstype> <pcent_no_%> <avail_kb>" one per real filesystem.
_disk_sample_cmd() {
    df --output=target,fstype,pcent,avail \
        -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs \
        -x fuse.portal -x fuse.rclone -x fuse.snapfuse \
        -x autofs -x nfs -x nfs4 -x cifs -x smbfs -x virtiofs \
        2>/dev/null \
      | awk 'NR>1 { gsub(/%/,"",$3); print $1, $2, $3, $4 }'
}

# Load disk alert state into _DISK_ALERTED (key → epoch).
_load_disk_alerts() {
    local alert_file="$1"
    declare -gA _DISK_ALERTED
    _DISK_ALERTED=()

    [[ -f "$alert_file" ]] || return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local key="${line%:*}"
        local ts="${line##*:}"
        [[ -z "$key" || -z "$ts" ]] && continue
        _DISK_ALERTED[$key]="$ts"
    done < "$alert_file" 2>/dev/null
}

# Save _DISK_ALERTED back to file, pruning entries past the cooldown window.
_save_disk_alerts() {
    local alert_file="$1"
    local cooldown="$2"
    local now
    now="$(date +%s)"
    local tmp="${alert_file}.tmp"

    {
        for key in "${!_DISK_ALERTED[@]}"; do
            local ts="${_DISK_ALERTED[$key]}"
            if (( now - ts < cooldown )); then
                echo "${key}:${ts}"
            fi
        done
    } > "$tmp"

    mv "$tmp" "$alert_file"
}

# Returns 0 (true) if alert is still within cooldown, 1 otherwise.
_disk_alert_suppressed() {
    local key="$1"
    local cooldown="$2"

    local prev_ts="${_DISK_ALERTED[$key]:-}"
    [[ -z "$prev_ts" ]] && return 1

    local now
    now="$(date +%s)"
    (( now - prev_ts < cooldown ))
}

_disk_alert_record() {
    local key="$1"
    _DISK_ALERTED[$key]="$(date +%s)"
}

# Return 0 if the fstype is in our exclusion list.
_disk_fstype_excluded() {
    local fstype="$1"
    local f
    for f in $_DISK_EXCLUDE_FSTYPES; do
        [[ "$fstype" == "$f" ]] && return 0
    done
    return 1
}

# Resolve per-mount thresholds from DISK_THRESHOLD_OVERRIDES (if present),
# falling back to the four defaults. Sets three globals consumed by
# disk_check immediately afterward.
_disk_resolve_thresholds() {
    local mount="$1" def_warn="$2" def_crit="$3" def_minfree="$4"

    _DISK_MOUNT_WARN="$def_warn"
    _DISK_MOUNT_CRIT="$def_crit"
    _DISK_MOUNT_MINFREE="$def_minfree"

    if declare -p DISK_THRESHOLD_OVERRIDES &>/dev/null; then
        local override="${DISK_THRESHOLD_OVERRIDES[$mount]+${DISK_THRESHOLD_OVERRIDES[$mount]}}"
        if [[ -n "$override" ]]; then
            local w="${override%%:*}"
            local rest="${override#*:}"
            local c="${rest%%:*}"
            local m="${rest#*:}"
            [[ "$w" != "-" && -n "$w" ]] && _DISK_MOUNT_WARN="$w"
            [[ "$c" != "-" && -n "$c" ]] && _DISK_MOUNT_CRIT="$c"
            [[ "$m" != "-" && -n "$m" ]] && _DISK_MOUNT_MINFREE="$m"
        fi
    fi
}

_disk_kb_to_gb() {
    awk -v kb="$1" 'BEGIN { printf "%.2f", kb/1024/1024 }'
}

# Float less-than: returns 0 (true) if $1 < $2.
_disk_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

# Main check. See file header for the severity rules and arg shape.
disk_check() {
    local alert_file="$1"
    local def_warn="$2"
    local def_crit="$3"
    local def_minfree="$4"
    local warn_cooldown="${5:-1800}"
    local crit_cooldown="${6:-300}"

    _load_disk_alerts "$alert_file"

    local sample
    sample="$(${_DISK_SAMPLE_CMD:-_disk_sample_cmd})"

    local prune_cd=$warn_cooldown
    (( crit_cooldown > prune_cd )) && prune_cd=$crit_cooldown

    if [[ -z "$sample" ]]; then
        _save_disk_alerts "$alert_file" "$prune_cd"
        return 0
    fi

    # Mounts that fired CRITICAL this tick — suppresses their WARN pass.
    local -A _crit_fired_mounts=()

    # Pass 1: CRITICAL
    while read -r mount fstype pcent avail; do
        [[ -z "$mount" || -z "$fstype" || -z "$pcent" || -z "$avail" ]] && continue
        [[ "$pcent" =~ ^[0-9]+$ ]] || continue
        [[ "$avail" =~ ^[0-9]+$ ]] || continue
        _disk_fstype_excluded "$fstype" && continue

        _disk_resolve_thresholds "$mount" "$def_warn" "$def_crit" "$def_minfree"

        if (( pcent >= _DISK_MOUNT_CRIT )); then
            _crit_fired_mounts[$mount]=1
            local key="disk:${mount}:critical"
            if ! _disk_alert_suppressed "$key" "$crit_cooldown"; then
                local avail_gb
                avail_gb="$(_disk_kb_to_gb "$avail")"
                local msg="CRITICAL: ${mount} ${fstype} at ${pcent}% (${avail_gb} GB free)"
                send_alert "disk" "$key" "$msg" "disk:${mount}"
                _disk_alert_record "$key"
            fi
        fi
    done <<< "$sample"

    # Pass 2: WARN (skipping mounts that fired CRITICAL this tick)
    while read -r mount fstype pcent avail; do
        [[ -z "$mount" || -z "$fstype" || -z "$pcent" || -z "$avail" ]] && continue
        [[ "$pcent" =~ ^[0-9]+$ ]] || continue
        [[ "$avail" =~ ^[0-9]+$ ]] || continue
        _disk_fstype_excluded "$fstype" && continue
        [[ -n "${_crit_fired_mounts[$mount]:-}" ]] && continue

        _disk_resolve_thresholds "$mount" "$def_warn" "$def_crit" "$def_minfree"

        if (( pcent >= _DISK_MOUNT_WARN )); then
            local avail_gb
            avail_gb="$(_disk_kb_to_gb "$avail")"
            if _disk_lt "$avail_gb" "$_DISK_MOUNT_MINFREE"; then
                local key="disk:${mount}:warn"
                if ! _disk_alert_suppressed "$key" "$warn_cooldown"; then
                    local msg="WARN: ${mount} ${fstype} at ${pcent}% (${avail_gb} GB free)"
                    send_alert "disk" "$key" "$msg" "disk:${mount}"
                    _disk_alert_record "$key"
                fi
            fi
        fi
    done <<< "$sample"

    _save_disk_alerts "$alert_file" "$prune_cd"
    return 0
}

# Print one line per monitored mount: "<mount> (<fstype>): <pct>% used, <gb> GB free [state]".
disk_status() {
    local alert_file="$1"
    local def_warn="${2:-80}"
    local def_crit="${3:-92}"
    local def_minfree="${4:-10}"

    echo "=== Disk State ==="
    echo ""

    _load_disk_alerts "$alert_file"

    local sample
    sample="$(${_DISK_SAMPLE_CMD:-_disk_sample_cmd})"
    if [[ -z "$sample" ]]; then
        echo "No filesystems to monitor"
        return 0
    fi

    while read -r mount fstype pcent avail; do
        [[ -z "$mount" || -z "$fstype" || -z "$pcent" || -z "$avail" ]] && continue
        [[ "$pcent" =~ ^[0-9]+$ ]] || continue
        [[ "$avail" =~ ^[0-9]+$ ]] || continue
        _disk_fstype_excluded "$fstype" && continue

        local avail_gb
        avail_gb="$(_disk_kb_to_gb "$avail")"
        local state="ok"
        if [[ -n "${_DISK_ALERTED[disk:${mount}:critical]:-}" ]]; then
            state="CRITICAL"
        elif [[ -n "${_DISK_ALERTED[disk:${mount}:warn]:-}" ]]; then
            state="WARN"
        fi
        echo "  ${mount} (${fstype}): ${pcent}% used, ${avail_gb} GB free [${state}]"
    done <<< "$sample"
}
