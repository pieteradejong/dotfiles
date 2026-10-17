#!/usr/bin/env python3
"""test-pwd-gen.py — tests for bin/pwd-gen.

Asserts the contract, not the randomness: lengths, character classes, counts,
the entropy line, exit codes, the wordlist resolution order. Hermetic: `--copy`
runs against a fake `pbcopy` on a private PATH that writes to a temp file, so
the real clipboard is never touched; wordlists are temp files.

Usage:  scripts/test-pwd-gen.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import math
import os
import stat
import string
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PWD_GEN = REPO / "bin" / "pwd-gen"
WORDLIST = REPO / "config" / "pwd-gen" / "wordlist.txt"

DEFAULT_SYMBOLS = "!@#$%^&*()-_=+[]{}:;,.?"
AMBIGUOUS = set("0O1lI|")

FAKE_PBCOPY = """#!/bin/sh
cat > "$FAKE_CLIPBOARD"
"""


class PwdGenTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="test-pwd-gen.")
        root = Path(cls.tmp.name)
        cls.fakebin = root / "fakebin"
        cls.fakebin.mkdir()
        pb = cls.fakebin / "pbcopy"
        pb.write_text(FAKE_PBCOPY)
        pb.chmod(pb.stat().st_mode | stat.S_IXUSR)
        cls.emptybin = root / "emptybin"
        cls.emptybin.mkdir()
        cls.clipboard = root / "clipboard"
        # 2048 distinct words, plus comments, blanks and EFF-style dice prefixes.
        cls.small_list = root / "small.txt"
        lines = ["# a comment", ""]
        lines += [f"1{i:04d}\tword{i:04d}" if i % 2 else f"word{i:04d}" for i in range(2048)]
        cls.small_list.write_text("\n".join(lines) + "\n")
        cls.tiny_list = root / "tiny.txt"
        cls.tiny_list.write_text("alpha\nbravo\ncharlie\n")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_pg(self, *args, env=None, with_pbcopy=False):
        # The real pbcopy lives in /usr/bin, so the "no pbcopy" PATH holds
        # only the empty dir; pwd-gen needs nothing else from PATH.
        e = {
            "PATH": f"{self.fakebin}:/usr/bin:/bin" if with_pbcopy else str(self.emptybin),
            "LC_ALL": "C.UTF-8",
            "FAKE_CLIPBOARD": str(self.clipboard),
        }
        if env:
            e.update(env)
        return subprocess.run(
            [sys.executable, str(PWD_GEN), *args],
            capture_output=True, text=True, env=e, check=False, stdin=subprocess.DEVNULL,
        )

    def lines(self, r):
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.endswith("\n"))
        return r.stdout.splitlines()

    # ── usage ────────────────────────────────────────────────────────────────
    def test_help_exits_0_and_prints_header(self):
        r = self.run_pg("--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("Usage:", r.stdout)
        self.assertIn("PWD_GEN_WORDLIST", r.stdout)
        self.assertEqual(r.stderr, "")

    def test_unknown_option_is_usage_error(self):
        r = self.run_pg("--bogus")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--bogus", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_length_below_class_count_is_usage_error(self):
        r = self.run_pg("--length", "3")
        self.assertEqual(r.returncode, 2)
        self.assertIn("at least 4", r.stderr)
        r = self.run_pg("--length", "3", "--no-symbols")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_contradicting_symbol_flags_are_usage_error(self):
        r = self.run_pg("--symbols", "#", "--no-symbols")
        self.assertEqual(r.returncode, 2)

    def test_bad_counts_are_usage_errors(self):
        self.assertEqual(self.run_pg("--count", "0").returncode, 2)
        self.assertEqual(self.run_pg("--words", "0").returncode, 2)
        self.assertEqual(self.run_pg("--symbols", "a b").returncode, 2)

    # ── random password ──────────────────────────────────────────────────────
    def test_default_is_20_chars_with_every_class(self):
        for _ in range(20):
            (pw,) = self.lines(self.run_pg())
            self.assertEqual(len(pw), 20)
            self.assertTrue(any(c in string.ascii_lowercase for c in pw), pw)
            self.assertTrue(any(c in string.ascii_uppercase for c in pw), pw)
            self.assertTrue(any(c in string.digits for c in pw), pw)
            self.assertTrue(any(c in DEFAULT_SYMBOLS for c in pw), pw)
            self.assertTrue(set(pw) <= set(string.ascii_letters + string.digits + DEFAULT_SYMBOLS))

    def test_length_flag(self):
        (pw,) = self.lines(self.run_pg("-l", "40"))
        self.assertEqual(len(pw), 40)

    def test_no_symbols(self):
        for _ in range(10):
            (pw,) = self.lines(self.run_pg("--no-symbols"))
            self.assertTrue(set(pw) <= set(string.ascii_letters + string.digits), pw)

    def test_custom_symbols(self):
        for _ in range(10):
            (pw,) = self.lines(self.run_pg("--symbols", "#", "-l", "8"))
            self.assertIn("#", pw)
            self.assertTrue(set(pw) <= set(string.ascii_letters + string.digits + "#"), pw)

    def test_no_ambiguous(self):
        for pw in self.lines(self.run_pg("--no-ambiguous", "-n", "30")):
            self.assertFalse(set(pw) & AMBIGUOUS, pw)

    def test_count_gives_distinct_lines(self):
        pws = self.lines(self.run_pg("-n", "5"))
        self.assertEqual(len(pws), 5)
        self.assertEqual(len(set(pws)), 5)

    def test_entropy_line_is_exact_for_default(self):
        r = self.run_pg()
        # 20 chars over 26+26+10+23 = 85 symbols, every class present
        # (inclusion–exclusion), as the tool itself computes.
        sizes = [26, 26, 10, 23]
        from itertools import combinations
        count = 0
        for k in range(len(sizes) + 1):
            for missing in combinations(sizes, k):
                count += (-1) ** k * (85 - sum(missing)) ** 20
        expected = f"entropy: {math.log2(count):.1f} bits (20 chars, 85-symbol alphabet"
        self.assertIn(expected, r.stderr)
        self.assertEqual(r.stderr.count("\n"), 1)

    def test_quiet_silences_stderr(self):
        r = self.run_pg("-q")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stderr, "")
        self.assertEqual(len(r.stdout.splitlines()), 1)

    # ── passphrase ───────────────────────────────────────────────────────────
    def test_shipped_wordlist_is_the_eff_large_list(self):
        words = WORDLIST.read_text().split()
        self.assertEqual(len(words), 7776)
        self.assertEqual(len(set(words)), 7776)
        self.assertEqual(words[0], "abacus")

    def test_passphrase_from_shipped_list(self):
        words = set(WORDLIST.read_text().split())
        r = self.run_pg("-w", "6")
        (pp,) = self.lines(r)
        parts = pp.split("-")
        self.assertEqual(len(parts), 6)
        for w in parts:
            self.assertIn(w, words)
        self.assertIn(f"entropy: {6 * math.log2(7776):.1f} bits (6 words from 7776", r.stderr)

    def test_separator_flag(self):
        (pp,) = self.lines(self.run_pg("-w", "4", "--sep", "."))
        self.assertEqual(pp.count("."), 3)
        self.assertNotIn("-", pp)

    def test_env_wordlist_accepts_comments_blanks_and_dice_format(self):
        r = self.run_pg("-w", "5", env={"PWD_GEN_WORDLIST": str(self.small_list)})
        (pp,) = self.lines(r)
        parts = pp.split("-")
        self.assertEqual(len(parts), 5)
        for w in parts:
            self.assertRegex(w, r"^word\d{4}$")
        self.assertIn("5 words from 2048", r.stderr)

    def test_env_wordlist_missing_exits_1(self):
        r = self.run_pg("-w", "4", env={"PWD_GEN_WORDLIST": str(self.tmp.name) + "/none"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("PWD_GEN_WORDLIST", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_env_wordlist_too_small_exits_1(self):
        r = self.run_pg("-w", "4", env={"PWD_GEN_WORDLIST": str(self.tiny_list)})
        self.assertEqual(r.returncode, 1)
        self.assertIn("need at least", r.stderr)
        self.assertEqual(r.stdout, "")

    # ── clipboard ────────────────────────────────────────────────────────────
    def test_copy_prints_nothing_and_fills_clipboard(self):
        if self.clipboard.exists():
            self.clipboard.unlink()
        r = self.run_pg("--copy", "-l", "24", with_pbcopy=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "")
        self.assertIn("copied 1 to the clipboard", r.stderr)
        self.assertEqual(len(self.clipboard.read_text()), 24)

    def test_copy_quiet_is_silent(self):
        r = self.run_pg("--copy", "-q", with_pbcopy=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout + r.stderr, "")

    def test_copy_without_pbcopy_exits_1(self):
        r = self.run_pg("--copy", with_pbcopy=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn("pbcopy", r.stderr)
        self.assertEqual(r.stdout, "")

    # ── repo contract ────────────────────────────────────────────────────────
    def test_is_executable_with_python3_shebang(self):
        self.assertTrue(os.access(PWD_GEN, os.X_OK))
        self.assertEqual(PWD_GEN.read_text().splitlines()[0], "#!/usr/bin/env python3")

    def test_stdlib_only(self):
        src = PWD_GEN.read_text()
        for line in src.splitlines():
            if line.startswith(("import ", "from ")):
                mod = line.split()[1].split(".")[0]
                self.assertIn(mod, sys.stdlib_module_names, line)


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv[1:] else 1
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PwdGenTest)
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
