#!/usr/bin/env bash
# memory-monitor.sh — proactive memory-pressure + runaway-growth detection
#
# Sourced by anomalous-mon. Provides:
#   memory_check  STATE_FILE ALERT_FILE
#   memory_status STATE_FILE
#
# Fires BEFORE the kernel OOM killer, on two INDEPENDENT criteria. Motivated by
# the 2026-06-12 incident (an unconstrained python job exhausted RAM+swap; the
# global OOM killer then tore the desktop session apart). See
# PLAN-memory-monitor.md and bin/runcapped.
#
# Signal A — system-wide pressure (regardless of which process):
#   Combined free headroom (MemAvailable + SwapFree) has dropped below
#   MEM_MIN_HEADROOM_MB, OR the kernel is stalling on memory
#   (PSI 'full' avg60 >= MEM_PSI_FULL_PCT). One alert listing the top RSS
#   consumers, on a cooldown (MEM_PRESSURE_COOLDOWN).
#
# Signal B — per-process runaway growth (large AND steadily climbing):
#   A process whose RSS is at least MEM_GROWTH_FLOOR_MB ("real" RAM — anything
#   smaller is ignored) AND grew by >= MEM_GROWTH_TICK_MB for MEM_GROWTH_CYCLES
#   consecutive ~1-minute cycles. This is deliberately NOT a raw slope: a tiny
#   process creeping a few bytes a year never qualifies (below the floor and
#   below the per-cycle delta), while a job ballooning GB/minute trips quickly.
#   Per-process overrides (MEM_GROWTH_OVERRIDES, comm -> cycles) let known
#   legitimate growers (browsers, ballooning VMs) need a longer streak.
#
# Signal B reuses cpu-monitor's consecutive-cycle state machine, so like CPU
# alerts it is purely cycle-counted (no wall-clock) and resets the moment a
# process stops growing. Signal A is threshold+cooldown like disk-monitor.
#
# State file (Signal B per-PID trend), one entry per line:
#   pid:<PID>:<NAME>:<LAST_RSS_KB>:<STREAK>:<ALERTED>
#
# Alert-state file (Signal A cooldown), one entry per line:
#   mem:pressure:<epoch>
# (parsed like disk-monitor's: key is everything up to the last colon).
#
# For testing:
#   _MEM_SAMPLE_CMD — override _memory_sample_cmd. Emits:
#       sys <mem_total_kb> <mem_avail_kb> <swap_total_kb> <swap_free_kb> <psi_full_avg60>
#       proc <pid> <rss_kb> <comm>
#       proc <pid> <rss_kb> <comm>
#       ...
#   set_mock_memory "<lines>" is the convenience helper in the test harness.

# ── Sampling ──────────────────────────────────────────────────────────

# Default sampler: /proc/meminfo + /proc/pressure/memory + per-process VmRSS.
_memory_sample_cmd() {
    local mem_total=0 mem_avail=0 swap_total=0 swap_free=0 psi_full=0
    local key val _rest
    while read -r key val _rest; do
        case "$key" in
            MemTotal:)     mem_total="$val" ;;
            MemAvailable:) mem_avail="$val" ;;
            SwapTotal:)    swap_total="$val" ;;
            SwapFree:)     swap_free="$val" ;;
        esac
    done < /proc/meminfo 2>/dev/null

    # PSI 'full' avg60 — the share of the last 60s in which *every* runnable
    # task was stalled waiting on memory. Best early "thrashing" signal.
    if [[ -r /proc/pressure/memory ]]; then
        psi_full="$(awk '/^full/ {
            for (i = 1; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/avg60=/, "", $i); print $i }
        }' /proc/pressure/memory 2>/dev/null)"
        [[ -z "$psi_full" ]] && psi_full=0
    fi

    echo "sys ${mem_total} ${mem_avail} ${swap_total} ${swap_free} ${psi_full}"

    # One pass over /proc/*/status emitting "proc <pid> <rss_kb> <comm>".
    # Kernel threads (no mm) have no VmRSS and are skipped.
    #
    # `|| true` is load-bearing (same class as _disk_sample_cmd's df guard): a
    # process can exit between the shell expanding the glob and awk opening
    # that file; mawk/gawk treat an unopenable command-line file as FATAL and
    # exit 2, killing the whole cycle under the caller's `set -e` — with the
    # error text already swallowed by the 2>/dev/null. awk aborts at the bad
    # file, so the tail of the proc list is lost for one tick; that only
    # resets those PIDs' growth streaks, which self-heals next tick.
    awk '
        function flush() {
            if (pid != "" && rss != "") print "proc", pid, rss, name
            pid = ""; rss = ""; name = ""
        }
        FNR == 1 { flush(); n = split(FILENAME, a, "/"); pid = a[n-1] }
        /^Name:/  { name = $2 }
        /^VmRSS:/ { rss = $2 }
        END { flush() }
    ' "${_MEM_PROC_ROOT:-/proc}"/[0-9]*/status 2>/dev/null || true
}

