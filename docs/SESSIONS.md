# Sessions — dotfiles

One dated section per session that changed this repo, newest first (`~/dev/CLAUDE.md` § Session
workflow, step 6; D68). This repo is public: nothing private goes here. Workspace-level sessions
are logged outside it.

## 2026-11-17 (evening) — `mac-maintenance.sh` reports the S3 media archive

**Asked:** "add to a maintenance script a report of what is in there" (the S3 media archive), after a disk survey and
a video backup catch-up in the media repo.

**Changed:** `scripts/mac-maintenance.sh` gets a `S3 MEDIA ARCHIVE` section that runs the media repo's `s3-report.sh`
(`MEDIA_REPORT_BIN`). There are 4 new checks in `scripts/test-mac-maintenance.sh`, and `docs/maintenance.md`,
CHANGELOG and D80 are updated.

**Verified:** `./test.sh maint` → 59 passed; `shellcheck -S warning` clean; a real `--dry-run` prints the section.

**Not verified / open:** nothing new here. The media-side open items are in the media repo's `TODO.md`.

**Shipped (2026-11-19):** the earlier D79 work (`3098be8`) and this change (`1d234a6`) were committed separately
after a full `./test.sh` (all suites passed, `restore` skipped). They were pushed to `daily-report`
(`f242d15..1d234a6`). The sweep `--check` exited 0, after `--apply` enabled Dependabot alerts on one private repo.

## 2026-11-17 — CI tested in three layers: actionlint, real run status, a template canary (D79)

**Asked:** is there any way to test CI/CD for the templates and all other repos? Then: plan it, test
it thoroughly, document everything in markdown. Pieter chose a private canary repo over `act`.

**Changed here:**
- The gate runs `actionlint` on changed workflows and blocks new errors (`workflow-lint`), and
  dotaudit WARNs on existing ones.
- New `scripts/ci-status.py`, which reads every own repo's default-branch CI, run per workflow.
  It feeds audit section 11 and the daily report's `## CI`.
- New `scripts/template-canary.sh`, which runs the 7 non-repo templates' workflows on GitHub
  through a private canary repo.
- `actionlint` added to `init.sh`, `test.sh` and CI. New suites `actionlint`, `cistatus`,
  `canary`.
- Docs: D79, a changelog line, `docs/maintenance.md` (*CI status*, *Template canary*, section
  11, two job rows), `scripts/README.md`, the check tables in `docs/dev-audit.md` and
  `repo-standards.md`, and `claude/templates-CLAUDE.md` (copied to `~/dev/templates/CLAUDE.md`).

**Verified:** gate 212 passed; dotaudit 107; ci-status 32 OK, with 14 of 14 mutations caught;
canary 56 passed through the real gate, with 14 of 14 mutations caught; tools 176; daily 18 OK;
`./test.sh actionlint` clean across 8 templates. Full `./test.sh`: 25 of 27 suites passed; `scan` and `ruff` caught two bugs in this session's code, both fixed and rerun (D79). The real `ci-status.py` read 154 repos: 17 red,
5 stale, 56 none, 76 green. A real `template-canary.sh --dry-run` built all 7 branches through the
gate and pushed nothing.

**Open (`TODO.md`):** create the canary repo and do its first real run; whether the audit runs the
canary unattended; commit and push this work; check section 11 after the 2026-11-22 audit. The red
repos are workspace items, outside this repo.

## 2026-11-16 — Workflow skills live in a private repo (D77)

**Asked:** more Claude skills for the most repeated requests, kept in a private repo.

**Changed here:** D77 (skills may live outside this repo; amends D75), a changelog line, and
three lines in `claude/dev-CLAUDE.md` § Session workflow naming the `log` and `ship` skills
(copied to `~/dev/CLAUDE.md`). The skills themselves, their scripts and tests are not in this repo.

**Verified:** `./test.sh docs` → 12 passed; `./test.sh claudemd` → passed; `doc-dupes` → clean.

**Open (`TODO.md` § Tooling):** a fresh session loading the skills unasked; `codex-agents-sync`
not available on this branch; these edits are uncommitted.

