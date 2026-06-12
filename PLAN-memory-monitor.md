# PLAN: Add `memory-monitor.sh` — warn on runaway / excessive memory *before* OOM

> **Status: Implemented** (2026-06-12) — `lib/memory-monitor.sh`, wired into
> `bin/anomalous-mon`, config in `etc/anomalous-mon.conf`, tests in the
> "Memory Monitor Tests" section of `test/test-anomalous-mon.sh` (15 cases).
> The job-cap mitigation (`bin/runcapped`) shipped alongside it.
>
> **Implementation note — Signal B is per-cycle-streak, not anchor/window.**
> The "Behavior" section below was the original design sketch (a windowed
> growth anchor). The shipped Signal B instead reuses cpu-monitor's
> consecutive-cycle state machine: a process alerts when it is **both** large
> (`RSS ≥ MEM_GROWTH_FLOOR_MB`) **and** has grown by `≥ MEM_GROWTH_TICK_MB` for
> `MEM_GROWTH_CYCLES` consecutive ~1-min cycles. This is simpler, needs no
> wall-clock (so it's deterministically testable like the CPU tests), and
> directly satisfies the "absolute size + sustained growth, not a raw slope"
> requirement: a tiny process creeping bytes/year is below both the floor and
> the per-cycle delta, and a sawtooth/GC process breaks its streak on each dip.
> Everything else below (Signal A, sampling, state files, mocking) shipped as
> described. See `CLAUDE.md` → "Memory monitoring" for the as-built summary.

## Context — the incident that motivates it

On **2026-06-12 ~11:23** the workstation's entire Cinnamon session collapsed to
the login screen, froze, and needed two more login attempts before coming back
as a blank desktop. anomalous-mon logged an OOM but reported the victim as
`unknown`.

Root cause (reconstructed from the kernel ring buffer — the lines were in
`dmesg` but *not* in the journal anomalous-mon reads):

```
oom-kill:constraint=CONSTRAINT_NONE ... global_oom ...
  task_memcg=.../user@1000.service/.../tmux-spawn-...scope,task=python
Out of memory: Killed process 2796388 (python) total-vm:7978356kB anon-rss:3424640kB ...
```

- `constraint=CONSTRAINT_NONE` + `global_oom` = **whole-machine** memory
  exhaustion (no cgroup limit; `MemoryMax=infinity` on the user slice,
  `systemd-oomd` not installed).
- The trigger was `vector-traversal/scripts/run_sae_comparison.py --save-matrices`,
  which accumulates a dict of NumPy distance matrices in RAM and then runs a
  bootstrap-CI stage **8-way parallel** via joblib (`Parallel(n_jobs=min(8,…))`).
  joblib's loky backend copies the matrices into each worker → ~8× memory.
- It blew past **31 GB RAM + 32 GB swap (~63 GB)**. The kernel's *global* OOM
  killer then walked the `user@1000.service` slice killing by score: the
  terminal/tmux `vte-spawn-*` scopes (the user's lost tmux sessions), then
  `dbus`, `gnome-keyring`, `pipewire`, `gvfs`, the portals — at which point
  Cinnamon is unrecoverable. The dev-1 incus VM survived because it lives in
  the *system* `machine.slice`, not the user session.

### What anomalous-mon did and didn't do

- It **did** log `python` as a CPU alert for 33 consecutive cycles (11:06→11:24).
  But CPU was a *symptom* — the per-core spike said nothing about the RAM the
  process was eating, so there was no actionable "you are about to OOM" signal.
- It has **no memory monitor at all** (`lib/` = cpu, disk, journal, stale-files,
  notify). Its only memory awareness is the *post-mortem* journal OOM detector.
- That detector reported `unknown` because it only matched systemd's scope-level
  `…: Failed with result 'oom-kill'` lines (which carry no victim name); the
  kernel `Killed process N (python)` line was in `dmesg`, not the journal.

This plan adds the missing **proactive** monitor. (Improving OOM *victim naming*
in `journal-monitor.sh` — reading `dmesg`/`journalctl -k` for the kernel
`Killed process N (name)` line — is a separate, smaller follow-up and is listed
under "Out of scope" below.)

## Behavior — two distinct signals

The user's explicit requirement: detect memory that is **excessive in absolute
terms** *and* memory that is **growing steadily** (runaway), even before it is
yet large. Those are two different detectors, deliberately kept separate:

### Signal A — system-wide pressure (absolute)

Each tick, sample system memory and fire a single host-level alert when **any**
of these cross, AND-gated where noted:

- `MemAvailable < MEM_AVAIL_MIN_MB` (headroom is gone), **or**
- swap used ≥ `MEM_SWAP_USED_PCT` of `SwapTotal` (we're deep into swap), **or**
- PSI `full` memory `avg60 ≥ MEM_PSI_FULL_PCT` (the machine is *stalling* on
  memory — this is the "froze for minutes / load avg 20" symptom, and the
  earliest honest signal that thrash has begun).

The alert body lists the **top RSS consumers** (name, PID, RSS) so the user can
see what to kill. Group `mem:system` (replace-in-place). Cooldown
`MEM_PRESSURE_COOLDOWN`.

### Signal B — per-process runaway growth (trend)

This is the one that would have caught the 2026-06-12 job *early*. For each
process whose RSS exceeds a floor `MEM_GROWTH_MIN_RSS_MB` (ignore small fry),
track RSS across consecutive cycles and count a **rise streak**: cycles where
RSS grew by at least `MEM_GROWTH_MIN_DELTA_MB` over the previous sample. When
the streak reaches `MEM_GROWTH_CYCLES`, fire `mem:runaway:<pid>`:

> `<name> (pid N) memory climbing: 3.4 GB and +600 MB/cycle over 5 cycles — about to OOM? kill N or re-run under runcapped.`

Going cold (RSS flat or falling for a cycle) resets the streak and clears the
alert for that PID, mirroring `cpu-monitor.sh`'s consecutive-cycle dedup exactly.
Per-process overrides (`MEM_GROWTH_OVERRIDES`, name→cycles) let known
legitimately-growing programs (a browser session, a VM ballooning) need a longer
streak before alerting — same shape as `CPU_SUSTAINED_OVERRIDES`.

Why a *slope* and not just an absolute per-process cap: a hard "process > 20 GB"
threshold both false-alarms on legitimately large jobs and fires too late on a
fast leak. A sustained upward slope crossing a modest floor is the signal that
distinguishes "big but stable" (fine) from "runaway" (about to take down the
session). Floor + delta + streak together suppress GC sawtooth and steady-state
large processes.

### Cadence note

The main loop's effective tick is ~60–65 s because `cpu_sample` blocks on
`pidstat -l 60 1`. That's *good* for Signal B — one sample per ~minute makes
"+N MB/cycle over K cycles" a meaningful minutes-long trend, the same timebase
CPU alerts already use. Signal A's PSI/`MemAvailable` read is instantaneous and
piggybacks the same tick.

## Files to add

- `lib/memory-monitor.sh` — mirror the shape of `lib/cpu-monitor.sh` (it already
  has the per-PID consecutive-cycle state machine this reuses) and
  `lib/disk-monitor.sh` (system-level threshold + cooldown). Public surface:
  `memory_check`, `memory_status`. Private helpers prefixed `_memory_*`.
- Tests in `test/test-anomalous-mon.sh` — a new "Memory Monitor Tests" section
  mirroring the disk/cpu sections.

## Files to modify

- `etc/anomalous-mon.conf` — add the config knobs below.
- `bin/anomalous-mon` — source the new lib (after `disk-monitor.sh`); declare
  `MEM_STATE_FILE` and `MEM_ALERT_FILE`; call `memory_check` after `disk_check`;
  extend `--status` to call `memory_status`.
- `README.md` — add a "Memory pressure / runaway" bullet and document the knobs.
- `CLAUDE.md` — add an "## Architecture → Memory monitoring (`lib/memory-monitor.sh`)"
  section (signals A/B, state-file format, the `_MEM_SAMPLE_CMD` mocking hook),
  a row in the State-files table, and a `bin/runcapped` note under a new
  "Standalone tool" or the existing mitigation discussion.

## Sampling source & mocking hook

`_MEM_SAMPLE_CMD` — override `_memory_sample_cmd` with a function emitting the
sample; default implementation reads `/proc`. Two record kinds on stdout so one
mock drives both signals (mirrors `_DISK_SAMPLE_CMD` / `_CPU_SAMPLE_CMD`):

```
sys <mem_avail_kb> <swap_total_kb> <swap_free_kb> <psi_full_avg60>
proc <pid> <rss_kb> <comm>
proc <pid> <rss_kb> <comm>
...
```

- `sys` line ← `/proc/meminfo` (`MemAvailable`, `SwapTotal`, `SwapFree`) +
  `/proc/pressure/memory` (`full … avg60=`).
- `proc` lines ← walk `/proc/[pid]/status` `VmRSS` (or reuse `pidstat -r`).
  Cheap; one pass per ~minute tick.

`set_mock_memory "<lines>"` convenience helper alongside `set_mock_disk` etc.
Float work (PSI percent, swap-used percent, MB deltas) shells out to `awk` like
`disk-monitor.sh`'s `_disk_lt`; integer KB comparisons stay native bash.

## State file

Path: `${XDG_RUNTIME_DIR:-/tmp}/anomalous-mon.mem-state` (per-PID trend) and
`${XDG_RUNTIME_DIR:-/tmp}/anomalous-mon.mem-alerts` (cooldown), mirroring the
cpu/disk split. Per-PID trend records:

```
pid:<PID>:<NAME>:<LAST_RSS_KB>:<RISE_STREAK>:<ALERTED>
```

Cooldown records (Signal A + per-PID Signal B):

```
mem:system:<epoch>
mem:runaway:<PID>:<epoch>
```

Parsed with the existing `${line%:*}` / `${line##*:}` convention. Corrupt files
load defensively to empty state (tested), like every other state file.

## Config knobs (etc/anomalous-mon.conf additions)

```bash
# Memory monitoring — proactive, fires BEFORE the kernel OOM killer.
# Signal A: system-wide pressure (absolute).
MEM_AVAIL_MIN_MB=1536        # alert when MemAvailable drops below ~1.5 GB
MEM_SWAP_USED_PCT=70         # alert when >=70% of swap is in use
MEM_PSI_FULL_PCT=20          # alert when memory PSI full avg60 >= 20% (stalling)
MEM_PRESSURE_COOLDOWN=300    # 5 min between system-pressure repeats

# Signal B: per-process runaway growth (trend).
MEM_GROWTH_MIN_RSS_MB=2048   # ignore processes smaller than 2 GB
MEM_GROWTH_MIN_DELTA_MB=250  # a "rise" cycle = RSS grew >= 250 MB over prev
MEM_GROWTH_CYCLES=5          # consecutive rise cycles before alerting (~5 min)
MEM_RUNAWAY_COOLDOWN=600     # 10 min between repeats for the same PID

# Per-process overrides: comm name -> rise cycles before alerting. For programs
# that legitimately grow for a while (browser sessions, ballooning VMs).
declare -A MEM_GROWTH_OVERRIDES=(
    [firefox]=15
    [qemu-system-x86_64]=15
)
```

Defaults are sized for this 31 GB host: `MEM_AVAIL_MIN_MB=1536` leaves a small
desktop reserve; `MEM_GROWTH_MIN_RSS_MB=2048` + 5×250 MB rise would have flagged
`run_sae_comparison.py` around 11:15 — ~8 minutes before the cascade.

## Public function signatures

```bash
# Main check called from bin/anomalous-mon each tick.
memory_check MEM_STATE_FILE MEM_ALERT_FILE

# Status output for `anomalous-mon --status`: current MemAvailable / swap /
# PSI, plus any PIDs with an active rise streak and their streak count.
memory_status MEM_STATE_FILE
```

(Thresholds are read from the sourced config globals, matching how
`disk_check`/`cpu_check_alerts` consume `*_THRESHOLD`/override globals rather
than taking every knob as a positional arg.)

## Test scenarios (mirror cpu/disk coverage)

Signal A:
1. Ample memory → no alert.
2. `MemAvailable` below floor → one `mem:system` alert, body lists top RSS.
3. Swap-used ≥ pct (but MemAvailable fine) → alert (OR semantics).
4. PSI full avg60 ≥ pct → alert.
5. Within cooldown → no re-alert; past cooldown → re-alert.

Signal B:
6. Process under `MEM_GROWTH_MIN_RSS_MB` growing fast → no alert (below floor).
7. Large process, flat RSS → streak stays 0, no alert.
8. Large process rising < `MIN_DELTA` per cycle → no streak, no alert.
9. Large process rising ≥ delta for `MEM_GROWTH_CYCLES` → one `mem:runaway:<pid>`.
10. After alert, RSS dips one cycle → streak resets, alert cleared; rises again →
    must re-accumulate the full streak before re-firing.
11. Per-process override raises the required streak (e.g. firefox needs 15).
12. Two independent growing PIDs tracked separately.
13. PID disappears (process exited) → its trend record is pruned, no stale alert.
14. Corrupt state file → loads to empty state, no crash.
15. Notification grouping: repeated system alerts share `mem:system`; repeated
    runaway alerts for one PID share `mem:runaway:<pid>` (verified via
    `setup_real_notify_test` like the disk grouped tests).

## Verification (manual, after install)

1. `./test/test-anomalous-mon.sh` passes (incl. new section).
2. Trend smoke test without risking the desktop — grow a *capped* hog so a real
   alert fires but a real OOM can't escape:
   ```bash
   bin/runcapped -m 8G -s 0 -- python -c '
   import time; buf=[]
   while True: buf.append(bytearray(300*1024*1024)); time.sleep(60)'
   ```
   Within ~5 cycles a `mem:runaway:<pid>` toast should appear; let the cap OOM
   the python (desktop untouched), confirming both the alert and the mitigation.
3. `anomalous-mon --status` shows a "Memory" section: MemAvailable, swap used,
   PSI full avg60, and any PID with an active rise streak.
4. `journalctl --user -u anomalous-mon -f` shows the `[ALERT] mem: …` line.

## Out of scope for this change (track separately)

- **OOM victim naming** in `journal-monitor.sh`: also read `dmesg` /
  `journalctl -k` for the kernel `Out of memory: Killed process N (name)` line so
  post-mortem OOM alerts name the real victim instead of `unknown`. Small,
  independent follow-up; worth doing since this incident proved the kernel line
  isn't in the unit journal the detector currently reads.
- **`systemd-oomd`** (proactive PSI-based cgroup killing): would have contained
  this at the OS level, but it's an apt package + config change, not code in this
  repo. Note for the user's yadm-tracked package list.
- **Per-workload caps as policy** (always launch heavy jobs via `bin/runcapped`,
  or a `MemoryMax` drop-in on a dedicated `jobs.slice`): the wrapper exists; making
  it the default path is a workflow decision, not part of the monitor.
- **Auto-killing** a runaway: alert-only is correct here, exactly as the CPU and
  service monitors are alert-only — the user pulls the trigger (or the cgroup cap
  does, when the job was launched under `runcapped`).

## Why this fits anomalous-mon

The loop shape is the union of two monitors it already has:
- **Signal A** is `disk_check`: sample a system-wide metric each tick, threshold
  with cooldown, grouped `notify-send` + journal log.
- **Signal B** is `cpu-monitor.sh`'s consecutive-cycle state machine, applied to
  RSS slope instead of CPU percent — same per-PID table, same streak/reset/
  alerted-flag logic, same override-by-comm map.

The state-file loader/saver pattern, the `send_alert` group convention, and the
`_*_SAMPLE_CMD` mocking model all carry over directly. ~180 lines of bash plus
mirror tests.