# ── State I/O (Signal B per-PID trend) ────────────────────────────────

# Populates: _MEM_NAME, _MEM_LAST_RSS, _MEM_STREAK, _MEM_ALERTED (keyed by PID)
_mem_load_state() {
    local state_file="$1"
    declare -gA _MEM_NAME _MEM_LAST_RSS _MEM_STREAK _MEM_ALERTED
    _MEM_NAME=(); _MEM_LAST_RSS=(); _MEM_STREAK=(); _MEM_ALERTED=()

    [[ -f "$state_file" ]] || return 0

    while IFS= read -r line; do
        case "$line" in
            pid:*)
                local rest="${line#pid:}"
                local f_pid="${rest%%:*}";  rest="${rest#*:}"
                local f_name="${rest%%:*}"; rest="${rest#*:}"
                local f_rss="${rest%%:*}";  rest="${rest#*:}"
                local f_streak="${rest%%:*}"; rest="${rest#*:}"
                local f_alerted="${rest%%:*}"
                # Defensive: numeric fields must be integers.
                [[ "$f_pid" =~ ^[0-9]+$ && "$f_rss" =~ ^[0-9]+$ \
                   && "$f_streak" =~ ^[0-9]+$ ]] || continue
                _MEM_NAME[$f_pid]="$f_name"
                _MEM_LAST_RSS[$f_pid]="$f_rss"
                _MEM_STREAK[$f_pid]="$f_streak"
                _MEM_ALERTED[$f_pid]="${f_alerted:-0}"
                ;;
        esac
    done < "$state_file" 2>/dev/null
}

_mem_save_state() {
    local state_file="$1"
    local tmp="${state_file}.tmp"
    {
        local pid
        for pid in "${!_MEM_LAST_RSS[@]}"; do
            echo "pid:${pid}:${_MEM_NAME[$pid]}:${_MEM_LAST_RSS[$pid]}:${_MEM_STREAK[$pid]:-0}:${_MEM_ALERTED[$pid]:-0}"
        done
    } > "$tmp"
    mv "$tmp" "$state_file"
}

# ── Alert-state I/O (Signal A cooldown) ───────────────────────────────

_mem_load_alerts() {
    local alert_file="$1"
    declare -gA _MEM_PRESSURE_ALERTED
    _MEM_PRESSURE_ALERTED=()
    [[ -f "$alert_file" ]] || return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local key="${line%:*}"
        local ts="${line##*:}"
        [[ -z "$key" || ! "$ts" =~ ^[0-9]+$ ]] && continue
        _MEM_PRESSURE_ALERTED[$key]="$ts"
    done < "$alert_file" 2>/dev/null
}

_mem_save_alerts() {
    local alert_file="$1" cooldown="$2"
    local now tmp
    now="${_MEM_NOW:-$(date +%s)}"
    tmp="${alert_file}.tmp"
    {
        local key
        for key in "${!_MEM_PRESSURE_ALERTED[@]}"; do
            local ts="${_MEM_PRESSURE_ALERTED[$key]}"
            (( now - ts < cooldown )) && echo "${key}:${ts}"
        done
    } > "$tmp"
    mv "$tmp" "$alert_file"
}

_mem_pressure_suppressed() {
    local key="$1" cooldown="$2"
    local prev="${_MEM_PRESSURE_ALERTED[$key]:-}"
    [[ -z "$prev" ]] && return 1
    local now
    now="${_MEM_NOW:-$(date +%s)}"
    (( now - prev < cooldown ))
}

# ── Helpers ───────────────────────────────────────────────────────────

_mem_kb_to_gb() { awk -v kb="$1" 'BEGIN { printf "%.1f", kb/1024/1024 }'; }

# Float >=: returns 0 (true) if $1 >= $2.
_mem_ge_float() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 >= b+0) }'; }

# Per-process growth-cycle threshold (MEM_GROWTH_OVERRIDES, else default).
_mem_growth_cycles() {
    local name="$1" default="$2"
    if declare -p MEM_GROWTH_OVERRIDES &>/dev/null; then
        local o="${MEM_GROWTH_OVERRIDES[$name]+${MEM_GROWTH_OVERRIDES[$name]}}"
        [[ -n "$o" ]] && { echo "$o"; return; }
    fi
    echo "$default"
}

# ── Main check ────────────────────────────────────────────────────────

