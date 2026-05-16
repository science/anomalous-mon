# Idle lock failure — 2026-05-02

## Symptom

Left machine for ~6 hours. On return, the desktop was unlocked and the
machine had not suspended. This has happened before; previous fix
(re-enabling a daemon "needed for sleep") addressed a different layer.

## Diagnosis

xidlehook is firing on schedule. The actual lock is silently failing
because **cinnamon-screensaver has been dying after spawn since
2026-05-02 ~01:00**, so every hourly `cinnamon-screensaver-command --lock`
is a no-op. The `xset dpms force standby` part of `~/bin/lock-screen`
runs and blanks the monitor, but does not lock anything — when input or
a video tab nudges the X server, the monitor wakes back up to a fully
unlocked desktop.

## Layout of the chain

```
xidlehook (3600s timer)
  └─ ~/bin/lock-screen
       ├─ cinnamon-screensaver-command --lock   ← sends Lock dbus call
       └─ xset dpms force standby                ← blanks monitor only
```

`xset force standby` is **not** a lock — it only powers down the panel.
The lock comes entirely from cinnamon-screensaver responding to the
`Lock` dbus method.

## Evidence

### xidlehook is fine

- `xidlehook.service` active since 2026-04-28, PID 3136676, never
  restarted.
- Timers: `--timer 3600 lock-screen --timer 7200 'systemctl suspend'`.
- Wakelock log shows the lock-screen path firing every hour at HH:02
  for the past 11+ hours. DPMS goes Standby ~12s later, Suspend at +30m,
  Off at +30m05s. Mechanically reliable.

### Lock dbus call is being delivered

`journalctl --user` shows hourly auto-activation:

```
May 02 14:02:39 dbus-daemon: Activating service name='org.cinnamon.ScreenSaver'
May 02 15:02:44 dbus-daemon: Activating service name='org.cinnamon.ScreenSaver'
May 02 16:02:50 dbus-daemon: Activating service name='org.cinnamon.ScreenSaver'
... (every hour)
May 02 20:03:12 dbus-daemon: Activating service name='org.cinnamon.ScreenSaver'
```

Each activation comes from a fresh dbus client (the
`cinnamon-screensaver-command` process the lock-screen script invokes).
That means: cinnamon-screensaver is **not** running persistently — every
Lock call is dbus-activating a new instance.

### The new instance dies without locking

Wakelock-logger subscribes to
`org.cinnamon.ScreenSaver.ActiveChanged`. Pattern in
`~/.local/state/wakelock-logger.log`:

| Date         | ActiveChanged true | ActiveChanged false |
|--------------|--------------------|---------------------|
| 2026-05-01   | 13:49, 14:45, 20:29, 23:58 | 13:54, 17:58, 01:01 (May 2) |
| 2026-05-02   | **none**           | 01:01 (above)       |

Last successful activation: **2026-05-01 20:29:25**.
Last deactivation: **2026-05-02 01:01:27**.
After that, every hourly `Lock` call has produced zero `ActiveChanged`
signals — the screen never enters the locked state.

The PIDs spawned each hour by dbus activation are all gone:
`ps -p 38229 -p 51098 -p 63817 -p 89679` returns nothing. The daemon
exits without sticking around to manage a lock.

### Current process state

- No persistent `cinnamon-screensaver` process. Only `csd-screensaver-proxy`
  (the inhibit shim) is running.
- `cinnamon-screensaver-command --query` → "The screensaver is not
  currently active."
- cinnamon-session lists `org.cinnamon.ScreenSaver` as a
  `RequiredComponent`, so it should be alive — but isn't.

## Why suspend (the 2h xidlehook timer) never fires either

`systemctl suspend` is xidlehook's second timer at 7200s, but it never
fires. The 3600s timer reliably fires once per hour, which means
`IDLETIME` is being reset shortly after each lock attempt — likely a
combination of the DPMS wake cycle, Firefox's `Playing video` /
`XResetScreenSaver` pings (a YouTube tab was the active window during
the incident), and other inhibitor traffic visible in the dbus log
(slack, xdg-desktop-portal-xapp, firefox all called Inhibit recently).
The result: 1h lock attempt → idle resets → 1h later, lock attempt
again — never reaching 2h.

## Suggested anomalous-mon checks

This bug class would have been catchable by any of:

1. **xidlehook fired but no `ActiveChanged true` followed within 10s.**
   Strongest signal. Wakelock-logger already captures both halves;
   anomalous-mon could correlate them.
2. **`cinnamon-screensaver` not in process list while a graphical
   session is active.** It's a `RequiredComponent`, so its absence is
   anomalous on its own.
3. **`Lock` dbus call observed but no subsequent `ActiveChanged true`
   within N seconds.** Same as (1) but expressed as a dbus invariant.
4. **`xidlehook` timer index never advances past 0** (i.e., the second
   timer never fires across long observation windows). Indicates the
   1h timer is in a reset loop and the system will never actually
   suspend.
5. **DPMS reaches Off but session `IdleHint` is still `no`** — means
   the monitor went dark but logind doesn't think the session is idle,
   which usually means the lock screen never engaged.

## Suggested fixes (separate from monitoring)

- Spawn cinnamon-screensaver in foreground once with stderr captured to
  find out why dbus-activated instances are dying:
  `nohup /usr/bin/cinnamon-screensaver >/tmp/css.log 2>&1 &`
- If it stays alive when launched manually, give it its own `--user`
  systemd unit (mirroring `xidlehook.service`) so it doesn't depend on
  dbus auto-activation surviving long enough to actually lock.
- Belt-and-braces: change `~/bin/lock-screen` to fall through to
  `loginctl lock-session` if `cinnamon-screensaver-command --lock`
  doesn't produce an `ActiveChanged true` within ~2s. That decouples
  the lock from cinnamon-screensaver's health.

## Files referenced

- `~/.config/systemd/user/xidlehook.service` — timer config
- `~/bin/lock-screen` — what xidlehook fires (lock + DPMS standby)
- `~/.local/state/wakelock-logger.log` — primary evidence trail
- `~/.config/yadm/dconf/cinnamon-linux-bambam.dconf` — confirms
  `idle-activation-enabled=false` is intentional (xidlehook-managed)
- `~/dev/brightness-ctl/PLAN_screensaver_dpms.md` — related prior work
