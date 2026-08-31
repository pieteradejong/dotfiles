# Mac maintenance script

> Purpose: Manually-run health/cleanup check. Unlike
> [`weekly-disk-cleanup.sh`](./weekly-cleanup.md), this is **not** scheduled
> via launchd — you run it yourself when you want a quick report.

## Where the files live

Same copy-based pattern as the rest of this repo (see main
[README](../README.md)): `~/scripts/mac-maintenance.sh` is the live file;
[`scripts/mac-maintenance.sh`](../scripts/mac-maintenance.sh) here is the
backup. No automatic sync — copy manually when edited.

## What it does

| Section | What it does |
|---|---|
| **Uptime** | `uptime` |
| **Memory stats** | `vm_stat`, plus a human-readable approximate-available-memory summary |
| **Library caches cleanup** (added 2026-08-24) | Wipes `~/Library/Caches/*`. Safe: every app rebuilds its cache on demand. Some entries may fail to delete with "Permission denied" if the owning app is running and has the file open (e.g. an active browser profile, a running helper process) — those are skipped, not fatal, since the `rm -rf` is wrapped with `|| true` so the script continues past `set -e`. |

Everything is written to `~/maintenance-YYYYMMDD.log` (new file each run)
and echoed to the terminal via `tee`.

## Run it

```zsh
zsh ~/scripts/mac-maintenance.sh
```

## Note on `set -e`

The script has `set -e` at the top, so any command that exits non-zero
aborts the rest of the script. The cache-cleanup `rm -rf` is deliberately
suffixed with `|| true` for this reason — without it, a single locked file
mid-cache would kill the script before later sections (or future additions)
run.

## Related, but separate

Deeper/riskier disk cleanup (npm/pip cache, Docker prune, aged Trash) is
handled by the actual scheduled job — see
[`weekly-cleanup.md`](./weekly-cleanup.md). `~/media` and `~/Downloads`
review is still manual/personal, per that doc's "deliberately left out of
automation" section.