memory_check() {
    local state_file="$1"
    local alert_file="$2"

    # Config with built-in fallbacks (mirrors disk_check's defaulting).
    local floor_kb=$(( ${MEM_GROWTH_FLOOR_MB:-1024} * 1024 ))
    local tick_kb=$((  ${MEM_GROWTH_TICK_MB:-150}  * 1024 ))
    local def_cycles="${MEM_GROWTH_CYCLES:-5}"
    local min_headroom_mb="${MEM_MIN_HEADROOM_MB:-2048}"
    local psi_thresh="${MEM_PSI_FULL_PCT:-20}"
    local pressure_cd="${MEM_PRESSURE_COOLDOWN:-300}"

    _mem_load_state "$state_file"
    _mem_load_alerts "$alert_file"

    local sample
    sample="$(${_MEM_SAMPLE_CMD:-_memory_sample_cmd})"

    # Parse sample into this-tick snapshots.
    declare -A seen_rss seen_name
    local sys_total=0 sys_avail=0 sys_swap_total=0 sys_swap_free=0 sys_psi=0
    local kind f1 f2 f3 f4 f5
    while read -r kind f1 f2 f3 f4 f5; do
        case "$kind" in
            sys)
                sys_total="$f1"; sys_avail="$f2"; sys_swap_total="$f3"
                sys_swap_free="$f4"; sys_psi="$f5"
                ;;
            proc)
                [[ "$f1" =~ ^[0-9]+$ && "$f2" =~ ^[0-9]+$ ]] || continue
                seen_rss[$f1]="$f2"
                seen_name[$f1]="${f3:-?}"
                ;;
        esac
    done <<< "$sample"

    # ── Signal B: per-process runaway growth ──────────────────────────
    local pid
    for pid in "${!seen_rss[@]}"; do
        local rss="${seen_rss[$pid]}"
        local name="${seen_name[$pid]}"
        local prev_rss="${_MEM_LAST_RSS[$pid]:-}"
        local streak=0
        local alerted="${_MEM_ALERTED[$pid]:-0}"

        if [[ -n "$prev_rss" ]] && (( rss >= prev_rss + tick_kb )); then
            streak=$(( ${_MEM_STREAK[$pid]:-0} + 1 ))
        else
            # Flat or shrinking — growth episode ends.
            streak=0
            if [[ "$alerted" == "1" ]]; then
                clear_alert "mem:runaway:${pid}"
                alerted=0
            fi
        fi

        _MEM_NAME[$pid]="$name"
        _MEM_LAST_RSS[$pid]="$rss"
        _MEM_STREAK[$pid]="$streak"
        _MEM_ALERTED[$pid]="$alerted"

        local cycles
        cycles="$(_mem_growth_cycles "$name" "$def_cycles")"
        if (( rss >= floor_kb && streak >= cycles )) && [[ "$alerted" != "1" ]]; then
            local rss_gb growth_mb
            rss_gb="$(_mem_kb_to_gb "$rss")"
            # Per-cycle delta is naturally tens–hundreds of MB; show MB (showing
            # GB rounds a 200 MB/cycle climb to a misleading "+0.0 GB").
            growth_mb=$(( (rss - prev_rss) / 1024 ))
            send_alert "mem" "mem:runaway:${pid}" \
                "Runaway memory: ${name} (pid ${pid}) at ${rss_gb} GB and climbing (+${growth_mb} MB last cycle, ${streak} cycles) — about to OOM? kill ${pid}, or re-run it under runcapped" \
                "mem:runaway:${name}"
            _MEM_ALERTED[$pid]=1
        fi
    done

    # Prune PIDs that vanished this tick (clear any active alert first).
    for pid in "${!_MEM_LAST_RSS[@]}"; do
        if [[ -z "${seen_rss[$pid]:-}" ]]; then
            [[ "${_MEM_ALERTED[$pid]:-0}" == "1" ]] && clear_alert "mem:runaway:${pid}"
            unset '_MEM_NAME[$pid]' '_MEM_LAST_RSS[$pid]' '_MEM_STREAK[$pid]' '_MEM_ALERTED[$pid]'
        fi
    done

    _mem_save_state "$state_file"

    # ── Signal A: system-wide pressure ────────────────────────────────
    # Skip entirely if we got no valid meminfo reading (empty/garbage sample) —
    # a missing sys line leaves sys_total=0 and would otherwise read as "zero
    # headroom" and false-alarm.
    if (( sys_total > 0 )); then

    # Combined free headroom across RAM and swap, in MB.
    local headroom_mb=$(( (sys_avail + sys_swap_free) / 1024 ))
    local psi_high=1
    _mem_ge_float "$sys_psi" "$psi_thresh" || psi_high=0

    if (( headroom_mb < min_headroom_mb )) || (( psi_high == 1 )); then
        local key="mem:pressure"
        if ! _mem_pressure_suppressed "$key" "$pressure_cd"; then
            # Top 3 RSS consumers for the alert body.
            local top=""
            local line
            while IFS=$'\t' read -r line; do
                [[ -z "$line" ]] && continue
                local t_rss="${line%%:*}"
                local t_rest="${line#*:}"
                local t_pid="${t_rest%%:*}"
                local t_name="${t_rest#*:}"
                top="${top}${top:+, }${t_name}(${t_pid}) $(_mem_kb_to_gb "$t_rss") GB"
            done < <(
                for pid in "${!seen_rss[@]}"; do
                    printf '%s:%s:%s\n' "${seen_rss[$pid]}" "$pid" "${seen_name[$pid]}"
                done | sort -t: -k1,1 -rn | head -3
            )
            local headroom_gb swap_used_gb
            headroom_gb="$(_mem_kb_to_gb $(( sys_avail + sys_swap_free )))"
            swap_used_gb="$(_mem_kb_to_gb $(( sys_swap_total - sys_swap_free )))"
            local reason
            if (( headroom_mb < min_headroom_mb )); then
                reason="only ${headroom_gb} GB free (RAM+swap)"
            else
                reason="memory stalling (PSI ${sys_psi}%)"
            fi
            send_alert "mem" "$key" \
                "System memory pressure: ${reason}; swap used ${swap_used_gb} GB. Top: ${top:-n/a}" \
                "mem:pressure"
            _MEM_PRESSURE_ALERTED[$key]="${_MEM_NOW:-$(date +%s)}"
        fi
    fi

    fi  # sys_total > 0

    _mem_save_alerts "$alert_file" "$pressure_cd"
    return 0
}

