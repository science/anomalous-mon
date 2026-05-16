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

# Wrap send_alert_action similarly so stale-files tests don't spawn real
# systemd-run units. Logs to ALERT_LOG as: type|key|message|action:<label>:<cmd>
_orig_send_alert_action="$(declare -f send_alert_action 2>/dev/null || true)"
send_alert_action() {
    local type="$1" key="$2" message="$3" label="$4" action_cmd="$5"

    if [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]; then
        return 1
    fi
    _ACTIVE_ALERTS[$key]=1

    ALERT_LOG="${ALERT_LOG}${type}|${key}|${message}|action:${label}:${action_cmd}\n"
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

# ── Disk Monitor Tests ────────────────────────────────────────────────

echo ""
echo "=== Disk Monitor Tests ==="
echo ""

source "$PROJECT_DIR/lib/disk-monitor.sh"

# Mock df output. Format per line: target fstype pcent avail_kb
set_mock_disk() {
    _DISK_SAMPLE_CMD="_mock_disk_output"
    _MOCK_DISK_DATA="$*"
}

_mock_disk_output() {
    echo "$_MOCK_DISK_DATA"
}

# --- Below warn → no alert ---
reset_test_state
set_mock_disk "/ ext4 50 50000000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Disk below warn threshold → no alert" "pass"
else
    test_result "Disk below warn threshold → no alert" "fail"
fi

# --- Crosses warn + below min-free → WARN fires ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
set_mock_disk "/ ext4 85 8000000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ "$ALERT_LOG" == *"disk:/:warn"* && "$ALERT_LOG" == *"WARN"* ]]; then
    test_result "Disk crosses warn + below min-free → WARN fires" "pass"
else
    test_result "Disk crosses warn + below min-free → WARN fires" "fail"
fi

# --- Crosses warn + plenty free → WARN suppressed (AND gate) ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
set_mock_disk "/ ext4 85 524288000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Disk crosses warn but plenty free → WARN suppressed (AND gate)" "pass"
else
    test_result "Disk crosses warn but plenty free → WARN suppressed (AND gate)" "fail"
fi

# --- Crosses critical → CRITICAL fires; WARN suppressed same tick ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
set_mock_disk "/ ext4 95 2000000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ "$ALERT_LOG" == *"disk:/:critical"* && "$ALERT_LOG" == *"CRITICAL"* && "$ALERT_LOG" != *"disk:/:warn"* ]]; then
    test_result "Disk crosses critical → CRITICAL fires, WARN suppressed in same tick" "pass"
else
    test_result "Disk crosses critical → CRITICAL fires, WARN suppressed in same tick" "fail"
fi

# --- Per-mount override: /boot at 80% with 90/97 → no alert ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
declare -gA DISK_THRESHOLD_OVERRIDES=([/boot]="90:97:0.1")
set_mock_disk "/boot ext4 80 200000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Disk override: /boot at 80% with 90/97 threshold → no alert" "pass"
else
    test_result "Disk override: /boot at 80% with 90/97 threshold → no alert" "fail"
fi

# --- Per-mount override: /boot at 92% → WARN fires with overridden thresholds ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
declare -gA DISK_THRESHOLD_OVERRIDES=([/boot]="90:97:0.1")
set_mock_disk "/boot ext4 92 50000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ "$ALERT_LOG" == *"disk:/boot:warn"* ]]; then
    test_result "Disk override: /boot at 92% with overridden thresholds → WARN fires" "pass"
else
    test_result "Disk override: /boot at 92% with overridden thresholds → WARN fires" "fail"
fi
unset DISK_THRESHOLD_OVERRIDES

# --- Cooldown dedup: back-to-back CRITICAL → one alert ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
set_mock_disk "/ ext4 95 2000000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
first_disk="$ALERT_LOG"
ALERT_LOG=""
_ACTIVE_ALERTS=()
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ -n "$first_disk" && -z "$ALERT_LOG" ]]; then
    test_result "Disk cooldown: duplicate within cooldown is suppressed" "pass"
else
    test_result "Disk cooldown: duplicate within cooldown is suppressed" "fail"
fi

# --- Cooldown: alert fires again after cooldown expires ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
set_mock_disk "/ ext4 95 2000000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
ALERT_LOG=""
_ACTIVE_ALERTS=()
# Backdate the alert state to simulate cooldown expiry
sed -i 's/:[0-9]*$/:1000000000/' "$TEST_TMP/disk.alerts"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ "$ALERT_LOG" == *"disk:/:critical"* ]]; then
    test_result "Disk cooldown: alert fires again after cooldown expires" "pass"
