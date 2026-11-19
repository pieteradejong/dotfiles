#!/usr/bin/env python3
"""test-pwd-gen.py — tests for bin/pwd-gen.

Asserts the contract (lengths, character classes, counts, the entropy line, exit
codes, the wordlist resolution order) and the randomness: chi-square tests at a
1e-9 false-alarm rate that each password character follows the exact expected
distribution, that every position has the same class mix, and that passphrase
words are uniform over the list, plus tests that the same checks reject a
modulo-biased and a fixed-position generator. Also the hardening (D83): the
clipboard is cleared after the delay only if unchanged, the clearer never sees
the value, the script runs isolated (a planted `secrets.py` is ignored), and a
changed shipped wordlist is refused. Hermetic: `--copy` runs against a fake
`pbcopy` and `pbpaste` on a private PATH without /usr/bin, backed by a temp
file, so the real clipboard is never touched; wordlists and tampered copies of
the tool are temp files.

Usage:  scripts/test-pwd-gen.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import math
import os
import re
import secrets
import stat
import string
import subprocess
import sys
import tempfile
import time
import unittest
from itertools import combinations
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PWD_GEN = REPO / "bin" / "pwd-gen"
WORDLIST = REPO / "config" / "pwd-gen" / "wordlist.txt"

DEFAULT_SYMBOLS = "!@#$%*-_"
WIDE_SYMBOLS = "!@#$%^&*()-_=+[]{}:;,.?"  # the default until D64
AMBIGUOUS = set("0O1lI|")

FAKE_PBCOPY = """#!/bin/sh
cat > "$FAKE_CLIPBOARD"
"""
FAKE_PBPASTE = """#!/bin/sh
cat "$FAKE_CLIPBOARD"
"""

# ── statistics for the randomness tests (stdlib only) ───────────────────────

DEFAULT_CLASSES = [string.ascii_lowercase, string.ascii_uppercase, string.digits,
                   DEFAULT_SYMBOLS]
RANDOMNESS_PASSWORDS = 20000
CHI2_ALPHA_Z = 6.0  # one-sided normal quantile for alpha ~ 1e-9


def chi2_critical(df, z=CHI2_ALPHA_Z):
    """Upper chi-square quantile by the Wilson–Hilferty approximation, close
    enough at these degrees of freedom to set a false-alarm rate of ~1e-9."""
    h = 2 / (9 * df)
    return df * (1 - h + z * math.sqrt(h)) ** 3


def chi2_stat(observed, expected):
    return sum((o - e) ** 2 / e for o, e in zip(observed, expected))


def chi2_contingency(table):
    """Pearson chi-square for independence of rows and columns; (stat, df)."""
    rows = [sum(r) for r in table]
    cols = [sum(c) for c in zip(*table)]
    n = sum(rows)
    stat = sum((table[i][j] - rows[i] * cols[j] / n) ** 2 / (rows[i] * cols[j] / n)
               for i in range(len(rows)) for j in range(len(cols)))
    return stat, (len(rows) - 1) * (len(cols) - 1)


def strings_missing_none_of(sizes, length):
    """Length-L strings over the union of these disjoint classes that use every
    one of them at least once (inclusion–exclusion), as an exact integer."""
    total = sum(sizes)
    return sum((-1) ** k * (total - sum(m)) ** length
               for k in range(len(sizes) + 1) for m in combinations(sizes, k))


def char_probabilities(classes, length):
    """Exact chance of each character at any one position of a password drawn
    uniformly from those that contain every class. Fixing that position to a
    character of class c leaves L-1 places that must cover the other classes,
    over the full alphabet."""
    sizes = [len(c) for c in classes]
    total = sum(sizes)
    valid = strings_missing_none_of(sizes, length)
    probs = {}
    for ci, cls in enumerate(classes):
        others = sizes[:ci] + sizes[ci + 1:]
        # Strings of length L-1 over all `total` symbols that use every other class.
        rest = sum((-1) ** k * (total - sum(m)) ** (length - 1)
                   for k in range(len(others) + 1) for m in combinations(others, k))
        for c in cls:
            probs[c] = rest / valid
    return probs


def class_index(classes, char):
    return next(i for i, cls in enumerate(classes) if char in cls)


def bucket_uniformity(indices, n, buckets):
    """Chi-square of indices in range(n) against uniform, over `buckets` near-equal
    buckets (expected counts follow each bucket's exact width); (stat, df)."""
    widths = [0] * buckets
    for i in range(n):
        widths[i * buckets // n] += 1
    counts = [0] * buckets
    for i in indices:
        counts[i * buckets // n] += 1
    expected = [len(indices) * w / n for w in widths]
    return chi2_stat(counts, expected), buckets - 1


def eff_words():
    """The shipped list as pwd-gen reads it: last field per line, sorted, distinct."""
    lines = (ln.strip() for ln in WORDLIST.read_text().splitlines())
    return sorted({ln.split()[-1] for ln in lines if ln and not ln.startswith("#")})


class PwdGenTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="test-pwd-gen.")
        root = Path(cls.tmp.name)
        cls.fakebin = root / "fakebin"
        cls.fakebin.mkdir()
        for name, body in (("pbcopy", FAKE_PBCOPY), ("pbpaste", FAKE_PBPASTE)):
            pb = cls.fakebin / name
            pb.write_text(body)
            pb.chmod(pb.stat().st_mode | stat.S_IXUSR)
        cls.emptybin = root / "emptybin"
        cls.emptybin.mkdir()
        cls.clipboard = root / "clipboard"
        # 2048 distinct words, plus comments, blanks and EFF-style dice prefixes.
        cls.small_list = root / "small.txt"
        lines = ["# a comment", ""]
        lines += [f"1{i:04d}\tword{i:04d}" if i % 2 else f"word{i:04d}" for i in range(2048)]
        cls.small_list.write_text("\n".join(lines) + "\n")
        # 1024 plain words and 1024 that contain the default separator.
        cls.mixed_list = root / "mixed.txt"
        cls.mixed_list.write_text(
            "".join(f"plain{i:04d}\nhy-phen{i:04d}\n" for i in range(1024)))
        cls.tiny_list = root / "tiny.txt"
        cls.tiny_list.write_text("alpha\nbravo\ncharlie\n")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_pg(self, *args, env=None, with_pbcopy=False):
        # The real pbcopy and pbpaste live in /usr/bin, which neither PATH
        # holds, so no test (and no clearer left running) reaches the real
        # clipboard; the fakes need only `cat` from /bin.
        e = {
            "PATH": f"{self.fakebin}:/bin" if with_pbcopy else str(self.emptybin),
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
        # 20 chars over 26+26+10+8 = 70 symbols, every class present
        # (inclusion–exclusion), as the tool itself computes.
        sizes = [26, 26, 10, 8]
        from itertools import combinations
        count = 0
        for k in range(len(sizes) + 1):
            for missing in combinations(sizes, k):
                count += (-1) ** k * (70 - sum(missing)) ** 20
        expected = f"entropy: {math.log2(count):.1f} bits (20 chars, 70-symbol alphabet"
        self.assertIn(expected, r.stderr)
        # The known value, so a shared mistake in the formula cannot pass.
        self.assertIn("entropy: 122.4 bits (20 chars, 70-symbol alphabet", r.stderr)
        self.assertEqual(r.stderr.count("\n"), 1)

    def test_wide_symbol_set_still_available(self):
        r = self.run_pg("--symbols", WIDE_SYMBOLS, "-n", "20")
        allowed = set(string.ascii_letters + string.digits + WIDE_SYMBOLS)
        for pw in self.lines(r):
            self.assertEqual(len(pw), 20)
            self.assertTrue(set(pw) <= allowed, pw)
            self.assertTrue(any(c in WIDE_SYMBOLS for c in pw), pw)
        self.assertIn("entropy: 128.1 bits (20 chars, 85-symbol alphabet", r.stderr)

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
        # The four hyphenated EFF words are left out under the default "-".
        self.assertIn(f"entropy: {6 * math.log2(7772):.1f} bits (6 words from 7772", r.stderr)

    def test_shipped_list_has_exactly_four_hyphenated_words(self):
        hyphenated = sorted(w for w in WORDLIST.read_text().split() if "-" in w)
        self.assertEqual(hyphenated, ["drop-down", "felt-tip", "t-shirt", "yo-yo"])

    def test_separator_flag(self):
        # With "." nothing is left out, so a hyphenated word may be drawn:
        # count the separators, and say nothing about "-".
        r = self.run_pg("-w", "4", "--sep", ".")
        (pp,) = self.lines(r)
        self.assertEqual(pp.count("."), 3)
        self.assertIn("4 words from 7776", r.stderr)

    def test_words_containing_the_separator_are_never_drawn(self):
        env = {"PWD_GEN_WORDLIST": str(self.mixed_list)}
        r = self.run_pg("-w", "6", "-n", "200", env=env)
        for pp in self.lines(r):
            parts = pp.split("-")
            self.assertEqual(len(parts), 6, pp)
            for w in parts:
                self.assertRegex(w, r"^plain\d{4}$")
        self.assertIn("6 words from 1024", r.stderr)
        # Another separator frees the hyphenated half again.
        r = self.run_pg("-w", "6", "-n", "200", "--sep", ".", env=env)
        self.assertIn("6 words from 2048", r.stderr)
        self.assertTrue(any("-" in pp for pp in self.lines(r)))

    def test_too_few_words_left_without_the_separator_exits_1(self):
        r = self.run_pg("-w", "4", "--sep", "d", env={"PWD_GEN_WORDLIST": str(self.small_list)})
        self.assertEqual(r.returncode, 1)
        self.assertIn("0 distinct words after leaving out 2048 that contain the separator",
                      r.stderr)
        self.assertEqual(r.stdout, "")

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
        self.assertIn("copied 1 to the clipboard; nothing printed; cleared in 30s unless replaced",
                      r.stderr)
        self.assertEqual(len(self.clipboard.read_text()), 24)

    def wait_for_clipboard(self, want, timeout=6.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.clipboard.read_text() == want:
                return True
            time.sleep(0.1)
        return self.clipboard.read_text() == want

    def test_copy_clears_the_clipboard_after_the_delay(self):
        r = self.run_pg("--copy", "--clear-after", "1", with_pbcopy=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("cleared in 1s unless replaced", r.stderr)
        self.assertEqual(len(self.clipboard.read_text()), 20)
        self.assertTrue(self.wait_for_clipboard(""), "clipboard was not cleared")

    def test_clear_leaves_a_replaced_clipboard_alone(self):
        r = self.run_pg("--copy", "--clear-after", "1", with_pbcopy=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.clipboard.write_text("something copied since")
        time.sleep(2.5)
        self.assertEqual(self.clipboard.read_text(), "something copied since")

    def test_clear_after_0_never_clears(self):
        r = self.run_pg("--copy", "--clear-after", "0", with_pbcopy=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not cleared", r.stderr)
        value = self.clipboard.read_text()
        time.sleep(1.5)
        self.assertEqual(self.clipboard.read_text(), value)

    def test_clearer_never_sees_the_value(self):
        # While the clearer waits, no process command line holds the password.
        r = self.run_pg("--copy", "--clear-after", "3", with_pbcopy=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        value = self.clipboard.read_text()
        ps = subprocess.run(["/bin/ps", "-axww", "-o", "command="],
                            capture_output=True, text=True, check=True).stdout
        self.assertIn("pbpaste", ps)  # the clearer is running...
        self.assertNotIn(value, ps)  # ...and only with a digest
        self.assertTrue(self.wait_for_clipboard(""), "clipboard was not cleared")

    def test_clear_after_usage_errors(self):
        self.assertEqual(self.run_pg("--clear-after", "5").returncode, 2)
        self.assertEqual(
            self.run_pg("--copy", "--clear-after", "-1", with_pbcopy=True).returncode, 2)

    def test_copy_quiet_is_silent(self):
        r = self.run_pg("--copy", "-q", "--clear-after", "0", with_pbcopy=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout + r.stderr, "")

    def test_copy_without_pbcopy_exits_1(self):
        r = self.run_pg("--copy", with_pbcopy=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn("pbcopy", r.stderr)
        self.assertEqual(r.stdout, "")

    # ── randomness quality ───────────────────────────────────────────────────
    # The tests above check the contract; these check the draws. Each sample is
    # independent by construction (one character per password, words drawn with
    # no conditioning), so the chi-square tests are exact, and each one fails
    # by chance with probability 1e-9 (CHI2_ALPHA_Z). The power tests below run
    # the same checks on two known-bad generators, so a check that cannot fail
    # is caught too.

    def sample_password_chars(self, n=RANDOMNESS_PASSWORDS):
        """One character per default password, at position i % 20, so the n
        samples are independent and every position is used equally often."""
        pws = self.lines(self.run_pg("-q", "-n", str(n)))
        self.assertEqual(len(pws), n)
        return [(i % 20, pw[i % 20]) for i, pw in enumerate(pws)]

    def test_password_characters_follow_the_exact_distribution(self):
        samples = self.sample_password_chars()
        probs = char_probabilities(DEFAULT_CLASSES, 20)
        counts = dict.fromkeys(probs, 0)
        for _, c in samples:
            counts[c] += 1
        stat = chi2_stat([counts[c] for c in probs],
                         [len(samples) * probs[c] for c in probs])
        crit = chi2_critical(len(probs) - 1)
        self.assertLess(stat, crit, f"chi2 {stat:.1f} over {len(probs) - 1} df")

    def test_every_position_has_the_same_class_mix(self):
        # A generator that put one character of each class at fixed positions
        # (rejected in D38) would pass the pooled test above but fail this one.
        samples = self.sample_password_chars()
        table = [[0] * len(DEFAULT_CLASSES) for _ in range(20)]
        for pos, c in samples:
            table[pos][class_index(DEFAULT_CLASSES, c)] += 1
        stat, df = chi2_contingency(table)
        self.assertLess(stat, chi2_critical(df), f"chi2 {stat:.1f} over {df} df")

    def test_passphrase_words_are_uniform_over_the_list(self):
        words = [w for w in eff_words() if "-" not in w]  # as the tool filters
        index = {w: i for i, w in enumerate(words)}
        drawn = []
        for pp in self.lines(self.run_pg("-q", "-w", "8", "-n", "5000")):
            drawn += pp.split("-")
        self.assertEqual(len(drawn), 40000)
        stat, df = bucket_uniformity([index[w] for w in drawn], len(words), 64)
        self.assertLess(stat, chi2_critical(df), f"chi2 {stat:.1f} over {df} df")

    def test_checks_reject_a_modulo_biased_generator(self):
        # `alphabet[byte % 70]`: the classic bug; 46 characters come up 4/256
        # of the time and 24 come up 3/256.
        alphabet = "".join(DEFAULT_CLASSES)
        probs = char_probabilities(DEFAULT_CLASSES, 20)
        counts = dict.fromkeys(probs, 0)
        for _ in range(RANDOMNESS_PASSWORDS):
            while True:
                pw = "".join(alphabet[secrets.randbits(8) % len(alphabet)] for _ in range(20))
                if all(any(c in cls for c in pw) for cls in DEFAULT_CLASSES):
                    break
            counts[pw[0]] += 1
        stat = chi2_stat([counts[c] for c in probs],
                         [RANDOMNESS_PASSWORDS * probs[c] for c in probs])
        self.assertGreater(stat, chi2_critical(len(probs) - 1))

    def test_checks_reject_fixed_position_classes(self):
        # One lower, upper, digit and symbol in positions 0-3, the rest free:
        # the fixed-position guarantee D38 rejected.
        alphabet = "".join(DEFAULT_CLASSES)
        table = [[0] * len(DEFAULT_CLASSES) for _ in range(20)]
        for i in range(RANDOMNESS_PASSWORDS):
            pw = [secrets.choice(cls) for cls in DEFAULT_CLASSES]
            pw += [secrets.choice(alphabet) for _ in range(16)]
            pos = i % 20
            table[pos][class_index(DEFAULT_CLASSES, pw[pos])] += 1
        stat, df = chi2_contingency(table)
        self.assertGreater(stat, chi2_critical(df))

    def test_exact_distribution_sums_to_one(self):
        probs = char_probabilities(DEFAULT_CLASSES, 20)
        self.assertAlmostEqual(sum(probs.values()), 1.0, places=12)
        # Smaller classes are over-represented because every class must appear.
        self.assertGreater(probs["!"], probs["a"])

    # ── repo contract ────────────────────────────────────────────────────────
    def test_is_executable_with_python3_shebang(self):
        self.assertTrue(os.access(PWD_GEN, os.X_OK))
        self.assertEqual(PWD_GEN.read_text().splitlines()[0], "#!/usr/bin/env -S python3 -I")

    # ── hardening (D83) ──────────────────────────────────────────────────────
    def tampered_copy(self, name, wordlist_extra=None, planted=None):
        """A copy of the tool in its repo layout under the temp dir, optionally
        with a module planted beside it or a line added to its wordlist."""
        root = Path(self.tmp.name) / name
        (root / "bin").mkdir(parents=True)
        (root / "config" / "pwd-gen").mkdir(parents=True)
        tool = root / "bin" / "pwd-gen"
        tool.write_bytes(PWD_GEN.read_bytes())
        tool.chmod(0o755)
        words = WORDLIST.read_bytes()
        if wordlist_extra:
            words += wordlist_extra.encode()
        (root / "config" / "pwd-gen" / "wordlist.txt").write_bytes(words)
        if planted:
            for mod, body in planted.items():
                (root / "bin" / f"{mod}.py").write_text(body)
        return tool

    def run_direct(self, tool, *args, env=None):
        # Through the shebang, as a shell runs it: env finds python3 on PATH.
        e = {"PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin", "LC_ALL": "C.UTF-8"}
        e.update(env or {})
        return subprocess.run([str(tool), *args], capture_output=True, text=True, env=e,
                              check=False, stdin=subprocess.DEVNULL)

    def test_planted_module_beside_the_script_is_ignored(self):
        # The 2026-11-19 review's attack: a `secrets.py` next to the script.
        evil = "def choice(seq):\n    return seq[0]\n"
        tool = self.tampered_copy("planted", planted={"secrets": evil})
        r = self.run_direct(tool, "-w", "4", "-n", "5", "-q")
        self.assertEqual(r.returncode, 0, r.stderr)
        for pp in r.stdout.splitlines():
            self.assertNotEqual(len(set(pp.split("-"))), 1, f"planted secrets.py was used: {pp}")
        r = self.run_direct(tool, "-n", "5", "-q")
        self.assertNotIn("aaaa", r.stdout)

    def test_pythonpath_is_ignored(self):
        evil_dir = Path(self.tmp.name) / "evil-pythonpath"
        evil_dir.mkdir(exist_ok=True)
        (evil_dir / "secrets.py").write_text("raise SystemExit('evil secrets imported')\n")
        r = self.run_direct(PWD_GEN, "-q", env={"PYTHONPATH": str(evil_dir)})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(r.stdout.strip()), 20)

    def test_changed_shipped_wordlist_is_refused(self):
        tool = self.tampered_copy("swapped", wordlist_extra="zzzextra\n")
        r = self.run_direct(tool, "-w", "4")
        self.assertEqual(r.returncode, 1)
        self.assertIn("is not the shipped EFF list", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_untouched_copy_passes_the_pin(self):
        r = self.run_direct(self.tampered_copy("clean"), "-w", "4", "-q")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(r.stdout.strip().split("-")), 4)

    def test_pinned_hash_matches_the_shipped_list(self):
        import hashlib
        pin = re.search(r'DEFAULT_WORDLIST_SHA256 = "([0-9a-f]{64})"', PWD_GEN.read_text())
        self.assertIsNotNone(pin)
        self.assertEqual(pin.group(1), hashlib.sha256(WORDLIST.read_bytes()).hexdigest())

    def test_stdlib_only(self):
        src = PWD_GEN.read_text()
        for line in src.splitlines():
            # Also covers the clearer's source, held in a string: `import a, b`.
            if line.startswith("from "):
                mods = [line.split()[1]]
            elif line.startswith("import "):
                mods = [m.strip().split()[0] for m in line[len("import "):].split(",")]
            else:
                continue
            for mod in mods:
                self.assertIn(mod.split(".")[0], sys.stdlib_module_names, line)


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv[1:] else 1
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PwdGenTest)
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
