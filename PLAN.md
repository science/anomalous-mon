# anomalous-mon: Desktop Anomaly Monitor

## Why this exists

On 2026-03-09, an rclone mount service (`gdrive-lt`) on a Linux Mint workstation (32GB RAM, `linux-bambam`) grew to 1.9GB RSS. Go's garbage collector entered a continuous collection loop at 193% CPU because `GOMEMLIMIT=1750MiB` left only 250MB of headroom before the `MemoryMax=2G` systemd hard kill. The problem was only noticed manually when the machine felt sluggish.

The root cause was fixed (tuned GOMEMLIMIT/MemoryMax/polling), but the broader problem remains: **there is no alerting when any process on this workstation behaves anomalously.** The next time won't necessarily be rclone — it could be a runaway build, a browser tab leaking, or a background service going haywire.

## Why not an existing tool

- **monit**: Designed for named server processes, not "any process." No wildcard CPU monitoring, no journal integration for OOM detection, and desktop notifications from a root daemon require D-Bus bridging hacks.
- **Prometheus/Grafana**: Full observability stack. Massive overkill for a single-user workstation.
- **atop**: Great for forensics after the fact, but no real-time alerting.
- **Custom cron script**: What we're building, but structured as a proper project with tests.

The requirements are simple enough that a purpose-built tool is the right call. The failure modes are benign (missed notification, false positive) — unlike cryptography where subtle bugs are catastrophic.

## What it monitors

### 1. Sustained CPU hogging (any process)

- Sample top CPU consumers every 60 seconds
- **Dual-track** CPU usage across samples using two state tables:
  - **PID table**: track per-PID CPU usage. Catches a single stuck process regardless of name changes (e.g., a process that `exec()`s or changes its comm name).
  - **Name table**: track per-process-name CPU usage. "At least one process with this name was above threshold" per sample. Catches rotating PIDs (e.g., a crash-looping service with `Restart=always` that burns CPU on each startup).
- Either table can independently trigger an alert
- Alert (desktop notification) when any entry in either table exceeds **25% CPU for 5 consecutive samples** (= 5 minutes sustained)
- Clear the counter when usage drops below threshold
- Deduplicate: don't spam repeated notifications for the same process while it's still hot. Re-alert if it clears and re-triggers.

### 2. OOM kills and memory limit hits (any service)

- Check `journalctl` for recent OOM-kill events, `memory.max` hits, and service failures due to memory
- Alert with the service/process name and context
- Track last-seen journal cursor to avoid re-alerting on old events

## Architecture

```
anomalous-mon/
  bin/
    anomalous-mon           # Main monitor script (bash)
  lib/
    cpu-monitor.sh          # CPU sampling and state tracking
    journal-monitor.sh      # Journal event detection
    notify.sh               # Desktop notification wrapper
  etc/
    anomalous-mon.conf      # Configuration (thresholds, intervals)
  test/
    test-anomalous-mon.sh   # Test suite
  install.sh                # Installs systemd timer + service
  uninstall.sh              # Removes systemd timer + service
  PLAN.md                   # This file
```

### Runtime files

- State file: `/tmp/anomalous-mon.state` (CPU tracking across samples)
- Journal cursor: `/tmp/anomalous-mon.cursor` (last-processed journal position)
- Log: stdout/stderr captured by journald (systemd service)

### Deployment

- **systemd user service + timer** (runs as the desktop user, not root)
- Timer fires every 60 seconds
- Running as the user means `notify-send` works natively (D-Bus session access)
- User-level means it can't monitor root processes, but that's fine — the concerning processes on a workstation (rclone, browsers, builds, Claude) all run as the user

### Configuration defaults

```
CPU_THRESHOLD=25           # percent (of one core)
CPU_SUSTAINED_CYCLES=5     # consecutive samples before alert (5 min at 60s interval)
SAMPLE_INTERVAL=60         # seconds (controlled by systemd timer, not the script)
OOM_LOOKBACK="2 minutes"   # journal window to check
```

## Design principles

1. **No dependencies beyond coreutils + systemd** — bash, ps, journalctl, notify-send. Nothing to install except the tool itself.
2. **Testable** — all logic in sourced library files. Tests can mock ps output, fake state files, and verify alerting decisions without actually running monitors.
3. **Silent when healthy** — produces no output, no notifications, no log noise when everything is normal.
4. **Idempotent** — safe to run manually, safe if timer fires twice, safe if state file is missing (cold start).
5. **Transparent** — `journalctl --user -u anomalous-mon` shows all activity. `anomalous-mon --status` shows current state.

## Test strategy

Tests use a pass/fail pattern similar to the yadm dotfiles test suite. Key test cases:

### CPU monitoring
- No processes above threshold → no alert
- Process above threshold for 1 cycle → no alert (not sustained)
- Process above threshold for 5 cycles → alert fires
- Process drops below threshold → counter resets
- Process re-triggers after clearing → new alert fires
- Multiple hot processes → independent tracking
- PID reuse (same PID, different process name) → PID counter resets, name counters track independently
- Same process name, rotating PIDs (crash-loop) → name table still accumulates, alert fires
- Same PID, name changes (exec or prctl) → PID table still accumulates, alert fires
- State file missing (cold start) → starts fresh, no crash
- State file corrupt → starts fresh, no crash

### Journal monitoring
- No OOM events → no alert
- OOM kill detected → alert with process name
- memory.max hit detected → alert with service name
- Same event not re-alerted (cursor tracking)
- Journal cursor file missing → scans recent window only

### Notification
- notify-send called with correct urgency and message
- Deduplication: same process doesn't spam alerts

### Integration
- Full cycle: sample → detect → alert → clear
- Config file overrides defaults
- --status flag shows current tracking state

## Implementation order

1. Scaffold project structure
2. Write tests for CPU monitoring logic (they will fail)
3. Implement cpu-monitor.sh
4. Write tests for journal monitoring (they will fail)
5. Implement journal-monitor.sh
6. Write tests for notification deduplication
7. Implement notify.sh
8. Write main script that ties it together
9. Write config file with defaults
10. Write install.sh / uninstall.sh (systemd timer + service)
11. Integration tests
12. Install on linux-bambam, verify with synthetic load (`stress-ng`)

## Non-goals

- Not a general-purpose monitoring framework
- No web UI, no metrics storage, no historical graphs
- No email/SMS alerting (desktop notifications only)
- No automatic remediation (alert only, never kill/restart)
- No monitoring of disk, network, or other resources (CPU and memory/OOM only, for now)

## Machine context

- **Host**: linux-bambam, Linux Mint, 32GB RAM, Cinnamon desktop
- **User**: steve
- **Dotfiles**: yadm-managed (`~/CLAUDE.md` has full details)
- **Notify**: `notify-send` works in Cinnamon sessions (`$DISPLAY` / `$DBUS_SESSION_BUS_ADDRESS` available)
- **Systemd user services**: already used extensively (rclone mounts, redshift-ctl)
- **Test pattern**: similar to `~/.config/yadm/test-dotfiles.sh` — bash, pass/fail, fast
