# System overview

> Purpose: The one-page answer to "what is this repo for, what runs on a
> schedule, and where does everything actually live." Ties together the
> per-topic docs rather than replacing them — each section links to the
> detailed file. For the historical "what happened and why" record, see
> [`maintenance-audit-2026-09.md`](./maintenance-audit-2026-09.md).

## 1. Why this repo exists

**To reproduce this entire computer from a GitHub clone.** Not just shell
config — the dev environment, editor settings, tool versions, and macOS app
preferences, so that replacement hardware can be brought back to a working
state without reconstructing anything from memory.

The success criterion is concrete: on a brand-new Mac, `git clone` followed
by `dotrestore` should produce a usable machine.

```mermaid
flowchart LR
    A["This Mac<br/><small>.zshrc · .gitconfig<br/>editors · macOS plists</small>"]
    B["~/dev/dotfiles<br/><small>local git repo</small>"]
    C["GitHub<br/><small>remote, public</small>"]
    D["New machine<br/><small>after git clone</small>"]
    E["Live files<br/><small>reproduced</small>"]

    A -->|"dotbackup"| B
    B -->|"push"| C
    B -->|"dotrestore"| A
    C -.->|"git clone<br/>(one-time)"| D
    D -->|"dotrestore"| E
```

`dotrestore` is the same command in both places — recovering a broken config
on this Mac and bootstrapping a new one are the same operation. The dashed
hop is the only manual step unique to new hardware.

**Important asymmetry:** `dotbackup` flows one way, live → repo. An edit made
to the *repo* copy that isn't also made to the live file in `~` is silently
overwritten on the next backup. This has bitten this repo before — see
[LEARNINGS.md](../LEARNINGS.md#issue-edits-made-in-the-repo-silently-disappear-after-dotbackup).

## 2. Where everything lives

Paths changed on 2026-09-01; these are current.

| Thing | Path | Notes |
|---|---|---|
| This repo | `~/dev/dotfiles` | moved from `~/dotfiles` |
| Loose personal scripts | `~/dev/projects/scripts/` | moved from `~/scripts`, which no longer exists |
| `mac-maintenance.sh` | `~/dev/dotfiles/scripts/` | **repo only** — single copy, run directly from here |
| `weekly-disk-cleanup.sh` | `~/dev/projects/scripts/` | live copy; launchd runs this path. Repo holds a manual backup copy |
| LaunchAgent plist | `~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist` | backed up to `macos/` and synced by `dotbackup` |
| Secrets | `~/.zshrc.secret` | outside the repo, mode `0600`, never committed |

Most of the repo is **copy-based, not symlinked** — live files in `~` are
what the system reads; the repo holds copies. `mac-maintenance.sh` is the
one deliberate exception: it has no live copy and is executed straight out
of the repo, so there is nothing to keep in sync.

## 3. Maintenance model

Two scripts, deliberately different in kind:

| | `weekly-disk-cleanup.sh` | `mac-maintenance.sh` |
|---|---|---|
| **Trigger** | Automatic — launchd, Sundays 09:00 | Manual — you run it |
| **Scope** | npm/pip cache, Docker prune, Trash >7 days | Uptime, memory report, `~/Library/Caches` |
| **Risk posture** | Only reclaims what regenerates or was already discarded | Reporting + cache quarantine |
| **Docs** | [`weekly-cleanup.md`](./weekly-cleanup.md) | [`mac-maintenance.md`](./mac-maintenance.md) |

### The goal for `mac-maintenance.sh`

**Eventually run it on a schedule** — daily or weekly, the same launchd
pattern the weekly cleanup already uses — so Mac housekeeping happens
without being remembered. The blocker is **idempotency**: a scheduled script
must be safe to re-run indefinitely without cumulative side effects.

Current status:

- **Uptime / memory reporting** — read-only, already idempotent.
- **Library caches cleanup** — as of 2026-09-01 this *moves* caches into a
  uniquely timestamped `~/.Trash/mac-maintenance-caches-<timestamp>/` folder
  instead of `rm -rf`. Repeated runs never collide, and
  `weekly-disk-cleanup.sh`'s 7-day Trash purge is what actually reclaims the
  space — so there's a real restore window. Effectively idempotent, but not
  yet verified across repeated runs.

Not yet scheduled. That's the next step once repeated runs are confirmed safe.

## 4. Run history

Every run of `mac-maintenance.sh` writes `~/maintenance-YYYYMMDD.log`. Three
runs exist so far, all manual — the gaps are eight months, then eight days,
which is exactly the problem scheduling is meant to solve.

| Run | Available memory | `~/Library/Caches` | Reclaimed |
|---|---|---|---|
| 2025-12-21 | 10.13 GB | — | — |
| 2026-08-24 | 10.25 GB | 262M → 258M | ~4 MB |
| 2026-09-01 | 9.97 GB | 4.4G → 124K | ~4.3 GB |

Reading these honestly:

- **The Dec 2025 run predates the cache step**, which was added 2026-08-24 —
  hence no figure.
- **The 2026-09-01 figure is not a typical weekly delta.** It was triggered
  while verifying the script consolidation, and it cleared caches that had
  accumulated across the preceding eight months. A scheduled weekly run would
  show numbers far closer to the 4 MB row.
- **All three runs predate the move-to-Trash change**, so their "After"
  figures reflect the old immediate `rm -rf` behaviour.
- **Memory readings are a snapshot, not a trend.** Three points taken at
  unrelated moments of unrelated workloads; the ~0.3 GB spread is noise, not
  signal. It becomes a real series only once runs are scheduled.

## 5. Visualization

A rendered view of the pipeline diagram and the run-history data:

**<https://claude.ai/code/artifact/7717cc86-7fd6-489d-98a6-2332fda381a1>**

Private to this account — the link will not resolve for anyone else unless
explicitly shared.

## 6. Related docs

| Doc | What it covers |
|---|---|
| [README](../README.md) | Quick start, commands, security posture, live TODO list |
| [`mac-maintenance.md`](./mac-maintenance.md) | The manual script in detail |
| [`weekly-cleanup.md`](./weekly-cleanup.md) | The scheduled job, its launchd setup, Full Disk Access limitation |
| [`maintenance-audit-2026-09.md`](./maintenance-audit-2026-09.md) | Aug/Sep 2026 cleanup, `~/config` retirement, security audit, open fallout |
| [LEARNINGS.md](../LEARNINGS.md) | Reusable gotchas — including the one-way `dotbackup` hazard |
| [`reinstall-commands.md`](./reinstall-commands.md) | Commands to reconstruct the system |
