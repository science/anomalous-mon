# rclone gdrive-lt OOM — 2026-06-09

## Symptom

`anomalous-mon` fired an OOM alert: `gdrive-lt.service: Failed with result
'oom-kill'` at 18:43:56. The mount was auto-restarted by systemd 10s later.
Suspected to be a recurrence of the May dangling-shortcut issue we thought
was fixed. It was **not** — same drive, different (and worse) failure mode.

## Diagnosis

A **self-referential Google Drive shortcut** creates an **infinite directory
loop**. rclone resolves shortcuts transparently, so a shortcut whose target
is one of its own ancestors makes the mount present an endlessly-deep tree:

```
Company Information…            (folder A, id 0B_bPdwK3VDKOVUx4dHNSdm0yMFU)
  └─ Corporation Documents mixrun   (id 15zn8DztDL0BYKpV3g3P9imYxFzqKgrV6)
       └─ Company Information…       ← SHORTCUT 1j_aVtSuQozFFDY69QGvzP3C6y5seBNc
            └─ target = A  → loops:  A → mixrun → A → mixrun → …
```

Any **recursive walk** of that subtree (an indexer, file manager, backup,
editor workspace search, `find`/`grep -r`, or rclone's own poll-driven
refresh) descends forever. rclone's VFS allocates a fresh node per path
level, so its in-memory directory tree grows **without bound** until the
unit's `MemoryMax=3G` cgroup cap trips the OOM killer.

This is **distinct** from the May 2026 dangling-shortcut problem:

| | Dangling shortcut (May) | Cyclic shortcut (this) |
|---|---|---|
| Target | deleted/moved → 404 | a live ancestor folder |
| Resource | CPU (re-resolve per listing) | **memory** (unbounded VFS tree) |
| `--drive-skip-dangling-shortcuts` | suppresses it | **no effect** (shortcut resolves fine) |
| Outcome | CPU alert | OOM-kill + mount restart |

`--drive-skip-dangling-shortcuts` cannot prevent a cycle because the cyclic
shortcut is *resolvable*, not dangling.

## Evidence

### Kernel OOM report (the heap was the directory tree, not page cache)

```
Memory cgroup out of memory: Killed process 1710027 (rclone)
  total-vm:15171948kB  anon-rss:3082788kB  file-rss:19200kB  swapents:2456371(pages)
```

- **anon-rss 3.0 GB** (resident) hit `MemoryMax=3G` → cgroup OOM.
- **swapents 2,456,371 pages ≈ 9.4 GB** more in swap → ~12.5 GB total heap.
- **file-rss only 19 MB** → *not* page cache, *not* `--buffer-size`/read-ahead
  per open file. Genuine Go heap = the runaway VFS node tree.
- `GOMEMLIMIT=1250MiB` is a *soft* limit; unbounded live allocation blew past
  it ~10×, so only the hard `MemoryMax` stopped it — by killing.

### Reproduction (caught early, no second OOM)

A controlled `find /home/steve/gdrive/lt` was caught 12+ levels deep with open
FDs showing the path segment `Corporation Documents mixrun/Company Information…`
repeating. cgroup `memory.current` climbed monotonically (40→84 MB in the few
minutes observed) and stopped the instant the walk was killed — confirming the
walk drives the growth.

### A second cycle existed

A bounded depth-8 directory scan (6,365 dirs, ID-based detector) found a second,
**direct** self-loop:

```
# Learning Tapestry Main/Partners/00 - Archive/Archives from Steve's mixrun/K12 OCX/04-Project Workspace
  folder id     = 1-wto8748Q4fFEOgsKOqFINgztBYA0xR6
  shortcut      = 1rs2NuujFHUDRQ0JAH7u861RhU8ibXSqN   (named "04-Project Workspace", target = the folder itself)
```

Both cycles sit under *"…mixrun"* folders — artifacts of a "mixrun" tool that
created self-referential shortcuts. That folder-name pattern is the highest-yield
place to look for more.

## Fix

1. **Break each cycle** by removing the loop-back *shortcut* (not the real
   folder). Done in the Drive web UI — "Remove shortcut", or **Move** it to a
   location **outside** the target folder's subtree (the real folder and its
   contents are untouched):
   - `1j_aVtSuQozFFDY69QGvzP3C6y5seBNc` — moved to personal *Drive>archive* (2026-06-09). Verified gone.
   - `1rs2NuujFHUDRQ0JAH7u861RhU8ibXSqN` — removed 2026-06-09.
   **Verified clean (2026-06-09):** after both removals, a full-drive depth-8
   ID scan (6,367 dirs) and a depth-20 scan of all 4 `*mixrun*` roots (3,752
   dirs) both reported **0 confirmed cycles**.
2. **Backstop:** `MemoryMax=3G` on `gdrive-lt.service` already confines a runaway
   to a mount restart instead of a system-wide OOM. Keep it. A heavier defense —
   `--drive-skip-shortcuts` (disables *all* shortcut resolution) — would make any
   cycle impossible but also hides legitimate shortcuts (the LT drive has ~111),
   so it was not adopted.

## Detection recipe (for the next time a gdrive OOM fires)

Never recurse the live mount to find a cycle — that *is* the bomb. Use a
**bounded-depth** listing that expands shortcuts but caps recursion, then flag
any folder whose Drive ID appears nested under itself:

```bash
# list dirs with IDs, capped depth (safe: cannot recurse infinitely)
rclone lsf gdrive-lt: -R --dirs-only --max-depth 8 --format "ip" --separator $'\t' \
  --drive-skip-dangling-shortcuts > /tmp/dirs.txt

# a shortcut id is emitted as "targetID<TAB>shortcutID"; the path is the LAST tab field.
# cycle  <=>  some path's target-id equals the target-id of one of its ancestors.
```

The `--max-depth` only catches cycles whose loop-point is within that depth;
scoped deep re-scans of `*mixrun*` folders cover deeper ones cheaply.

## Related

- `memory/rclone-gdrive-dangling-shortcuts.md` — the May CPU issue (different
  failure mode; corrected to cross-reference this).
- `lib/journal-monitor.sh` — the OOM detector that surfaced this.
