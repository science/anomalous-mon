#!/usr/bin/env bash
# cpu-monitor.sh — CPU sampling and dual-track state tracking
#
# Sourced by anomalous-mon. Provides:
#   cpu_sample STATE_FILE PER_CORE_THRESHOLD TOTAL_CPU_THRESHOLD
#   cpu_check_alerts STATE_FILE SUSTAINED_CYCLES
#
# A process is "hot" if it exceeds EITHER threshold:
#   - PER_CORE_THRESHOLD: pidstat %CPU value (percent of one core)
#   - TOTAL_CPU_THRESHOLD: percent of total CPU (all cores combined);
#     converted to pidstat scale internally as TOTAL_CPU_THRESHOLD * nproc
#
# State file format (line-based, one entry per line):
#   pid:<PID>:<NAME>:<COUNT>:<ALERTED>:<ARGS>
#   name:<NAME>:<COUNT>:<ALERTED>
#
# Uses pidstat (sysstat) for interval-based CPU measurement instead of
# ps %CPU (which is a lifetime average and misses recent spikes).
#
# The sampling function can be overridden for testing by setting
# _CPU_SAMPLE_CMD to a function that outputs lines:
#   PID %CPU COMM ARGS...
#
# _NPROC can be set to override nproc for testing.

# Default: sample real processes via pidstat (60-second interval)
_cpu_sample_cmd() {
    # pidstat output: timestamp UID PID %usr %system %guest %wait %CPU CPU Command
    # We want: PID %CPU COMM ARGS
    pidstat -l 60 1 2>/dev/null \
        | awk '/^Average:/ { exit } NR>3 && /^[0-9]/ && $9+0 > 0 {
            pid=$4; cpu=$9; cmd=$11
            # Extract bare command name (basename, no path)
            n=split(cmd, parts, "/")
            comm=parts[n]
            # Full command line is field 11 onward
            args=""
            for(i=11;i<=NF;i++) args=args (i>11?" ":"") $i
            print pid, cpu, comm, args
        }' \
        || true
}

# Parse state file into associative arrays.
# Populates: _PID_COUNT, _PID_NAME, _PID_ALERTED, _PID_ARGS, _NAME_COUNT, _NAME_ALERTED
_load_state() {
    local state_file="$1"

    declare -gA _PID_COUNT _PID_NAME _PID_ALERTED _PID_ARGS _NAME_COUNT _NAME_ALERTED

    # Clear arrays
    _PID_COUNT=()
    _PID_NAME=()
    _PID_ALERTED=()
    _PID_ARGS=()
    _NAME_COUNT=()
    _NAME_ALERTED=()

    [[ -f "$state_file" ]] || return 0

    while IFS= read -r line; do
        case "$line" in
            pid:*)
                # pid:<PID>:<NAME>:<COUNT>:<ALERTED>:<ARGS>
                local rest="${line#pid:}"
                local f_pid="${rest%%:*}"; rest="${rest#*:}"
                local f_name="${rest%%:*}"; rest="${rest#*:}"
                local f_count="${rest%%:*}"; rest="${rest#*:}"
                local f_alerted="${rest%%:*}"; rest="${rest#*:}"
                local f_args="$rest"
                _PID_COUNT[$f_pid]="$f_count"
                _PID_NAME[$f_pid]="$f_name"
                _PID_ALERTED[$f_pid]="$f_alerted"
                _PID_ARGS[$f_pid]="$f_args"
                ;;
            name:*)
                local rest="${line#name:}"
                local f_name="${rest%%:*}"; rest="${rest#*:}"
                local f_count="${rest%%:*}"; rest="${rest#*:}"
                local f_alerted="$rest"
                _NAME_COUNT[$f_name]="$f_count"
                _NAME_ALERTED[$f_name]="$f_alerted"
                ;;
        esac
    done < "$state_file" 2>/dev/null
}

