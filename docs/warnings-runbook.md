# Warnings runbook

What the red and yellow maintenance lines mean, and how to clear each one. Where they come from is
in [maintenance.md](maintenance.md) § Reports; why they work this way is
[D60](design-decisions.md#d60--maintenance-reports-stay-on-the-mac-notification-session-start-line-dashboard-email-retired--2026-11-09)
and
[D62](design-decisions.md#d62--warnings-name-each-finding-in-red-in-every-new-terminal-secret-files-are-scanned-live--2026-11-10).

## Where the warnings appear

| Place | When | What you see |
|---|---|---|
| New terminal | before the first prompt of every new zsh (`shell/.zshrc`, one-shot `precmd` hook) | nothing when all is well; otherwise the status line and the detail lines, in red and yellow |
| Claude Code | session start in `~/dev` (`claude/hooks/session-start.sh`, after `whatsup --brief`) | the same lines, without colour, so Claude reads them too |
| `whatsup` | full view at the workspace root | the same lines under *Maintenance* |
| By hand | `maintenance-status` | the same lines, always including the status line |
| Dashboard | `~/dev/audit-reports/dashboard.html`, rebuilt after each audit | history and per-run detail |
| Report | `~/dev/audit-reports/security-audit-<date>.md`, mode 600 | every finding with its section |

Nothing is mailed or sent off the Mac (D60).

## Reading the output

```
Maintenance: cleanup 2d ago, Self-check OK · ⚠ audit 0d ago: 1 FAIL (0 new) · ⚠ 1 secret file(s) on disk
  ✗ secret file on disk: outside any repo, no version control and no guard: some-recovery-codes.txt
  ✗ audit: 12 repo(s) missing secret scanning / push protection / Dependabot alerts — run: github-security-sweep.sh --apply
```

- **The status line** summarises each job. Red when any part has a `⚠`.
- **`✗` lines (red)** need action: something sensitive is exposed, or a FAIL is open.
- **`⚠` lines (yellow)** are one step from a problem, for example a key one `git add -A` away from
  a commit.
- **`… N more in <report>`** means more than 5 audit FAILs; the rest are in the report.

## Each kind of line, and how to clear it

### `✗ secret file on disk: outside any repo, no version control and no guard: <path>`

A credential-shaped file sits in `~/dev` outside any git repo, and no `.gitignore` above it would
keep it out of a future repo. The name triggered it: a private key (`*.pem`, `*.key`, `id_rsa*`,
…), an `.env` file, `*credentials*.json`, a password database, `.netrc`, or `*recovery*code*`.
`~/dev` is backed up, so the file is also in every backup.

1. **Move the secret where it belongs.** Recovery codes and passwords go into the password manager.
   Keys go into `~/.ssh` (mode 600) or the Keychain. Runtime secrets go into the app's secret store
   ([policy/secure-development.md](policy/secure-development.md) § Runtime secrets).
2. **Delete the file**: `rm <path>`. Don't move it to the Trash, because the Trash is backed up too.
3. **Consider the backups.** Older copies remain in backup version history until they expire. For
   account recovery codes, the clean fix is to **regenerate** them on the account (GitHub:
   Settings → Password and authentication → Recovery codes), which makes every old copy useless.
4. **Verify**: run `maintenance-status`. The line is gone at once, because the scan is live, with
   no audit run needed.
5. **Record it**: tick the matching `TODO.md` item and the finding in the private findings register.

If the file is a placeholder, rename it to `*.example` or `*.template`, which the scan exempts. If
a whole directory is meant to hold such files, add it to the private audit skip list
(`private/audit/skiplist.conf`, a `skip:<dir-name>` line).

### `⚠ secret file on disk: untracked and NOT ignored — one git add -A from being committed: <path>`

The file is inside a repo, untracked, and not covered by `.gitignore`. The commit gate would block
it, but do not rely on that.

1. If the file must stay, add it to that repo's `.gitignore` (`.env.*` with `!.env.example` covers
   the common case), and commit the `.gitignore`.
2. If it doesn't need to be there, move the secret out as above and delete the file.
3. **Verify**: run `maintenance-status`.

### `✗ audit: <finding>`

A FAIL from the latest weekly security audit, from any section except 6, which the live scan
above replaces. What each section checks, and its fix, is in [maintenance.md](maintenance.md) §
Weekly security & privacy audit, *What it checks*. Many findings carry their fix command after
`run:`.

- **Verify**: audit findings refresh only when the audit runs, on Sundays at 10:00. To refresh
  sooner, run `scripts/security-audit.sh --quick --no-notify`. `--quick` skips sections 2, 4 and
  8, so findings from those clear at the next full run.
- A FAIL that is accepted on purpose (a known false positive) belongs in the skip list or the
  check's own allowlist, never ignored by habit. A red line that is always there stops being read,
  and that is exactly how the recovery-codes case below lasted two months.

### Status-line items

| Item | Meaning | What to do |
|---|---|---|
| `⚠ cleanup …: N problem(s)` | the last weekly cleanup's Self-check found problems | `weekly-cleanup-check` prints each `PROBLEM:` line; see maintenance.md § Weekly disk cleanup |
| `⚠ cleanup overdue` / `⚠ audit overdue` | the log is older than 8 days, so the job is not running | `launchctl list \| grep com.pieterdejong`; reload the plist (maintenance.md § Install / operate) |
| `⚠ audit …: N FAIL (M new)` | open audit FAILs; `M new` since the previous full report | the `✗ audit:` lines below it, or the report |
| `⚠ <job>: last run failed (exit N)` | another launchd job exited non-zero | that job's log (maintenance.md § At a glance, *Output*) |
| `⚠ <job>: never run` | no log at all | install the job, or check its log path |

## Worked example: recovery codes left in `~/dev` (2026-11)

- **What happened.** A file of GitHub account recovery codes sat in the root of `~/dev` from at
  least September. Every weekly audit reported it as a section-6 FAIL, but only in the report and a
  short notification, and the session-start line showed only a count. Nobody opened the report.
- **The fix.** The codes went into the password manager and the file was deleted. The next
  `maintenance-status` run showed no secret-file line, and the rerun of the section-6 scan found
  no FAIL.
- **What changed (D62).** The finding is now named, in red, in every new terminal and every Claude
  session until it is fixed. It is checked live, so it disappears the moment it is fixed.

## Testing the warnings themselves

```zsh
./test.sh bin                                   # maintenance-status: colour, --quiet, live scan, audit lines
./test.sh tools                                 # the audit's section 6 through the shared scanner
touch ~/dev/projects/scratch/zz-recovery-codes.txt && maintenance-status --quiet   # a red ✗ line
rm ~/dev/projects/scratch/zz-recovery-codes.txt && maintenance-status --quiet      # silent for it again
```

Don't use a name containing `test`, `fixture`, `mock`, `spec` or `example` for that probe, because
the scan exempts those paths (`is_example_path` in `security/patterns.sh`).
