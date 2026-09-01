# Weekly disk cleanup

> Purpose: Automated weekly job that reclaims disk space from caches and
> trash that either regenerate automatically or were already discarded.
> Set up 2026-08-20 after a home-directory disk space review (drive was at
> 95% capacity, 52GB free of 926GB).

## Where the files live

This repo is copy-based (see main [README](../README.md)) — the *live*
files that actually run are in your home directory; the copies here are
backups kept in sync via `dotbackup` / `dotrestore`.

| Live location | Backed up here |
|---|---|
| `~/scripts/weekly-disk-cleanup.sh` | [`scripts/weekly-disk-cleanup.sh`](../scripts/weekly-disk-cleanup.sh) |
| `~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist` | [`macos/com.pieterdejong.weeklycleanup.plist`](../macos/com.pieterdejong.weeklycleanup.plist) |

`sync-dotfiles.sh backup`/`restore` handles the plist automatically
(added to the macOS section alongside iTerm2/Rectangle). The script itself
is copied manually when edited — there's no automatic sync for `scripts/`.

## What runs, and why it's safe

| Step | What it does | Why it's safe |
|---|---|---|
| **npm cache** | `npm cache verify` then `npm cache clean --force` on `~/.npm/_cacache` | npm re-downloads any package tarball on the next `npm install`. No source code or project files touched. |
| **pip cache** | `pip3 cache purge` on `~/Library/Caches/pip` | pip re-downloads wheels/sdists on the next `pip install`. |
| **Docker** | `docker system prune -f` | Removes only stopped containers, unused networks, dangling (untagged) images, and build cache. Deliberately **not** `-a` — that flag also removes any image not currently backing a container, which could force a slow re-pull of something meant to be kept. Skipped entirely if Docker Desktop isn't running (checked via `docker info`), so the job never hangs waiting on it. |
| **Trash** | Deletes items in `~/.Trash` older than **7 days** | Anything trashed this week survives until next week's run, so an accidental delete still has a recovery window before it's permanent. |

Each section is wrapped independently — if one step fails or is skipped
(e.g. Docker not running), the rest still execute.

## Logs

- `~/.weekly-disk-cleanup.log` — the script's own log (before/after sizes per section), trimmed to last 1000 lines automatically
- `~/.weekly-disk-cleanup.launchd.log` — raw stdout/stderr from launchd (mostly useful if the script fails to launch at all)

## Schedule

Every **Sunday at 9:00 AM**, whether or not the Mac is actively in use at
that moment (as long as it's awake — launchd does not wake a sleeping Mac
for this job, it just runs it at the next opportunity after wake, or skips
if the Mac was off entirely).

## Common operations

**Run it manually right now** (doesn't wait for Sunday):
```zsh
launchctl start com.pieterdejong.weeklycleanup
cat ~/.weekly-disk-cleanup.log
```

**Check it's registered:**
```zsh
launchctl list | grep weeklycleanup
```

**Change the schedule** (edit `Weekday` 0=Sun..6=Sat, `Hour`, `Minute` in
`~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist`), then reload:
```zsh
launchctl unload ~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist
launchctl load ~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist
```
Remember to also update the copy in `dotfiles/macos/` (`dotbackup` will
pick it up automatically next time it runs).

**Disable/remove entirely:**
```zsh
launchctl unload ~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist
rm ~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist
rm ~/scripts/weekly-disk-cleanup.sh
```
(and remove the copies from `dotfiles/scripts/` and `dotfiles/macos/` if
retiring it for good.)

## Known limitation: Trash and pip cache need Full Disk Access

Tested on 2026-08-20 by comparing a launchd-triggered run against running
the script directly in a terminal:

- **npm cache** and the **Docker daemon check** behaved identically both
  ways — reliable as-is.
- **Trash** and **pip cache** were largely a no-op under launchd (a test
  file placed in `~/.Trash` was left untouched; pip only removed 4 stray
  files instead of the full ~2100-file cache) but worked completely when
  run directly in a terminal.

This is macOS's TCC ("Full Disk Access") protection: `~/.Trash` is one of
the specially-protected folders, and a plain `launchd` agent has no
Full Disk Access grant by default, so those operations silently fail
instead of erroring loudly. Terminal apps (iTerm2, Terminal.app) typically
already have this access granted, which is why running the script
directly works fine.

**To fix** so the automated Sunday run has full access:
1. System Settings → Privacy & Security → Full Disk Access
2. Click **+**, press `Cmd+Shift+G`, type `/bin/zsh`, press Enter, click Open
3. Toggle it on

**Trade-off to weigh first:** this grants Full Disk Access to *any* zsh
script run on this Mac, not just this one — a broader grant than "just
this job." If that's not worth it, the job still safely runs npm cache
cleanup and the Docker check every week; only the Trash and pip cache
steps will effectively be a no-op until Full Disk Access is granted, and
you can always run `zsh ~/scripts/weekly-disk-cleanup.sh` by hand (in a
terminal) any time for the full effect.

## Related: manual maintenance script

`~/dev/dotfiles/scripts/mac-maintenance.sh` is a separate, manually-run script
(not scheduled) that reports uptime/memory and, as of 2026-08-24, also
clears `~/Library/Caches` (15G reclaimed the first time it ran — general
app caches that had never been part of this automated job). See
[`mac-maintenance.md`](./mac-maintenance.md).

## Deliberately left out of automation

These came up in the same disk-space review but are too consequential to
run unattended on a schedule:

- **`docker system prune -a`** — would remove all unused images, not just dangling ones. Run manually for the deeper Docker cleanup.
- **`~/media` and `~/Downloads`** — almost entirely movies/TV downloads. Biggest single opportunity by far, but deletion choices here are personal, not mechanical.
- **`~/My Drive`** — switching Google Drive from "Mirror" to "Stream" mode would free most of this locally.
- **iPhone backups** in `~/Library/Application Support/MobileSync` — old backups can pile up; review via System Settings → General → Storage → Manage.
- **`~/.ollama` models** — review with `ollama list`, remove unused ones with `ollama rm <model>`.
