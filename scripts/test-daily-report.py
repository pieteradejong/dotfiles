#!/usr/bin/env python3
"""test-daily-report.py — tests for scripts/daily-report.py.

Hermetic: each case builds a fake HOME and ~/dev in a temp dir — a launchd register, a stub
`launchctl`, job logs, real temp git repos (one own, one fork, one skip-listed) and a git wrapper
that records every directory it is run in — and points the script at them through its env vars.
NOW is fixed to Saturday 2026-11-14 07:00, so a Sunday job is not due and a 03:00 daily one is.

Usage:  scripts/test-daily-report.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "daily-report.py"
NOW = "2026-11-14T07:00:00"

REGISTER = """# launchd register

| Label | Installed | Trigger | Runs | Source | Last change | Decision / doc |
|---|---|---|---|---|---|---|
| `com.pieterdejong.docsbackup` | yes | daily 03:00 | backup | `x` | - | - |
| `com.pieterdejong.securityaudit` | yes | Sundays 10:00 | audit | `x` | - | - |
| `com.pieterdejong.nightly` | yes | daily 05:00 | something | `x` | - | - |
| `com.pieterdejong.rcdev` | yes | RunAtLoad + KeepAlive | rc | `x` | - | - |
| `com.pieterdejong.later` | no | Mondays 09:00 | later | `x` | - | - |
| `homebrew.mxcl.thing` | yes | RunAtLoad | thing | `app` | - | - |
"""

BACKUP = """# Backup run 2026-11-14 03:00

- Result: **FAIL**: dev (rc=1)

| Target | Result | Started | Took | Uploaded | Moved to versions | Check | Errors |
|---|---|---|---|---|---|---|---|
| gdrive | OK | 03:00 | 1m | 7 (1 KiB) | 1 | 0 differences, 3 matching | 0 |
| dev | FAIL | 03:03 | 2m | 4 (1 KiB) | 2 | 2 differences, 9 matching | 2 |

## dev
- Errors:
  - 1× `projects/secret-name/file.md: sizes differ`
