# anomalous-mon

Desktop anomaly monitor for Linux workstations. Detects sustained CPU hogging and OOM kills, alerting via desktop notifications.

## Why

Built after an rclone mount grew to 1.9GB RSS and entered a GC loop at 193% CPU without any alerting. Existing tools (monit, Prometheus, atop) are either too server-oriented, too heavy, or lack real-time alerting for arbitrary desktop processes.

## What it monitors

**Sustained CPU hogging** — Samples top CPU consumers every 60 seconds. Uses dual-track state (PID table + process name table) to catch both stuck processes and crash-looping services with rotating PIDs. Alerts after 5 consecutive samples above 25% CPU.

**OOM kills and memory limit hits** — Checks journalctl for OOM-kill events and cgroup `memory.max` hits. Tracks journal cursor to avoid re-alerting on old events.

**Disk-space exhaustion** — Two severities per mount. WARN fires when a filesystem crosses `DISK_WARN_PCT` *and* absolute free space drops below `DISK_MIN_FREE_GB` (the AND-gate silences large disks with generous headroom but still catches small VM disks). CRITICAL fires unconditionally on percent once `DISK_CRIT_PCT` is crossed. Pseudo/virtual/network filesystems (tmpfs, squashfs, overlay, nfs, etc.) are excluded. Per-mount thresholds are overridable via `DISK_THRESHOLD_OVERRIDES` in the config — e.g. `/boot` legitimately runs 70–80% full.

**Large stale files** — A separate weekly timer (`anomalous-mon-stale.timer`) walks configured roots for files larger than `STALE_FILES_MIN_SIZE_GB` that haven't been modified in `STALE_FILES_AGE_DAYS`. Fires a single summary desktop bubble with an "Open report" button that launches the detail report in your default text editor. Uses `mtime`, not `atime` — `relatime`/`noatime` mounts make atime unreliable, and large read-only files (old VM images, archives, downloads) are exactly what we want to surface. FUSE/network mounts under scan roots are auto-pruned. Silence a specific file with `anomalous-mon --ack <path>`; acks expire after `STALE_FILES_ACK_TTL` days so you get re-prompted eventually.

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
CPU_THRESHOLD=60           # percent of one core (per-process)
CPU_THRESHOLD_TOTAL=25     # percent of total CPU (all cores combined)
CPU_SUSTAINED_CYCLES=5     # consecutive samples before alert (5 min at 60s interval)
OOM_LOOKBACK="2 minutes"   # journal window on cold start

DISK_WARN_PCT=80           # percent-used threshold for WARN
DISK_CRIT_PCT=92           # percent-used threshold for CRITICAL
DISK_MIN_FREE_GB=10        # WARN is AND-gated by this absolute headroom

STALE_FILES_MIN_SIZE_GB=1  # ≥ 1 GiB
STALE_FILES_AGE_DAYS=180   # not modified in 6 months
STALE_FILES_ACK_TTL=90     # acked files re-prompt after N days
STALE_FILES_ROOTS=("$HOME")
STALE_FILES_IGNORE=("$HOME/.cache" "$HOME/snap")  # paths/globs to skip
```

Per-mount disk threshold overrides (e.g. `/boot` runs 70–80% full by design) are set via the `DISK_THRESHOLD_OVERRIDES` associative array in the same config file.

## Stale-files CLI

```bash
anomalous-mon --stale-scan          # run a scan now (also fires weekly via timer)
anomalous-mon --stale-report        # print the latest report
anomalous-mon --ack /path/to/file   # silence a file you've decided to keep
anomalous-mon --unack /path/to/file # un-silence
anomalous-mon --status              # includes stale-files state alongside CPU/disk
```

## rclone shortcut-cycle scanner (standalone)

`bin/rclone-cycle-scan` is a **separate on-demand utility**, not part of the monitoring loop. Use it when an rclone Google Drive mount mysteriously OOM-kills or restarts (anomalous-mon's OOM alert fires). The usual cause is a **self-referential Drive shortcut** — a shortcut whose target is one of its own ancestor folders — which makes the mount present an infinitely deep directory tree; any recursive walk grows rclone's VFS heap until it OOMs. rclone has no cycle detection, so this scans the **remote** (Drive API, in a separate process — it never touches the live mount or its caches) to a bounded depth and names the exact shortcut to move in the Drive web UI.

```bash
bin/rclone-cycle-scan                          # scan gdrive-lt: + gdrive-personal:, depth 8
bin/rclone-cycle-scan gdrive-lt: --max-depth 12
bin/rclone-cycle-scan "gdrive-lt:Some/Subtree" # scan one subtree, deeper
bin/rclone-cycle-scan --json                   # machine-readable output
```

Scans remotes in parallel (~9 min for both). Exit codes: `0` clean, `1` cycles found, `2` scan failed. It reports the loop-back shortcut to move — it does not auto-fix. Background and the motivating incident: `FINDINGS-rclone-oom-2026-06-09.md`; design rationale (why on-demand, not a weekly timer) in `PLAN-cycle-monitor.md`.

## Tests

```bash
./test/test-anomalous-mon.sh                   # bash: CPU/OOM/disk/stale/notify logic
pytest test/test_rclone_cycle_scan.py          # python: rclone-cycle-scan detection logic
```

The bash suite covers CPU dual-track logic, journal monitoring, disk WARN/CRITICAL severity gating, notification deduplication, grouped replace-id collapsing, state file recovery, and integration scenarios. The pytest suite covers the shortcut-cycle detector (self-loops, multi-hop loops, false-positive guards, loop-unrolling dedup).

## Design

- No dependencies beyond coreutils + systemd (bash, ps, journalctl, notify-send)
- Silent when healthy — no output, no notifications, no log noise
- Runs as user (not root) — desktop processes are the concern
- Idempotent — safe to run manually or if timer fires twice
- Logs tracking progress to journald when processes are being monitored
