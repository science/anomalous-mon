# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- **Run tests:** `./test/test-anomalous-mon.sh` — pass/fail suite, no side effects (all I/O redirected to `$(mktemp -d)`).
- **Run a single test:** there's no test selector. The suite is a single bash file with inline assertions; comment out sections you don't want to run, or copy the `reset_test_state` + assertion block into a scratch script that sources the libs.
- **Run one monitoring cycle manually:** `bin/anomalous-mon` (with no args). This is what the systemd timer invokes — safe to run ad-hoc.
- **Inspect current tracking state:** `bin/anomalous-mon --status`.
- **Tail live logs:** `journalctl --user -u anomalous-mon -f`.
- **Force a timer-driven run now:** `systemctl --user start anomalous-mon.service`.

There is no build step, no linter, no lockfile. Pure bash + coreutils + sysstat (`pidstat`) + systemd + `notify-send`.

## Deployment model

The systemd user unit's `ExecStart` points **directly at the repo path** (`/home/steve/dev/anomalous-mon/bin/anomalous-mon`) — no symlink, no copy, no `make install`. Editing a file in the repo and saving it IS the deploy; the next timer tick picks up the change. The timer fires every ~5s after the previous run finishes (`OnUnitInactiveSec=5`), even though the sampling interval inside `cpu_sample` is 60s (controlled by `pidstat -l 60 1`).

Consequence: never leave the repo in a syntactically broken state — a running user would hit the bad code within seconds.

## Architecture

### Dual-track CPU dedup (`lib/cpu-monitor.sh`)

The trickiest piece. Two parallel state tables are maintained per cycle:

- **PID table** — keyed by PID. Catches a single stuck process even if its comm name changes mid-life (exec, prctl).
- **Name table** — keyed by comm. Catches crash-loopers with rotating PIDs (systemd `Restart=always` services that burn CPU on each startup).

Each entry counts *consecutive* cycles above threshold. Going cold resets and clears any fired alert for that entry.

`cpu_check_alerts` fires alerts in two passes:
1. PID pass — for each hot PID at/over its cycle budget, fire `pid:<PID>`. Also record `_pid_alerted_names[$name]=1` for the current cycle.
2. Name pass — for each hot name at/over its cycle budget, **skip** firing if `_pid_alerted_names[$name]` is set this cycle (a PID alert already tells the user about this process), but still mark the name as alerted so it doesn't re-fire later in the same hot streak.

Thresholds are OR'd: a process alerts if it exceeds `CPU_THRESHOLD` (per-core) *or* `CPU_THRESHOLD_TOTAL * nproc` (total-CPU scaled to pidstat's percent-of-one-core units). Per-process cycle overrides live in `CPU_SUSTAINED_OVERRIDES` in `etc/anomalous-mon.conf` (e.g. firefox/qemu/zoom need 120 cycles before alerting).

### Collapsed desktop bubbles (`lib/notify.sh`)

`send_alert TYPE KEY MESSAGE [GROUP]` — the optional `GROUP` arg drives `notify-send -p`/`-r` so successive bubbles for the same group **replace** the prior bubble instead of stacking. Callers set `GROUP` to the process name (CPU alerts) or the alert key (OOM alerts). The `group → notify-id` map persists in `$NOTIFY_ID_FILE` across timer re-invocations.

Without `GROUP`, `send_alert` keeps its in-memory `_ACTIVE_ALERTS` key dedup — that only matters within a single process run, not across ticks.

The log line (`echo "[ALERT] …"`) always fires, regardless of grouping — every alert lands in journalctl. Only the desktop bubble is collapsed.

### Journal OOM detection (`lib/journal-monitor.sh`)

Pattern-matches `MESSAGE` fields against `/Out of memory|oom-kill|Killed process/` and `/memory\.max|MemoryMax|memory limit/`. Uses two persistence mechanisms:

- **Cursor file** (`anomalous-mon.cursor`) — last journalctl cursor processed; avoids re-alerting old events.
- **Alert state file** (`anomalous-mon.oom-alerts`) — `key:epoch` lines; enforces `OOM_COOLDOWN` seconds between duplicate alerts for the same key.

Self-feed filter: journal entries whose `_SYSTEMD_USER_UNIT == "anomalous-mon.service"` are skipped — otherwise our own `[ALERT] oom: …` log lines would match the OOM regex and retrigger.

Kernel `Out of memory: Killed process N (name) …` lines contain the victim's real process name; the scope-level `Failed with result 'oom-kill'` lines do not. The OOM detector currently parses both but the victim-name extraction only works on the kernel line.

### Disk-space monitoring (`lib/disk-monitor.sh`)

Two severities per mount, computed fresh each tick from `df --output=target,fstype,pcent,avail` (not `-P`; the two options are mutually exclusive on GNU coreutils):