else
    test_result "Disk cooldown: alert fires again after cooldown expires" "fail"
fi

# --- Fstype filter: excluded fstypes never alert ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
set_mock_disk "/snap/core squashfs 99 100
/run tmpfs 99 1000
/dev devtmpfs 99 1000"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Disk fstype filter: excluded fstypes ignored even at 99%" "pass"
else
    test_result "Disk fstype filter: excluded fstypes ignored even at 99%" "fail"
fi

# --- Empty df output → no crash, no alert ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
set_mock_disk ""
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Disk empty df output → no crash, no alert" "pass"
else
    test_result "Disk empty df output → no crash, no alert" "fail"
fi

# --- Garbage df line (missing columns) → skipped, no crash ---
reset_test_state
rm -f "$TEST_TMP/disk.alerts"
set_mock_disk "garbage_line_missing_columns"
disk_check "$TEST_TMP/disk.alerts" 80 92 10 1800 300 2>/dev/null || true
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Disk garbage df line → skipped, no crash" "pass"
else
    test_result "Disk garbage df line → skipped, no crash" "fail"
fi

# Reset _DISK_SAMPLE_CMD so later tests don't pick it up
unset _DISK_SAMPLE_CMD

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

# ── send_alert_action Tests ───────────────────────────────────────────
#
# send_alert_action spawns a transient systemd-run scope that wraps
# notify-send --wait, so user clicks survive the parent script exit.
# We mock both systemd-run and notify-send to capture their invocations.

echo ""
echo "=== send_alert_action Tests ==="
echo ""

setup_action_test() {
    SYSTEMD_RUN_CALLS_FILE="$TEST_TMP/systemd-run-calls.log"
    NOTIFY_CALLS_FILE="$TEST_TMP/notify-calls.log"
    rm -f "$SYSTEMD_RUN_CALLS_FILE" "$NOTIFY_CALLS_FILE"
    NOTIFY_ID_FILE="$TEST_TMP/notify-ids"
    rm -f "$NOTIFY_ID_FILE"
    source "$PROJECT_DIR/lib/notify.sh"
    _ACTIVE_ALERTS=()

    # Mock systemd-run: capture argv (one call per file line; args joined by ||).
    # Embedded newlines in args (e.g. the bash -c script) are escaped to '\n'
    # so each invocation occupies exactly one line.
    systemd-run() {
        local joined=""
        local a
        for a in "$@"; do
            a="${a//$'\n'/\\n}"
            joined="${joined}${joined:+||}${a}"
        done
        printf '%s\n' "$joined" >> "$SYSTEMD_RUN_CALLS_FILE"
    }

    # Mock notify-send the same way the grouped tests do.
    notify-send() {
        local joined=""
        local a
        for a in "$@"; do
            a="${a//$'\n'/\\n}"
            joined="${joined}${joined:+||}${a}"
        done
        printf '%s\n' "$joined" >> "$NOTIFY_CALLS_FILE"
    }

    # Mock command lookup so the lib detects systemd-run as available.
    command() {
        if [[ "$1" == "-v" && "$2" == "systemd-run" ]]; then
            echo "/usr/bin/systemd-run"
            return 0
        fi
        builtin command "$@"
    }
}

teardown_action_test() {
    unset -f systemd-run notify-send command 2>/dev/null || true
    unset SYSTEMD_RUN_CALLS_FILE
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
    # Restore the test wrapper for send_alert_action too
    send_alert_action() {
        local type="$1" key="$2" message="$3" label="$4" action_cmd="$5"
        if [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]]; then
            return 1
        fi
        _ACTIVE_ALERTS[$key]=1
        ALERT_LOG="${ALERT_LOG}${type}|${key}|${message}|action:${label}:${action_cmd}\n"
        return 0
    }
}

# --- send_alert_action emits [ALERT] log line ---
setup_action_test
log="$(send_alert_action "stale-files" "stale:1" "Test message" "Open" "xdg-open /tmp/x")"
if [[ "$log" == *"[ALERT] stale-files: Test message"* ]]; then
    test_result "send_alert_action: emits [ALERT] log line" "pass"
else
    test_result "send_alert_action: emits [ALERT] log line" "fail"
fi
teardown_action_test

