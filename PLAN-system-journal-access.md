# Reading OOM events from the system journal

> **Status: Implemented** in `lib/journal-monitor.sh` (`_journal_system_cmd`, `_journal_check_system`) plus the yadm sudoers rule `~/.config/yadm/sudoers.d/anomalous-mon-journal` (2026-11-02).

## Problem

`_journal_cmd` ran `journalctl --user --system`. steve is not in the `adm` or
`systemd-journal` group, so journald silently returned only steve's user
journal. Kernel OOM-kill lines and system services' `oom-kill` results never
reached the monitor: the journal OOM alerts for them could not fire. Found
while diagnosing a USB hub fault on 2026-11-02, when `journalctl -k` as steve
returned nothing.

## Options considered

- **Add steve to `systemd-journal`.** One line, but every process running as
  steve (browser, npm scripts, editor plugins, Claude Code) could then read
  all system logs, the kernel log (undoing `kernel.dmesg_restrict=1`), sudo's
  command audit trail, and the `test` user's journal (`user-1002.journal`).
  It weakens the steve/test separation and the kernel-log restriction for one
  alert. Rejected.
- **Run anomalous-mon as another user.** It has to be steve: it notifies on
  steve's session bus (same-uid only), scans steve's home for stale files and
  starts `runcapped` scopes in steve's user manager. Rejected.
- **A relay daemon** (DynamicUser + `SupplementaryGroups=systemd-journal`)
  writing filtered lines to `/run/anomalous-mon/`. Works, but adds a service
  and a root-owned copy of the filter. Rejected as more machinery than needed.
- **A sudoers rule naming one exact query.** Chosen (steve's suggestion):
  sudo is designed to allow a specific command with specific arguments.

## Design

The rule allows exactly `_JOURNAL_SYSTEM_ARGV`:

```
/usr/bin/journalctl --system --no-pager --quiet --output=json --since=-10min \
    --grep=Out.of.memory|oom-kill|Killed.process|memory.max|MemoryMax|memory.limit
```

- **No variable arguments.** sudo's `*` wildcard matches across spaces, so
  `--after-cursor=*` would also accept `--after-cursor=x <any options>`, which
  means the whole journal. A fixed relative window (`--since=-10min`, which
  journalctl resolves itself) avoids wildcards entirely. Duplicates across
  overlapping windows are dropped by `__REALTIME_TIMESTAMP`.
- **`--system`** reads system services and the kernel, never users' journals.
- **`--grep`** filters inside journalctl, so only matching lines are returned.
  It avoids spaces and backslashes (sudoers escaping; `.` stands in for space).
  The exact bash regexes in `_journal_handle_line` still decide what alerts.
- **`--no-pager` + `NOEXEC`.** `sudo journalctl` with a terminal starts `less`,
  whose `!sh` is a shell. `--no-pager` stops the pager; NOEXEC stops
  journalctl from executing anything at all.
- **Group, not root.** `(:systemd-journal)` with `sudo -g systemd-journal`
  runs it as steve with the journal group. A hole in the rule could leak
  journal contents, never root.
- **NOPASSWD** (runs every 5 s), with `!log_allowed, !pam_session,
  !pam_setcred, !use_pty` for this command only, so allowed runs add no log
  lines. Refused variants are still logged.
- The rule file is root-owned in `/etc/sudoers.d`, so changing the query
  needs the PIN, even though anomalous-mon itself is edited and deployed
  straight from the repo.

## What a compromised steve account still gets

Lines matching the pattern from system services and the kernel: OOM-kill
records, including the killed process's name and uid for any user. Nothing
else.

## Tests

- `test/test-anomalous-mon.sh`: system pass alerts, de-duplicates by
  timestamp, cold-start cutoff, never moves the user cursor, survives a
  failing query under `set -e`, skips sudo when the rule is absent, calls sudo
  with the exact argv; sudo audit lines are ignored.
- `test/test-live.sh`: the real rule allows the real query; output is JSON.
- yadm `test-dotfiles.sh`: rule parses and is installed 0440; sudo allows the
  exact argv (sourced from this repo) and refuses it as root, with an extra
  argument, without `--no-pager`, and with a different `--grep`.

## Incident during rollout

sudo writes refused command lines into steve's user journal. The refusal
tests' command lines contain the `--grep` pattern, so the user pass matched
them as OOM events and fired two false alerts. Fix: skip entries with
`SYSLOG_IDENTIFIER=sudo`. (This false-positive path predated the change: any
sudo command line mentioning `oom-kill` would have triggered it.)
