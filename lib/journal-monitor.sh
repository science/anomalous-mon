#!/usr/bin/env bash
# journal-monitor.sh — Journal event detection for OOM kills and memory limit hits
#
# Sourced by anomalous-mon. Provides:
#   journal_check CURSOR_FILE LOOKBACK ALERT_STATE_FILE COOLDOWN_SECS
#
# Checks journalctl for OOM-kill events and memory.max hits.
# Tracks cursor to avoid re-alerting on old events.
# Uses persistent alert state with time-based cooldown to prevent
# alert storms during crash-restart loops.
#
# Alert state file format (one entry per line):
#   <key>:<epoch_timestamp>
#
# For testing, set _JOURNAL_CMD to override journalctl output.

# Default: query real journal
_journal_cmd() {
    local cursor_arg="$1"
    local lookback="$2"

    if [[ -n "$cursor_arg" ]]; then
        journalctl --user --system --after-cursor="$cursor_arg" \
            --no-pager -o json 2>/dev/null
    else
        journalctl --user --system --since="-${lookback}" \
            --no-pager -o json 2>/dev/null
    fi
}

# Load journal alert state into associative array.
# Populates: _JOURNAL_ALERTED (key → epoch timestamp)
_load_journal_alerts() {
    local alert_file="$1"
    declare -gA _JOURNAL_ALERTED
    _JOURNAL_ALERTED=()

    [[ -f "$alert_file" ]] || return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local key="${line%:*}"
        local ts="${line##*:}"
        _JOURNAL_ALERTED[$key]="$ts"
    done < "$alert_file" 2>/dev/null
}

# Save journal alert state back to file, pruning expired entries.
_save_journal_alerts() {
    local alert_file="$1"
    local cooldown="$2"
    local now
    now="$(date +%s)"
    local tmp="${alert_file}.tmp"

    {
        for key in "${!_JOURNAL_ALERTED[@]}"; do
            local ts="${_JOURNAL_ALERTED[$key]}"
            # Only keep entries still within cooldown
            if (( now - ts < cooldown )); then
                echo "${key}:${ts}"
            fi
        done
    } > "$tmp"

    mv "$tmp" "$alert_file"
}

# Check if a journal alert key is within cooldown.
# Returns 0 (true) if suppressed, 1 if ok to alert.
_journal_alert_suppressed() {
    local key="$1"
    local cooldown="$2"

    local prev_ts="${_JOURNAL_ALERTED[$key]:-}"
    [[ -z "$prev_ts" ]] && return 1

    local now
    now="$(date +%s)"
    (( now - prev_ts < cooldown ))
}

# Record that a journal alert was fired.
_journal_alert_record() {
    local key="$1"
    _JOURNAL_ALERTED[$key]="$(date +%s)"
}

# Check journal for OOM/memory events and alert.
# Args: $1=cursor_file, $2=lookback, $3=alert_state_file, $4=cooldown_secs
journal_check() {
    local cursor_file="$1"
    local lookback="$2"
    local alert_file="${3:-}"
    local cooldown="${4:-1800}"

    local cursor=""
    if [[ -f "$cursor_file" ]]; then
        cursor="$(cat "$cursor_file" 2>/dev/null)"
    fi

    # Load persistent alert state
    if [[ -n "$alert_file" ]]; then
        _load_journal_alerts "$alert_file"
    else
        declare -gA _JOURNAL_ALERTED
        _JOURNAL_ALERTED=()
    fi

    local output
    output="$(${_JOURNAL_CMD:-_journal_cmd} "$cursor" "$lookback")"

    [[ -z "$output" ]] && return 0

    local new_cursor=""

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Extract cursor for tracking
        local cur
        cur="$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('__CURSOR',''))" 2>/dev/null)" || continue
        [[ -n "$cur" ]] && new_cursor="$cur"

        # Skip our own journal entries to prevent self-feeding alert loops
        local source_unit
        source_unit="$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('_SYSTEMD_USER_UNIT','') or d.get('_SYSTEMD_UNIT',''))" 2>/dev/null)" || true
        [[ "$source_unit" == "anomalous-mon.service" ]] && continue

        local message
        message="$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('MESSAGE',''))" 2>/dev/null)" || continue

        # Check for OOM kill
        if [[ "$message" =~ (Out of memory|oom-kill|Killed process) ]]; then
            local proc_name
            proc_name="$(echo "$message" | grep -oP 'Killed process \d+ \(\K[^)]+' || echo "unknown")"
            local alert_key="oom:${proc_name}"
            if ! _journal_alert_suppressed "$alert_key" "$cooldown"; then
                send_alert "oom" "$alert_key" \
                    "OOM kill detected: ${proc_name} — ${message}" \
                    "$alert_key"
                _journal_alert_record "$alert_key"
            fi
        fi

        # Check for memory.max hit (cgroup)
        if [[ "$message" =~ (memory\.max|MemoryMax|memory limit) ]]; then
            local unit
            unit="$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('_SYSTEMD_UNIT','unknown'))" 2>/dev/null)" || unit="unknown"
            local alert_key="memmax:${unit}"
            if ! _journal_alert_suppressed "$alert_key" "$cooldown"; then
                send_alert "oom" "$alert_key" \
                    "Memory limit hit: ${unit} — ${message}" \
                    "$alert_key"
                _journal_alert_record "$alert_key"
            fi
        fi

    done <<< "$output"

    # Update cursor
    if [[ -n "$new_cursor" ]]; then
        echo "$new_cursor" > "$cursor_file"
    fi

    # Save alert state (prunes expired entries)
    if [[ -n "$alert_file" ]]; then
        _save_journal_alerts "$alert_file" "$cooldown"
    fi

    return 0
}
