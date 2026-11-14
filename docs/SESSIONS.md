# Sessions — dotfiles

One dated section per session that changed this repo, newest first (`~/dev/CLAUDE.md` § Session
workflow, step 6; D68). This repo is public: nothing private goes here. Workspace-level sessions
are logged outside it.

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
