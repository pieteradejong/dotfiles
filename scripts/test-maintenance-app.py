#!/usr/bin/env python3
"""test-maintenance-app.py — tests for scripts/maintenance-app.py.

Starts the real server on a free port (--port 0 --no-open) over fixture daily reports in a temp
dir, then checks the pages and the guards: token, Host header, day paths, escaping, CSP, the
127.0.0.1 bind, and that nothing under the reports directory changes. No network beyond loopback.

Usage:  scripts/test-maintenance-app.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import hashlib
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "maintenance-app.py"
EVIL = "<script>alert(1)</script>"


def day(date, status, commits, subject="normal"):
    return {
        "date": date, "generated": f"{date} 07:00:00",
        "window": {"since": f"{date} 00:00:00", "until": f"{date} 07:00:00"},
        "needs_action": [f"backup failed {EVIL}"] if status == "failed" else [], "incomplete": [],
        "jobs": [{"name": "docsbackup", "label": "com.pieterdejong.docsbackup", "trigger": "daily 03:00",
                  "cadence": "daily", "status": status, "last_exit": 0, "last_run": None, "result": "r", "note": ""}],
        "backups": [{"name": "offsite", "source": "`~/stuff`", "dest": "crypt:offsite",
                     "encrypted": "yes", "schedule": "daily 03:00", "verify": "cryptcheck",
                     "status": "stale" if status == "failed" else "ok", "last_run": f"{date} 03:05:00",
                     "result": f"last OK run 50 h ago {EVIL}" if status == "failed" else "last run OK"}],
        "admin": {"decisions": [], "changelog": [], "registers": [], "todo_opened": [], "todo_ticked": [],
                  "baseline": False},
        "git": [{"repo": "~/dev/x", "branch": "main", "commits": [{"sha": "abc", "subject": subject}] * commits,
                 "dirty": 0, "unpushed": 0}],
        "sessions": {"logs": [], "claude": []},
        "counts": {"needs_action": int(status == "failed"), "jobs_ok": int(status == "ok"),
                   "jobs_bad": int(status == "failed"),
                   "backups_ok": int(status == "ok"), "backups_bad": int(status == "failed"), "decisions": 1, "changelog": 0, "registers": 0,
                   "todo_opened": 2, "todo_ticked": 1, "commits": commits, "claude_sessions": 3, "session_logs": 0},
    }


class App(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.reports = Path(cls.tmp.name) / "audit-reports" / "daily"
        cls.reports.mkdir(parents=True)
        for d in (day("2026-11-13", "ok", 2), day("2026-11-14", "failed", 1, subject=EVIL)):
            (cls.reports / f"daily-{d['date']}.json").write_text(json.dumps(d))
            (cls.reports / f"daily-{d['date']}.md").write_text(
                f"# Daily report — {d['date']}\n\n## Git work\n\n| Repo | Commits |\n|---|---|\n"
                f"| `~/dev/x` | 1 |\n\n- `abc` {EVIL} and **bold**\n")
        (cls.reports.parent / "secret.txt").write_text("not served\n")
        cls.before = cls.digest()
        env = dict(os.environ, DAILY_STATE_DIR=str(Path(cls.tmp.name) / "state"),
                   DEV_ROOT=str(Path(cls.tmp.name)), HOME=str(Path(cls.tmp.name)))
        cls.proc = subprocess.Popen([sys.executable, str(SCRIPT), "--port", "0", "--no-open",
                                     "--reports", str(cls.reports)], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = cls.proc.stdout.readline()
        m = re.search(r"http://127\.0\.0\.1:(\d+)/\?t=([A-Za-z0-9_\-]+)", line)
        if not m:
            cls.proc.kill()
            raise RuntimeError(f"no URL line: {line!r} {cls.proc.stderr.read()}")
        cls.port, cls.token = int(m.group(1)), m.group(2)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=10)
        cls.proc.stdout.close()
        cls.proc.stderr.close()
        cls.tmp.cleanup()

    @classmethod
    def digest(cls):
        h = hashlib.sha256()
        for f in sorted(cls.reports.parent.rglob("*")):
            h.update(str(f).encode())
            if f.is_file():
                h.update(f.read_bytes())
        return h.hexdigest()

    def get(self, path, token=True, host=None, cookie=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        headers = {"Host": host or f"127.0.0.1:{self.port}"}
        if cookie:
            headers["Cookie"] = cookie
        elif token:
            headers["Cookie"] = f"ma={self.token}"
        c.request("GET", path, headers=headers)
        r = c.getresponse()
        body = r.read().decode(errors="replace")
        c.close()
        return r, body

    def test_overview_renders(self):
        r, body = self.get("/")
        self.assertEqual(r.status, 200)
        for s in ("Needs action", "Scheduled jobs", "Trends", "2026-11-14", "docsbackup", "<svg"):
            self.assertIn(s, body)

    def test_backups_section(self):
        _, body = self.get("/")
        sec = body[body.index("<h2>Backups</h2>"):body.index("<h2>Trends</h2>")]
        self.assertIn("offsite", sec)
        self.assertIn("crypt:offsite", sec)
        self.assertIn('<i class="s-bad"></i>stale', sec)          # latest day: stale is red
        self.assertIn('class="c s-ok"', sec)                        # 2026-11-13 cell in the grid
        self.assertIn('class="c s-bad"', sec)                       # 2026-11-14 cell
        self.assertIn("Backups ok", body)                           # tile
        self.assertNotIn(EVIL, sec)
        self.assertIn("&lt;script&gt;", sec)

    def test_report_without_backups_key(self):
        """Reports written before D72 have no "backups": the overview still renders."""
        old = {k: v for k, v in day("2026-11-01", "ok", 0).items() if k != "backups"}
        app = __import__("importlib.util").util
        spec = app.spec_from_file_location("ma", SCRIPT)
        mod = app.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertIn("None recorded yet", mod.job_grid([old], "backups"))
        self.assertIn("No backup targets", mod.backup_table(old))

    def test_day_page_and_raw(self):
        r, body = self.get("/day/2026-11-14")
        self.assertEqual(r.status, 200)
        self.assertIn("<table", body)
        self.assertIn("<strong>bold</strong>", body)
        r, body = self.get("/day/2026-11-14.md")
        self.assertEqual(r.status, 200)
        self.assertTrue(r.getheader("Content-Type").startswith("text/plain"))

    def test_untrusted_text_escaped(self):
        for path in ("/", "/day/2026-11-14"):
            _, body = self.get(path)
            self.assertNotIn(EVIL, body, path)
            self.assertIn("&lt;script&gt;", body, path)

    def test_token_required(self):
        self.assertEqual(self.get("/", token=False)[0].status, 403)
        self.assertEqual(self.get("/", cookie="ma=wrong")[0].status, 403)
        self.assertEqual(self.get("/api/days", token=False)[0].status, 403)

    def test_token_in_url_becomes_cookie(self):
        r, _ = self.get(f"/?t={self.token}", token=False)
        self.assertEqual(r.status, 303)
        self.assertEqual(r.getheader("Location"), "/")
        cookie = r.getheader("Set-Cookie")
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)

    def test_foreign_host_rejected(self):
        self.assertEqual(self.get("/", host="evil.test")[0].status, 403)
        self.assertEqual(self.get("/", host=f"localhost:{self.port}")[0].status, 200)

    def test_bad_day_paths(self):
        for p in ("/day/../secret.txt", "/day/..%2Fsecret.txt", "/day/2026-13", "/api/day/../../etc",
                  "/day/2026-11-15", "/nope"):
            r, body = self.get(p)
            self.assertEqual(r.status, 404, p)
            self.assertNotIn("not served", body)

    def test_security_headers(self):
        r, _ = self.get("/")
        self.assertIn("default-src 'none'", r.getheader("Content-Security-Policy"))
        self.assertEqual(r.getheader("X-Content-Type-Options"), "nosniff")
        self.assertEqual(r.getheader("Cache-Control"), "no-store")

    def test_api(self):
        _, body = self.get("/api/days")
        self.assertEqual([d["date"] for d in json.loads(body)], ["2026-11-13", "2026-11-14"])
        _, body = self.get("/api/day/2026-11-13")
        self.assertEqual(json.loads(body)["counts"]["commits"], 2)

    def test_post_not_allowed(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request("POST", "/", body="x", headers={"Host": f"127.0.0.1:{self.port}", "Cookie": f"ma={self.token}"})
        self.assertEqual(c.getresponse().status, 501)
        c.close()

    def test_binds_loopback_only(self):
        r = subprocess.run(["lsof", "-nP", f"-iTCP:{self.port}", "-sTCP:LISTEN"], capture_output=True,
                           text=True, check=False)
        if r.returncode != 0 and not r.stdout:
            self.skipTest("lsof unavailable")
        listen = [ln for ln in r.stdout.splitlines() if "LISTEN" in ln]
        self.assertTrue(listen)
        self.assertTrue(all(f"127.0.0.1:{self.port}" in ln for ln in listen), listen)

    def test_zz_nothing_written(self):
        self.get("/")
        self.get("/day/2026-11-14")
        self.assertEqual(self.digest(), self.before)


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv else 1
    sys.argv = [a for a in sys.argv if a != "--verbose"]
    sys.exit(0 if unittest.main(verbosity=verbosity, exit=False).result.wasSuccessful() else 1)