# --- send_alert_action invokes systemd-run when available ---
setup_action_test
send_alert_action "stale-files" "stale:2" "Test message" "Open report" "xdg-open /tmp/x" >/dev/null
call="$(cat "$SYSTEMD_RUN_CALLS_FILE" 2>/dev/null || true)"
if [[ "$call" == *"systemd-run"* || "$call" == *"--user"* ]] \
    && [[ "$call" == *"Open report"* ]] \
    && [[ "$call" == *"xdg-open /tmp/x"* ]] \
    && [[ "$call" == *"Test message"* ]]; then
    test_result "send_alert_action: invokes systemd-run with label, message, ACTION_CMD" "pass"
else
    test_result "send_alert_action: invokes systemd-run with label, message, ACTION_CMD" "fail"
fi
teardown_action_test

# --- send_alert_action in-memory dedup: same key not spawned twice ---
setup_action_test
send_alert_action "stale-files" "stale:dup" "First" "Open" "true" >/dev/null || true
send_alert_action "stale-files" "stale:dup" "Second" "Open" "true" >/dev/null || true
calls=$(wc -l < "$SYSTEMD_RUN_CALLS_FILE" 2>/dev/null || echo 0)
if (( calls == 1 )); then
    test_result "send_alert_action: in-memory dedup suppresses duplicate KEY" "pass"
else
    test_result "send_alert_action: in-memory dedup suppresses duplicate KEY" "fail"
fi
teardown_action_test

# --- send_alert_action fallback when systemd-run missing ---
setup_action_test
# Override command -v to deny systemd-run
command() {
    if [[ "$1" == "-v" && "$2" == "systemd-run" ]]; then
        return 1
    fi
    builtin command "$@"
}
send_alert_action "stale-files" "stale:nofallback" "Test fallback" "Open" "xdg-open /tmp/x" >/dev/null
# systemd-run should NOT have been called
sr_calls=$(wc -l < "$SYSTEMD_RUN_CALLS_FILE" 2>/dev/null || echo 0)
# notify-send SHOULD have been called (the fallback path)
ns_calls=$(wc -l < "$NOTIFY_CALLS_FILE" 2>/dev/null || echo 0)
if (( sr_calls == 0 )) && (( ns_calls == 1 )); then
    test_result "send_alert_action: falls back to plain notify-send when systemd-run absent" "pass"
else
    test_result "send_alert_action: falls back to plain notify-send when systemd-run absent" "fail"
fi
teardown_action_test

# ── Stale Files Monitor Tests ─────────────────────────────────────────

echo ""
echo "=== Stale Files Monitor Tests ==="
echo ""

source "$PROJECT_DIR/lib/stale-files-monitor.sh"

# Mock find output. Format per line: size_bytes<TAB>mtime_epoch<TAB>path
# Usage: set_mock_stale "2147483648	1700000000	/path/a" "1073741824	1690000000	/path/b"
set_mock_stale() {
    _STALE_FILES_SCAN_CMD="_mock_stale_output"
    _MOCK_STALE_DATA="$(printf '%s\n' "$@")"
}

_mock_stale_output() {
    [[ -n "${_MOCK_STALE_DATA:-}" ]] && printf '%s\n' "$_MOCK_STALE_DATA"
}

reset_stale_state() {
    reset_test_state
    unset _STALE_FILES_SCAN_CMD _MOCK_STALE_DATA _STALE_FINDMNT_CMD _MOCK_FINDMNT_DATA
    unset STALE_FILES_IGNORE STALE_FILES_ROOTS
    STALE_FILES_IGNORE=()
    STALE_FILES_ROOTS=("$TEST_TMP")
    STALE_FILES_MIN_SIZE_GB=1
    STALE_FILES_AGE_DAYS=180
    STALE_FILES_ACK_TTL=90
    STALE_FILES_MAX_REPORT_ENTRIES=50
    STALE_FILES_FSTYPE_EXCLUDE='fuse\..*|nfs.*|cifs|smbfs|virtiofs|sshfs|gvfs|davfs'
    rm -f "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
}

# --- Empty scan → no alert, last-scan timestamp written ---
reset_stale_state
set_mock_stale ""
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
if [[ -z "$ALERT_LOG" && -f "$TEST_TMP/stale.last-scan" ]]; then
    test_result "Stale empty scan → no alert, last-scan updated" "pass"
else
    test_result "Stale empty scan → no alert, last-scan updated" "fail"
fi

# --- Non-empty scan → exactly one summary alert with count and total ---
reset_stale_state
set_mock_stale \
    "2147483648	1700000000	/home/steve/iso/old.iso" \
    "1073741824	1690000000	/home/steve/vm/dev.qcow2"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
