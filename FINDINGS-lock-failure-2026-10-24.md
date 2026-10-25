# Idle lock failure — 2026-10-24 (VM console keyboard grab)

## Symptom

The 30-minute idle lock on linux-bambam silently failed three times:
2026-10-21 16:03 and 16:33, and 2026-10-23 19:24. Each time the journal shows:

```
org.cinnamon.ScreenSaver[N]: Starting screensaver...
xidlehook[N]: lock-screen: cinnamon-screensaver did NOT activate within 2s.
cinnamon-session[3109]: Detected that screensaver has left the bus   (~30 s later)
```

The desktop then stayed unlocked until the next input. xidlehook fires its
lock timer once per idle period, so nothing retried.

This is a different cause from `FINDINGS-lock-failure-2026-05-02.md`, where
cinnamon-screensaver died after every spawn.

## Root cause

cinnamon-screensaver must grab the keyboard and pointer before it activates
(`/usr/share/cinnamon-screensaver/manager.py` `set_active` → libcscreensaver
`grab_root`). If another X client holds an active grab, it retries a few
times, then gives up quietly and exits about 30 s later.

The incus dev VM consoles (spice-gtk `remote-viewer`, two of them, running
since Oct 6 and Oct 10) hold an **active keyboard grab whenever the pointer
is over the VM display, whether or not the viewer has focus**.

## Evidence (reproduced live, no sudo)

Test harness: start `cinnamon-screensaver --debug` by hand, request a lock,
poll `--query`, unlock with `cinnamon-screensaver-command --deactivate`.
That call unlocks as the same user with no password: `SetActive(false)` →
`manager.unlock()`.

- **dev-1 focused, pointer on the viewer's menu strip:** locked in 200 ms.
- **dev-1 focused, pointer over the VM display:** not locked. The debug log shows:
  ```
  Grabbing keyboard widget=0x1ee
  Couldn't grab keyboard!  (AlreadyGrabbed)     x4
  Nuking focus
  Couldn't grab keyboard!  (AlreadyGrabbed)     x4
  ```
- **Same state, the real `~/bin/lock-screen --force`:** rc=2, "did NOT
  activate". This is the exact production signature.
- **X server grab dump** (`setxkbmap -option grab:debug; xdotool key
  XF86LogGrabInfo`), written to `/var/log/Xorg.0.log`:
  ```
  Active grab 0x5e00000 (xi2) on device 'Virtual core keyboard' (3):
        client pid 9974 /usr/bin/remote-viewer spice+unix:///home/steve/.config/incus/sockets/1490907274.spice
  ```

A small probe tried to grab the keyboard and released it at once. It
mapped exactly which states leave the grab held:

- **Grabbed:** dev-1 focused with the pointer over the VM display. Also grabbed with the pointer still over the VM display but a terminal focused, or no window focused at all.
- **Free:** the pointer moved to another monitor, or onto the viewer's menu strip.
- **Free:** dev-1 minimized.

`lock-screen`'s old workaround, `xdotool windowactivate <nemo-desktop>`
when a viewer was focused, **was a no-op**. It fails with `XGetWindowProperty[_NET_WM_DESKTOP]
failed` and focus stays on the viewer. Even if it had worked, moving focus
does not release the grab.

## Fix (yadm, 2026-10-24)

`~/bin/lock-screen` does the following on each attempt:

1. If the pointer is over a remote-viewer, virt-viewer, vncviewer or vinagre window, move it to a monitor's bottom-centre or centre. This counts as input, which is harmless because the lock follows.
2. Verify with `~/bin/x-keyboard-grab-free`. If the grab is still held, minimize the viewers.
3. Run `cinnamon-screensaver-command --lock` and wait up to 6 s.

It makes 3 attempts, 10 s apart, and stops early if input shows a person is
back. On final failure it dumps the X grabs to Xorg.0.log, sends a critical
"Idle lock FAILED" notification and forces DPMS standby. `flock` serialises runs.

Also: `sleep-blockers` now probes for a held grab instead of checking focus.

With the fix, `lock-screen --force` from the bad state locked in 200 ms.

## Monitoring notes

- Failure line to alert on: `lock-screen: giving up: the screen is NOT
  locked` (journal tag `lock-screen`). Per-attempt lines name the active
  window, the pointer's window and the probe result.
- `pkill -f <pattern>` in a test harness can kill its own shell when the
  pattern text appears in the shell's command line. Match exact `args`
  with `ps`/`awk` instead.
