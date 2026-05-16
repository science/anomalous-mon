#!/usr/bin/env bash
# notify.sh — Desktop notification wrapper with deduplication
#
# Sourced by anomalous-mon. Provides:
#   send_alert TYPE KEY MESSAGE [GROUP]
#
# In-memory dedup: tracks which keys have active alerts within the current
# process. Won't re-notify for the same key until clear_alert is called.
#
# Cross-invocation dedup (GROUP): when GROUP is set, notify-send is invoked
# with -p (print id) and -r <prior_id> so successive bubbles in the same
# group replace rather than stack. Mapping group → id persists in
# NOTIFY_ID_FILE so the replacement survives timer-driven re-invocations.

# Associative array of currently active alerts (key → 1)
declare -gA _ACTIVE_ALERTS

# Persisted group → notify-send id mapping.
# Caller sets NOTIFY_ID_FILE (usually $STATE_DIR/anomalous-mon.notify-ids).
NOTIFY_ID_FILE="${NOTIFY_ID_FILE:-}"
declare -gA _NOTIFY_IDS

_load_notify_ids() {
    _NOTIFY_IDS=()
    [[ -n "$NOTIFY_ID_FILE" && -f "$NOTIFY_ID_FILE" ]] || return 0
    local group id
    while IFS=$'\t' read -r group id; do
        [[ -z "$group" ]] && continue
        _NOTIFY_IDS[$group]="$id"
    done < "$NOTIFY_ID_FILE" 2>/dev/null
}

_save_notify_ids() {
    [[ -n "$NOTIFY_ID_FILE" ]] || return 0
    local tmp="${NOTIFY_ID_FILE}.tmp"
    {
        local group
        for group in "${!_NOTIFY_IDS[@]}"; do
            printf '%s\t%s\n' "$group" "${_NOTIFY_IDS[$group]}"
        done
    } > "$tmp"
    mv "$tmp" "$NOTIFY_ID_FILE"
}

# Send a desktop notification if not already alerted for this key.
# Args: $1=type (cpu|oom), $2=key (in-memory dedup), $3=message,
#       $4=group (optional; enables notify-send replace-id flow)
send_alert() {
    local type="$1" key="$2" message="$3" group="${4:-}"

    # Already alerted for this key — suppress
    if [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]; then
        return 1
    fi

    _ACTIVE_ALERTS[$key]=1

    local urgency="critical"
    local icon="dialog-warning"
    local summary="anomalous-mon: ${type}"
    local timestamp
    timestamp="[$(date +%H:%M)]"
    local body="${timestamp} ${message}"

    if command -v notify-send &>/dev/null; then
        if [[ -n "$group" ]]; then
            _load_notify_ids
            local prev_id="${_NOTIFY_IDS[$group]:-}"
            local new_id
            if [[ -n "$prev_id" ]]; then
                new_id="$(notify-send -u "$urgency" -i "$icon" -p -r "$prev_id" "$summary" "$body" 2>/dev/null || true)"
            else
                new_id="$(notify-send -u "$urgency" -i "$icon" -p "$summary" "$body" 2>/dev/null || true)"
            fi
            new_id="${new_id//[^0-9]/}"
            if [[ -n "$new_id" ]]; then
                _NOTIFY_IDS[$group]="$new_id"
                _save_notify_ids
            fi
        else
            notify-send -u "$urgency" -i "$icon" "$summary" "$body"
        fi
    fi

    echo "[ALERT] ${type}: ${message}"
    return 0
}

# Send an interactive notification with a clickable action button.
# Click handling is delegated to a detached systemd-run scope so it survives
# the parent script exit (notify-send --wait blocks until close/click).
#
# Args:
#   $1 type          (e.g. "stale-files")
#   $2 key           (in-memory dedup, like send_alert)
#   $3 message       (notification body)
#   $4 button_label  (e.g. "Open report")
#   $5 action_cmd    (shell command to run if the button is clicked)
#
# WARNING: $5 is eval'd. Quote paths with ${PATH@Q} when constructing.
send_alert_action() {
    local type="$1" key="$2" message="$3" button_label="$4" action_cmd="$5"

    if [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]; then
        return 1
    fi
    _ACTIVE_ALERTS[$key]=1

    local timestamp
    timestamp="[$(date +%H:%M)]"
    local summary="anomalous-mon: ${type}"
    local body="${timestamp} ${message}"

    if command -v systemd-run >/dev/null 2>&1; then
        # Slugify the key so it's a valid systemd unit name.
        local slug="${key//[^a-zA-Z0-9]/_}"
        systemd-run --user --no-block --quiet \
            --unit="anomalous-mon-notify-${slug}-$$" \
            bash -c '
                result=$(notify-send --wait \
                    --urgency=normal -i dialog-information \
                    --action="action=$1" "$2" "$3" 2>/dev/null)
                [[ "$result" == "action" ]] && eval "$4"
            ' _ "$button_label" "$summary" "$body" "$action_cmd"
    elif command -v notify-send >/dev/null 2>&1; then
        # Fallback: fire-and-forget bubble without the action button.
        notify-send --urgency=normal -i dialog-information "$summary" "$body"
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