- **CRITICAL** fires when `pcent >= CRIT_PCT`, unconditionally. Short cooldown (`DISK_CRIT_COOLDOWN`, 300s default) so it keeps nagging until cleared.
- **WARN** fires when `pcent >= WARN_PCT` **AND** `avail < MIN_FREE_GB`. The AND-gate is load-bearing: it silences a 2 TB disk at 80% (400 GB free) while still catching a 40 GB VM at 80% (8 GB free). Long cooldown (`DISK_WARN_COOLDOWN`, 1800s default).

`disk_check` runs two passes over the sample. The CRITICAL pass records any mount that fired into `_crit_fired_mounts`; the WARN pass then skips those mounts so a single tick never emits both alerts for the same mount. The `notify-send` group is `disk:<mount>` (severity is *not* part of the group) so as a mount climbs WARN → CRITICAL the bubble replaces in place rather than stacking.

**Per-mount overrides** via `DISK_THRESHOLD_OVERRIDES` in the config, formatted `"warn:crit:min_free_gb"` with `-` to inherit. `/boot` and `/boot/efi` ship with tightened overrides because they legitimately run 70-80% full.

**Fstype filtering** is belt-and-suspenders: the sampler passes `-x` flags to df (tmpfs, squashfs, efivarfs, overlay, fuse.*, autofs, nfs, cifs, virtiofs, …), and `disk_check` re-checks the fstype column against `_DISK_EXCLUDE_FSTYPES` in case a mock or future sample source leaks a pseudo fs through.

**Float comparisons.** Bash `(( ))` can't compare floats, and `MIN_FREE_GB` can be fractional (e.g. `0.1` for `/boot`). `_disk_lt` and `_disk_kb_to_gb` shell out to `awk` for the float work; the integer comparisons (pcent vs. warn/crit) stay in native bash.

### Test mocking model (`test/test-anomalous-mon.sh`)

The libs are designed to be sourced and mocked:

- `_CPU_SAMPLE_CMD` — override `_cpu_sample_cmd` with a function returning fake `pid %cpu comm args` lines. `set_mock_ps "..."` is a convenience helper.
- `_JOURNAL_CMD` — override `_journal_cmd` with a function returning fake journalctl JSON.
- `_DISK_SAMPLE_CMD` — override `_disk_sample_cmd` with a function returning fake `target fstype pcent avail_kb` lines (one per mount). `set_mock_disk "..."` is the convenience helper.
- `_NPROC` — override `nproc` for deterministic total-CPU threshold math (fixed to 4 in tests).

There are two flavors of `send_alert` in the test file:
1. A **mock wrapper** (default) that captures calls to `ALERT_LOG` in `type|key|message|group\n` format. This is what most tests assert against.
2. The **real `send_alert`** from `lib/notify.sh`, used in the "Grouped Notification Tests" section. `setup_real_notify_test` / `teardown_real_notify_test` swap it in/out. `notify-send` is mocked as a bash function that appends to `$NOTIFY_CALLS_FILE` — **file-backed, not array-backed**, because `send_alert` invokes notify-send inside `$(...)` command substitution (subshell) so variable updates don't propagate back.

## State files

All under `${XDG_RUNTIME_DIR:-/tmp}`:

| File | Purpose | Format |
|---|---|---|
| `anomalous-mon.state` | CPU dual-track counters + alerted flags | line-based: `pid:<PID>:<NAME>:<COUNT>:<ALERTED>:<ARGS>` or `name:<NAME>:<COUNT>:<ALERTED>` |
| `anomalous-mon.cursor` | last journalctl cursor | single line, opaque cursor token |
| `anomalous-mon.oom-alerts` | OOM cooldown state | `<key>:<epoch>` per line |
| `anomalous-mon.disk-alerts` | Disk WARN/CRITICAL cooldown state | `disk:<mount>:<severity>:<epoch>` per line; `<severity>` is `warn` or `critical`. Parsed with `${line%:*}` / `${line##*:}` so a key with embedded colons like `disk:/:warn` still splits correctly. |
| `anomalous-mon.notify-ids` | group → notify-send id | `<group>\t<id>` per line |

Corrupt state files are tolerated: the loaders parse defensively and fall through to empty state on garbage (tested).

## Conventions

- Libs declare `_FOO` private helpers (underscore prefix) and expose only a small public surface (`cpu_sample`, `cpu_check_alerts`, `cpu_status`, `journal_check`, `send_alert`, `clear_alert`, `is_alert_active`).
- State I/O uses a write-tmp-then-`mv` pattern for atomicity — follow it when adding new state files.
- Configuration lives in `etc/anomalous-mon.conf`, sourced by `bin/anomalous-mon` at startup. Don't hardcode thresholds in libs.
