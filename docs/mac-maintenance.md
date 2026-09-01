# Mac maintenance script

> Purpose: Manually-run health/cleanup check. Unlike
> [`weekly-disk-cleanup.sh`](./weekly-cleanup.md), this is **not** scheduled
> via launchd — you run it yourself when you want a quick report.

## Where the file lives

Unlike most of this repo, this one isn't copy-based — there's a single
copy, [`scripts/mac-maintenance.sh`](../scripts/mac-maintenance.sh), and
you run it directly from here. No live copy elsewhere to keep in sync.

## What it does

| Section | What it does |
|---|---|
| **Uptime** | `uptime` |
| **Memory stats** | `vm_stat`, plus a human-readable approximate-available-memory summary |
| **Library caches cleanup** (added 2026-08-24, moved-not-deleted 2026-09-01) | Moves `~/Library/Caches/*` into a timestamped folder under `~/.Trash` (`mac-maintenance-caches-YYYYMMDD-HHMMSS`), rather than `rm -rf`. Every app rebuilds its cache on demand, so this is expected to be safe either way, but moving into Trash gives an actual restore window instead of relying solely on that convention — `weekly-disk-cleanup.sh`'s existing "Trash items older than 7 days" step is what eventually reclaims the space (see [`weekly-cleanup.md`](./weekly-cleanup.md)). Some entries may fail to move with "Permission denied" if the owning app is running and has the file open (e.g. an active browser profile, a running helper process) — those are skipped, not fatal, since the `mv` is wrapped with `|| true` so the script continues past `set -e`. |

Everything is written to `~/maintenance-YYYYMMDD.log` (new file each run)
and echoed to the terminal via `tee`.

## Roadmap

Currently manual-only (see Purpose note above). The eventual goal is to
run this automatically on a schedule (daily or weekly, same pattern as
[`weekly-disk-cleanup.sh`](../scripts/weekly-disk-cleanup.sh)'s launchd
job), which requires each section to be **idempotent** — safe to re-run
repeatedly without cumulative side effects. Current status per section:

- **Uptime/memory reporting** — read-only, already idempotent.
- **Library caches cleanup** — effectively idempotent (moving an
  already-empty cache is a no-op, and each run's quarantine folder is
  uniquely timestamped so repeated runs never collide), but not yet
  verified across repeated runs.

Not yet scheduled via launchd — that's the next step once the above is
confirmed safe to automate.

## Run it

```zsh
zsh ~/dev/dotfiles/scripts/mac-maintenance.sh
```

## Note on `set -e`

The script has `set -e` at the top, so any command that exits non-zero
aborts the rest of the script. The cache-cleanup `mv` is deliberately
suffixed with `|| true` for this reason — without it, a single locked file
mid-cache would kill the script before later sections (or future additions)
run.

## Related, but separate

Deeper/riskier disk cleanup (npm/pip cache, Docker prune, aged Trash) is
handled by the actual scheduled job — see
[`weekly-cleanup.md`](./weekly-cleanup.md). `~/media` and `~/Downloads`
review is still manual/personal, per that doc's "deliberately left out of
automation" section.
