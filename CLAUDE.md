# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- **Run tests:** `./test/test-anomalous-mon.sh` — pass/fail suite, no side effects (all I/O mocked, redirected to `$(mktemp -d)`). 122 checks.
- **Run the live tests:** `./test/test-live.sh` (opt-in; also gated by `ANOMALOUS_MON_LIVE_TESTS=1`). Exercises the **real** samplers (pidstat/df/`/proc`/journalctl/find) plus true end-to-end: spawns a real growing process and asserts a `mem:runaway` alert fires through the real `/proc` sampler (and reads the message back), and runs a real OOM inside a `runcapped` scope to confirm containment. Needs `pidstat`, user `systemd-run`, `python3`, a journal; briefly allocates a few hundred MB. This is the layer the mocked suite can't cover.
- **Run a single test:** there's no test selector. The suite is a single bash file with inline assertions; comment out sections you don't want to run, or copy the `reset_test_state` + assertion block into a scratch script that sources the libs.
- **Run one monitoring cycle manually:** `bin/anomalous-mon` (with no args). This is what the systemd timer invokes — safe to run ad-hoc.
- **Inspect current tracking state:** `bin/anomalous-mon --status`.
- **Tail live logs:** `journalctl --user -u anomalous-mon -f`.
- **Force a timer-driven run now:** `systemctl --user start anomalous-mon.service`.
- **Run the weekly stale-files scan ad-hoc:** `bin/anomalous-mon --stale-scan` (also fires via `anomalous-mon-stale.timer` weekly).
- **Print the latest stale-files report:** `bin/anomalous-mon --stale-report`.
- **Silence a file the stale-scan keeps flagging:** `bin/anomalous-mon --ack /path/to/file` (or `--unack` to reverse).
- **Hunt an rclone shortcut-cycle (after a gdrive OOM alert):** `bin/rclone-cycle-scan` — scans `gdrive-lt:` + `gdrive-personal:` for self-referential Drive shortcuts that loop forever and OOM the mount; names the exact shortcut to move. See "Standalone tool" below.
- **Run a heavy job memory-capped (so an OOM can't take down the desktop):** `runcapped <command…>` (or `bin/runcapped`). Wraps the command in a memory-limited systemd user scope. See "Standalone tool: `bin/runcapped`" below.
- **Run the Python tests:** `pytest test/test_rclone_cycle_scan.py` (only the `rclone-cycle-scan` logic; everything else is bash).

There is no build step, no linter, no lockfile. Mostly bash + coreutils + sysstat (`pidstat`) + systemd + `notify-send`. The one exception is `bin/rclone-cycle-scan` (Python 3 stdlib only; shells out to `rclone`).

## Standalone tool: `bin/rclone-cycle-scan`

Not part of the 5 s monitoring loop — a **separate on-demand utility**. Reach for it when an rclone gdrive mount mysteriously OOM-kills / restarts (anomalous-mon's journal OOM alert fires). The cause is usually a **self-referential Google Drive shortcut** — a shortcut whose target is one of its own ancestor folders — which makes the mount present an infinitely deep tree; any recursive walk grows rclone's VFS heap until `MemoryMax` OOMs it. rclone has no cycle detection and `rclone mount` ignores `--max-depth`, so this scans the **remote** (Drive API, separate process — never the live mount, so it doesn't disturb the dir/VFS caches) to a bounded depth and reports the cyclic shortcut to move in the Drive web UI.

```
bin/rclone-cycle-scan                       # scan the two default remotes, depth 8
bin/rclone-cycle-scan gdrive-lt: --max-depth 12
bin/rclone-cycle-scan "gdrive-lt:Some/Subtree"   # scan one subtree deeper
```

Runs the two remotes in **parallel** (different Google accounts → independent API quotas; ~9 min wall-clock for both). Exit codes: `0` clean, `1` cycles found, `2` a scan failed. Detection logic (`detect_cycles`) is pure and unit-tested in `test/test_rclone_cycle_scan.py`. Full background + the incident that motivated it: `FINDINGS-rclone-oom-2026-06-09.md` and `PLAN-cycle-monitor.md` (which records *why* this is on-demand rather than a weekly timer). It does **not** auto-fix — you move/remove the shortcut in the Drive UI.

## Standalone tool: `bin/runcapped`

Also **not** part of the 5 s loop — the *mitigation* companion to the memory monitor. The monitor (`lib/memory-monitor.sh`) *warns*; `runcapped` *contains*. Wrap any heavy job in a memory-capped systemd `--user --scope` so that if it runs away, the kernel's **cgroup** OOM killer terminates only that job's cgroup — not the desktop session. (The 2026-06-12 incident was a *global* OOM that killed dbus/keyring/pipewire/Cinnamon precisely because the job was unconstrained.)

```
runcapped python scripts/run_sae_comparison.py --dataset asap_set1_2 --device cuda --save-matrices
runcapped -m 8G -s 0 -n bigmatrix python train.py    # 8G cap, no swap, named scope
```

Defaults: `MemoryMax`=`MemoryHigh`=18G, `MemorySwapMax`=4G (`-m`/`-s` to override; `-s 0` forbids swap so a runaway fails fast instead of thrashing). Runs in the foreground; stdin/stdout/Ctrl-C/exit-code pass through (`exec systemd-run`). A small swap cap is deliberate — it makes a runaway *fail fast* rather than grind the machine through tens of GB of swap first. Full docs: `man runcapped` (source `man/runcapped.1`) or `runcapped --help`.

**Install:** the script lives in the repo (revision-controlled); it's reached on `$PATH` via a symlink `~/.local/bin/runcapped → bin/runcapped`, and `man runcapped` works via `~/.local/share/man/man1/runcapped.1 → man/runcapped.1`. **`install.sh` creates both symlinks** (`ln -sfn`, idempotent) — the repo's installer owns them, matching the brightness-ctl/dev-vm-manager convention, so a fresh `yadm bootstrap` (clone repo + run `install.sh`) gets `runcapped` on `$PATH` for free. Editing the repo file IS the deploy (same model as the systemd `ExecStart`).

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

**`df` exit-code resilience (load-bearing).** `df` exits **non-zero** when *any* mount can't be stat'd — a dead fuse mount (`Transport endpoint is not connected`) is common debris after an OOM kills a gvfs/fuse helper. `df` still prints every healthy mount to stdout, so `_disk_sample_cmd` wraps the `df | awk` pipeline in `{ …; } || true`. Without this, the caller's `set -e` turns one flaky mount into an aborted *entire* monitoring cycle — and since `disk_check` runs **before** the memory/stale checks, a single dead mount silently took the whole monitor down every tick. (This is exactly what happened post-incident on 2026-06-12.)

### Memory monitoring (`lib/memory-monitor.sh`)

Proactive — fires *before* the kernel OOM killer, unlike the journal OOM detector which is post-mortem. Motivated by the 2026-06-12 global-OOM incident (`PLAN-memory-monitor.md`): an unconstrained Python job exhausted RAM+swap and the global OOM killer tore the desktop session apart. `memory_check` does everything in one pass (no separate sample/check split like CPU) and fires on **two independent criteria**:

- **Signal A — system-wide pressure** (threshold + cooldown, like disk). Fires when combined free headroom `MemAvailable + SwapFree` drops below `MEM_MIN_HEADROOM_MB`, **OR** memory PSI `full` avg60 ≥ `MEM_PSI_FULL_PCT` (the kernel is *stalling* on memory — the earliest "thrashing/freeze" signal). Body lists the top-3 RSS consumers. Group `mem:pressure`; cooldown `MEM_PRESSURE_COOLDOWN`. **Guarded on `sys_total > 0`** so an empty/garbage sample (zeros) doesn't read as "zero headroom" and false-alarm.
- **Signal B — per-process runaway growth** (consecutive-cycle streak, reusing cpu-monitor's state-machine shape). A process alerts only when it is **both** large (`RSS ≥ MEM_GROWTH_FLOOR_MB`, ~1 GB — anything smaller is ignored) **and** has grown by `≥ MEM_GROWTH_TICK_MB` for `MEM_GROWTH_CYCLES` consecutive ~1-minute cycles. This is deliberately **not a raw slope**: a tiny driver creeping bytes/year is below the floor *and* below the per-cycle delta, so it never qualifies; a sawtooth/GC process breaks its streak each dip. The streak resets (and clears the alert) the moment growth stalls. Per-process overrides via `MEM_GROWTH_OVERRIDES` (comm → cycles) let known legitimate growers (browsers, ballooning VMs) need a longer streak. Group `mem:runaway:<name>`.

**Sampling** (`_memory_sample_cmd`, overridable via `_MEM_SAMPLE_CMD`; `set_mock_memory` in tests). Emits one `sys <mem_total_kb> <mem_avail_kb> <swap_total_kb> <swap_free_kb> <psi_full_avg60>` line (from `/proc/meminfo` + `/proc/pressure/memory`) followed by `proc <pid> <rss_kb> <comm>` lines (one awk pass over `/proc/[0-9]*/status`; kernel threads with no `VmRSS` are skipped). The awk pass carries a load-bearing `|| true` (same class as the df guard): a process exiting between glob expansion and awk opening its file makes mawk/gawk die fatally with exit 2, which under `set -e` killed whole cycles intermittently on t480 (FINDINGS-mem-sampler-proc-race-2026-07-20.md). `_MEM_PROC_ROOT` overrides the `/proc` root as the regression-test seam. The per-PID trend state tracks *every* process so growth can be measured from first sighting; PID reuse just resets the streak (new tiny RSS < prev + tick). `_MEM_NOW` overrides the clock for cooldown tests.

**The mitigation companion is `bin/runcapped`** — wrap a heavy job in a memory-capped systemd scope so an OOM kills only the job, not the desktop. See "Standalone tool" below. The monitor *warns*; `runcapped` *contains*.

### Battery monitoring (`lib/battery-monitor.sh`)

**Opt-in per host** — written for a laptop that runs 24/7 on AC as a server (t480-server) with its charge capped below 100% for pack longevity. The tracked config ships all three settings empty; with all three empty `battery_check` returns before sampling, so desktops and everyday laptops are untouched. A host enables checks in `etc/anomalous-mon.conf.local`. Three independent checks per pack, each with its own key `battery:<pack>:<check>` and a shared `BATTERY_COOLDOWN`:

- **low** — capacity < `BATTERY_LOW_PCT`. The message distinguishes *AC offline* (running on battery: breaker trip or outage) from *AC online* (the pack is not charging back up: charge-cap/EC fault or a failing pack).
- **high** — capacity > `BATTERY_HIGH_PCT`: the charge cap is not holding. Don't enable it until the packs are actually below it, or it fires immediately.
- **threshold** — `charge_control_end_threshold` != `BATTERY_EXPECT_END_THRESHOLD`: the cap itself was lost (EC reset, unit not applied). The leading indicator — *high* only notices after the pack has charged past the cap.

**Sampling** (`_battery_sample_cmd`; `_BATTERY_SAMPLE_CMD` mock, `_BATTERY_PS_ROOT` fake-sysfs seam, `_BATTERY_NOW` clock seam) reads `/sys/class/power_supply`: `type == Battery` and `scope != Device` (a wireless mouse is also a power_supply "Battery"), status spaces → underscores, AC = any `Mains` supply online, `-` when the pack has no threshold support. Wrapped in `{ …; } || true` per the sampler rule (FINDINGS-mem-sampler-proc-race-2026-07-20.md).

### Stale large-files monitor (`lib/stale-files-monitor.sh`)

A **separate weekly timer** (`anomalous-mon-stale.{service,timer}`, `OnCalendar=Mon 03:00` with `RandomizedDelaySec=2h`, `Persistent=true`). Not invoked from the 5s loop — a filesystem walk every 5s would be absurd. The main binary's `--stale-scan` flag is the service entrypoint.

Pipeline per scan: `find` → ignore filter → ack filter → summarize + alert → write report.

**`find` invocation.** Per scan root, with `-xdev` to keep within one filesystem, plus an auto-built `-prune` group for FUSE/network mount targets that sit under the root. Output is `size_bytes\tmtime_epoch\tpath`. Wrapped in `nice -n 19 ionice -c 3` to stay polite. `LC_ALL=C` so `%T@` is dot-formatted under non-C locales. Uses `+${N}G` size syntax (readable; rounding imprecision is fine for "looking for big").

**Mount auto-prune.** `_stale_excluded_mounts_under` reads `findmnt --raw -lo TARGET,FSTYPE`, keeps mounts under the scan root whose fstype matches `STALE_FILES_FSTYPE_EXCLUDE` (`fuse.*|nfs.*|cifs|smbfs|virtiofs|sshfs|gvfs|davfs`). `_stale_build_prune_clauses` then folds those targets, plus any **literal-prefix** entries from `STALE_FILES_IGNORE`, into a `-path X -o -path Y -o ...` group that `find` skips before descending. Globby ignore entries stay as a post-filter in the read loop.

**Ignore vs ack.** Two-tier silencing:
- `STALE_FILES_IGNORE` (config array): permanent, supports glob and prefix subtree. Matched via `[[ $path == $pat ]] || [[ $path == $pat/* ]]`.
- Ack file (runtime): per-path with TTL. Lives under `${XDG_STATE_HOME:-$HOME/.local/state}/anomalous-mon/stale-acks` — **persistent**, not under `XDG_RUNTIME_DIR` (which is wiped on logout). Format `<epoch>\t<path>`. On load, entries older than `STALE_FILES_ACK_TTL` days are silently dropped and pruned from the saved file.

**Single summary alert.** One scan emits one `send_alert_action` call: *"Found N large stale files (X GB total). Click 'Open report' or run 'anomalous-mon --stale-report'."* No grouping (weekly cadence makes replace-id pointless). The action button opens the report file via `xdg-open`. If `send_alert_action` isn't defined (shouldn't happen post-install), falls back to `send_alert`.

**Report format.** Written to `${STATE_DIR}/anomalous-mon.stale-report`: header (timestamp, scan params, root list, ack count), then sorted-desc-by-size table of `SIZE / AGE / PATH`, capped at `STALE_FILES_MAX_REPORT_ENTRIES` (default 50). Empty scan still writes the report with "No stale files found." so `--stale-report` always shows something coherent.

**mtime, not atime.** Documented caveat: relatime/noatime make atime unreliable, so a file you `cat` daily but never edit looks stale. This is intentional — large read-only files (ISOs, VM images, archives) are exactly what we want to surface.

### Clickable notifications (`lib/notify.sh`'s `send_alert_action`)

Companion to `send_alert`. Same fire-and-forget contract from the caller's perspective, but spawns a **transient systemd-run scope** (`systemd-run --user --no-block --quiet --unit=anomalous-mon-notify-<slug>-<pid>`) running a small bash that invokes `notify-send --wait --action="action=<label>" ...`. When the user clicks the action button, notify-send prints `action` to stdout, the inner bash `eval`s the `ACTION_CMD`. When the bubble is dismissed (X button or daemon expiry) without action, the eval is skipped and the unit cleans up.

Why systemd-run: `Type=oneshot` services take their cgroup with them when the main PID exits, which would kill a backgrounded `notify-send --wait`. The transient unit is independent.

Fallback path: if `systemd-run` isn't available, emits a regular `notify-send` bubble with no `--wait` and no action button. Log line always fires (journal audit trail independent of click handling).

**Security note.** `ACTION_CMD` is `eval`'d in the transient scope. Quote paths with `${PATH@Q}` when constructing. Never interpolate untrusted data.

### Test mocking model (`test/test-anomalous-mon.sh`)

The libs are designed to be sourced and mocked:

- `_CPU_SAMPLE_CMD` — override `_cpu_sample_cmd` with a function returning fake `pid %cpu comm args` lines. `set_mock_ps "..."` is a convenience helper.
- `_JOURNAL_CMD` — override `_journal_cmd` with a function returning fake journalctl JSON.
- `_DISK_SAMPLE_CMD` — override `_disk_sample_cmd` with a function returning fake `target fstype pcent avail_kb` lines (one per mount). `set_mock_disk "..."` is the convenience helper.
- `_STALE_FILES_SCAN_CMD` — override `_stale_files_scan_cmd` with a function returning fake `size_bytes<TAB>mtime_epoch<TAB>path` lines. `set_mock_stale "..."` is the convenience helper.
- `_STALE_FINDMNT_CMD` — override `_stale_findmnt_cmd` for mount-prune testing. Emits `target<SPACE>fstype` lines. `set_mock_findmnt "..."` is the convenience helper.
- `_MEM_SAMPLE_CMD` — override `_memory_sample_cmd` with a function returning a fake `sys …` line + `proc <pid> <rss_kb> <comm>` lines. `set_mock_memory "..."` is the convenience helper. `_MEM_NOW` overrides the clock for pressure-cooldown tests.
- `_NPROC` — override `nproc` for deterministic total-CPU threshold math (fixed to 4 in tests).
- `_CPU_SAMPLE_INTERVAL` — overrides the `pidstat` interval (default 60s) so the live smoke test can sample in ~2s instead of waiting a full minute. Not used by the mocked suite.

**The mocked suite cannot test the default samplers themselves** (the real pidstat/df/`/proc`/journalctl/find parsing) or true end-to-end alerting — those replace points are exactly what's mocked. `test/test-live.sh` is the opt-in complement that runs the real samplers and drives a real runaway process + real `runcapped` OOM, asserting on the actual alert text. Add coverage for new *logic* to `test-anomalous-mon.sh`; add coverage for new *real-I/O parsing or e2e behavior* to `test-live.sh`.

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
| `anomalous-mon.mem-state` | Memory: per-PID runaway-growth trend (Signal B) | `pid:<PID>:<NAME>:<LAST_RSS_KB>:<STREAK>:<ALERTED>` per line |
| `anomalous-mon.mem-alerts` | Memory: system-pressure cooldown (Signal A) | `mem:pressure:<epoch>` per line (parsed like `disk-alerts`) |
| `anomalous-mon.notify-ids` | group → notify-send id | `<group>\t<id>` per line |
| `anomalous-mon.stale-report` | Stale-files: latest human-readable report | header + sorted SIZE/AGE/PATH table; regenerated each scan |
| `anomalous-mon.stale-last-scan` | Stale-files: timestamp of last scan | single epoch |

Plus **one persistent file** outside `XDG_RUNTIME_DIR` (would be lost on logout otherwise):

| File | Purpose | Format |
|---|---|---|
| `${XDG_STATE_HOME:-$HOME/.local/state}/anomalous-mon/stale-acks` | Stale-files ack list, per-path TTL silencing | `<epoch>\t<path>` per line. Expired entries pruned on next load. |

Corrupt state files are tolerated: the loaders parse defensively and fall through to empty state on garbage (tested).

## Conventions

- Libs declare `_FOO` private helpers (underscore prefix) and expose only a small public surface (`cpu_sample`, `cpu_check_alerts`, `cpu_status`, `journal_check`, `send_alert`, `clear_alert`, `is_alert_active`).
- State I/O uses a write-tmp-then-`mv` pattern for atomicity — follow it when adding new state files.
- Configuration lives in `etc/anomalous-mon.conf`, sourced by `bin/anomalous-mon` at startup. Don't hardcode thresholds in libs.

## Design docs at repo root

- `PLAN.md` — original project plan.
- `PLAN-<feature>.md` — per-feature design plans, written *before* implementation. Each starts with a **Status:** banner (`Implemented` vs `Pending`) — a `PLAN-*.md` for a shipped feature is kept around as historical design context (rationale that the code itself doesn't capture), not as an open todo. Examples: `PLAN-disk-monitor.md` (Implemented), `PLAN-service-monitor.md` (Pending).
- `FINDINGS-<topic>-<date>.md` — diagnostic write-ups of incidents that motivated (or could have been caught by) a monitor. Useful context when designing new checks; often paired with a `PLAN-*.md` for the resulting feature (e.g. `FINDINGS-lock-failure-2026-05-02.md` motivates `PLAN-service-monitor.md`).

When you start a new feature, write a `PLAN-<feature>.md` first with `Status: Pending`. When it ships, flip the banner to `Status: Implemented` and add a pointer to the implementing file/commit. Don't delete it — the original design rationale is often the most useful breadcrumb six months later.
