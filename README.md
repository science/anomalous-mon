# anomalous-mon

Desktop anomaly monitor for Linux workstations. Detects sustained CPU hogging and OOM kills, alerting via desktop notifications.

## Why

Built after an rclone mount grew to 1.9GB RSS and entered a GC loop at 193% CPU without any alerting. Existing tools (monit, Prometheus, atop) are either too server-oriented, too heavy, or lack real-time alerting for arbitrary desktop processes.

## What it monitors

**Sustained CPU hogging** — Samples top CPU consumers every 60 seconds. Uses dual-track state (PID table + process name table) to catch both stuck processes and crash-looping services with rotating PIDs. Alerts after 5 consecutive samples above 25% CPU.

**OOM kills and memory limit hits** — Checks journalctl for OOM-kill events and cgroup `memory.max` hits. Tracks journal cursor to avoid re-alerting on old events.

**Collapsed notifications** — Successive alerts for the same process name (e.g. a pipeline spawning many short-lived `python` PIDs) replace the existing notification bubble instead of stacking. Each event still logs a distinct `[ALERT]` line to journald. The replace-id mapping is persisted in `${XDG_RUNTIME_DIR:-/tmp}/anomalous-mon.notify-ids` so replacement survives timer re-invocations.

## Install

```bash
git clone https://github.com/science/anomalous-mon.git ~/dev/anomalous-mon
~/dev/anomalous-mon/install.sh
```

This installs a systemd user timer that runs every 60 seconds. Notifications use `notify-send` (works in Cinnamon/GNOME sessions).

```bash
# Check status
~/dev/anomalous-mon/bin/anomalous-mon --status

# View logs
journalctl --user -u anomalous-mon -f

# Uninstall
~/dev/anomalous-mon/uninstall.sh
```

## Configuration

Edit `etc/anomalous-mon.conf`:

```bash
CPU_THRESHOLD=25           # percent (of one core)
CPU_SUSTAINED_CYCLES=5     # consecutive samples before alert (5 min at 60s interval)
OOM_LOOKBACK="2 minutes"   # journal window on cold start
```

## Tests

```bash
./test/test-anomalous-mon.sh
```

49 tests covering CPU dual-track logic, journal monitoring, notification deduplication, grouped replace-id collapsing, state file recovery, and integration scenarios.

## Design

- No dependencies beyond coreutils + systemd (bash, ps, journalctl, notify-send)
- Silent when healthy — no output, no notifications, no log noise
- Runs as user (not root) — desktop processes are the concern
- Idempotent — safe to run manually or if timer fires twice
- Logs tracking progress to journald when processes are being monitored