# Exactly one alert line, mentions count "2" and "stale-files" type
alert_count=$(echo -e "$ALERT_LOG" | grep -c "^stale-files|" || true)
if (( alert_count == 1 )) && [[ "$ALERT_LOG" == *"2 large stale files"* ]]; then
    test_result "Stale non-empty scan → exactly one summary alert (count, total)" "pass"
else
    test_result "Stale non-empty scan → exactly one summary alert (count, total)" "fail"
fi

# --- Config ignore (prefix-style) filters whole subtree ---
reset_stale_state
STALE_FILES_IGNORE=("/home/steve/.cache")
set_mock_stale \
    "2147483648	1700000000	/home/steve/.cache/big.dat" \
    "1073741824	1690000000	/home/steve/vm/keep.qcow2"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
# Only the qcow2 should remain in the alert (1 file)
if [[ "$ALERT_LOG" == *"1 large stale files"* ]] && [[ -f "$TEST_TMP/stale.report" ]] \
    && ! grep -q '.cache/big.dat' "$TEST_TMP/stale.report" \
    && grep -q 'vm/keep.qcow2' "$TEST_TMP/stale.report"; then
    test_result "Stale ignore (prefix): subtree filtered out" "pass"
else
    test_result "Stale ignore (prefix): subtree filtered out" "fail"
fi

# --- Config ignore (glob) filters matching paths ---
reset_stale_state
STALE_FILES_IGNORE=("/home/steve/iso/*.iso")
set_mock_stale \
    "2147483648	1700000000	/home/steve/iso/ubuntu.iso" \
    "1073741824	1690000000	/home/steve/iso/dvd.img"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
# Only the .img should remain (1 file)
if [[ "$ALERT_LOG" == *"1 large stale files"* ]] \
    && grep -q 'dvd.img' "$TEST_TMP/stale.report" \
    && ! grep -q 'ubuntu.iso' "$TEST_TMP/stale.report"; then
    test_result "Stale ignore (glob): matching paths filtered out" "pass"
else
    test_result "Stale ignore (glob): matching paths filtered out" "fail"
fi

# --- All files filtered → no alert ---
reset_stale_state
STALE_FILES_IGNORE=("/home/steve/iso")
set_mock_stale \
    "2147483648	1700000000	/home/steve/iso/ubuntu.iso" \
    "1073741824	1690000000	/home/steve/iso/dvd.img"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
if [[ -z "$ALERT_LOG" ]]; then
    test_result "Stale ignore: all filtered → no alert" "pass"
else
    test_result "Stale ignore: all filtered → no alert" "fail"
fi

# --- Ack filters specific path ---
reset_stale_state
now_ts="$(date +%s)"
printf '%s\t%s\n' "$now_ts" "/home/steve/iso/ubuntu.iso" > "$TEST_TMP/stale.acks"
set_mock_stale \
    "2147483648	1700000000	/home/steve/iso/ubuntu.iso" \
    "1073741824	1690000000	/home/steve/vm/dev.qcow2"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
if [[ "$ALERT_LOG" == *"1 large stale files"* ]] \
    && ! grep -q 'ubuntu.iso' "$TEST_TMP/stale.report" \
    && grep -q 'dev.qcow2' "$TEST_TMP/stale.report"; then
    test_result "Stale ack: acked path filtered, others remain" "pass"
else
    test_result "Stale ack: acked path filtered, others remain" "fail"
fi

# --- Ack TTL expiry: stale ack drops, path reappears ---
reset_stale_state
expired_ts=$(( $(date +%s) - 100 * 86400 ))   # 100 days ago, > TTL of 90
printf '%s\t%s\n' "$expired_ts" "/home/steve/iso/ubuntu.iso" > "$TEST_TMP/stale.acks"
set_mock_stale "2147483648	1700000000	/home/steve/iso/ubuntu.iso"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
# File should NOT be filtered (ack expired), AND ack file should no longer contain that path
if [[ "$ALERT_LOG" == *"1 large stale files"* ]] \
    && grep -q 'ubuntu.iso' "$TEST_TMP/stale.report" \
    && ! grep -q 'ubuntu.iso' "$TEST_TMP/stale.acks"; then
    test_result "Stale ack TTL: expired ack drops, path reappears, ack file pruned" "pass"
else
    test_result "Stale ack TTL: expired ack drops, path reappears, ack file pruned" "fail"
fi

