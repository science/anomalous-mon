# PLAN: Add `service-monitor.sh` — alert on user/system unit not-active

## Context

Suspend on the user's workstation depends on `xidlehook.service` (a user systemd unit) staying alive. It has SEGV'd twice in 10 days and was once manually stopped during diagnosis and forgotten — leaving suspend silently broken for 12 days. There is no existing visibility on "this service is dead."

anomalous-mon is the natural home for this check: it already runs every 5s, has notify-send plumbing, cooldowns, atomic state-file writes, tests, and journal-tagged alerts. We add a fourth monitor — service liveness — alongside CPU/OOM/disk.

The check is generic (configurable unit list), so future "service should be alive" needs (e.g. `dpms-wake.service`) reuse the same code.

## Behavior

For each unit in `SERVICE_CHECK_UNITS`:
- Sample state via `systemctl [--user|--system] is-active <unit>`.
- If `active`: clear any tracked `first_inactive` for the unit.
- If not active: record `first_inactive = now` on first observation. On subsequent ticks, if `now - first_inactive >= SERVICE_DOWN_THRESHOLD`, fire an alert (subject to `SERVICE_COOLDOWN`).
- Alert message: `<unit> has been <state> for <Nm Ns> — run: systemctl [--user] start <unit>`.

State value (`active`, `inactive`, `failed`, `activating`, `deactivating`) is included in the alert body so the user can distinguish a crash-loop (`activating` flapping) from a hard-stopped unit (`inactive`).

