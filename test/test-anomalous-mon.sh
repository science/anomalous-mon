#!/usr/bin/env bash
# test-anomalous-mon.sh — Test suite for anomalous-mon
#
# Run: ./test/test-anomalous-mon.sh
# All tests use temp directories and mock functions — no side effects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test framework
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

test_result() {
    local description="$1" result="$2"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ "$result" == "pass" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $description"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $description"
    fi
}

# Create temp directory for test state files
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

# Source the library files
source "$PROJECT_DIR/lib/notify.sh"
source "$PROJECT_DIR/lib/cpu-monitor.sh"
source "$PROJECT_DIR/lib/journal-monitor.sh"

# Override nproc for deterministic total-CPU threshold calculations
_NPROC=4

# ── Mock helpers ──────────────────────────────────────────────────────

# Capture alerts instead of sending real notifications
ALERT_LOG=""
_real_notify_send="$(command -v notify-send 2>/dev/null || true)"

# Override notify-send so it's never called for real
notify-send() { :; }

# Wrap send_alert to log calls.
# ALERT_LOG format per entry: type|key|message|group\n
_orig_send_alert="$(declare -f send_alert)"
send_alert() {
    local type="$1" key="$2" message="$3" group="${4:-}"

    # In-memory key dedup (applies regardless of group)
    if [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]; then
        return 1
    fi
    _ACTIVE_ALERTS[$key]=1

    ALERT_LOG="${ALERT_LOG}${type}|${key}|${message}|${group}\n"
    return 0
}