# --- stale_files_ack appends entry; stale_files_unack removes it ---
reset_stale_state
rm -f "$TEST_TMP/stale.acks"
stale_files_ack "$TEST_TMP/stale.acks" "/home/steve/big.iso"
if [[ -f "$TEST_TMP/stale.acks" ]] && grep -qF '/home/steve/big.iso' "$TEST_TMP/stale.acks"; then
    test_result "stale_files_ack: appends path to ack file" "pass"
else
    test_result "stale_files_ack: appends path to ack file" "fail"
fi
stale_files_unack "$TEST_TMP/stale.acks" "/home/steve/big.iso"
if ! grep -qF '/home/steve/big.iso' "$TEST_TMP/stale.acks" 2>/dev/null; then
    test_result "stale_files_unack: removes path from ack file" "pass"
else
    test_result "stale_files_unack: removes path from ack file" "fail"
fi

# --- ack file with corrupt lines: starts fresh, no crash ---
reset_stale_state
printf 'garbage\nno-tab-here\nbad:line\n' > "$TEST_TMP/stale.acks"
set_mock_stale "2147483648	1700000000	/home/steve/iso/keep.iso"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
if [[ "$ALERT_LOG" == *"1 large stale files"* ]]; then
    test_result "Stale ack: corrupt ack file tolerated, scan proceeds" "pass"
else
    test_result "Stale ack: corrupt ack file tolerated, scan proceeds" "fail"
fi

# --- Mount-prune: FUSE/nfs mounts under root pruned; ext4 not pruned ---
set_mock_findmnt() {
    _STALE_FINDMNT_CMD="_mock_findmnt_output"
    _MOCK_FINDMNT_DATA="$(printf '%s\n' "$@")"
}
_mock_findmnt_output() {
    [[ -n "${_MOCK_FINDMNT_DATA:-}" ]] && printf '%s\n' "$_MOCK_FINDMNT_DATA"
    return 0
}

reset_stale_state
set_mock_findmnt \
    "/home/steve ext4" \
    "/home/steve/gdrive fuse.rclone" \
    "/home/steve/nfs-share nfs4" \
    "/home/steve/code ext4"
excluded="$(_stale_excluded_mounts_under "/home/steve" 2>&1 || true)"
if [[ "$excluded" == *"/home/steve/gdrive"* ]] \
    && [[ "$excluded" == *"/home/steve/nfs-share"* ]] \
    && [[ "$excluded" != *"/home/steve/code"* ]] \
    && [[ "$excluded" != "/home/steve"$'\n'* && "$excluded" != "/home/steve" ]]; then
    test_result "Stale mount-prune: fuse.* and nfs mounts excluded, ext4 retained" "pass"
else
    test_result "Stale mount-prune: fuse.* and nfs mounts excluded, ext4 retained" "fail"
fi

# --- Mount-prune: mountpoints outside scan root ignored ---
reset_stale_state
set_mock_findmnt \
    "/home/steve ext4" \
    "/mnt/external fuse.rclone" \
    "/home/steve/gdrive fuse.rclone"
excluded="$(_stale_excluded_mounts_under "/home/steve" 2>&1 || true)"
if [[ "$excluded" == *"/home/steve/gdrive"* ]] \
    && [[ "$excluded" != *"/mnt/external"* ]]; then
    test_result "Stale mount-prune: out-of-root mountpoints ignored" "pass"
else
    test_result "Stale mount-prune: out-of-root mountpoints ignored" "fail"
fi

# --- Prune-clause builder: produces -path clauses for excluded mounts ---
reset_stale_state
set_mock_findmnt \
    "/home/steve ext4" \
    "/home/steve/gdrive fuse.rclone"
_stale_build_prune_clauses "/home/steve" expr
if [[ "$expr" == *"-path"* ]] && [[ "$expr" == *"/home/steve/gdrive"* ]]; then
    test_result "Stale mount-prune: build_prune_clauses emits -path for excluded mounts" "pass"
else
    test_result "Stale mount-prune: build_prune_clauses emits -path for excluded mounts" "fail"
fi

# --- Prune-clause builder: empty when no exclusions ---
reset_stale_state
set_mock_findmnt "/home/steve ext4"
_stale_build_prune_clauses "/home/steve" expr
if [[ -z "$expr" ]]; then
    test_result "Stale mount-prune: build_prune_clauses empty when no exclusions" "pass"
else
    test_result "Stale mount-prune: build_prune_clauses empty when no exclusions" "fail"
fi

