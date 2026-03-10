#!/usr/bin/env bash
# notify.sh — Desktop notification wrapper with deduplication
#
# Sourced by anomalous-mon. Provides:
#   send_alert TYPE KEY MESSAGE
#
# Deduplication: tracks which keys have active alerts. Won't re-notify
# for the same key until clear_alert is called for it.

# Associative array of currently active alerts (key → 1)
declare -gA _ACTIVE_ALERTS

# Send a desktop notification if not already alerted for this key.
# Args: $1=type (cpu|oom), $2=key (identifier for dedup), $3=message
send_alert() {
    local type="$1" key="$2" message="$3"

    # Already alerted for this key — suppress
    if [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]; then
        return 1
    fi

    _ACTIVE_ALERTS[$key]=1

    local urgency="critical"
    local icon="dialog-warning"
    local summary="anomalous-mon: ${type}"

    if command -v notify-send &>/dev/null; then
        notify-send -u "$urgency" -i "$icon" "$summary" "$message"
    fi

    echo "[ALERT] ${type}: ${message}"
    return 0
}

# Clear an active alert, allowing re-notification if it triggers again.
# Args: $1=key
clear_alert() {
    local key="$1"
    unset '_ACTIVE_ALERTS[$key]'
}

# Check if an alert is currently active for a key.
# Args: $1=key
is_alert_active() {
    local key="$1"
    [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]
}
