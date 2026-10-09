# Routine maintenance

Everything that keeps this Mac and `~/dev` healthy: what runs by itself, when, where
its output goes, and the short list of things only a person can do. Replaces the old
`weekly-cleanup.md` and `mac-maintenance.md`.

| Job | When | What | Output |
|---|---|---|---|
| [Security & privacy audit](#weekly-security--privacy-audit) | Sundays 10:00 (launchd) | full audit incl. GitHub | `~/dev/audit-reports/security-audit-YYYY-MM-DD.md` |
| [Dashboard](#dashboard) | after each audit run | trend, findings by repo × check, disk reclaimed, action list | `~/dev/audit-reports/dashboard.html` |
| [Disk cleanup](#weekly-disk-cleanup) | Sundays 09:00 (launchd) | caches, Docker, old Trash | `~/.weekly-disk-cleanup.log` |
| [Docs backup](#daily-docs-backup) | daily 03:00 (launchd) | `~/docs` to cloud | `~/docs/.backup/logs/` |
| [Remote Control server](#remote-control-server-rcdev) | always on (launchd, at login) | Claude Code Remote Control rooted at `~/dev` | `~/Library/Logs/claude-remote-control/dev.log` |
| [Commit/push gate](policy/security-and-privacy.md#2-the-commitpush-gate) | every commit and push | secrets, personal data | terminal |
| [Mac maintenance](#mac-maintenance-manual) | by hand | uptime, memory, app caches | `~/maintenance-YYYYMMDD.log` |

launchd runs a calendar job once on wake if the Mac was asleep at the scheduled time;
if the Mac was off, that week's run is skipped.

**Check what is loaded:** `launchctl list | grep com.pieterdejong`

---

## Weekly security & privacy audit

`scripts/security-audit.sh`, scheduled by
[`macos/com.pieterdejong.securityaudit.plist`](../macos/com.pieterdejong.securityaudit.plist).
Read-only toward every repo. Why it is built this way: [design decisions D15](design-decisions.md#d15--a-weekly-local-audit-reports-outside-git--2026-09-14).

### What it checks

| # | Section | What it does | A finding means |
|---|---|---|---|
| 1 | Gate | `security/gate.sh status` | commits on this machine may be unprotected — fix first |
| 2 | Local repos | `dotaudit --github` over every repo under `~/dev`; adds `--history` in the first week of each month | see the dotaudit report it links to; [dev-audit.md](dev-audit.md) explains each check |
| 3 | GitHub settings | `github-security-sweep.sh --check` | an owned repo lacks secret scanning, push protection or Dependabot alerts — run `github-security-sweep.sh --apply` |
| 4 | Uncloned repos | mirrors every owned GitHub repo with no local clone into `~/.cache/security-audit/mirrors/`, then runs gitleaks over full history and looks for the private personal values | a secret or personal value is in a repo nobody has looked at locally |
| 5 | Bypasses | `SECURITY_GATE_BYPASS` uses in the last 7 days, with reasons | confirm each reason still holds |
| 6 | Loose files | credential-shaped files (`*.pem`, `*.key`, `.env*`, recovery codes, …) outside any repo (FAIL), or untracked and not ignored inside one (WARN). A file outside any repo that a `.gitignore` in its directory or an ancestor already ignores — generated env files in `templates/`, say — is listed as info | move it to the password manager, or add it to `.gitignore` |
| 7 | Account | SSH keys on the GitHub account, `gh` token scopes | remove any key you cannot place |

The report lands in `~/dev/audit-reports/` (mode 600, never inside a git repo) with the
dotaudit and sweep reports from the same run beside it. A notification shows counts only.
The script exits 1 on any FAIL; each run appends one line to
`~/Library/Logs/security-audit/security-audit.log`.

### Install / operate

```zsh
cp ~/dev/dotfiles/macos/com.pieterdejong.securityaudit.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pieterdejong.securityaudit.plist

launchctl kickstart gui/$(id -u)/com.pieterdejong.securityaudit   # run now
~/dev/dotfiles/scripts/security-audit.sh --quick --no-notify      # fast manual run (skips 2 and 4)
~/dev/dotfiles/scripts/security-audit.sh --history                # force full-history dotaudit

launchctl bootout gui/$(id -u)/com.pieterdejong.securityaudit     # disable
```

Raw launchd output: `~/Library/Logs/security-audit/launchd.out`. The mirror cache can be
deleted at any time; the next run re-creates it.

### Dashboard

Each audit run ends by calling [`scripts/audit-dashboard.py`](../scripts/audit-dashboard.py),
which rebuilds `~/dev/audit-reports/dashboard.html` (mode 600) from what is already on disk: every
`security-audit-*.md`, every dotaudit `findings-*.tsv`, and `~/.weekly-disk-cleanup.log`. Four
views: the FAIL/WARN trend (plus one sparkline per dotaudit check), a repo × check heatmap whose
cells open their findings, space reclaimed per cleanup run, and an action list of FAILs grouped by
the fix they need, with ticks kept in the browser's local storage.

```zsh
open ~/dev/audit-reports/dashboard.html
~/dev/dotfiles/scripts/audit-dashboard.py     # rebuild now, without re-running the audit
```

The page is self-contained: inline SVG, no external scripts or fonts, and a
Content-Security-Policy that blocks network loads. It holds the same detail as the reports, so
the same rules apply: never inside a git repo, never published. A failure to draw it prints a
WARN and never changes the audit's exit code. Why a local file and not a hosted page:
[D28](design-decisions.md#d28--the-maintenance-dashboard-is-a-local-file-built-from-the-reports--2026-10-07).

Forks and upstream clones appear in it like any other repo; their findings are not to be fixed
there (the do-not-touch register).

---

## Weekly disk cleanup

Reclaims space from caches that regenerate and Trash that was already discarded.

| Live location | Backed up here |
|---|---|
| [`bin/weekly-disk-cleanup.sh`](../bin/weekly-disk-cleanup.sh) | itself — the repo file *is* the live script; launchd runs this path. There is no second copy |
| `~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist` | [`macos/com.pieterdejong.weeklycleanup.plist`](../macos/com.pieterdejong.weeklycleanup.plist) |

Files that must hold absolute paths (this plist, iTerm2's prefs, the editor settings) are
stored with a literal `$HOME` marker and expanded again by `sync restore` — see
[D20](design-decisions.md#d20--sanitize-with-a-home-marker-not---2026-09-22). The committed copies are
backups, not directly loadable files.

The script is never executed by the test suite — it empties Trash and prunes
caches. `./test.sh bin` asserts it statically instead: that it parses, that every
aggressive form in its `IDEAS` block is still commented out, that the live
`docker system prune` has no `-a`/`--volumes`, and that every live `rm -rf` targets one
of the allowlisted paths below, with the Trash sweep's age filter intact. `--dry-run` is the
one mode that is safe to execute. (Allowlist test update: pending, see D27.)

| Step | What it does | Why it is safe |
|---|---|---|
| npm cache | `npm cache verify`, then `npm cache clean --force` | re-downloaded on the next install |
| pip cache | `pip3 cache purge` | same |
| Docker | `docker system prune -f` (not `-a`); skipped if no Docker daemon is running — Colima is started on demand, so usually skipped ([containers.md](containers.md)) | removes only stopped containers, unused networks, dangling images, build cache |
| Trash | deletes items that have been in `~/.Trash` 7+ days (`-ctime`; `-mtime` would purge an old file the moment it is trashed) | this week's deletions keep a recovery window |
| pip-tools cache | `rm -rf ~/Library/Caches/pip-tools/*` | pip-compile's download cache; `pip3 cache purge` never touches it |
| uv cache | `uv cache prune` (not `clean`) | drops only unreferenced entries |
| Homebrew | `brew cleanup -s --prune=all` | old versions and downloads; `brew autoremove` stays an idea |
| pnpm store | `pnpm store prune` | only packages no project references |
| Xcode DerivedData | `rm -rf ~/Library/Developer/Xcode/DerivedData/*` | build cache |
| App-updater leftovers | `rm -rf` of `~/Library/Caches/*.ShipIt`, `*-updater` and `*/org.sparkle-project.Sparkle/Installation/*` untouched 3+ days | installers kept after the app updated (Squirrel/Electron and Sparkle apps alike); the 3-day rule spares an update staged for the next relaunch |
| Old maintenance logs | `find ~ -maxdepth 1 -name 'maintenance-*.log' -mtime +30 -delete` | logs only |

Each step runs independently; one failing does not stop the rest. Logs:
`~/.weekly-disk-cleanup.log` (trimmed to 1000 lines, before each run) and
`~/.weekly-disk-cleanup.launchd.log`. The script puts Homebrew and `~/.local/bin` on `PATH` itself:
launchd's bare `PATH` found Xcode's old `/usr/bin/pip3`, which does not know pip's current cache
layout, so the pip step was a no-op.

```zsh
weekly-disk-cleanup.sh --dry-run    # sizes + what each step would run; changes nothing, no log
weekly-disk-cleanup.sh              # real run from a terminal: prints and logs, and has Full Disk Access for Trash
launchctl start com.pieterdejong.weeklycleanup && cat ~/.weekly-disk-cleanup.log   # run the launchd job now
```

**Known limitation — Full Disk Access.** Under launchd the Trash and pip-cache steps are
largely a no-op: `~/.Trash` is TCC-protected and a plain launchd agent has no Full Disk
Access. Granting it to `/bin/zsh` fixes that but applies to *every* zsh script — a broader
grant than this job. Without it, run the script by hand in a terminal for the full effect.

**Deliberately not automated:** `docker system prune -a`; `~/Downloads` and media folders;
switching Google Drive from Mirror to Stream; old iPhone backups; unused `ollama` models;
`brew autoremove`; HuggingFace models; Playwright browsers; caches of apps that are usually open;
old nvm versions; project `node_modules`/`.venv`. Each is a judgement call or costs a large
re-download, not a mechanical cleanup. Why: [D27](design-decisions.md).

---

## Remote Control server (rcdev)

One always-on `claude remote-control --name dev` server rooted at `~/dev`, so the Claude
mobile app and claude.ai/code can start new sessions on this Mac that reach every repo.
It shows up as **dev**. Spawned sessions start in `~/dev`, so name the repo in the
prompt ("in projects/foo, …"). They run in the default permission mode, so approve
prompts from the phone. `~/dev` is trusted; that trust covers the subdirectories.

| Live location | Backed up here |
|---|---|
| [`bin/rcdev`](../bin/rcdev) | itself, run in place, like everything in `bin/` |
| `~/Library/LaunchAgents/com.pieterdejong.rcdev.plist` | [`macos/com.pieterdejong.rcdev.plist`](../macos/com.pieterdejong.rcdev.plist). The plist holds no absolute path (`$HOME` is expanded by `bash -c` at run time), so `rcdev install` copies it as is |

```zsh
rcdev install     # install + start; it then starts at every login
rcdev status      # up/down, pid, memory (~100-150 MB idle)
rcdev restart     # after a Claude Code update
rcdev log         # tail ~/Library/Logs/claude-remote-control/dev.log
rcdev uninstall   # stop it and remove the agent
```

`KeepAlive` restarts it if it exits, at most once a minute (`ThrottleInterval`). The
log rotates once past 5 MB (`dev.log.1`). launchd starts with a bare `PATH`, so
`rcdev run` sets one: `~/.local/bin`, `bin/`, Homebrew, and nvm's default node. Secrets
from `~/.zshrc` are **not** loaded into spawned sessions.

Separate from this server: interactive `claude` sessions in a terminal are reachable from
the phone on their own (`remoteControlAtStartup: true` in `~/.claude/settings.json`),
and `rc-projects` runs ad-hoc per-project servers. Tests: `./test.sh bin` exercises the
whole lifecycle against a stub `launchctl` and a fake HOME; the real agent is never touched.

---

## Daily docs backup

`~/docs/.backup/backup_docs.py --execute`, scheduled by
`~/Library/LaunchAgents/com.pieterdejong.docsbackup.plist` at 03:00 daily, low priority.
Logs in `~/docs/.backup/logs/`. Principles and coverage: [`policy/backups.md`](policy/backups.md).

---

## Mac maintenance (manual)

```zsh
zsh ~/dev/dotfiles/scripts/mac-maintenance.sh
```

Reports uptime and memory, then moves `~/Library/Caches/*` into a timestamped folder in
`~/.Trash` (a restore window, instead of `rm -rf`); the weekly cleanup's 7-day Trash rule
reclaims the space later. Entries held open by running apps fail to move and are skipped.
Output goes to `~/maintenance-YYYYMMDD.log`. Not scheduled: each section must first be
confirmed idempotent across repeated runs.

---

## Monthly, by hand (15 minutes)

1. Read the latest `security-audit-*.md`. Every FAIL gets fixed or a written reason in the
   private findings register.
2. Review the bypass reasons in section 5 of the audit; delete old lines from
   `~/.local/state/security-gate/bypass.log` once reviewed.
3. Rotate anything the audit flagged as leaked — rotate first, then clean up.
4. `~/dev/dotfiles/test.sh` still passes; `security/gate.sh status` is all `ok`.
5. `brew upgrade gitleaks git` — then bump `gitleaks-version` and `gitleaks-sha256` in
   `.github/workflows/security-reusable.yml` and `gitleaks-reusable.yml` if gitleaks changed.