# --- Prune-clause builder: folds literal-prefix ignores into find prune list ---
reset_stale_state
set_mock_findmnt "/home/steve ext4"
STALE_FILES_IGNORE=("/home/steve/.cache" "/home/steve/*.tmp")   # 1 literal + 1 glob
_stale_build_prune_clauses "/home/steve" expr
# Literal prefix should appear; globby pattern should NOT (handled by post-filter)
if [[ "$expr" == *"/home/steve/.cache"* ]] && [[ "$expr" != *"*.tmp"* ]]; then
    test_result "Stale mount-prune: folds literal-prefix ignores, skips globs" "pass"
else
    test_result "Stale mount-prune: folds literal-prefix ignores, skips globs" "fail"
fi

# --- Report contains SIZE/AGE/PATH columns and entries are sorted desc by size ---
reset_stale_state
set_mock_stale \
    "1073741824	1690000000	/home/steve/small.bin" \
    "5368709120	1700000000	/home/steve/big.bin" \
    "2147483648	1695000000	/home/steve/med.bin"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
# Check that header row exists
if grep -qE '^  SIZE +AGE +PATH' "$TEST_TMP/stale.report"; then
    test_result "Stale report: header row SIZE/AGE/PATH present" "pass"
else
    test_result "Stale report: header row SIZE/AGE/PATH present" "fail"
fi
# Check ordering: big.bin should appear before med.bin, which appears before small.bin
big_line="$(grep -n big.bin "$TEST_TMP/stale.report" | head -1 | cut -d: -f1)"
med_line="$(grep -n med.bin "$TEST_TMP/stale.report" | head -1 | cut -d: -f1)"
small_line="$(grep -n small.bin "$TEST_TMP/stale.report" | head -1 | cut -d: -f1)"
if [[ -n "$big_line" && -n "$med_line" && -n "$small_line" ]] \
    && (( big_line < med_line )) && (( med_line < small_line )); then
    test_result "Stale report: entries sorted by size desc" "pass"
else
    test_result "Stale report: entries sorted by size desc" "fail"
fi

# --- Report cap honored when entry count exceeds STALE_FILES_MAX_REPORT_ENTRIES ---
reset_stale_state
STALE_FILES_MAX_REPORT_ENTRIES=3
mock_lines=()
for i in {1..10}; do
    # decreasing sizes so sort order is predictable
    size=$(( (11 - i) * 1073741824 ))
    mock_lines+=( "${size}	1700000000	/path/file${i}.bin" )
done
set_mock_stale "${mock_lines[@]}"
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
# Should contain exactly 3 entries; truncation note should mention 10 total
entry_count=$(grep -cE '^  [0-9]+\.[0-9]+ [GMK]?i?B  ' "$TEST_TMP/stale.report" || true)
if (( entry_count == 3 )) && grep -q "top 3 of 10" "$TEST_TMP/stale.report"; then
    test_result "Stale report: respects STALE_FILES_MAX_REPORT_ENTRIES cap" "pass"
else
    test_result "Stale report: respects STALE_FILES_MAX_REPORT_ENTRIES cap" "fail"
fi

# --- Empty scan: report still written with 'No stale files found' ---
reset_stale_state
set_mock_stale ""
stale_files_check "$TEST_TMP/stale.report" "$TEST_TMP/stale.last-scan" "$TEST_TMP/stale.acks"
if [[ -f "$TEST_TMP/stale.report" ]] && grep -q 'No stale files found' "$TEST_TMP/stale.report"; then
    test_result "Stale report: empty scan still writes report with placeholder" "pass"
else
    test_result "Stale report: empty scan still writes report with placeholder" "fail"
fi

# --- stale_files_report prints report contents ---
reset_stale_state
echo "test report contents here" > "$TEST_TMP/stale.report"
out="$(stale_files_report "$TEST_TMP/stale.report")"
if [[ "$out" == *"test report contents here"* ]]; then
    test_result "stale_files_report: prints report file contents" "pass"
else
    test_result "stale_files_report: prints report file contents" "fail"
fi

# --- stale_files_report prints message when no report exists ---
reset_stale_state
rm -f "$TEST_TMP/stale.report"
out="$(stale_files_report "$TEST_TMP/stale.report")"
if [[ "$out" == *"No stale-files report"* ]]; then
    test_result "stale_files_report: handles missing report gracefully" "pass"
else
    test_result "stale_files_report: handles missing report gracefully" "fail"
fi

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

for f in lib/cpu-monitor.sh lib/journal-monitor.sh lib/disk-monitor.sh lib/stale-files-monitor.sh lib/notify.sh etc/anomalous-mon.conf; do
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