# ── Status (for --status) ─────────────────────────────────────────────

memory_status() {
    local state_file="$1"

    echo "=== Memory State ==="
    echo ""

    local sample
    sample="$(${_MEM_SAMPLE_CMD:-_memory_sample_cmd})"

    declare -A seen_rss seen_name
    local sys_total=0 sys_avail=0 sys_swap_total=0 sys_swap_free=0 sys_psi=0
    local kind f1 f2 f3 f4 f5
    while read -r kind f1 f2 f3 f4 f5; do
        case "$kind" in
            sys) sys_total="$f1"; sys_avail="$f2"; sys_swap_total="$f3"
                 sys_swap_free="$f4"; sys_psi="$f5" ;;
            proc) [[ "$f1" =~ ^[0-9]+$ ]] || continue
                  seen_rss[$f1]="$f2"; seen_name[$f1]="${f3:-?}" ;;
        esac
    done <<< "$sample"

    printf "  RAM available:   %s GB / %s GB\n" \
        "$(_mem_kb_to_gb "$sys_avail")" "$(_mem_kb_to_gb "$sys_total")"
    printf "  Swap used:       %s GB / %s GB\n" \
        "$(_mem_kb_to_gb $(( sys_swap_total - sys_swap_free )))" "$(_mem_kb_to_gb "$sys_swap_total")"
    printf "  Combined free:   %s GB (RAM+swap headroom)\n" \
        "$(_mem_kb_to_gb $(( sys_avail + sys_swap_free )))"
    printf "  Memory PSI full avg60: %s%%\n" "$sys_psi"
    echo ""

    _mem_load_state "$state_file"
    local def_cycles="${MEM_GROWTH_CYCLES:-5}"
    local floor_kb=$(( ${MEM_GROWTH_FLOOR_MB:-1024} * 1024 ))
    local any=0
    local pid
    for pid in "${!_MEM_LAST_RSS[@]}"; do
        local streak="${_MEM_STREAK[$pid]:-0}"
        local rss="${_MEM_LAST_RSS[$pid]}"
        # Show only processes that are large and currently in a growth streak.
        (( streak > 0 && rss >= floor_kb )) || continue
        any=1
        local name="${_MEM_NAME[$pid]}"
        local cycles
        cycles="$(_mem_growth_cycles "$name" "$def_cycles")"
        local flag=""
        [[ "${_MEM_ALERTED[$pid]:-0}" == "1" ]] && flag=" [ALERTED]"
        printf "  growing: %s (pid %s): %s GB, %s/%s cycles%s\n" \
            "$name" "$pid" "$(_mem_kb_to_gb "$rss")" "$streak" "$cycles" "$flag"
    done
    (( any == 0 )) && echo "  No processes in a growth streak (all clear)"
}
