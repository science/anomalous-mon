#!/usr/bin/env bash
# test-live.sh — environment-dependent tests that exercise the REAL samplers
# and REAL end-to-end alerting (the things the mocked unit suite cannot cover).
#
# Unlike test-anomalous-mon.sh (pure logic, mocked I/O, runs anywhere), this:
#   • runs each default _*_sample_cmd against the live machine and asserts the
#     output is well-formed (catches pidstat/df/proc/journalctl format drift),
#   • spawns a REAL growing process and asserts a mem:runaway alert actually
#     fires through the real /proc sampler — reading the alert text back,
#   • runs a REAL OOM inside a runcapped scope and asserts it is contained.
#
# It is NOT run by default (needs pidstat, systemd --user, /proc, a journal,
# and it allocates a few hundred MB briefly). Opt in:
#     ANOMALOUS_MON_LIVE_TESTS=1 ./test/test-live.sh
# or just run it directly. Exits non-zero if any check fails.
#
# Requires: pidstat (sysstat), systemd-run (user), python3, coreutils.

set -uo pipefail   # NOT -e: live commands intentionally return non-zero

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
check() { if [[ "$2" == ok ]]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; jobs -p | xargs -r kill 2>/dev/null || true' EXIT

# ── Load libs + a capturing send_alert (so we can read alert messages) ──
source "$PROJECT_DIR/etc/anomalous-mon.conf"
source "$PROJECT_DIR/lib/notify.sh"
source "$PROJECT_DIR/lib/cpu-monitor.sh"
source "$PROJECT_DIR/lib/disk-monitor.sh"
source "$PROJECT_DIR/lib/journal-monitor.sh"
source "$PROJECT_DIR/lib/memory-monitor.sh"
source "$PROJECT_DIR/lib/stale-files-monitor.sh"

notify-send() { :; }            # never pop a real bubble
ALERTS=""                       # captured "type|key|message|group" lines
send_alert() {
    local type="$1" key="$2" msg="$3" group="${4:-}"
    [[ -n "${_ACTIVE_ALERTS[$key]:-}" ]] && return 1
    _ACTIVE_ALERTS[$key]=1
    ALERTS+="${type}|${key}|${msg}|${group}"$'\n'
    return 0
}

# ════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Live Sampler Smoke Tests (real I/O) ==="
echo ""

# --- CPU sampler: real pidstat (2s interval), with a guaranteed-hot burner ---
( timeout 5 yes >/dev/null 2>&1 ) &   # burn one core so a line is guaranteed
burner=$!
cpu_out="$(_CPU_SAMPLE_INTERVAL=2 _cpu_sample_cmd)"
kill "$burner" 2>/dev/null || true
# Every line must be "PID %CPU COMM [args]" — int PID, numeric %CPU.
cpu_ok=ok
[[ -z "$cpu_out" ]] && cpu_ok=bad
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r p c _ <<<"$line"
    [[ "$p" =~ ^[0-9]+$ ]] || cpu_ok=bad
    [[ "$c" =~ ^[0-9]+([.][0-9]+)?$ ]] || cpu_ok=bad
done <<<"$cpu_out"
check "CPU sampler (real pidstat) emits well-formed 'PID %CPU COMM' lines" "$cpu_ok" \
      "got: $(printf '%s' "$cpu_out" | head -1)"

# --- Disk sampler: real df, must return 0 and include the root filesystem ---
if disk_raw="$(_disk_sample_cmd)"; then disk_rc=0; else disk_rc=$?; fi
disk_ok=ok
(( disk_rc == 0 )) || disk_ok=bad
grep -qE '^/ [^ ]+ [0-9]+ [0-9]+$' <<<"$disk_raw" || disk_ok=bad
check "Disk sampler (real df) returns 0 and emits 'target fstype pcent avail' incl. /" "$disk_ok" \
      "rc=$disk_rc first=$(head -1 <<<"$disk_raw")"

# --- Memory sampler: real /proc — one valid sys line + valid proc lines ---
mem_raw="$(_memory_sample_cmd)"
mem_ok=ok
sys_line="$(grep -m1 '^sys ' <<<"$mem_raw" || true)"
read -r _ mtot mavail stot sfree psi <<<"$sys_line"
[[ "$mtot" =~ ^[0-9]+$ ]] && (( mtot > 0 )) || mem_ok=bad
[[ "$mavail" =~ ^[0-9]+$ && "$stot" =~ ^[0-9]+$ && "$sfree" =~ ^[0-9]+$ ]] || mem_ok=bad
[[ "$psi" =~ ^[0-9]+([.][0-9]+)?$ ]] || mem_ok=bad
# proc lines: at least one, all "proc <int pid> <int rss> <comm>"
proc_n=0
while IFS= read -r line; do
    [[ "$line" == proc\ * ]] || continue
    read -r _ pp rr _ <<<"$line"
    [[ "$pp" =~ ^[0-9]+$ && "$rr" =~ ^[0-9]+$ ]] || mem_ok=bad
    proc_n=$((proc_n+1))
done <<<"$mem_raw"
(( proc_n > 0 )) || mem_ok=bad
check "Memory sampler (real /proc) emits valid sys line (MemTotal>0) + proc lines" "$mem_ok" \
      "sys='$sys_line' procs=$proc_n"

# --- Journal sampler: real journalctl JSON, returns 0, lines are valid JSON ---
if jr_raw="$(_journal_cmd "" "1 hour")"; then jr_rc=0; else jr_rc=$?; fi
jr_ok=ok
(( jr_rc == 0 )) || jr_ok=bad
first_json="$(grep -m1 . <<<"$jr_raw" || true)"
if [[ -n "$first_json" ]]; then
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$first_json" 2>/dev/null || jr_ok=bad
fi
check "Journal sampler (real journalctl -o json) returns 0 and emits valid JSON" "$jr_ok" \
      "rc=$jr_rc"

# --- Stale sampler: real find over a temp root with a planted old file ---
stale_root="$TMP/staleroot"; mkdir -p "$stale_root"
printf 'data' > "$stale_root/planted.bin"
touch -d '100 days ago' "$stale_root/planted.bin"
( STALE_FILES_ROOTS=("$stale_root"); STALE_FILES_MIN_SIZE_GB=0; STALE_FILES_AGE_DAYS=0
  STALE_FILES_IGNORE=()
  st_raw="$(_stale_files_scan_cmd)"
  # Expect one line: "<size>\t<mtime_epoch>\t<path>" for the planted file.
  if grep -qP '^[0-9]+\t[0-9]+(\.[0-9]+)?\t.*/planted\.bin$' <<<"$st_raw"; then
      exit 0
  fi
  echo "   stale raw: $st_raw" >&2
  exit 1 ) && check "Stale sampler (real find) emits 'size<TAB>mtime<TAB>path' for planted file" ok \
                || check "Stale sampler (real find) emits 'size<TAB>mtime<TAB>path' for planted file" bad

# ════════════════════════════════════════════════════════════════════════
echo ""
echo "=== End-to-End: real runaway process → real alert ==="
echo ""

# Thresholds tuned small/fast for a ~400 MB test grower. Pressure (Signal A)
# is disabled (huge headroom requirement, impossible PSI) so we isolate the
# per-process runaway path (Signal B) end-to-end through the real /proc sampler.
MEM_GROWTH_FLOOR_MB=150
MEM_GROWTH_TICK_MB=20
MEM_GROWTH_CYCLES=3
MEM_MIN_HEADROOM_MB=1        # effectively never (we always have >1 MB free)
MEM_PSI_FULL_PCT=100000      # effectively never
unset MEM_GROWTH_OVERRIDES 2>/dev/null || true

# Real process that grows RSS by ~40 MB every 0.4s up to ~520 MB, then holds.
python3 -c '
import time
chunks = []
for _ in range(13):
    b = bytearray(40 * 1024 * 1024)   # allocate + zero-fill → resident
    b[::4096] = b"\x01" * len(b[::4096])
    chunks.append(b)
    time.sleep(0.4)
time.sleep(30)
' &
grower=$!
echo "  (spawned grower pid $grower; polling memory_check via the real sampler…)"

mem_state="$TMP/mem.state"; mem_alerts="$TMP/mem.alerts"
runaway_msg=""
for i in $(seq 1 20); do
    memory_check "$mem_state" "$mem_alerts"
    hit="$(grep -m1 "mem:runaway:${grower}|" <<<"$ALERTS" || true)"
    if [[ -n "$hit" ]]; then
        runaway_msg="$(cut -d'|' -f3 <<<"$hit")"
        break
    fi
    sleep 0.5
done
kill "$grower" 2>/dev/null || true

if [[ -n "$runaway_msg" ]]; then
    echo "  >> captured alert: \"$runaway_msg\""
fi
e2e_ok=ok
[[ -n "$runaway_msg" ]] || e2e_ok=bad
[[ "$runaway_msg" == *"$grower"* ]] || e2e_ok=bad      # names the offending PID
[[ "$runaway_msg" == *python* ]]   || e2e_ok=bad      # names the process
[[ "$runaway_msg" == *GB* ]]       || e2e_ok=bad      # reports a size
check "E2E runaway: real growing process fires mem:runaway naming pid+process+size" "$e2e_ok" \
      "msg='${runaway_msg:-<none>}'"

# ════════════════════════════════════════════════════════════════════════
echo ""
echo "=== End-to-End: runcapped contains a real OOM ==="
echo ""

# A process that grabs memory without bound, in a 128 MB / no-swap scope.
# The cgroup OOM killer must terminate it (non-zero exit) WITHOUT touching the
# rest of the session. timeout is a safety net in case the cap somehow fails.
set +e
timeout 30 "$PROJECT_DIR/bin/runcapped" -m 128M -s 0 -n livetest-oom -- \
    python3 -c '
b = []
while True:
    b.append(bytearray(20 * 1024 * 1024))
' >/dev/null 2>&1
rc_capped=$?
set -e 2>/dev/null || true

# 137 = 128 + SIGKILL(9): the cgroup OOM killer fired. timeout(124) would mean
# it never got killed (cap failed). 0 would mean it somehow exited cleanly.
cap_ok=ok
(( rc_capped != 0 && rc_capped != 124 )) || cap_ok=bad
# Sanity: our own shell (and thus the session) is obviously still alive here.
check "runcapped containment: capped OOM hog is killed in-scope (rc=$rc_capped, expect ~137)" "$cap_ok" \
      "rc=$rc_capped"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Live results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
(( FAIL == 0 ))