## 2026-11-16 — Expo on latest stable, applied unattended; every launchd job in the daily report (D78)

**Asked:** keep Expo on the latest stable version in the maintenance script, with `test.sh`
proving it works, and put anything launchd in the report.

- **Decisions** (D78): Expo goes to npm `latest`, SDK majors included, replacing the
  pinned-SDK rule of D55 and D76. A passing bump is written into a clean checkout, uncommitted,
  after the clone test and a second `./test.sh` in the checkout; a failure restores the
  manifests. The daily report lists every launchd plist on the Mac. Pieter chose unattended
  application over the recommended report-only.
- **Scripts.** `template-versions.py` `expo_latest`; `latest-deps.py` Expo phase (`--no-expo`,
  `--expo-only`), owners and args registers, a checkout-scoped runner; `daily-report.py`
  *All launchd jobs*.
- **Tests.** `./test.sh` → all suites passed in 781 s. New: 5 Expo cases in `latestdeps`, the
  Expo case with a hold in `templates`, and a launchd case and Expo counts in `daily`. The daily
  fixtures no longer read the real `/Library`. Real dry run: two Expo apps to move, three current.
  Real report: 35 launchd jobs, 6 with a missing program.
- **Installed** `com.pieterdejong.latestdeps` at Pieter's go-ahead; the launchd register is updated.
- **Open** (`TODO.md`): the first Saturday run with the Expo phase (2026-11-21), and the six
  leftover launchd jobs.

## 2026-11-16 — Weekly test of the projects against latest stable (D76)

**Asked:** the maintenance scripts should always test the projects against the latest stable
packages, with the decisions documented.

- **Decisions** (D76): a throwaway clone and a report, never a commit to the projects; every own
  repo with a `test.sh`, minus forks, do-not-touch, scratch and a skip list; its own Saturday
  launch agent, which the Sunday audit and the daily report read. Two runs per project, pinned
  then latest, so failures that are already there aren't blamed on the bump.
- **Script** `scripts/latest-deps.py`. It imports `template-versions.py` for the registry lookups,
  holds and bumps. The launch agent `macos/com.pieterdejong.latestdeps.plist` is written, not
  installed. `security-audit.sh` gains section 10, and `daily-report.py` reads the verdict counts.
- **Tests.** New suite `./test.sh latestdeps` (9 offline cases), plus new cases in `tools` and
  `daily`. Real dry run: 50 in scope, 64 skipped. A real run on two projects gave `2 ok`, with
  nothing written in either.
- **Open** (`TODO.md`): the agent install (needs Pieter), the first Saturday run, and `--ci`
  for the projects marked `needs-ci`.

## 2026-11-16 — Claude skill `mobile-vetting` (D75)

**Asked:** a skill so that any web app is fully vetted for mobile, with recommendations rather than
questions, everything documented in markdown, and thorough tests.

- **Skill** `claude/skills/mobile-vetting/`, symlinked into `~/.claude/skills`. It has
  `SKILL.md` (triggers and steps) and `references/checklist.md` (every check id and its fix).
  `scripts/mobile-audit.mjs` checks five devices plus a throttled load: 19 check ids, report.md and
  report.json, screenshots, exit 0/1/2. `scripts/ios-simulator.sh` drives the real iOS Safari, and
  `templates/` holds the drop-in Playwright spec and device projects. `@playwright/test` is pinned
  at 1.63.0, with one WebKit download.
- **Rule.** A hard rule in `claude/dev-CLAUDE.md` (copied to `~/dev/CLAUDE.md`) and an Enforcement
  row in `repo-standards.md`. README tree updated.
- **Tests.** New suite `./test.sh mobile`: 108 cases over 11 invented fixture pages, a stub `xcrun`
  and the template in Playwright's runner. A 27-mutant sweep caught 26. The two real gaps it found
  (no viewport-less page, an exemption never decisive) got fixtures. The survivor left is an
  equivalent mutant (D75).
- **Real runs** on two web apps found false positives, now fixed as exemptions with fixtures. The
  screenshots showed two defects no check caught, and those became `word-split` and
  `body-scroller`. Findings are in those projects' TODO entries.
