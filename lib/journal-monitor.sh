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
# Two passes:
#   - the user journal (steve's own services), read directly, tracked by cursor;
#   - the system + kernel journal, through one fixed sudo-allowed query (below),
#     de-duplicated by timestamp.
#
# For testing, set _JOURNAL_CMD / _JOURNAL_SYSTEM_CMD to override journalctl
# output, and _JOURNAL_NOW to fix the clock.

# Default: query the user journal (readable without privileges)
_journal_cmd() {
    local cursor_arg="$1"
    local lookback="$2"

    if [[ -n "$cursor_arg" ]]; then
        journalctl --user --after-cursor="$cursor_arg" \
            --no-pager -o json 2>/dev/null
    else
        journalctl --user --since="-${lookback}" \
            --no-pager -o json 2>/dev/null
    fi
}

# The system + kernel journal is readable only by the systemd-journal group,
# which steve is deliberately not in. The sudoers rule installed from yadm
# (~/.config/yadm/sudoers.d/anomalous-mon-journal) allows exactly this command,
# run as steve with group systemd-journal, without a PIN. sudo matches the
# arguments literally: change anything here and the rule must change with it
# (test-dotfiles.sh checks that they agree). Keep --grep last.
_JOURNAL_SYSTEM_ARGV=(
    /usr/bin/journalctl --system --no-pager --quiet --output=json --since=-10min
    '--grep=Out.of.memory|oom-kill|Killed.process|memory.max|MemoryMax|memory.limit'
)
JOURNAL_SUDOERS_RULE="${JOURNAL_SUDOERS_RULE:-/etc/sudoers.d/anomalous-mon-journal}"

_journal_system_cmd() {
    # Without the rule, sudo -n would fail (and log the refusal) every cycle.
    [[ -e "$JOURNAL_SUDOERS_RULE" ]] || return 0
    # journalctl --grep exits 1 when nothing matches, which is the normal case.
    sudo -n -g systemd-journal "${_JOURNAL_SYSTEM_ARGV[@]}" 2>/dev/null || true
}

# Print one field of a journal JSON line (empty if absent).
_journal_field() {
    python3 -c 'import sys,json; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null
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

# Alert on one journal JSON line if it is an OOM kill or a memory-limit hit.
# Args: $1=json_line, $2=cooldown_secs
_journal_handle_line() {
    local line="$1"
    local cooldown="$2"

    # Skip our own journal entries to prevent self-feeding alert loops
    local source_unit
    source_unit="$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('_SYSTEMD_USER_UNIT','') or d.get('_SYSTEMD_UNIT',''))" 2>/dev/null)" || true
    [[ "$source_unit" == "anomalous-mon.service" ]] && return 0

    # Skip sudo's audit lines: they quote whole command lines, which can contain
    # the very words matched below (the sudo-allowed system query's own --grep
    # pattern is logged every time a variant of it is refused).
    [[ "$(_journal_field "$line" SYSLOG_IDENTIFIER)" == "sudo" ]] && return 0

    local message
    message="$(_journal_field "$line" MESSAGE)" || return 0

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
        unit="$(_journal_field "$line" _SYSTEMD_UNIT)"
        [[ -n "$unit" ]] || unit="unknown"
        local alert_key="memmax:${unit}"
        if ! _journal_alert_suppressed "$alert_key" "$cooldown"; then
            send_alert "oom" "$alert_key" \
                "Memory limit hit: ${unit} — ${message}" \
                "$alert_key"
            _journal_alert_record "$alert_key"
        fi
    fi
    return 0
}

# System + kernel journal pass. The sudo-allowed query has a fixed 10 min
# window (sudo can't match a changing cursor argument safely), so entries are
# de-duplicated by __REALTIME_TIMESTAMP (µs): only entries newer than the one
# stored in ts_file are handled. On a cold start (no ts_file) the cutoff is
# now - lookback, matching the user pass.
# Args: $1=ts_file, $2=lookback, $3=cooldown_secs
_journal_check_system() {
    local ts_file="$1"
    local lookback="$2"
    local cooldown="$3"

    local output
    output="$(${_JOURNAL_SYSTEM_CMD:-_journal_system_cmd})" || output=""
    [[ -z "$output" ]] && return 0

    local cutoff=""
    if [[ -f "$ts_file" ]]; then
        cutoff="$(cat "$ts_file" 2>/dev/null)"
    fi
    if [[ ! "$cutoff" =~ ^[0-9]+$ ]]; then
        local now="${_JOURNAL_NOW:-$(date +%s)}"
        local secs
        secs="$(date -u -d "1970-01-01 00:00:00 UTC + ${lookback}" +%s 2>/dev/null)" || secs=120
        cutoff=$(( (now - secs) * 1000000 ))
    fi

    local newest="$cutoff"
    local line ts
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ts="$(_journal_field "$line" __REALTIME_TIMESTAMP)" || continue
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        if (( ts <= cutoff )); then
            continue
        fi
        if (( ts > newest )); then
            newest="$ts"
        fi
        _journal_handle_line "$line" "$cooldown"
    done <<< "$output"

    echo "$newest" > "${ts_file}.tmp" && mv "${ts_file}.tmp" "$ts_file"
}

# Check journal for OOM/memory events and alert.
# Args: $1=cursor_file, $2=lookback, $3=alert_state_file, $4=cooldown_secs
# The system pass keeps its timestamp in "<cursor_file>.system-ts".
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

    # User journal pass, tracked by cursor
    local output
    output="$(${_JOURNAL_CMD:-_journal_cmd} "$cursor" "$lookback")" || output=""

    local new_cursor=""
    local line cur
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Extract cursor for tracking
        cur="$(_journal_field "$line" __CURSOR)" || continue
        [[ -n "$cur" ]] && new_cursor="$cur"

        _journal_handle_line "$line" "$cooldown"
    done <<< "$output"

    # Update cursor
    if [[ -n "$new_cursor" ]]; then
        echo "$new_cursor" > "$cursor_file"
    fi

    # System + kernel journal pass (via the sudo rule; empty without it)
    _journal_check_system "${cursor_file}.system-ts" "$lookback" "$cooldown"

    # Save alert state (prunes expired entries)
    if [[ -n "$alert_file" ]]; then
        _save_journal_alerts "$alert_file" "$cooldown"
    fi

    return 0
}
