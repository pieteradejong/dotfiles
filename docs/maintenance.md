# Routine maintenance

Everything that keeps this Mac and `~/dev` healthy: what runs by itself, when, where
its output goes, and the short list of things only a person can do. Replaces the old
`weekly-cleanup.md` and `mac-maintenance.md`.

| Job | When | What | Output |
|---|---|---|---|
| [Security & privacy audit](#weekly-security--privacy-audit) | Sundays 10:00 (launchd) | full audit incl. GitHub | `~/dev/audit-reports/security-audit-YYYY-MM-DD.md` |
| [Disk cleanup](#weekly-disk-cleanup) | Sundays 09:00 (launchd) | caches, Docker, old Trash | `~/.weekly-disk-cleanup.log` |
| [Docs backup](#daily-docs-backup) | daily 03:00 (launchd) | `~/docs` to cloud | `~/docs/.backup/logs/` |
| [Commit/push gate](policy/security-and-privacy.md#the-commitpush-gate) | every commit and push | secrets, personal data | terminal |
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

---

## Weekly disk cleanup

Reclaims space from caches that regenerate and Trash that was already discarded.

| Live location | Backed up here |
|---|---|
| [`bin/weekly-disk-cleanup.sh`](../bin/weekly-disk-cleanup.sh) | itself — the repo file *is* the live script; launchd runs this path. There is no second copy |
| `~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist` | [`macos/com.pieterdejong.weeklycleanup.plist`](../macos/com.pieterdejong.weeklycleanup.plist) |

The script is never executed by the test suite — it empties Trash and prunes
caches. `./test.sh bin` asserts it statically instead: that it parses, that every
aggressive form in its `IDEAS` block is still commented out, that the live
`docker system prune` has no `-a`/`--volumes`, and that the only live `rm -rf` is
the `~/.Trash` sweep with its age filter intact.

| Step | What it does | Why it is safe |
|---|---|---|
| npm cache | `npm cache verify`, then `npm cache clean --force` | re-downloaded on the next install |
| pip cache | `pip3 cache purge` | same |
| Docker | `docker system prune -f` (not `-a`); skipped if no Docker daemon is running — Colima is started on demand, so usually skipped ([containers.md](containers.md)) | removes only stopped containers, unused networks, dangling images, build cache |
| Trash | deletes items in `~/.Trash` older than 7 days | this week's deletions keep a recovery window |

Each step runs independently; one failing does not stop the rest. Logs:
`~/.weekly-disk-cleanup.log` (trimmed to 1000 lines) and `~/.weekly-disk-cleanup.launchd.log`.

```zsh
launchctl start com.pieterdejong.weeklycleanup && cat ~/.weekly-disk-cleanup.log   # run now
```

**Known limitation — Full Disk Access.** Under launchd the Trash and pip-cache steps are
largely a no-op: `~/.Trash` is TCC-protected and a plain launchd agent has no Full Disk
Access. Granting it to `/bin/zsh` fixes that but applies to *every* zsh script — a broader
grant than this job. Without it, run the script by hand in a terminal for the full effect.

**Deliberately not automated:** `docker system prune -a`; `~/Downloads` and media folders;
switching Google Drive from Mirror to Stream; old iPhone backups; unused `ollama` models.
Each is a judgement call, not a mechanical one.

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
   `.github/workflows/gitleaks-reusable.yml` if gitleaks changed.
