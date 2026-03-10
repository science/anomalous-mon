#!/usr/bin/env bash
# journal-monitor.sh — Journal event detection for OOM kills and memory limit hits
#
# Sourced by anomalous-mon. Provides:
#   journal_check CURSOR_FILE LOOKBACK
#
# Checks journalctl for OOM-kill events and memory.max hits.
# Tracks cursor to avoid re-alerting on old events.
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

# Check journal for OOM/memory events and alert.
# Args: $1=cursor_file, $2=lookback (e.g., "2 minutes")
journal_check() {
    local cursor_file="$1"
    local lookback="$2"

    local cursor=""
    if [[ -f "$cursor_file" ]]; then
        cursor="$(cat "$cursor_file" 2>/dev/null)"
    fi

    local output
    output="$(${_JOURNAL_CMD:-_journal_cmd} "$cursor" "$lookback")"

    [[ -z "$output" ]] && return 0

    local new_cursor=""
    local found_events=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Extract cursor for tracking
        local cur
        cur="$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('__CURSOR',''))" 2>/dev/null)" || continue
        [[ -n "$cur" ]] && new_cursor="$cur"

        local message
        message="$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('MESSAGE',''))" 2>/dev/null)" || continue

        # Check for OOM kill
        if [[ "$message" =~ (Out of memory|oom-kill|Killed process) ]]; then
            local proc_name
            proc_name="$(echo "$message" | grep -oP 'Killed process \d+ \(\K[^)]+' || echo "unknown")"
            send_alert "oom" "oom:${proc_name}" \
                "OOM kill detected: ${proc_name} — ${message}"
            found_events=1
        fi

        # Check for memory.max hit (cgroup)
        if [[ "$message" =~ (memory\.max|MemoryMax|memory limit) ]]; then
            local unit
            unit="$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('_SYSTEMD_UNIT','unknown'))" 2>/dev/null)" || unit="unknown"
            send_alert "oom" "memmax:${unit}" \
                "Memory limit hit: ${unit} — ${message}"
            found_events=1
        fi

    done <<< "$output"

    # Update cursor
    if [[ -n "$new_cursor" ]]; then
        echo "$new_cursor" > "$cursor_file"
    fi

    return 0
}
