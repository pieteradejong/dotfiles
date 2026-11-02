#!/usr/bin/env python3
"""test-claude-md-check.py — tests for scripts/claude-md-check.py.

Hermetic: every run gets fixture CLAUDE.md files in a temp dir, a temp HOME, and a
PATH holding only stub binaries that print canned version banners, so no real tool
is probed and nothing under the real ~/.claude or ~/dev is read or written. One
smoke case runs `--list` (no probes) over the repo's real sources, so the parsers
are proven on the files they exist for.

Usage:  scripts/test-claude-md-check.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CHECK = REPO / "scripts" / "claude-md-check.py"

# name -> (stdout, stderr, exit). Banners copied from real tools, multi-line where the tool's is.
STUBS = {
    "sw_vers": ("27.0.1\n", "", 0),
    "uname": ("27.0.0\n", "", 0),
    "zsh": ("zsh 5.9.2 (aarch64-apple-darwin25.4.0)\n", "", 0),
    "brew": ("Homebrew 7.0.11-24-g2833c25\n", "", 0),
    "node": ("v26.7.0\n", "", 0),
    "python3": ("Python 3.15.2\n", "", 0),
    "go": ("go version go1.20.3 darwin/arm64\n", "", 0),
    "gh": ("gh version 2.103.3 (2026-10-26)\nhttps://github.com/cli/cli/releases/tag/v2.103.3\n", "", 0),
    "java": ("", 'openjdk version "17.0.1" 2021-10-19\nOpenJDK Runtime Environment\n', 0),
    "kubectl": ("Client Version: v1.37.2\nKustomize Version: v5.8.1\n", "", 0),
    "jq": ("jq-1.8.2\n", "", 0),
    "code": ("1.96.0\n138f619c86f1199955d53b4166bef66ef252935c\narm64\n", "", 0),
    "git": ("git version 2.56.0\n", "", 0),
    "npm": ("", "npm ERR! broken\n", 3),          # exits non-zero
    "gem": ("no digits here at all\n", "", 0),     # garbage
}

MATCHING = """\
# CLAUDE.md

## System

- **OS**: macOS 27.0 (Darwin 27.0.0), Apple Silicon
- **Shell**: zsh 5.9 with oh-my-zsh

## Package Managers

| Manager | Version | Use for |
|---------|---------|---------|
| homebrew | 7.0 | system packages |

## Languages

| Language | Version | Path |
|----------|---------|------|
| Node.js | v26.7.0 | via nvm 0.40.3 |
| Java | OpenJDK 17.0.1 | system |
| Go | 1.20 | system |

Python is Homebrew-managed (3.15); always use `python3`.

## Tools

| Tool | Version |
|---|---|
| gh (GitHub CLI) | 2.103.3 |
| `kube|ctl` | 1.37 |
| jq | 1.8.2 |
| Mystery tool | 4.2.0 |

## Editors

- **VS Code** 1.96.0 — `code`
"""

DEV = """\
# Workspace

| Stack | Variants |
|---|---|
| git | 1.0.0 |

