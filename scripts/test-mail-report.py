#!/usr/bin/env python3
"""test-mail-report.py — tests for bin/mail-report.

Hermetic: a fake `security` on a private PATH stands in for the Keychain, and
every send is a --dry-run, so no test touches the real Keychain or the network.
Passes on Linux CI, where there is no `security` at all.

Usage:  scripts/test-mail-report.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import email
import email.policy
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MAIL_REPORT = REPO / "bin" / "mail-report"

SERVICE = "test-mail-report-service"
ACCOUNT = "sender@example.com"
PASSWORD = "fake-app-password-do-not-print"

# What `security find-generic-password -s SERVICE` prints for a known service:
# the attribute dump on stdout (the acct line is what mail-report parses); with
# -w only the password. An unknown service exits 44 with a message on stderr.
FAKE_SECURITY = f"""#!/bin/sh
svc=""; want_pw=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift ;;
    -w) want_pw=1 ;;
  esac
  shift
done
if [ "$svc" != "{SERVICE}" ]; then
  echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
  exit 44
fi
if [ "$want_pw" = 1 ]; then
  echo "{PASSWORD}"
else
  printf 'keychain: "/Users/someone/Library/Keychains/login.keychain-db"\\n'
  printf 'attributes:\\n'
  printf '    "acct"<blob>="{ACCOUNT}"\\n'
  printf '    "svce"<blob>="{SERVICE}"\\n'
fi
"""


class MailReportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="test-mail-report.")
        cls.fakebin = Path(cls.tmp.name) / "fakebin"
        cls.fakebin.mkdir()
        sec = cls.fakebin / "security"
        sec.write_text(FAKE_SECURITY)
        sec.chmod(sec.stat().st_mode | stat.S_IXUSR)
        cls.emptybin = Path(cls.tmp.name) / "emptybin"
        cls.emptybin.mkdir()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_mr(self, *args, stdin="", service=SERVICE, env=None, with_security=True):
        e = {
            "PATH": f"{self.fakebin if with_security else self.emptybin}:/usr/bin:/bin",
            "MAIL_REPORT_SERVICE": service,
            "LC_ALL": "C.UTF-8",
        }
        if env:
            e.update(env)
        return subprocess.run(
            [sys.executable, str(MAIL_REPORT), *args],
            input=stdin, capture_output=True, text=True, env=e, check=False,
        )

    # ── usage ────────────────────────────────────────────────────────────────
    def test_help_exits_0_and_prints_usage(self):
        r = self.run_mr("--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("Usage:", r.stdout)
        self.assertIn("dotfiles-mail-report", r.stdout)

    def test_missing_subject_is_usage_error(self):
        r = self.run_mr("--dry-run", stdin="body\n")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--subject is required", r.stderr)

    def test_unknown_option_is_usage_error(self):
        r = self.run_mr("--bogus", "--subject", "s")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--bogus", r.stderr)

    # ── configuration ────────────────────────────────────────────────────────
    def test_unknown_service_exits_3(self):
        r = self.run_mr("--dry-run", "--subject", "s", stdin="x\n", service="no-such-service")
        self.assertEqual(r.returncode, 3)
        self.assertIn("not configured", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_no_security_binary_exits_3(self):
        r = self.run_mr("--dry-run", "--subject", "s", stdin="x\n", with_security=False)
        self.assertEqual(r.returncode, 3)
        self.assertIn("not configured", r.stderr)

    # ── composition (dry run) ────────────────────────────────────────────────
    def test_dry_run_prints_message_and_sends_nothing(self):
        r = self.run_mr("--dry-run", "--subject", "weekly test", stdin="line one\nline two\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"From: {ACCOUNT}", r.stdout)
        self.assertIn(f"To: {ACCOUNT}", r.stdout)
        self.assertIn("Subject: weekly test", r.stdout)
        self.assertIn("Content-Type: text/plain", r.stdout)
        self.assertIn("line one\nline two\n", r.stdout)
        self.assertIn("X-Mailer: dotfiles mail-report", r.stdout)
        self.assertIn("Date: ", r.stdout)

    def test_recipient_defaults_to_sender_then_env_then_flag(self):
        env = {"MAIL_REPORT_TO": "inbox@example.com"}
        r = self.run_mr("--dry-run", "--subject", "s", stdin="x\n", env=env)
        self.assertIn("To: inbox@example.com", r.stdout)
        self.assertIn(f"From: {ACCOUNT}", r.stdout)
        r = self.run_mr("--dry-run", "--subject", "s", "--to", "flag@example.com", stdin="x\n", env=env)
        self.assertIn("To: flag@example.com", r.stdout)

    def test_utf8_body_round_trips(self):
        # A non-ASCII body is transfer-encoded on the wire; the decoded content
        # must be the input, byte for byte.
        body = "Reclaimed: 1 234 MB — déjà vu ✓\n"
        r = self.run_mr("--dry-run", "--subject", "s", stdin=body)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("charset=\"utf-8\"", r.stdout)
        msg = email.message_from_string(r.stdout, policy=email.policy.default)
        self.assertEqual(msg.get_content(), body)

    def test_empty_body_is_marked(self):
        r = self.run_mr("--dry-run", "--subject", "s", stdin="")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("(no output)", r.stdout)

    def test_test_flag_composes_a_probe_without_stdin(self):
        r = self.run_mr("--dry-run", "--test")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Subject: mail-report test from", r.stdout)
        self.assertIn("mail-report is configured", r.stdout)

    # ── never the password ───────────────────────────────────────────────────
    def test_password_never_printed(self):
        for args, stdin in (
            (("--dry-run", "--subject", "s"), "x\n"),
            (("--dry-run", "--test"), ""),
            (("--subject", "s", "--bogus"), ""),
        ):
            r = self.run_mr(*args, stdin=stdin)
            self.assertNotIn(PASSWORD, r.stdout + r.stderr, args)

    def test_send_failure_reports_without_password(self):
        # Port 9 on localhost is closed: the SMTP connection is refused at once.
        env = {"MAIL_REPORT_SMTP": "127.0.0.1:9"}
        r = self.run_mr("--subject", "s", stdin="x\n", env=env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("send failed via 127.0.0.1:9", r.stderr)
        self.assertNotIn(PASSWORD, r.stdout + r.stderr)

    # ── static ───────────────────────────────────────────────────────────────
    def test_script_is_executable_and_stdlib_only(self):
        self.assertTrue(os.access(MAIL_REPORT, os.X_OK), "bin/mail-report is executable")
        src = MAIL_REPORT.read_text()
        self.assertTrue(src.startswith("#!/usr/bin/env python3\n"))
        for line in src.splitlines():
            if line.startswith(("import ", "from ")):
                mod = line.split()[1].split(".")[0]
                self.assertIn(mod, {"os", "re", "smtplib", "socket", "ssl", "subprocess", "sys", "email"},
                              f"non-stdlib import: {line}")


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv[1:] else 1
    sys.argv = [sys.argv[0]]
    unittest.main(verbosity=verbosity)