# Save state arrays back to file.
_save_state() {
    local state_file="$1"
    local tmp="${state_file}.tmp"

    {
        for pid in "${!_PID_COUNT[@]}"; do
            echo "pid:${pid}:${_PID_NAME[$pid]}:${_PID_COUNT[$pid]}:${_PID_ALERTED[$pid]}:${_PID_ARGS[$pid]:-}"
        done
        for name in "${!_NAME_COUNT[@]}"; do
            echo "name:${name}:${_NAME_COUNT[$name]}:${_NAME_ALERTED[$name]}"
        done
    } > "$tmp"

    mv "$tmp" "$state_file"
}

# Get the sustained cycles threshold for a given process name.
# Uses CPU_SUSTAINED_OVERRIDES if set, otherwise falls back to default.
_get_sustained_cycles() {
    local name="$1"
    local default="$2"

    if declare -p CPU_SUSTAINED_OVERRIDES &>/dev/null; then
        local override="${CPU_SUSTAINED_OVERRIDES[$name]+${CPU_SUSTAINED_OVERRIDES[$name]}}"
        if [[ -n "$override" ]]; then
            echo "$override"
            return
        fi
    fi
    echo "$default"
}

# Take a CPU sample and update state.
# Args: $1=state_file, $2=per_core_threshold, $3=total_cpu_threshold (% of total)
cpu_sample() {
    local state_file="$1"
    local per_core_threshold="$2"
    local total_cpu_pct="${3:-0}"

    # Convert total-CPU percentage to pidstat scale (% of one core * nproc)
    local nproc_val="${_NPROC:-$(nproc)}"
    local total_threshold=$(( total_cpu_pct * nproc_val ))

    _load_state "$state_file"

    # Track which PIDs and names are hot this cycle
    declare -A hot_pids hot_names hot_pid_args

    # Get current CPU snapshot
    local sample
    sample="$(${_CPU_SAMPLE_CMD:-_cpu_sample_cmd})"

    while read -r pid pcpu comm args; do
        [[ -z "$pid" ]] && continue
        # Remove any decimal from pcpu for integer comparison
        local pcpu_int="${pcpu%%.*}"
        [[ -z "$pcpu_int" ]] && pcpu_int=0

        if (( pcpu_int >= per_core_threshold || ( total_threshold > 0 && pcpu_int >= total_threshold ) )); then
            hot_pids[$pid]="$comm"
            hot_pid_args[$pid]="${args:-$comm}"
            hot_names[$comm]=1
        fi
    done <<< "$sample"

    # Update PID table
    # Increment hot PIDs, checking for name changes
    for pid in "${!hot_pids[@]}"; do
        local current_name="${hot_pids[$pid]}"
        local prev_name="${_PID_NAME[$pid]:-}"

        if [[ -n "$prev_name" && "$prev_name" != "$current_name" ]]; then
            # PID changed names — keep counting (same PID = same process)
            _PID_NAME[$pid]="$current_name"
        fi

        _PID_NAME[$pid]="$current_name"
        _PID_ARGS[$pid]="${hot_pid_args[$pid]:-$current_name}"
        _PID_COUNT[$pid]=$(( ${_PID_COUNT[$pid]:-0} + 1 ))
        # Preserve alerted state
        _PID_ALERTED[$pid]="${_PID_ALERTED[$pid]:-0}"
    done

    # Clear cold PIDs
    for pid in "${!_PID_COUNT[@]}"; do
        if [[ -z "${hot_pids[$pid]:-}" ]]; then
            # PID went cold — reset
            if [[ "${_PID_ALERTED[$pid]:-0}" == "1" ]]; then
                clear_alert "pid:${pid}"
            fi
            unset '_PID_COUNT[$pid]' '_PID_NAME[$pid]' '_PID_ALERTED[$pid]' '_PID_ARGS[$pid]'
        fi
    done

    # Update Name table
    for name in "${!hot_names[@]}"; do
        _NAME_COUNT[$name]=$(( ${_NAME_COUNT[$name]:-0} + 1 ))
        _NAME_ALERTED[$name]="${_NAME_ALERTED[$name]:-0}"
    done

    # Clear cold names
    for name in "${!_NAME_COUNT[@]}"; do
        if [[ -z "${hot_names[$name]:-}" ]]; then
            if [[ "${_NAME_ALERTED[$name]:-0}" == "1" ]]; then
                clear_alert "name:${name}"
            fi
            unset '_NAME_COUNT[$name]' '_NAME_ALERTED[$name]'
        fi
    done

    _save_state "$state_file"
}