- **Unverified / open** (`TODO.md` § Tooling): simulator pass on a real simulator, CI browser
  install, symlink in the restore script, unprompted triggering in a new session.

## 2026-11-15 — Backups in the daily report and `maintenance-app`; `notes-app` (D72, D73)

**Asked:** back up the notes folder to a second, encrypted provider (the first copy already existed),
document the backups the same way the launchd jobs are shown in the local web app, and, as a
stretch goal, a local web app that makes the notes searchable.

- **Backups view.** `daily-report.py` reads a `## Targets` table in the private backup-state
  register plus each target's state JSON, and reports per target: `ok`, `failed`, `stale`,
  `missing`, `dry run`, `manual` or `once`. `maintenance-app` shows the tile, the table and a
  30-day grid. Decision D72.
- **Notes search.** `bin/notes-app` and `scripts/notes-app.py`: an in-memory index, AND/phrase
  search, title-first ranking, highlighted snippets, read-only. It subclasses `maintenance-app`'s
  handler, whose cookie name and CSP are now per app. Decision D73.
- **Tests.** `daily` 14 (+2), `app` 14 (+2), new `notes` suite with 21 cases; `ruff`,
  `shellcheck`, `coverage`, `docs` and `entry` pass.
- **Outside this repo:** the backup script got the encrypted target, a check that each target's
  remote is configured, and 6 new cases in its own tests (40 passed). The provider sign-in is
  interactive and is left to Pieter (`~/dev/TODO.md`).
- **Unverified:** both apps in the browser (`TODO.md`); the encrypted target's first real run waits
  on the sign-in. D72 and D73 are `Verified: PARTIAL`.
- **Later: personal data never in git (D74).** A root hard rule, gate rules `personal-originals`
  and `personal-data-store`, the dotaudit check `tracked-data`, and global-gitignore entries.
  Tests: `gate`, `dotaudit` and `docs` pass. The backup file list is unchanged, and the real
  workspace has 0 `tracked-data` findings. A privacy screen also caught real note titles in a
  test fixture before any commit; they were replaced with invented ones. `notes-app` gained
  multiple sources, including a JSON Lines export (`--source`, a local sources file).
- **Not committed or pushed.**

## 2026-11-14 — Daily report and `maintenance-app` (D70, D71)

**Asked:** a daily markdown report of what the maintenance scripts and launchd jobs did, kept
local with a notification and backed up to Google Drive, covering every job, git work and Claude
sessions, with the emphasis on administrative work; then a local web app that visualises it.

- **Report.** `scripts/daily-report.py` plus the launch agent `com.pieterdejong.dailyreport` at
  07:00, installed and loaded. It writes `~/dev/audit-reports/daily/` (mode 600), which the
  nightly `~/dev` backup already carries to Drive. `maintenance-status` shows its to-act count.
  Decision D70.
- **Web app.** `bin/maintenance-app` and `scripts/maintenance-app.py`: stdlib, loopback only, a
  per-run token, read-only. Its default port is any free one, because 8765 was taken by another
  local server. Decision D71.
- **Tests.** New suites `daily` (12 cases) and `app` (12 cases); `bin` gained 4
  `maintenance-status` cases and is at 191 passed.
- **Before the work,** another session's uncommitted changes (D64, D65, D67, D69) were committed
  as they stood (`adda30d`). `claude/CLAUDE.md` and `claude/dev-CLAUDE.md` were brought up to the
  newer live copies, so the docs sync check passes again; the live files were not changed.
- **Corrected in-session:** an earlier "`test.sh` exits 0 on failure" was wrong. That was `tail`'s
  status in a pipe, and `test.sh` exits 1 correctly.
- **Unverified:** the first scheduled 07:00 run, the report on Drive after the next backup, and a
  browser check of the app (the Chrome extension was not connected). All three are in `TODO.md`.
  D70 and D71 are `Verified: PARTIAL`.
- **Not pushed;** branch `daily-report`. Nothing goes to GitHub without Pieter's OK.
