# Disk-space warning module for anomalous-mon

> **Status: Implemented** in `lib/disk-monitor.sh` (commit `d54f8f3`). Kept as historical context for the WARN/CRITICAL severity rules and the AND-gate rationale.

## Context

dev-1 just hit 100% disk (39 GB used / 1.1 MB free) and wedged the shell — the
Claude instance inside could not fork to run `rm` or `df` because `/tmp` was
full. By the time the user noticed, manual recovery from the host was the only
option.

We want an *earlier* warning, percentage-based, so the system is still usable
when the alert arrives. The warning needs to cover all three machines the user
works on: the host workstation (linux-bambam) and both dev VMs (dev-1, dev-2).

## Why anomalous-mon (vs. a "more native Linux" option)

The host already runs anomalous-mon via a user systemd timer with a dedup-aware
notify-send pipeline, and **it is already deployed identically on host +
dev-1 + dev-2** through yadm bootstrap (all three appear in
`YADM_DESKTOP_MACHINES`, all have `notify-send` from `apt-desktop.txt`, all run
Cinnamon sessions). Adding disk alongside CPU and OOM is ~150 lines of bash
with zero new dependencies. Alternatives considered and rejected:

- `cron + df + mailx` — requires an MTA, no desktop bubble, diverges per host.
- Prometheus node_exporter + Alertmanager — heavy server stack for a
  workstation.
- Cockpit — dashboard, not push alerts.
- GNOME/Cinnamon has no built-in filesystem-space alerter.

PLAN.md:140 already lists disk monitoring as a "not yet" item — this is the
expected next module.

## Files

**Create:**
- `/home/steve/dev/anomalous-mon/lib/disk-monitor.sh`

**Modify:**
- `/home/steve/dev/anomalous-mon/bin/anomalous-mon` — source the lib, call
  `disk_check`, include disk in `--status`.
- `/home/steve/dev/anomalous-mon/etc/anomalous-mon.conf` — add disk config
  block + `DISK_THRESHOLD_OVERRIDES` associative array.
- `/home/steve/dev/anomalous-mon/test/test-anomalous-mon.sh` — new "Disk
  Monitor Tests" section (10 cases) + add the new file to the structure
  assertion.
- `/home/steve/dev/anomalous-mon/PLAN.md` — move disk from "not yet" to
  implemented.
- `/home/steve/dev/anomalous-mon/README.md` — one-paragraph mention in the
  module list.

## Module contract

```
disk_check ALERT_STATE_FILE WARN_PCT CRIT_PCT MIN_FREE_GB WARN_COOLDOWN CRIT_COOLDOWN
```

