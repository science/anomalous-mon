# FINDINGS — intermittent `status=2/INVALIDARGUMENT` cycle deaths (memory sampler /proc race)

**Date:** 2026-07-20. **Status:** root-caused, fixed, regression-tested.

## Symptom

On t480-server, `anomalous-mon.service` died on a single cycle 2–3×/day at
random times with `code=exited, status=2/INVALIDARGUMENT`, self-recovering on
the next timer fire ~5s later. No error text in the journal. Occasionally
paged via hc-bridge when its 30s poll happened to land inside the ~5s failed
window. First occurrence Jul 15 14:53 — the day the memory monitor shipped
(`1407beb`). Failing runs lasted ~62s: exactly the 60s pidstat sample plus the
fast post-sample checks, i.e. the failure sat in `memory_check`.

## Root cause

`_memory_sample_cmd` (lib/memory-monitor.sh) ran:

```bash
awk '…' /proc/[0-9]*/status 2>/dev/null
```

The shell expands the glob first; awk then opens each file in turn. If any
process exits in that window, the file is gone — and mawk/gawk treat an
unopenable command-line input file as a **fatal error, exit status 2**
(mawk also skips the remaining files). Unlike `_cpu_sample_cmd` and
`_disk_sample_cmd`, this sampler had no `|| true`, so under `bin/anomalous-mon`'s
`set -euo pipefail` the whole cycle aborted with status 2. The `2>/dev/null`
is why the journal showed no error text.

This is the same bug class as the 2026-06-12 df incident (dead fuse mount →
df non-zero → cycle abort), which is why `_disk_sample_cmd`'s `|| true` is
documented as load-bearing. The memory sampler simply missed the same guard.

Nuance found while writing the regression test: mawk aborts *at open* of the
bad file, so the proc entry pending flush (the previous file's) is lost along
with the tail. Consequence with the fix: a mid-list vanish costs part of one
tick's proc list — those PIDs' growth streaks reset and re-arm next tick.
Rare (2–3/day) and self-healing; no false alerts.

## Proof

- `mawk 'END{…}' /nonexistent` → prints "cannot open", exit 2. (An empty
  program `'{}'` exits 0 — mawk optimizes away the read — which is why a naive
  probe can look fine.)
- The exact sampler awk under heavy process churn (`/bin/true` fork loops) hit
  rc=2 on the first iteration.
- Full `bin/anomalous-mon` run under the same churn exited 2 with **empty
  stderr** — the exact production signature — on the first cycle; with the fix,
  50/50 cycles clean under identical churn.

## Fix

`lib/memory-monitor.sh`: append `|| true` to the awk (mirroring the df guard),
and make the proc root overridable (`${_MEM_PROC_ROOT:-/proc}`) as a test seam.
Regression tests in `test/test-anomalous-mon.sh` exercise the REAL sampler
against a fake proc root containing an unreadable status file: sampler must
exit 0 and still emit earlier procs, and `memory_check` must survive
end-to-end. The e2e assertion crosses a process boundary (`bash -c 'set -e …'`)
because a function called in an `if` condition runs with `set -e` ignored and
could never go red.

## Related

- The t480 RCA plan that scoped this hunt (xtrace wrapper + soak — not needed;
  static analysis + local repro found it first):
  `~/dev/home-assistant/docs/plans/anomalous-mon-code2-rca.md`.
- FINDINGS-lock-failure-2026-05-02.md / the df guard in `_disk_sample_cmd` —
  prior art for "sampler must not take the cycle down".
