#!/usr/bin/env bash
# battery-monitor.sh — laptop-battery guard for always-on hosts
#
# Sourced by anomalous-mon. Provides:
#   battery_check ALERT_STATE_FILE LOW_PCT HIGH_PCT EXPECT_END_THRESHOLD COOLDOWN
#   battery_status ALERT_STATE_FILE
#
# Written for a laptop that runs 24/7 on AC as a server (t480-server) with its
# charge capped below 100% for pack longevity. Three independent checks, each
# opt-in — an empty value disables it, and with all three empty battery_check
# does not even sample (the shipped default, so desktops and everyday laptops
# are untouched):
#
#   - low:       a pack's capacity < LOW_PCT. On battery power that means the
#                mains are gone (breaker trip, outage); on AC it means the pack
#                is not charging back up (charge cap or EC fault, dying pack).
#   - high:      a pack's capacity > HIGH_PCT — the charge cap is not holding.
#   - threshold: a pack's charge_control_end_threshold != EXPECT_END_THRESHOLD —
#                the cap itself was lost (EC reset, unit not applied). This is
#                the leading indicator; "high" only notices once the pack has
#                actually charged past the cap.
#
# Alert-state file format (one entry per line): battery:<pack>:<check>:<epoch>
#
# For testing, set _BATTERY_SAMPLE_CMD to a function emitting lines of
# "<pack> <capacity> <status> <ac_online> <end_threshold|->", _BATTERY_PS_ROOT
# to point the default sampler at a fake /sys/class/power_supply, and
# _BATTERY_NOW to pin the clock.

# Default sampler. One line per system battery (type Battery, scope not
# Device — a wireless mouse is also a power_supply "Battery"). Spaces in the
# status ("Not charging") become underscores so the line splits cleanly.
# ac_online is 1 if any Mains supply reports online. The trailing `|| true` is
# load-bearing: this feeds a $( ) under the caller's `set -e` (see
# FINDINGS-mem-sampler-proc-race-2026-07-20.md).
_battery_sample_cmd() {
    local root="${_BATTERY_PS_ROOT:-/sys/class/power_supply}"
    {
        [[ -d "$root" ]] || return 0
        local ac=0 d
        for d in "$root"/*; do
            [[ "$(cat "$d/type" 2>/dev/null)" == "Mains" ]] || continue
            [[ "$(cat "$d/online" 2>/dev/null)" == "1" ]] && ac=1
        done
        for d in "$root"/*; do
            [[ "$(cat "$d/type" 2>/dev/null)" == "Battery" ]] || continue
            [[ "$(cat "$d/scope" 2>/dev/null)" == "Device" ]] && continue
            local cap status end
            cap="$(cat "$d/capacity" 2>/dev/null)" || continue
            status="$(cat "$d/status" 2>/dev/null)" || status="Unknown"
            end="$(cat "$d/charge_control_end_threshold" 2>/dev/null)" || end="-"
            echo "$(basename "$d") ${cap} ${status// /_} ${ac} ${end:--}"
        done
    } || true
}

_battery_now() { echo "${_BATTERY_NOW:-$(date +%s)}"; }

# Load alert state into _BATTERY_ALERTED (key → epoch).
_load_battery_alerts() {
    local alert_file="$1"
    declare -gA _BATTERY_ALERTED
    _BATTERY_ALERTED=()
    [[ -f "$alert_file" ]] || return 0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local key="${line%:*}" ts="${line##*:}"
        [[ -z "$key" || ! "$ts" =~ ^[0-9]+$ ]] && continue
        _BATTERY_ALERTED[$key]="$ts"
    done < "$alert_file" 2>/dev/null
}

# Save _BATTERY_ALERTED, pruning entries past the cooldown window.
_save_battery_alerts() {
    local alert_file="$1" cooldown="$2" now key
    now="$(_battery_now)"
    {
        for key in "${!_BATTERY_ALERTED[@]}"; do
            (( now - _BATTERY_ALERTED[$key] < cooldown )) && echo "${key}:${_BATTERY_ALERTED[$key]}"
        done
    } > "${alert_file}.tmp"
    mv "${alert_file}.tmp" "$alert_file"
}

# Fire an alert for KEY unless it fired within COOLDOWN seconds.
_battery_alert() {
    local key="$1" msg="$2" pack="$3" cooldown="$4" now prev
    now="$(_battery_now)"
    prev="${_BATTERY_ALERTED[$key]:-}"
    [[ -n "$prev" ]] && (( now - prev < cooldown )) && return 0
    send_alert "battery" "$key" "$msg" "battery:${pack}" || true
    _BATTERY_ALERTED[$key]="$now"
}

battery_check() {
    local alert_file="$1" low="$2" high="$3" expect_end="$4" cooldown="${5:-1800}"

    [[ -z "$low" && -z "$high" && -z "$expect_end" ]] && return 0

    _load_battery_alerts "$alert_file"

    local sample
    sample="$(${_BATTERY_SAMPLE_CMD:-_battery_sample_cmd})"

    local pack cap status ac end
    while read -r pack cap status ac end; do
        [[ -z "$pack" || ! "$cap" =~ ^[0-9]+$ ]] && continue
        local ac_word="AC offline — running on battery (breaker trip or outage?)"
        [[ "$ac" == "1" ]] && ac_word="AC online but not charging back up (charge cap or EC fault, or a failing pack?)"

        if [[ -n "$low" ]] && (( cap < low )); then
            _battery_alert "battery:${pack}:low" \
                "${pack} at ${cap}% (below ${low}%), ${status//_/ } — ${ac_word}" \
                "$pack" "$cooldown"
        fi
        if [[ -n "$high" ]] && (( cap > high )); then
            _battery_alert "battery:${pack}:high" \
                "${pack} at ${cap}% (above ${high}%), ${status//_/ } — charge cap not holding (charge stop threshold now ${end})" \
                "$pack" "$cooldown"
        fi
        if [[ -n "$expect_end" && "$end" =~ ^[0-9]+$ ]] && (( end != expect_end )); then
            _battery_alert "battery:${pack}:threshold" \
                "${pack} charge stop threshold is ${end}%, expected ${expect_end}% — charge cap lost (is battery-charge-limit.service applied?)" \
                "$pack" "$cooldown"
        fi
    done <<< "$sample"

    _save_battery_alerts "$alert_file" "$cooldown"
    return 0
}

# Print one line per pack: "<pack>: <cap>% <status>, AC <on|off>, stop at <end>% [alerts]".
battery_status() {
    local alert_file="$1"
    echo "=== Battery State ==="
    echo ""
    _load_battery_alerts "$alert_file"
    local sample
    sample="$(${_BATTERY_SAMPLE_CMD:-_battery_sample_cmd})"
    if [[ -z "$sample" ]]; then
        echo "No batteries"
        return 0
    fi
    local pack cap status ac end
    while read -r pack cap status ac end; do
        [[ -z "$pack" ]] && continue
        local flags="" k
        for k in low high threshold; do
            [[ -n "${_BATTERY_ALERTED[battery:${pack}:${k}]:-}" ]] && flags+=" ${k^^}"
        done
        echo "  ${pack}: ${cap}% ${status//_/ }, AC $([[ "$ac" == 1 ]] && echo on || echo off), stop at ${end}%${flags:+ [${flags# }]}"
    done <<< "$sample"
}