Six positional args (mirrors `journal_check`'s shape). Reuses the
journal-monitor cooldown pattern verbatim — see
`lib/journal-monitor.sh:33-87` for `_load_*_alerts`, `_save_*_alerts`,
`_alert_suppressed`, `_alert_record`. Same structure, renamed globals
(`_DISK_ALERTED` instead of `_JOURNAL_ALERTED`).

**Severity semantics:**
- `pcent >= CRIT_PCT` → CRITICAL fires (unconditional on %). Short cooldown,
  keeps nagging.
- `pcent >= WARN_PCT` **and** `avail_gb < MIN_FREE_GB` → WARN fires. Long
  cooldown. The AND-gate is what silences a 2 TB disk at 80% (400 GB free)
  while still catching a 40 GB VM at 80% (8 GB free).
- CRITICAL fired for a mount in this tick suppresses WARN for the same mount
  in the same tick.

## Config additions (`etc/anomalous-mon.conf`)

```bash
# Disk-space monitoring
DISK_WARN_PCT=80              # percent-used for WARN
DISK_CRIT_PCT=92              # percent-used for CRITICAL
DISK_MIN_FREE_GB=10           # WARN gated by absolute headroom (see module contract)
DISK_WARN_COOLDOWN=1800       # 30 min between WARN repeats per mount
DISK_CRIT_COOLDOWN=300        # 5 min between CRITICAL repeats per mount

# Per-mount override. Value is "warn:crit:min_free_gb" — any field may be "-"
# to inherit the default. /boot legitimately runs 70-80% full; raise its bar.
declare -A DISK_THRESHOLD_OVERRIDES=(
    [/boot]="90:97:0.1"
    [/boot/efi]="90:97:0.05"
)
```

**Default tuning rationale.** With `MIN_FREE_GB=10`:
- 40 GB VM at 80% (8 GB free) → WARN fires (8 < 10). ✓
- 40 GB VM at 92% (3.2 GB free) → CRITICAL fires. ✓
- 2 TB workstation at 80% (400 GB free) → WARN suppressed (400 ≥ 10). ✓
- 2 TB workstation at 92% (160 GB free) → CRITICAL fires — arguably noisy,
  but acceptable since % threshold on a healthy disk this large signals fast
  fill rate.

## Integration (`bin/anomalous-mon`)

After `journal_check`, add:

```bash
DISK_ALERT_FILE="${STATE_DIR}/anomalous-mon.disk-alerts"

disk_check "$DISK_ALERT_FILE" \
    "$DISK_WARN_PCT" "$DISK_CRIT_PCT" "$DISK_MIN_FREE_GB" \
    "$DISK_WARN_COOLDOWN" "$DISK_CRIT_COOLDOWN"
```

`--status` gains a paragraph listing each monitored mount with `used% /
free GB / alert state`.

## State file

`${STATE_DIR}/anomalous-mon.disk-alerts`, one entry per line:

```
disk:<mount>:<severity>:<epoch>
```

Same load/save/prune behavior as `anomalous-mon.oom-alerts`. Pruned on each
save using the longer of the two cooldowns.

## Notification format

Plain text, no emoji — matches the existing cpu/journal alerts:

- WARN:     `WARN: /home ext4 at 85% (12 GB free)`
- CRITICAL: `CRITICAL: / ext4 at 93% (2 GB free)`

Call shape: `send_alert "disk" "disk:${mount}:${severity}" "$msg" "disk:${mount}"`.
GROUP = `disk:<mount>` (without severity) so as a mount climbs warn→critical
the bubble replaces in place rather than stacking.

## Filesystem enumeration

`findmnt --real` leaks 15+ squashfs snap mounts on this host, so use `df` with
explicit `-x` excludes, then parse:

```bash
_disk_sample_cmd() {
    df -P --output=target,fstype,pcent,avail \
        -x tmpfs -x devtmpfs -x squashfs -x overlay \
        -x fuse.portal -x fuse.rclone -x fuse.snapfuse \
        -x autofs -x nfs -x nfs4 -x cifs -x smbfs -x virtiofs \
        2>/dev/null \
      | awk 'NR>1 { gsub(/%/,"",$3); print $1, $2, $3, $4 }'
}
```

Overridable via `_DISK_SAMPLE_CMD` for tests, matching the `_CPU_SAMPLE_CMD` /
`_JOURNAL_CMD` pattern. `disk_check` also applies an in-module fstype-exclude
filter as belt-and-suspenders in case a mock (or future sample source) leaks
tmpfs/squashfs through.

## Headless-session fallback

anomalous-mon runs as a systemd **user** timer. On an SSH-only dev-VM session
(no active Cinnamon / D-Bus), `notify-send` fails silently — the existing
behavior in `lib/notify.sh`. The `[ALERT]` line always lands in the journal,
so the fallback channel on a headless VM is:

```
journalctl --user -u anomalous-mon.service -f
```

This is a pre-existing limitation of the project, not introduced here. No
extra work unless the user wants cross-VM alert forwarding (out of scope).

## Test plan

New section `=== Disk Monitor Tests ===` in
`/home/steve/dev/anomalous-mon/test/test-anomalous-mon.sh`. Uses
`_DISK_SAMPLE_CMD="_mock_disk"` injection, mirroring `_CPU_SAMPLE_CMD`:

1. Below warn → no alert.
2. Crosses warn **and** below min-free → WARN fires; alert key
   `disk:/:warn` recorded.
3. Crosses warn **but** plenty absolute free (e.g. 500 GB free) → WARN
   suppressed. Validates the AND gate.
4. Crosses critical → CRITICAL fires; WARN suppressed in same tick.
5. Per-mount override: `/boot` at 80% with `90:97:0.1` override → no alert;
   same mount at 92% → WARN fires with overridden thresholds.
6. Cooldown dedup: two back-to-back `disk_check` calls at critical → one
   alert. Backdate the state file → second alert fires (parallel to existing
   OOM cooldown test).
7. Fstype filter: mock includes a squashfs and tmpfs line at 99% → no alerts.
8. Empty df output → no crash, no alert.
9. Garbage df line (missing column) → skipped, no crash.
10. Structure assertion: `lib/disk-monitor.sh` exists (add to existing file
    list).

Expected result: **49 existing tests + 10 new = 59 pass.**

## Verification (end-to-end on a live machine without actually filling a disk)

1. **Parse sanity:** `cd /home/steve/dev/anomalous-mon; source
   lib/disk-monitor.sh; _disk_sample_cmd` — confirms 4-column output.

2. **Force a WARN on `/` via temporary low thresholds:**
   ```bash
   DISK_WARN_PCT=10 DISK_CRIT_PCT=99 DISK_MIN_FREE_GB=99999 \
   DISK_WARN_COOLDOWN=60 DISK_CRIT_COOLDOWN=60 \
   bash -c '
     cd /home/steve/dev/anomalous-mon
     source etc/anomalous-mon.conf
     source lib/notify.sh
     source lib/disk-monitor.sh
     NOTIFY_ID_FILE=/tmp/t.ids disk_check /tmp/t.disk-alerts \
       "$DISK_WARN_PCT" "$DISK_CRIT_PCT" "$DISK_MIN_FREE_GB" \
       "$DISK_WARN_COOLDOWN" "$DISK_CRIT_COOLDOWN"'
   ```
   Expect a desktop bubble "anomalous-mon: disk — WARN: / ext4 at …% …";
   `/tmp/t.disk-alerts` contains a `disk:/:warn:<epoch>` line.

3. **Critical-replaces-warn bubble:** repeat step 2 with `DISK_CRIT_PCT=10`
   immediately after. GROUP `disk:/` causes the bubble to replace in place
   rather than stack — visually verifiable in the notification tray.

4. **Cooldown:** run step 2 three times within a minute → only the first
   produces a bubble; `/tmp/t.disk-alerts` epoch unchanged after dedup.

5. **Full suite:** `./test/test-anomalous-mon.sh` → 59 pass.

6. **Live deploy check:** `bin/anomalous-mon --status` on host + dev-1 +
   dev-2. Expect no `[ALERT] disk:` lines on healthy machines. Watch
   `journalctl --user -u anomalous-mon.service -f` for one timer tick and
   confirm clean `[tracking]` output.

## Out of scope

- Cross-machine alert forwarding (VM → host) for headless SSH sessions.
- Inode exhaustion (`df -i`).
- Per-process disk-usage attribution (which process is filling the disk).
- Predictive alerts (fill-rate extrapolation).

These can be follow-ups; the present plan addresses only the "catch a
filesystem crossing a % threshold before it wedges" requirement.
