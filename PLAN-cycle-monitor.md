# PLAN: rclone shortcut-cycle scanner (on-demand utility)

**Status: Implemented** (2026-06-10, `bin/rclone-cycle-scan` + `test/test_rclone_cycle_scan.py`)

Motivated by `FINDINGS-rclone-oom-2026-06-09.md`: self-referential Google Drive
shortcuts create infinite directory loops that grow rclone's VFS heap until the
mount OOM-kills. rclone has no cycle detection and `rclone mount` ignores
`--max-depth` (verified empirically), so a cycle can only be found by an
out-of-band, bounded-depth scan of the remote.

## Why on-demand, not a weekly timer

The original plan (below, superseded) was a weekly systemd-timed scan with a
deadman self-check. Reconsidered 2026-06-10 and **deliberately scoped down** to a
freestanding CLI utility, no timer, for these reasons:

- **The base rate is tiny and falling.** Two cycles ever, in tens of thousands of
  folders, both artifacts of one retired "mixrun" tool. Scanning ~9 min of Drive
  API churn every Friday, 52×/year, to catch a near-zero-rate event is
  disproportionate.
- **The consequence already has a detector.** A cycle only hurts when something
  walks it deep enough to OOM — and that OOM-kill fires `anomalous-mon`'s existing
  journal alert (`lib/journal-monitor.sh`). That alert *is* the trigger. The
  weekly scan was just front-running an alarm we already have.
- **A cycle that never gets walked isn't a problem.** Proactive scanning would
  flag loops that would never actually detonate.

So: the OOM alert tells you *when*; this utility tells you *which shortcut*. You
run it on demand, it names the culprit, you move the shortcut in the Drive UI.

## The utility: `bin/rclone-cycle-scan`

Freestanding, executable Python 3 script (stdlib only; shells out to `rclone`).
Does **not** source any anomalous-mon lib or read its config — self-contained so
it's trivially runnable and testable.

```
bin/rclone-cycle-scan [REMOTE...] [--max-depth N] [--rclone-flags "..."]
                      [--report-file F] [--json] [-q]
```

- **Default remotes** when none given: `gdrive-lt:` and `gdrive-personal:`
  (personal included because broken shortcuts get parked there). Positional args
  override.
- **Scans the REMOTE, never the mount.** Runs `rclone lsf <remote> -R --dirs-only
  --max-depth N --format "ip" --separator \t --drive-skip-dangling-shortcuts` —
  a separate short-lived process hitting the Drive API. It never touches
  `~/gdrive/...`, so it neither force-loads the live mount's dir-cache nor evicts
  hot files from the 10 GB VFS cache, and `--dirs-only` reads no file contents.
- **Parallel across remotes** (`ThreadPoolExecutor`): each remote is a different
  Google account, so Drive's per-user query limit (~10/s) is independent —
  measured 2026-06-10, two concurrent scans ran at full speed, zero throttling.
  Wall-clock ~9 min for both vs ~17 min sequential. A per-remote scan failure is
  isolated and reported; the exit code reflects it.
- **Detection** (`detect_cycles`, the pure unit-tested core): each `lsf` line is
  `id\tpath`; a *shortcut's* id field is itself `targetID\tshortcutID`, so a
  shortcut line has 3 tab-fields. Contract: **path = last field, effective
  (target) id = first field, shortcut id = second field (or the id, for a plain
  folder)**. Build `effective_id[path]`; for each path, walk its `/`-split
  ancestor prefixes — a cycle exists when an ancestor shares the path's effective
  id. One finding per **shortcut id** (dedup keeps the shallowest occurrence — the
  shortcut's real location; deeper repeats are the loop unrolling). Detection runs
  **per remote** (Drive ids are globally unique but ancestry is only meaningful
  within one remote's path tree).
- **Output**: a human report to stdout (header: remotes, depth, timestamp; then
  one block per cycle — looping folder path + copy-pasteable shortcut id to move).
  `--json` emits machine-readable findings. `--report-file F` also writes the
  report to a file. `-q` suppresses the per-remote progress lines on stderr.
- **Exit codes**: `0` = clean, `1` = cycles found, `2` = a scan failed (rclone
  error / partial coverage). Lets you wire it into `&&` chains or a future hook.

### `--max-depth` caveat

`--max-depth 8` (default) only catches cycles whose loop-point sits within that
depth; both known cycles loop at depth ~5–6. For a deeper sweep, raise it or pass
a specific deep subtree as the remote arg (e.g. `gdrive-lt:Learning Tapestry
Main/Partners`). `--fast-list` is deliberately NOT used: it rebuilds the tree from
a flat object list and wouldn't traverse the shortcut, so it could miss the very
cycles we scan for — per-directory traversal is what exposes loops.

### Tests: `test/test_rclone_cycle_scan.py` (pytest)

Tests the pure `detect_cycles` function (no network, no rclone): direct self-loop
→ 1 finding; A↔B two-hop → 2 findings (each cyclic shortcut once — removing either
breaks the loop); same-name/different-id → 0 (false-positive guard); clean tree
→ 0; malformed/short lines tolerated; shortcut-id (3-field) parsing. The script is
loaded via `importlib` from its hyphenated path so the logic stays in one
freestanding file. `pyproject.toml` declares `requires-python` + a `pytest`
dev-extra; no runtime deps.

## What was dropped vs the original weekly-monitor design

- No systemd `.service`/`.timer` pair, no `OnCalendar=Fri 20:00`.
- No deadman / staleness self-check, no persistent last-scan timestamp.
- No `lib/cycle-monitor.sh`, no `lib/cycle_monitor.py`, no `bin/anomalous-mon`
  flag wiring (`--cycle-scan`/`--cycle-report`), no `etc/anomalous-mon.conf` block.
- No desktop `send_alert_action` integration — the existing OOM journal alert is
  the notification path; this tool's output is its report.

The detection logic is identical to what the weekly plan specified; only the
*delivery* (on-demand CLI vs timed service + alert glue) changed.

## Out of scope

- Auto-remediation (moving/deleting the shortcut). Detection + a copy-pasteable
  fix only; the user removes the shortcut in the Drive UI.
- Re-introducing a schedule. If the OOM alert ever proves insufficient (e.g.
  cycles start forming faster than they detonate), wrap this same binary in a
  systemd timer — the utility is the reusable core either way.
