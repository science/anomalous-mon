#!/usr/bin/env bash
# cpu-monitor.sh — CPU sampling and dual-track state tracking
#
# Sourced by anomalous-mon. Provides:
#   cpu_sample STATE_FILE
#   cpu_check_alerts STATE_FILE THRESHOLD SUSTAINED_CYCLES
#
# State file format (line-based, one entry per line):
#   pid:<PID>:<NAME>:<COUNT>:<ALERTED>
#   name:<NAME>:<COUNT>:<ALERTED>
#
# The ps sampling function can be overridden for testing by setting
# _CPU_SAMPLE_CMD to a function or command that outputs ps-style lines:
#   PID %CPU COMM

# Default: sample real processes
_cpu_sample_cmd() {
    ps -eo pid=,pcpu=,comm= --sort=-pcpu 2>/dev/null | head -20
}

# Parse state file into associative arrays.
# Populates: _PID_COUNT, _PID_NAME, _PID_ALERTED, _NAME_COUNT, _NAME_ALERTED
_load_state() {
    local state_file="$1"

    declare -gA _PID_COUNT _PID_NAME _PID_ALERTED _NAME_COUNT _NAME_ALERTED

    # Clear arrays
    _PID_COUNT=()
    _PID_NAME=()
    _PID_ALERTED=()
    _NAME_COUNT=()
    _NAME_ALERTED=()

    [[ -f "$state_file" ]] || return 0

    while IFS=: read -r type f1 f2 f3 f4; do
        case "$type" in
            pid)
                _PID_COUNT[$f1]="$f3"
                _PID_NAME[$f1]="$f2"
                _PID_ALERTED[$f1]="$f4"
                ;;
            name)
                _NAME_COUNT[$f1]="$f2"
                _NAME_ALERTED[$f1]="$f3"
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
            echo "pid:${pid}:${_PID_NAME[$pid]}:${_PID_COUNT[$pid]}:${_PID_ALERTED[$pid]}"
        done
        for name in "${!_NAME_COUNT[@]}"; do
            echo "name:${name}:${_NAME_COUNT[$name]}:${_NAME_ALERTED[$name]}"
        done
    } > "$tmp"

    mv "$tmp" "$state_file"
}

# Take a CPU sample and update state.
# Args: $1=state_file, $2=threshold
cpu_sample() {
    local state_file="$1"
    local threshold="$2"

    _load_state "$state_file"

    # Track which PIDs and names are hot this cycle
    declare -A hot_pids hot_names

    # Get current CPU snapshot
    local sample
    sample="$(${_CPU_SAMPLE_CMD:-_cpu_sample_cmd})"

    while read -r pid pcpu comm; do
        [[ -z "$pid" ]] && continue
        # Remove any decimal from pcpu for integer comparison
        local pcpu_int="${pcpu%%.*}"
        [[ -z "$pcpu_int" ]] && pcpu_int=0

        if (( pcpu_int >= threshold )); then
            hot_pids[$pid]="$comm"
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
            unset '_PID_COUNT[$pid]' '_PID_NAME[$pid]' '_PID_ALERTED[$pid]'
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
# Args: $1=state_file, $2=sustained_cycles
cpu_check_alerts() {
    local state_file="$1"
    local sustained_cycles="$2"
    local alerted=0

    _load_state "$state_file"

    # Check PID table
    for pid in "${!_PID_COUNT[@]}"; do
        if (( _PID_COUNT[$pid] >= sustained_cycles )) && [[ "${_PID_ALERTED[$pid]}" != "1" ]]; then
            local name="${_PID_NAME[$pid]}"
            send_alert "cpu" "pid:${pid}" \
                "PID ${pid} (${name}) sustained high CPU for ${sustained_cycles} cycles"
            _PID_ALERTED[$pid]=1
            alerted=1
        fi
    done

    # Check Name table
    for name in "${!_NAME_COUNT[@]}"; do
        if (( _NAME_COUNT[$name] >= sustained_cycles )) && [[ "${_NAME_ALERTED[$name]}" != "1" ]]; then
            send_alert "cpu" "name:${name}" \
                "Process '${name}' sustained high CPU for ${sustained_cycles} cycles"
            _NAME_ALERTED[$name]=1
            alerted=1
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

    if (( ${#_PID_COUNT[@]} > 0 )); then
        echo "PID table:"
        for pid in "${!_PID_COUNT[@]}"; do
            local flag=""
            [[ "${_PID_ALERTED[$pid]}" == "1" ]] && flag=" [ALERTED]"
            echo "  PID ${pid} (${_PID_NAME[$pid]}): ${_PID_COUNT[$pid]} cycles${flag}"
        done
    fi

    if (( ${#_NAME_COUNT[@]} > 0 )); then
        echo "Name table:"
        for name in "${!_NAME_COUNT[@]}"; do
            local flag=""
            [[ "${_NAME_ALERTED[$name]}" == "1" ]] && flag=" [ALERTED]"
            echo "  ${name}: ${_NAME_COUNT[$name]} cycles${flag}"
        done
    fi
}