Not a table: git 1.0.0 and | git | 1.0.0 | in prose.
"""


def write_stub(d, name, out, err, rc):
    p = d / name
    p.write_text(
        "#!/bin/sh\n"
        f"printf '%s' '{out}'\n"
        f"printf '%s' '{err}' >&2\n"
        f"exit {rc}\n")
    p.chmod(p.stat().st_mode | stat.S_IXUSR)


class ClaudeMdCheckTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Stubs are written once: macOS scans every new executable on its first run,
        # which costs more than the whole check when repeated for each case.
        cls.stubs = tempfile.TemporaryDirectory(prefix="test-claude-md-check.bin.")
        cls.bin = Path(cls.stubs.name)
        for name, (out, err, rc) in STUBS.items():
            write_stub(cls.bin, name, out, err, rc)
        hang = cls.bin / "colima"  # never answers; only the timeout case lists Colima
        hang.write_text("#!/bin/sh\nexec /bin/sleep 30\n")
        hang.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.stubs.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="test-claude-md-check.")
        root = Path(self.tmp.name)
        self.home = root / "home"
        (self.home / ".claude").mkdir(parents=True)
        (self.home / "dev").mkdir()
        self.glob = root / "src" / "CLAUDE.md"
        self.glob.parent.mkdir()
        self.glob.write_text(MATCHING)
        self.dev = root / "src" / "dev-CLAUDE.md"
        self.dev.write_text(DEV)

    def tearDown(self):
        self.tmp.cleanup()

    def run_check(self, *args, glob=None, env=None):
        if glob is not None:
            self.glob.write_text(glob)
        e = {
            "PATH": str(self.bin),
            "HOME": str(self.home),
            "LC_ALL": "C.UTF-8",
            "GLOBAL_CLAUDE_SRC": str(self.glob),
            "DEV_CLAUDE_SRC": str(self.dev),
            "TODAY": "2026-10-29",
            "PROBE_TIMEOUT": "2",
        }
        if env:
            e.update(env)
        return subprocess.run([sys.executable, str(CHECK), *args], capture_output=True, text=True,
                              env=e, check=False, stdin=subprocess.DEVNULL, timeout=60)

    def line_for(self, r, needle):
        hits = [ln for ln in r.stdout.splitlines() if needle in ln]
        self.assertTrue(hits, f"no line with {needle!r} in:\n{r.stdout}")
        return hits[0]

    # ── versions ─────────────────────────────────────────────────────────────
    def test_matching_file_exits_0(self):
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("0 FAIL", r.stdout)

    def test_banner_parsing(self):
        r = self.run_check()
        for needle in ("ok    macOS 27.0", "ok    Darwin 27.0.0", "ok    zsh 5.9", "ok    homebrew 7.0",
                       "ok    Node.js 26.7.0", "ok    Java 17.0.1", "ok    Go 1.20",
                       "ok    python3 (prose) 3.15", "ok    gh (GitHub CLI) 2.103.3",
                       "ok    jq 1.8.2", "ok    VS Code 1.96.0"):
            self.line_for(r, needle)

    def test_pipe_inside_backticks_is_one_cell(self):
        r = self.run_check("--list")
        self.line_for(r, "`kube|ctl`\t1.37")

    def test_unknown_tool_is_a_note_not_a_fail(self):
        r = self.run_check()
        self.assertIn("note", self.line_for(r, "Mystery tool"))
        self.assertEqual(r.returncode, 0)

    def test_tables_without_version_header_and_prose_rows_are_ignored(self):
        r = self.run_check("--list")
        self.assertNotIn("dev-CLAUDE.md", r.stdout)

    def test_names_match_case_insensitively(self):
        r = self.run_check("--list")
        self.assertIn("brew --version", self.line_for(r, "homebrew"))

    def test_drift_fails_and_names_tool(self):
        r = self.run_check(glob=MATCHING.replace("| jq | 1.8.2 |", "| jq | 1.7.1 |"))
        self.assertEqual(r.returncode, 1)
        line = self.line_for(r, "jq:")
        self.assertIn("FAIL", line)
        self.assertIn("states 1.7.1, installed 1.8.2", line)

    def test_prefix_is_precision_not_substring(self):
        r = self.run_check(glob=MATCHING.replace("| Go | 1.20 |", "| Go | 1.2 |"))
        self.assertIn("FAIL", self.line_for(r, "Go:"))

    def test_missing_tool_fails(self):
        r = self.run_check(glob=MATCHING + "\n| Tool | Version |\n|---|---|\n| cargo | 1.72.0 |\n")
        self.assertIn("not installed / not on PATH", self.line_for(r, "cargo"))
        self.assertEqual(r.returncode, 1)

    def test_probe_exit_nonzero_fails(self):
        r = self.run_check(glob=MATCHING + "\n| Tool | Version |\n|---|---|\n| npm | 11.7.0 |\n")
        self.assertIn("probe failed with exit 3", self.line_for(r, "npm"))
        self.assertEqual(r.returncode, 1)

    def test_probe_garbage_fails(self):
        r = self.run_check(glob=MATCHING + "\n| Tool | Version |\n|---|---|\n| gem | 3.0.3.1 |\n")
        self.assertIn("could not read a version", self.line_for(r, "gem"))

    def test_probe_hang_times_out(self):
        r = self.run_check(glob=MATCHING + "\n| Tool | Version |\n|---|---|\n| Colima | 0.10.3 |\n",
                           env={"PROBE_TIMEOUT": "1"})
        self.assertIn("timed out after 1s", self.line_for(r, "Colima"))
        self.assertEqual(r.returncode, 1)

    def test_fenced_block_is_ignored(self):
        fenced = MATCHING + "\n```\n| Tool | Version |\n|---|---|\n| cargo | 1.0.0 |\nas of 2020-01-01\n```\n"
        r = self.run_check(glob=fenced)
        self.assertNotIn("cargo", r.stdout)
        self.assertNotIn("  WARN ", r.stdout)

    # ── dates ────────────────────────────────────────────────────────────────
    def dated(self, phrase):
        return self.run_check(glob=MATCHING + f"\nRouting table, {phrase}.\n", env={"MAX_AGE_DAYS": "90"})

    def test_date_at_limit_is_ok(self):
        r = self.dated("as of 2026-07-31")  # 90 days before 2026-10-29
        self.assertNotIn("  WARN ", r.stdout)

    def test_date_one_day_past_limit_warns_exit_0(self):
        r = self.dated("as of 2026-07-30")
        self.assertIn("91 days old", self.line_for(r, "  WARN "))
        self.assertEqual(r.returncode, 0)

    def test_month_form(self):
        self.assertNotIn("  WARN ", self.dated("as of Oct 2026").stdout)
        self.assertIn("as of June 2026", self.line_for(self.dated("as of June 2026"), "  WARN "))

    def test_checked_and_verified_forms(self):
        self.assertIn("  WARN ", self.dated("last checked 2025-01-01").stdout)
        self.assertIn("  WARN ", self.dated("Verified 2025-01-01").stdout)

    def test_future_date_ignored(self):
        self.assertNotIn("  WARN ", self.dated("as of 2027-06-01").stdout)

    def test_event_dates_are_not_claims(self):
        self.assertNotIn("  WARN ", self.dated("deleted 2020-01-01").stdout)

    def test_date_in_code_span_ignored(self):
        self.assertNotIn("  WARN ", self.dated("`as of 2020-01-01`").stdout)

    # ── size ─────────────────────────────────────────────────────────────────
    def test_size_warns(self):
        r = self.run_check(env={"MAX_LINES": "10"})
        self.assertIn("lines (limit 10)", self.line_for(r, "  WARN "))
        self.assertEqual(r.returncode, 0)

    # ── --apply ──────────────────────────────────────────────────────────────
    STALE = (MATCHING.replace("macOS 27.0 (Darwin 27.0.0)", "macOS 26.4 (Darwin 25.4.0)")
             .replace("| Node.js | v26.7.0 |", "| Node.js | v22.16.0 |")
             .replace("Homebrew-managed (3.15)", "Homebrew-managed (3.14)"))

    def test_apply_fixes_only_version_tokens_keeping_precision(self):
        r = self.run_check("--apply", glob=self.STALE)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.glob.read_text(), MATCHING)
        self.assertIn(f"wrote {self.glob}", r.stdout)
        self.assertIn("copy it to the live", r.stderr)

    def test_apply_keeps_v_prefix(self):
        self.run_check("--apply", glob=self.STALE)
        self.assertIn("| Node.js | v26.7.0 |", self.glob.read_text())

    def test_apply_is_idempotent(self):
        self.run_check("--apply", glob=self.STALE)
        first = self.glob.read_text()
        r = self.run_check("--apply")
        self.assertEqual(self.glob.read_text(), first)
        self.assertNotIn("wrote", r.stdout)

    def test_apply_leaves_unfixable_fails(self):
        r = self.run_check("--apply", glob=self.STALE + "\n| Tool | Version |\n|---|---|\n| cargo | 1.0 |\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("| cargo | 1.0 |", self.glob.read_text())

    def test_apply_quiet_shows_fixes_only(self):
        r = self.run_check("--apply", "--quiet", glob=self.STALE)
        self.assertNotIn("  ok ", r.stdout)
        self.assertIn("fixed", r.stdout)

    def test_dry_run_writes_nothing_and_prints_diff(self):
        r = self.run_check("--apply", "--dry-run", glob=self.STALE)
        self.assertEqual(self.glob.read_text(), self.STALE)
        self.assertIn("-| Node.js | v22.16.0 |", r.stdout)
        self.assertIn("+| Node.js | v26.7.0 |", r.stdout)
        self.assertEqual(r.returncode, 1)

    def test_apply_refuses_live_copy(self):
        live = self.home / ".claude" / "CLAUDE.md"
        live.write_text(self.STALE)
        r = self.run_check("--apply", env={"GLOBAL_CLAUDE_SRC": str(live)})
        self.assertEqual(r.returncode, 2)
        self.assertIn("never a live copy", r.stderr)
        self.assertEqual(live.read_text(), self.STALE)

    # ── CLI ──────────────────────────────────────────────────────────────────
    def test_help(self):
        r = self.run_check("--help")
        self.assertEqual(r.returncode, 0)
        self.assertTrue(r.stdout.startswith("claude-md-check.py"))

    def test_unknown_flag(self):
        r = self.run_check("--bogus")
        self.assertEqual(r.returncode, 2)
        self.assertIn("unknown argument", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_dry_run_without_apply(self):
        self.assertEqual(self.run_check("--dry-run").returncode, 2)

    def test_missing_source(self):
        r = self.run_check(env={"DEV_CLAUDE_SRC": str(self.home / "nope.md")})
        self.assertEqual(r.returncode, 2)
        self.assertIn("source not found", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_bad_env_number(self):
        self.assertEqual(self.run_check(env={"MAX_LINES": "lots"}).returncode, 2)

    def test_quiet_prints_only_problems(self):
        r = self.run_check("--quiet", glob=MATCHING.replace("| jq | 1.8.2 |", "| jq | 1.7 |"))
        body = [ln for ln in r.stdout.splitlines() if ln.startswith("  ")]
        self.assertTrue(body)
        self.assertTrue(all(ln.split()[0] in ("WARN", "FAIL") for ln in body), body)

    def test_results_on_stdout_not_stderr(self):
        r = self.run_check(glob=MATCHING.replace("| jq | 1.8.2 |", "| jq | 1.7 |"))
        self.assertIn("FAIL", r.stdout)
        self.assertEqual(r.stderr, "")

    # ── smoke: the real sources parse ────────────────────────────────────────
    def test_real_sources_parse(self):
        r = self.run_check("--list", env={"GLOBAL_CLAUDE_SRC": str(REPO / "claude" / "CLAUDE.md"),
                                          "DEV_CLAUDE_SRC": str(REPO / "claude" / "dev-CLAUDE.md")})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("claude/CLAUDE.md", r.stdout)
        total = int(r.stdout.splitlines()[-1].split()[0])
        self.assertGreaterEqual(total, 20, "the global file's version tables stopped parsing")
        self.assertNotIn("(no probe)", r.stdout, "a version row has no probe in PROBES")


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv[1:] else 1
    sys.argv = sys.argv[:1]
    result = unittest.main(verbosity=verbosity, exit=False).result
    print(f"claude-md-check: {result.testsRun - len(result.failures) - len(result.errors)} passed, "
          f"{len(result.failures) + len(result.errors)} failed")
    sys.exit(0 if result.wasSuccessful() else 1)