# Reset test state
reset_test_state() {
    ALERT_LOG=""
    _ACTIVE_ALERTS=()
    rm -f "$TEST_TMP"/*.state "$TEST_TMP"/*.cursor
}

# Set mock ps output for cpu-monitor
# Usage: set_mock_ps "PID %CPU COMM" ...
set_mock_ps() {
    _CPU_SAMPLE_CMD="_mock_ps_output"
    _MOCK_PS_DATA="$*"
}

_mock_ps_output() {
    echo "$_MOCK_PS_DATA"
}

# ── CPU Monitor Tests ─────────────────────────────────────────────────

echo ""
echo "=== CPU Monitor Tests ==="
echo ""

# --- No processes above threshold → no alert ---
reset_test_state
set_mock_ps "1234 5.0 bash
5678 2.0 sshd"
cpu_sample "$TEST_TMP/cpu.state" 60 25
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "No processes above threshold → no alert" "pass"
else
    test_result "No processes above threshold → no alert" "fail"
fi

# --- Process above threshold for 1 cycle → no alert ---
reset_test_state
set_mock_ps "1234 70.0 rclone"
cpu_sample "$TEST_TMP/cpu.state" 60 25
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Process above threshold for 1 cycle → no alert" "pass"
else
    test_result "Process above threshold for 1 cycle → no alert" "fail"
fi

# --- Process above threshold for 5 cycles → alert fires ---
reset_test_state
set_mock_ps "1234 70.0 rclone"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ "$ALERT_LOG" == *"pid:1234"* && "$ALERT_LOG" != *"name:rclone"* ]]; then
    test_result "Process above threshold for 5 cycles → PID alert fires, name alert suppressed" "pass"
else
    test_result "Process above threshold for 5 cycles → PID alert fires, name alert suppressed" "fail"
fi

# --- PID alert passes process name as dedup group ---
reset_test_state
set_mock_ps "1234 70.0 rclone"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if echo -e "$ALERT_LOG" | grep -qE '^cpu\|pid:1234\|.*\|rclone$'; then
    test_result "PID alert passes process name as dedup group" "pass"
else
    test_result "PID alert passes process name as dedup group" "fail"
fi

# --- Process drops below threshold → counter resets ---
reset_test_state
set_mock_ps "1234 70.0 rclone"
for i in {1..3}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
# Drop below threshold
set_mock_ps "1234 5.0 rclone"
cpu_sample "$TEST_TMP/cpu.state" 60 25
# Back above
set_mock_ps "1234 70.0 rclone"
cpu_sample "$TEST_TMP/cpu.state" 60 25
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Process drops below threshold → counter resets" "pass"
else
    test_result "Process drops below threshold → counter resets" "fail"
fi

# --- Process re-triggers after clearing → new alert fires ---
reset_test_state
set_mock_ps "1234 70.0 rclone"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
ALERT_LOG="" # reset log but keep alerted state in state file
# Drop below
set_mock_ps "1234 5.0 rclone"
cpu_sample "$TEST_TMP/cpu.state" 60 25
# Re-trigger
set_mock_ps "1234 70.0 rclone"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ "$ALERT_LOG" == *"pid:1234"* ]]; then
    test_result "Process re-triggers after clearing → new alert fires" "pass"
else
    test_result "Process re-triggers after clearing → new alert fires" "fail"
fi

# --- Multiple hot processes → independent tracking ---
reset_test_state
set_mock_ps "1234 70.0 rclone
5678 80.0 firefox"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ "$ALERT_LOG" == *"rclone"* && "$ALERT_LOG" == *"firefox"* ]]; then
    test_result "Multiple hot processes → independent tracking" "pass"
else
    test_result "Multiple hot processes → independent tracking" "fail"
fi

# --- Same process name, rotating PIDs → name table alerts ---
reset_test_state
for i in {1..5}; do
    # Different PID each cycle, same name
    set_mock_ps "$((1000 + i)) 70.0 crasher"
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ "$ALERT_LOG" == *"name:crasher"* ]]; then
    test_result "Same process name, rotating PIDs → name table alerts" "pass"
else
    test_result "Same process name, rotating PIDs → name table alerts" "fail"
fi

# --- Name alert passes process name as dedup group ---
reset_test_state
for i in {1..5}; do
    set_mock_ps "$((1000 + i)) 70.0 crasher"
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if echo -e "$ALERT_LOG" | grep -qE '^cpu\|name:crasher\|.*\|crasher$'; then
    test_result "Name alert passes process name as dedup group" "pass"
else
    test_result "Name alert passes process name as dedup group" "fail"
fi

# --- Same PID, name changes → PID table still accumulates ---
reset_test_state
set_mock_ps "9999 70.0 starter"
cpu_sample "$TEST_TMP/cpu.state" 60 25
cpu_sample "$TEST_TMP/cpu.state" 60 25
# Process exec()s into different binary
set_mock_ps "9999 70.0 worker"
cpu_sample "$TEST_TMP/cpu.state" 60 25
cpu_sample "$TEST_TMP/cpu.state" 60 25
cpu_sample "$TEST_TMP/cpu.state" 60 25
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ "$ALERT_LOG" == *"pid:9999"* ]]; then
    test_result "Same PID, name changes → PID table still accumulates" "pass"
else
    test_result "Same PID, name changes → PID table still accumulates" "fail"
fi

# --- State file missing (cold start) → starts fresh ---
reset_test_state
rm -f "$TEST_TMP/cpu.state"
set_mock_ps "1234 70.0 rclone"
cpu_sample "$TEST_TMP/cpu.state" 60 25
if [[ -f "$TEST_TMP/cpu.state" ]]; then
    test_result "State file missing (cold start) → starts fresh, creates state" "pass"
else
    test_result "State file missing (cold start) → starts fresh, creates state" "fail"
fi

# --- State file corrupt → starts fresh ---
reset_test_state
echo "garbage:::corrupt::data" > "$TEST_TMP/cpu.state"
set_mock_ps "1234 70.0 rclone"
cpu_sample "$TEST_TMP/cpu.state" 60 25
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "State file corrupt → starts fresh, no crash" "pass"
else
    test_result "State file corrupt → starts fresh, no crash" "fail"
fi

# --- Deduplication: same process doesn't spam alerts ---
reset_test_state
set_mock_ps "1234 70.0 rclone"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
local_alert_count=$(echo -e "$ALERT_LOG" | grep -c "pid:1234" || true)
# Run more cycles and check again
for i in {1..3}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
ALERT_LOG=""
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Deduplication: alerted process doesn't re-alert while still hot" "pass"
else
    test_result "Deduplication: alerted process doesn't re-alert while still hot" "fail"
fi

# --- Per-process sustained cycles override ---
reset_test_state
declare -gA CPU_SUSTAINED_OVERRIDES=([slowburn]=10)
set_mock_ps "1234 70.0 slowburn"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Per-process override: 5 cycles not enough when override is 10" "pass"
else
    test_result "Per-process override: 5 cycles not enough when override is 10" "fail"
fi
# Continue to 10 cycles
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ "$ALERT_LOG" == *"slowburn"* ]]; then
    test_result "Per-process override: alerts after reaching override threshold (10)" "pass"
else
    test_result "Per-process override: alerts after reaching override threshold (10)" "fail"
fi
unset CPU_SUSTAINED_OVERRIDES

# --- Total-CPU threshold: process below per-core but above total → alert ---
# With _NPROC=4, total threshold = 25 * 4 = 100 in pidstat terms
# Process at 40% per-core (below 60%) but imagine higher total scenario:
# Test with process at 120% (multi-threaded), below per-core in a sense but above total threshold
reset_test_state
set_mock_ps "2222 120.0 compiler"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 200 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ "$ALERT_LOG" == *"compiler"* ]]; then
    test_result "Total-CPU threshold: process above total threshold (120% > 100%) → alert" "pass"
else
    test_result "Total-CPU threshold: process above total threshold (120% > 100%) → alert" "fail"
fi

# --- Total-CPU threshold: process below both thresholds → no alert ---
reset_test_state
set_mock_ps "3333 80.0 builder"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 200 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Total-CPU threshold: process below both thresholds (80% < 100%, 80% < 200%) → no alert" "pass"
else
    test_result "Total-CPU threshold: process below both thresholds (80% < 100%, 80% < 200%) → no alert" "fail"
fi

# ── Journal Monitor Tests ─────────────────────────────────────────────

echo ""
echo "=== Journal Monitor Tests ==="
echo ""

# --- No OOM events → no alert ---
reset_test_state
_JOURNAL_CMD="_mock_journal_empty"
_mock_journal_empty() { echo ""; }
journal_check "$TEST_TMP/journal.cursor" "2 minutes"
if [[ -z "$ALERT_LOG" ]]; then
    test_result "No OOM events → no alert" "pass"
else
    test_result "No OOM events → no alert" "fail"
fi

# --- OOM kill detected → alert with process name ---
reset_test_state
_JOURNAL_CMD="_mock_journal_oom"
_mock_journal_oom() {
    echo '{"__CURSOR":"cursor1","MESSAGE":"Killed process 1234 (rclone) total-vm:2048000kB","_SYSTEMD_UNIT":"user@1000.service"}'
}
journal_check "$TEST_TMP/journal.cursor" "2 minutes"
if [[ "$ALERT_LOG" == *"oom"* && "$ALERT_LOG" == *"rclone"* ]]; then
    test_result "OOM kill detected → alert with process name" "pass"
else
    test_result "OOM kill detected → alert with process name" "fail"
fi

# --- OOM alert passes alert key as dedup group ---
reset_test_state
_JOURNAL_CMD="_mock_journal_oom"
journal_check "$TEST_TMP/journal.cursor" "2 minutes"
if echo -e "$ALERT_LOG" | grep -qE '^oom\|oom:rclone\|.*\|oom:rclone$'; then
    test_result "OOM alert passes alert key as dedup group" "pass"
else
    test_result "OOM alert passes alert key as dedup group" "fail"
fi

# --- memory.max hit detected → alert with service name ---
reset_test_state
_JOURNAL_CMD="_mock_journal_memmax"
_mock_journal_memmax() {
    echo '{"__CURSOR":"cursor2","MESSAGE":"memory.max limit exceeded for /user.slice/user-1000.slice","_SYSTEMD_UNIT":"gdrive-lt.service"}'
}
journal_check "$TEST_TMP/journal.cursor" "2 minutes"
if [[ "$ALERT_LOG" == *"memmax"* && "$ALERT_LOG" == *"gdrive-lt"* ]]; then
    test_result "memory.max hit detected → alert with service name" "pass"
else
    test_result "memory.max hit detected → alert with service name" "fail"
fi

# --- Cursor tracking: cursor file updated ---
reset_test_state
_JOURNAL_CMD="_mock_journal_oom"
journal_check "$TEST_TMP/journal.cursor" "2 minutes"
if [[ -f "$TEST_TMP/journal.cursor" ]] && [[ "$(cat "$TEST_TMP/journal.cursor")" == "cursor1" ]]; then
    test_result "Journal cursor file updated after processing" "pass"
else
    test_result "Journal cursor file updated after processing" "fail"
fi

# --- Cursor file missing → scans recent window (no crash) ---
reset_test_state
rm -f "$TEST_TMP/journal.cursor"
_JOURNAL_CMD="_mock_journal_empty"
journal_check "$TEST_TMP/journal.cursor" "2 minutes"
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Journal cursor file missing → scans recent window, no crash" "pass"
else
    test_result "Journal cursor file missing → scans recent window, no crash" "fail"
fi

# --- Self-feed filter: own journal entries are ignored ---
reset_test_state
_JOURNAL_CMD="_mock_journal_self_feed"
_mock_journal_self_feed() {
    # Simulate anomalous-mon's own alert output appearing in the journal
    echo '{"__CURSOR":"cursor3","MESSAGE":"[ALERT] oom: OOM kill detected: unknown — gdrive-lt.service: Failed with result oom-kill.","_SYSTEMD_USER_UNIT":"anomalous-mon.service"}'
}
journal_check "$TEST_TMP/journal.cursor" "2 minutes" "$TEST_TMP/oom.alerts" 1800
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Self-feed filter: own journal entries are ignored" "pass"
else
    test_result "Self-feed filter: own journal entries are ignored" "fail"
fi

# --- OOM cooldown: duplicate OOM within cooldown is suppressed ---
reset_test_state
_JOURNAL_CMD="_mock_journal_oom"
journal_check "$TEST_TMP/journal.cursor" "2 minutes" "$TEST_TMP/oom.alerts" 1800
first_oom="$ALERT_LOG"
ALERT_LOG=""
_ACTIVE_ALERTS=()
rm -f "$TEST_TMP/journal.cursor"
journal_check "$TEST_TMP/journal.cursor" "2 minutes" "$TEST_TMP/oom.alerts" 1800
if [[ -n "$first_oom" && -z "$ALERT_LOG" ]]; then
    test_result "OOM cooldown: duplicate OOM within cooldown is suppressed" "pass"
else
    test_result "OOM cooldown: duplicate OOM within cooldown is suppressed" "fail"
fi

# --- OOM cooldown: alert fires again after cooldown expires ---
reset_test_state
_JOURNAL_CMD="_mock_journal_oom"
journal_check "$TEST_TMP/journal.cursor" "2 minutes" "$TEST_TMP/oom.alerts" 1800
ALERT_LOG=""
_ACTIVE_ALERTS=()
rm -f "$TEST_TMP/journal.cursor"
# Backdate the alert state to simulate cooldown expiry
sed -i 's/:[0-9]*$/:1000000000/' "$TEST_TMP/oom.alerts"
journal_check "$TEST_TMP/journal.cursor" "2 minutes" "$TEST_TMP/oom.alerts" 1800
if [[ "$ALERT_LOG" == *"rclone"* ]]; then
    test_result "OOM cooldown: alert fires again after cooldown expires" "pass"
else
    test_result "OOM cooldown: alert fires again after cooldown expires" "fail"
fi

# ── Notification Tests ────────────────────────────────────────────────

echo ""
echo "=== Notification Tests ==="
echo ""

# --- send_alert records alert ---
reset_test_state
send_alert "cpu" "test:key1" "Test message"
if [[ "$ALERT_LOG" == *"test:key1"* ]]; then
    test_result "send_alert records alert with key and message" "pass"
else
    test_result "send_alert records alert with key and message" "fail"
fi

# --- Duplicate alert suppressed ---
reset_test_state
send_alert "cpu" "test:dup" "First alert"
ALERT_LOG=""
send_alert "cpu" "test:dup" "Second alert" || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Duplicate alert for same key is suppressed" "pass"
else
    test_result "Duplicate alert for same key is suppressed" "fail"
fi

# --- clear_alert allows re-notification ---
reset_test_state
send_alert "cpu" "test:clear" "First"
ALERT_LOG=""
clear_alert "test:clear"
send_alert "cpu" "test:clear" "Second"
if [[ "$ALERT_LOG" == *"test:clear"* ]]; then
    test_result "clear_alert allows re-notification for same key" "pass"
else
    test_result "clear_alert allows re-notification for same key" "fail"
fi

# --- is_alert_active works ---
reset_test_state
send_alert "cpu" "test:active" "msg"
if is_alert_active "test:active"; then
    test_result "is_alert_active returns true for active alert" "pass"
else
    test_result "is_alert_active returns true for active alert" "fail"
fi

if ! is_alert_active "test:nonexistent"; then
    test_result "is_alert_active returns false for no alert" "pass"
else
    test_result "is_alert_active returns false for no alert" "fail"
fi

# --- Notification body includes compact timestamp ---
reset_test_state
NOTIFY_LOG=""
# Override notify-send to capture the body
notify-send() {
    # Args: -u urgency -i icon summary body
    shift 4  # skip -u critical -i icon
    shift 1  # skip summary
    NOTIFY_LOG="$1"
}
# Call the real send_alert from notify.sh (not our test wrapper)
_ACTIVE_ALERTS=()
source "$PROJECT_DIR/lib/notify.sh"
send_alert "cpu" "test:ts" "Test message"
# Restore test send_alert wrapper
eval "$_orig_send_alert"
send_alert() {
    local type="$1" key="$2" message="$3" group="${4:-}"
    if [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]; then
        return 1
    fi
    _ACTIVE_ALERTS[$key]=1
    ALERT_LOG="${ALERT_LOG}${type}|${key}|${message}|${group}\n"
    return 0
}
# Check that the notification body starts with a timestamp like [HH:MM]
if [[ "$NOTIFY_LOG" =~ ^\[[0-2][0-9]:[0-5][0-9]\]\  ]]; then
    test_result "Notification body includes compact [HH:MM] timestamp" "pass"
else
    test_result "Notification body includes compact [HH:MM] timestamp" "fail"
fi

# ── Grouped Notification Tests ────────────────────────────────────────
#
# These tests exercise the real send_alert from lib/notify.sh (not the test
# mock wrapper). They mock notify-send itself to capture the argv of each
# invocation and return fake incrementing ids when -p is present.

echo ""
echo "=== Grouped Notification Tests ==="
echo ""

setup_real_notify_test() {
    # send_alert's grouped path invokes notify-send in $(...) command
    # substitution, so shell-variable updates in the mock don't propagate
    # back to the parent. Capture calls in files instead.
    NOTIFY_CALLS_FILE="$TEST_TMP/notify-calls.log"
    NOTIFY_ID_COUNTER_FILE="$TEST_TMP/notify-id-counter"
    rm -f "$NOTIFY_CALLS_FILE" "$NOTIFY_ID_COUNTER_FILE"
    NOTIFY_ID_FILE="$TEST_TMP/notify-ids"
    rm -f "$NOTIFY_ID_FILE"
    # Re-source real notify.sh (clobbers test wrapper)
    source "$PROJECT_DIR/lib/notify.sh"
    _ACTIVE_ALERTS=()
    # Capture notify-send argv; emit incrementing id when -p is present
    notify-send() {
        local has_p=0 joined=""
        local a
        for a in "$@"; do
            joined="${joined}${joined:+||}${a}"
            [[ "$a" == "-p" ]] && has_p=1
        done
        echo "$joined" >> "$NOTIFY_CALLS_FILE"
        if (( has_p )); then
            local next=1000
            if [[ -f "$NOTIFY_ID_COUNTER_FILE" ]]; then
                next=$(( $(cat "$NOTIFY_ID_COUNTER_FILE") + 1 ))
            fi
            echo "$next" > "$NOTIFY_ID_COUNTER_FILE"
            echo "$next"
        fi
    }
}

# Read the Nth captured notify-send invocation (1-indexed).
_notify_call() {
    sed -n "${1}p" "$NOTIFY_CALLS_FILE" 2>/dev/null || true
}

# Latest notify id emitted (or empty if no -p calls yet).
_notify_last_id() {
    cat "$NOTIFY_ID_COUNTER_FILE" 2>/dev/null || true
}

teardown_real_notify_test() {
    unset -f notify-send 2>/dev/null || true
    unset NOTIFY_ID_FILE
    # Restore test send_alert wrapper
    eval "$_orig_send_alert"
    send_alert() {
        local type="$1" key="$2" message="$3" group="${4:-}"
        if [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]; then
            return 1
        fi
        _ACTIVE_ALERTS[$key]=1
        ALERT_LOG="${ALERT_LOG}${type}|${key}|${message}|${group}\n"
        return 0
    }
}

# --- Ungrouped alert: notify-send called without -p or -r ---
setup_real_notify_test
send_alert "cpu" "pid:999" "Test message" >/dev/null
call1="$(_notify_call 1)"
if [[ "$call1" != *"||-p"* ]] && [[ "$call1" != *"||-r||"* ]]; then
    test_result "Ungrouped alert: notify-send invoked without -p or -r" "pass"
else
    test_result "Ungrouped alert: notify-send invoked without -p or -r" "fail"
fi
teardown_real_notify_test

# --- Grouped alert first call: -p present, -r absent ---
setup_real_notify_test
send_alert "cpu" "pid:111" "Python 1 hot" "python" >/dev/null
call1="$(_notify_call 1)"
if [[ "$call1" == *"||-p||"* ]] && [[ "$call1" != *"||-r||"* ]]; then
    test_result "Grouped first call: -p present, -r absent" "pass"
else
    test_result "Grouped first call: -p present, -r absent" "fail"
fi
teardown_real_notify_test

# --- Grouped alert second call: -r carries stored id ---
setup_real_notify_test
send_alert "cpu" "pid:111" "Python 1 hot" "python" >/dev/null
first_id="$(_notify_last_id)"
send_alert "cpu" "pid:112" "Python 2 hot" "python" >/dev/null
call2="$(_notify_call 2)"
if [[ "$call2" == *"||-r||${first_id}||"* ]]; then
    test_result "Grouped second call: -r carries stored id" "pass"
else
    test_result "Grouped second call: -r carries stored id" "fail"
fi
teardown_real_notify_test

# --- Grouped alerts for different groups: independent replace-ids ---
setup_real_notify_test
send_alert "cpu" "pid:111" "Python 1" "python" >/dev/null
python_id="$(_notify_last_id)"
send_alert "cpu" "pid:222" "Firefox 1" "firefox" >/dev/null
firefox_id="$(_notify_last_id)"
send_alert "cpu" "pid:112" "Python 2" "python" >/dev/null
call3="$(_notify_call 3)"
if [[ "$call3" == *"||-r||${python_id}||"* ]] && [[ "${python_id}" != "${firefox_id}" ]]; then
    test_result "Grouped: independent replace-ids per group" "pass"
else
    test_result "Grouped: independent replace-ids per group" "fail"
fi
teardown_real_notify_test

# --- Grouped alert persists id to NOTIFY_ID_FILE ---
setup_real_notify_test
send_alert "cpu" "pid:111" "Python 1" "python" >/dev/null
stored_id="$(_notify_last_id)"
if [[ -f "$NOTIFY_ID_FILE" ]] && grep -qE "^python	${stored_id}$" "$NOTIFY_ID_FILE"; then
    test_result "Grouped alert persists id to NOTIFY_ID_FILE" "pass"
else
    test_result "Grouped alert persists id to NOTIFY_ID_FILE" "fail"
fi
teardown_real_notify_test

# --- Grouped alert loads existing id from NOTIFY_ID_FILE ---
setup_real_notify_test
# Prepopulate the file as if a prior anomalous-mon run left it there
printf 'python\t7777\n' > "$NOTIFY_ID_FILE"
send_alert "cpu" "pid:999" "Python after restart" "python" >/dev/null
call1="$(_notify_call 1)"
if [[ "$call1" == *"||-r||7777||"* ]]; then
    test_result "Grouped alert loads existing id from NOTIFY_ID_FILE" "pass"
else
    test_result "Grouped alert loads existing id from NOTIFY_ID_FILE" "fail"
fi
teardown_real_notify_test

# --- Grouped alert always emits [ALERT] log line (not suppressed by in-memory dedup) ---
setup_real_notify_test
log1="$(send_alert "cpu" "pid:111" "Python 1" "python")"
log2="$(send_alert "cpu" "pid:112" "Python 2" "python")"
if [[ "$log1" == *"[ALERT]"*"Python 1"* ]] && [[ "$log2" == *"[ALERT]"*"Python 2"* ]]; then
    test_result "Grouped alerts always emit [ALERT] log line" "pass"
else
    test_result "Grouped alerts always emit [ALERT] log line" "fail"
fi
teardown_real_notify_test

# ── Integration Tests ─────────────────────────────────────────────────

echo ""
echo "=== Integration Tests ==="
echo ""

# --- Config file overrides defaults ---
reset_test_state
source "$PROJECT_DIR/etc/anomalous-mon.conf"
if [[ "$CPU_THRESHOLD" == "60" && "$CPU_THRESHOLD_TOTAL" == "25" && "$CPU_SUSTAINED_CYCLES" == "5" ]]; then
    test_result "Config file loads with correct defaults" "pass"
else
    test_result "Config file loads with correct defaults" "fail"
fi

# --- Full cycle: sample → detect → alert → clear ---
reset_test_state
set_mock_ps "7777 90.0 runaway"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
first_alert="$ALERT_LOG"
# Goes cold
set_mock_ps "7777 1.0 runaway"
cpu_sample "$TEST_TMP/cpu.state" 60 25
ALERT_LOG=""
# Re-heats
set_mock_ps "7777 90.0 runaway"
for i in {1..5}; do
    cpu_sample "$TEST_TMP/cpu.state" 60 25
done
cpu_check_alerts "$TEST_TMP/cpu.state" 5 || true
if [[ -n "$first_alert" && -n "$ALERT_LOG" ]]; then
    test_result "Full cycle: sample → detect → alert → clear → re-alert" "pass"
else
    test_result "Full cycle: sample → detect → alert → clear → re-alert" "fail"
fi

# --- Project structure exists ---
for f in bin lib etc test; do
    if [[ -d "$PROJECT_DIR/$f" ]]; then
        test_result "Directory $f/ exists" "pass"
    else
        test_result "Directory $f/ exists" "fail"
    fi
done

for f in lib/cpu-monitor.sh lib/journal-monitor.sh lib/notify.sh etc/anomalous-mon.conf; do
    if [[ -f "$PROJECT_DIR/$f" ]]; then
        test_result "File $f exists" "pass"
    else
        test_result "File $f exists" "fail"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "  Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_TOTAL} total"
echo "════════════════════════════════════════"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