# Check state and fire alerts for anything that has sustained high CPU.
# Args: $1=state_file, $2=default_sustained_cycles
cpu_check_alerts() {
    local state_file="$1"
    local default_cycles="$2"
    local alerted=0

    _load_state "$state_file"

    # Check PID table
    local -A _pid_alerted_names=()
    for pid in "${!_PID_COUNT[@]}"; do
        local name="${_PID_NAME[$pid]}"
        local cycles
        cycles="$(_get_sustained_cycles "$name" "$default_cycles")"
        if (( _PID_COUNT[$pid] >= cycles )) && [[ "${_PID_ALERTED[$pid]}" != "1" ]]; then
            local args="${_PID_ARGS[$pid]:-$name}"
            send_alert "cpu" "pid:${pid}" \
                "PID ${pid} (${name}) sustained high CPU for ${_PID_COUNT[$pid]} cycles: ${args}" \
                "$name"
            _PID_ALERTED[$pid]=1
            _pid_alerted_names[$name]=1
            alerted=1
        fi
    done

    # Check Name table (skip if a PID alert already fired for this name)
    for name in "${!_NAME_COUNT[@]}"; do
        local cycles
        cycles="$(_get_sustained_cycles "$name" "$default_cycles")"
        if (( _NAME_COUNT[$name] >= cycles )) && [[ "${_NAME_ALERTED[$name]}" != "1" ]]; then
            if [[ "${_pid_alerted_names[$name]:-}" == "1" ]]; then
                _NAME_ALERTED[$name]=1
            else
                send_alert "cpu" "name:${name}" \
                    "Process '${name}' sustained high CPU for ${_NAME_COUNT[$name]} cycles" \
                    "$name"
                _NAME_ALERTED[$name]=1
                alerted=1
            fi
        fi
    done

    _save_state "$state_file"
    return 0
}

# Print current tracking state (for --status).
cpu_status() {
    local state_file="$1"

    if [[ ! -f "$state_file" ]]; then
        echo "No CPU state file (cold start)"
        return
    fi

    _load_state "$state_file"

    echo "=== CPU Tracking State ==="
    echo ""

    if (( ${#_PID_COUNT[@]} == 0 && ${#_NAME_COUNT[@]} == 0 )); then
        echo "No processes being tracked (all clear)"
        return
    fi

    local default_cycles="${CPU_SUSTAINED_CYCLES:-5}"

    if (( ${#_PID_COUNT[@]} > 0 )); then
        echo "PID table:"
        for pid in "${!_PID_COUNT[@]}"; do
            local name="${_PID_NAME[$pid]}"
            local cycles
            cycles="$(_get_sustained_cycles "$name" "$default_cycles")"
            local flag=""
            [[ "${_PID_ALERTED[$pid]}" == "1" ]] && flag=" [ALERTED]"
            echo "  PID ${pid} (${name}): ${_PID_COUNT[$pid]}/${cycles} cycles${flag} — ${_PID_ARGS[$pid]:-}"
        done
    fi

    if (( ${#_NAME_COUNT[@]} > 0 )); then
        echo "Name table:"
        for name in "${!_NAME_COUNT[@]}"; do
            local cycles
            cycles="$(_get_sustained_cycles "$name" "$default_cycles")"
            local flag=""
            [[ "${_NAME_ALERTED[$name]}" == "1" ]] && flag=" [ALERTED]"
            echo "  ${name}: ${_NAME_COUNT[$name]}/${cycles} cycles${flag}"
        done
    fi
}