Notification group is `service:<unit>` so successive alerts for the same unit replace the bubble in place rather than stacking (matches disk-monitor's `disk:<mount>` group convention).

## Files to add

- `lib/service-monitor.sh` — mirror the shape of `lib/disk-monitor.sh`. Public surface: `service_check`, `service_status`. Private helpers prefixed `_service_*`.
- Tests inside the existing `test/test-anomalous-mon.sh` — a new section "Service Monitor Tests" mirroring the disk-monitor section.

## Files to modify

- `etc/anomalous-mon.conf` — add three new variables (config knobs below).
- `bin/anomalous-mon` — source the new lib (after the existing `disk-monitor.sh` source); declare `SERVICE_ALERT_FILE`; call `service_check` after `disk_check`; extend `--status` to call `service_status`.
- `README.md` — add a "Service liveness" bullet to the "What it monitors" section, and document the new config keys.
- `CLAUDE.md` — add an "## Architecture → Service liveness (`lib/service-monitor.sh`)" section describing the state-file format and mocking hook (`_SERVICE_STATE_CMD`).

## State file

Path: `${XDG_RUNTIME_DIR:-/tmp}/anomalous-mon.service-alerts`

Two record types per line, both consumed by the existing `${line%:*}` / `${line##*:}` parser convention:

```
service:<unit>:first_inactive:<epoch>   # when we first noticed it was non-active
service:<unit>:alerted:<epoch>          # when we last fired (for cooldown gating)
```

Pruning: drop entries whose epoch is older than `max(SERVICE_DOWN_THRESHOLD, SERVICE_COOLDOWN)` ago AND the unit is currently active. Don't prune `first_inactive` for an actively-down unit even if old — that's the timer.

## Config knobs (etc/anomalous-mon.conf additions)

```bash
# Service liveness — alert when listed units are not "active" for too long.
# Each entry is "<unit>" (default user scope) or "system:<unit>" for system units.
SERVICE_CHECK_UNITS=(
    "xidlehook.service"
    # "system:dpms-wake.service"   # example for a system unit
)
SERVICE_DOWN_THRESHOLD=300   # seconds — alert if not-active for >= this long
SERVICE_COOLDOWN=1800        # seconds — re-alert cadence while unit is still down
```

## Public function signatures

```bash
# Main check called from bin/anomalous-mon.
service_check ALERT_STATE_FILE DOWN_THRESHOLD COOLDOWN UNIT_LIST_REF

# Status output for `bin/anomalous-mon --status`.
service_status ALERT_STATE_FILE UNIT_LIST_REF
```

`UNIT_LIST_REF` is the name of the SERVICE_CHECK_UNITS array (passed by name to support older bash; or pass as `"${SERVICE_CHECK_UNITS[@]}"` directly — pick whichever matches the project's existing convention; disk-monitor passes scalar args, so service-monitor will probably take the array via `nameref` or as trailing positional args).

## Mocking hook

`_SERVICE_STATE_CMD` — override `_service_state_cmd` with a function that, given a unit spec (`xidlehook.service` or `system:foo.service`), echoes the state string. Default implementation shells out to `systemctl [--user|--system] is-active <unit>`. Mirrors the `_DISK_SAMPLE_CMD` / `_CPU_SAMPLE_CMD` / `_JOURNAL_CMD` pattern.

Add `set_mock_service "<unit> <state>\n<unit> <state>..."` convenience helper alongside `set_mock_disk` etc.

## Test scenarios (mirror disk-monitor's coverage)

1. Unit active → no alert, no state recorded.
2. Unit goes inactive on first tick → state records `first_inactive = T0`, no alert (under threshold).
3. Unit stays inactive < threshold → no alert, `first_inactive` stable.
4. Unit stays inactive >= threshold → alert fires once, `alerted` recorded.
5. Subsequent tick still inactive, within cooldown → no re-alert.
6. Subsequent tick still inactive, past cooldown → re-alert (`alerted` updated).
7. Unit recovers → `first_inactive` cleared, `alerted` cleared.
8. Unit goes inactive again later → cycle restarts cleanly from step 2.
9. Multiple units in `SERVICE_CHECK_UNITS` → independent state per unit.
10. State `failed` vs `activating` vs `inactive` all count as "not active"; alert message includes the actual state.
11. Corrupt state file → loaded defensively (no crash, empty state).
12. Notification grouping: two consecutive alerts for the same unit use the same `service:<unit>` group (verified via `setup_real_notify_test` like the disk grouped tests).

## Verification (manual, after install)

1. `./test/test-anomalous-mon.sh` passes (incl. new section).
2. `systemctl --user is-active xidlehook.service` → confirms baseline state.
3. Lower `SERVICE_DOWN_THRESHOLD=10` temporarily in `etc/anomalous-mon.conf`, then:
   - `systemctl --user stop xidlehook.service`
   - Wait ~15s.
   - Critical-urgency Cinnamon toast appears with message "xidlehook.service has been inactive for ~15s — run: systemctl --user start xidlehook.service".
   - `journalctl --user -u anomalous-mon -f` shows `[ALERT] service: ...` line.
   - `systemctl --user start xidlehook.service` → next tick clears state.
4. Restore `SERVICE_DOWN_THRESHOLD=300`.
5. `bin/anomalous-mon --status` shows a "Service State" section listing each monitored unit and its current state + alert flag.

## Out of scope for this change

- **`systemd-coredump`** to capture the underlying SEGV. Worth doing — but it's an apt package change, not a code change to this project. Track separately (one-line edit to the user's yadm-tracked `~/.config/yadm/packages/apt-linux-bambam.txt`).
- **Re-evaluating logind `IdleAction=suspend` fallback.** User declined for now; the watchdog is the primary safety net.
- **Restarting xidlehook automatically when down.** Tempting, but if it's down because of a SEGV loop, an auto-restart could mask the diagnostic signal we want. Alert-only is correct; user pulls the trigger.

## Why this fits anomalous-mon

The monitoring loop is identical in shape to `disk_check`:
- Sample fresh state each tick.
- Track per-key threshold-crossing in a state file.
- Alert with grouped notify-send + journal log.
- Suppress within cooldown window.

The only conceptual difference is the sample is a string (`active`/`inactive`/...) rather than a numeric percent. The state-file format, the loader/saver pattern, the `send_alert` group convention, and the test mocking model all carry over directly. ~150 lines of bash, plus mirror tests.