"""

SKIPLIST = "skip:memorial:do-not-touch\nfork:theirs:upstream\n"


class DailyReport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.t = Path(self.tmp.name)
        self.home, self.dev = t / "home", t / "home" / "dev"
        for d in (self.home / "Library/LaunchAgents", self.dev / "audit-reports", t / "bin", t / "state",
                  self.home / ".claude/projects/-tmp-proj"):
            d.mkdir(parents=True)
        (t / "register.md").write_text(REGISTER)
        (t / "skiplist.conf").write_text(SKIPLIST)
        (t / "backup.md").write_text(BACKUP)
        (t / "audit.log").write_text(
            f"2026-11-08 10:20:00\t3 FAIL\t2 WARN\t0 new\t1 resolved\t{self.dev}/audit-reports/security-audit-2026-11-08.md\n")
        self.lc_out = ("-\t1\tcom.pieterdejong.docsbackup\n-\t1\tcom.pieterdejong.securityaudit\n"
                       "-\t0\tcom.pieterdejong.nightly\n4242\t0\tcom.pieterdejong.rcdev\n")
        self.write_exec(t / "bin/launchctl", f'#!/bin/sh\ncat "{t}/lc.txt"\n')
        (t / "lc.txt").write_text(self.lc_out)
        self.git_calls = t / "git-calls.txt"
        real_git = subprocess.run(["sh", "-c", "command -v git"], check=False, capture_output=True, text=True).stdout.strip()
        self.write_exec(t / "bin/git", f'#!/bin/sh\necho "$PWD|$*" >> "{self.git_calls}"\nexec "{real_git}" "$@"\n')
        # A plist for the generic job, with a log that has no activity at 05:00 → missing.
        (t / "nightly.out").write_text("2026-11-12T05:00:01 ran ok\n")
        with open(self.home / "Library/LaunchAgents/com.pieterdejong.nightly.plist", "wb") as fh:
            import plistlib
            plistlib.dump({"Label": "com.pieterdejong.nightly", "StandardOutPath": str(t / "nightly.out")}, fh)
        os.utime(t / "nightly.out", (1762941601, 1762941601))  # 2025, long before the window
        self.own = self.mkrepo("projects/mine", "pieteradejong", commit="Add | the <script> thing")
        self.fork = self.mkrepo("projects/theirs", "someone-else", commit="their commit")
        self.memorial = self.dev / "projects/memorial"
        (self.memorial / ".git").mkdir(parents=True)
        (self.memorial / ".git/config").write_text('[remote "origin"]\n\turl = git@github.com:pieteradejong/memorial.git\n')
        (self.dev / "TODO.md").write_text("# TODO\n\n- [ ] alpha — 2026-11-01\n- [ ] beta — 2026-11-02\n")
        (self.dev / "SESSIONS.md").write_text("# Sessions\n\n## 2026-11-14 — did a thing\n\n**Asked:** stuff\n")
        (self.home / ".claude/projects/-tmp-proj/abc.jsonl").write_text('{"text": "TRANSCRIPT-SECRET-42"}\n')
        self.env = dict(os.environ, HOME=str(self.home), DEV_ROOT=str(self.dev), NOW=NOW,
                        DAILY_OUT=str(self.dev / "audit-reports/daily"), DAILY_STATE_DIR=str(t / "state"),
                        LAUNCHD_REGISTER=str(t / "register.md"), SKIPLIST_FILE=str(t / "skiplist.conf"),
                        LAUNCHCTL=str(t / "bin/launchctl"), LAUNCH_AGENTS_DIR=str(self.home / "Library/LaunchAgents"),
                        AUDIT_LOG=str(t / "audit.log"), CLEANUP_LOG=str(t / "none.log"),
                        BACKUP_REPORT=str(t / "backup.md"), RCDEV_LOG_DIR=str(t / "rc"),
                        CLAUDE_PROJECTS=str(self.home / ".claude/projects"), GIT=str(t / "bin/git"),
                        NOTIFY_BIN=str(t / "bin/no-notify"))

    def tearDown(self):
        self.tmp.cleanup()

    def write_exec(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def mkrepo(self, rel, owner, commit):
        r = self.dev / rel
        r.mkdir(parents=True)
        g = ["git", "-C", str(r), "-c", "user.name=t", "-c", "user.email=t@users.noreply.github.com"]
        subprocess.run(["git", "init", "-q", "-b", "main", str(r)], check=True)
        subprocess.run(g[:3] + ["remote", "add", "origin", f"git@github.com:{owner}/{r.name}.git"], check=True)
        (r / "README.md").write_text("x\n")
        subprocess.run(g + ["add", "."], check=True)
        subprocess.run(g + ["commit", "-q", "-m", commit], check=True)
        return r

    def run_report(self, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPT), *args], check=False, env=env or self.env,
                              capture_output=True, text=True, timeout=120)

    def report(self):
        r = self.run_report("--no-notify")
        md = (self.dev / "audit-reports/daily/daily-2026-11-14.md").read_text()
        data = json.loads((self.dev / "audit-reports/daily/daily-2026-11-14.json").read_text())
        return r, md, data

    def job(self, data, name):
        return next(j for j in data["jobs"] if j["name"] == name)

    def test_job_statuses_and_needs_action(self):
        r, md, data = self.report()
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertEqual(self.job(data, "securityaudit")["status"], "not due")
        self.assertEqual(self.job(data, "docsbackup")["status"], "failed")
        self.assertEqual(self.job(data, "nightly")["status"], "missing")
        self.assertEqual(self.job(data, "rcdev")["status"], "running")
        self.assertEqual(self.job(data, "later")["status"], "pending")
        self.assertNotIn("thing", [j["name"] for j in data["jobs"]])  # not one of ours
        self.assertTrue(any("docs backup failed: dev" in a for a in data["needs_action"]))
        self.assertTrue(any("nightly: due Fri 05:00" in a or "nightly: due" in a for a in data["needs_action"]))
        self.assertIn("## Needs action", md)

    def test_backup_file_names_never_reported(self):
        _, md, data = self.report()
        self.assertNotIn("secret-name", md)
        self.assertNotIn("secret-name", json.dumps(data))

    def test_skip_and_fork_repos_untouched(self):
        _, md, data = self.report()
        calls = self.git_calls.read_text()
        self.assertNotIn(str(self.memorial), calls)
        self.assertNotIn(str(self.fork), calls)
        self.assertIn(str(self.own), calls)
        repos = [g["repo"] for g in data["git"]]
        self.assertEqual(repos, ["~/dev/projects/mine"])
        self.assertIn("memorial", md)  # named as skip-listed
        self.assertEqual(data["repos_not_own"], 1)

    def test_commit_subject_escaped_in_markdown_table_context(self):
        _, md, data = self.report()
        self.assertEqual(data["git"][0]["commits"][0]["subject"], "Add | the <script> thing")
        self.assertIn("Add | the <script> thing", md)  # a bullet, not a table cell
        self.assertTrue(any("today's commits not on GitHub" in a for a in data["needs_action"]))

    def test_todo_tick_and_add_across_runs(self):
        _, md, data = self.report()
        self.assertTrue(data["admin"]["baseline"])
        self.assertIn("First run", md)
        (self.dev / "TODO.md").write_text("# TODO\n\n- [x] alpha — 2026-11-01\n- [ ] beta — 2026-11-02\n"
                                          "- [ ] gamma — 2026-11-14\n")
        env = dict(self.env, NOW="2026-11-15T07:00:00")
        r = self.run_report("--no-notify", env=env)
        data = json.loads((self.dev / "audit-reports/daily/daily-2026-11-15.json").read_text())
        self.assertFalse(data["admin"]["baseline"], r.stderr)
        self.assertEqual([x["item"] for x in data["admin"]["todo_ticked"]], ["alpha — 2026-11-01"])
        self.assertEqual([x["item"] for x in data["admin"]["todo_opened"]], ["gamma — 2026-11-14"])
        self.assertEqual(data["window"]["since"], "2026-11-14 07:00:00")

    def test_new_decision_and_changelog_line(self):
        (self.own / "DECISIONS.md").write_text("# Decisions\n\n## D1 — old\n\n**Verified.** yes\n")
        (self.own / "CHANGELOG.md").write_text("# Changelog\n\n## [Unreleased]\n\n- old line\n\n## [1.0]\n\n- shipped\n")
        self.report()
        (self.own / "DECISIONS.md").write_text("# Decisions\n\n## D1 — old\n\n**Verified.** yes\n\n"
                                               "## D2 — new\n\n**Verified: PARTIAL.** later\n")
        (self.own / "CHANGELOG.md").write_text("# Changelog\n\n## [Unreleased]\n\n- old line\n- new line\n\n"
                                               "## [1.0]\n\n- shipped\n")
        self.run_report("--no-notify", env=dict(self.env, NOW="2026-11-15T07:00:00"))
        data = json.loads((self.dev / "audit-reports/daily/daily-2026-11-15.json").read_text())
        self.assertEqual([(x["title"], x["verified"]) for x in data["admin"]["decisions"]], [("D2 — new", "PARTIAL")])
        self.assertEqual([x["line"] for x in data["admin"]["changelog"]], ["new line"])

    def test_sessions_counted_never_read(self):
        _, md, data = self.report()
        self.assertNotIn("TRANSCRIPT-SECRET-42", md + json.dumps(data))
        self.assertEqual(data["counts"]["claude_sessions"], 1)
        self.assertEqual([x["title"] for x in data["sessions"]["logs"]], ["did a thing"])

    def test_files_private(self):
        self.report()
        d = self.dev / "audit-reports/daily"
        self.assertEqual(stat.S_IMODE(d.stat().st_mode), 0o700)
        for f in ("daily-2026-11-14.md", "daily-2026-11-14.json"):
            self.assertEqual(stat.S_IMODE((d / f).stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.t / "state/state.json").stat().st_mode), 0o600)

    def test_dry_run_writes_nothing(self):
        r = self.run_report("--stdout")
        self.assertIn("# Daily report — 2026-11-14", r.stdout)
        self.assertFalse((self.dev / "audit-reports/daily").exists())
        self.assertFalse((self.t / "state/state.json").exists())

    def test_refuses_inside_git_repo(self):
        r = self.run_report("--out", str(self.own / "reports"))
        self.assertEqual(r.returncode, 3)
        self.assertFalse((self.own / "reports").exists())

    def test_unreadable_source_is_named_and_exit_2(self):
        env = dict(self.env, LAUNCHD_REGISTER=str(self.t / "missing.md"), LAUNCHCTL=str(self.t / "nope"))
        r = self.run_report("--json", env=env)
        self.assertEqual(r.returncode, 2)
        data = json.loads(r.stdout)
        self.assertEqual(data["incomplete"], ["launchd register", "launchctl list"])
        self.assertTrue(any("report incomplete" in a for a in data["needs_action"]))

    def test_summary_and_notify(self):
        self.write_exec(self.t / "bin/no-notify", f'#!/bin/sh\nprintf "%s\\n" "$@" > "{self.t}/notified"\n')
        r = self.run_report("--summary")
        self.assertIn("to act on", r.stdout)
        notified = (self.t / "notified").read_text()
        self.assertTrue(notified.startswith("Daily report\n"))
        self.assertNotIn("<script>", notified)  # counts only


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv else 1
    sys.argv = [a for a in sys.argv if a != "--verbose"]
    sys.exit(0 if unittest.main(verbosity=verbosity, exit=False).result.wasSuccessful() else 1)
