#!/usr/bin/env python3
"""test-model-versions.py — tests for scripts/model-versions.py.

Hermetic: each case writes a fixture lineup and fixture ollama.com pages (search results and
tags pages, in the markup the live site uses) to a temp dir and points the script at them
through a file:// OLLAMA_WEB, so nothing is fetched.

Usage:  scripts/test-model-versions.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import os
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "model-versions.py"


def card(name, updated, sizes=(), caps=(), downloads=50_000):
    badges = "".join(f'<span class="cap">{c}</span>' for c in caps)
    badges += "".join(f'<span class="size">{s}</span>' for s in sizes)
    return (f'<li class="x"><a href="/library/{name}" class="group">'
            f'<span title="Updated {updated}">2w</span>{badges}'
            f'<span title="{downloads:,} downloads"><span>{downloads}</span></span></a></li>')


def tags(name, rows):
    return "".join(f'<div class="group"><a href="/library/{name}:{t}" class="md:hidden flex">'
                   f'<span class="font-mono"> abc123</span> • {gb} • 32K context window •</a></div>'
                   for t, gb in rows)


class ModelVersions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.web = self.d / "web"
        self.web.mkdir()
        self.lineup = self.d / "lineup"
        self.lineup.write_text("# test\nreasoner big:27b 18\nembed vec:0.6b 1\nembed old-vec:latest 1\n")

    def tearDown(self):
        self.tmp.cleanup()

    def page(self, path_qs, body):
        (self.web / (urllib.parse.quote(path_qs, safe="") + ".html")).write_text(f"<ul>{body}</ul>")

    def search(self, **q):
        return "/search?" + urllib.parse.urlencode(q)

    def standard(self):
        self.page(self.search(q="big"), card("big", "October 1, 2026", ["27b"], ["thinking"]))
        self.page(self.search(q="vec"), card("vec", "January 5, 2026", ["0.6b"], ["embedding"]))
        self.page(self.search(c="thinking", o="newest"), "".join([
            card("newer-big", "November 2, 2026", ["14b", "32b"], ["thinking", "tools"]),
            card("cloudy", "November 3, 2026", [], ["thinking", "cloud"]),          # cloud only
            card("tiny", "November 4, 2026", ["4b"], ["thinking"]),                 # too small
            card("huge", "November 5, 2026", ["120b"], ["thinking"]),               # too big
            card("niche", "November 6, 2026", ["30b"], ["thinking"], downloads=12), # unused
            card("older", "September 1, 2026", ["30b"], ["thinking"]),              # not newer
            card("big", "October 1, 2026", ["27b"], ["thinking"]),                  # ours
        ]))
        self.page("/library/newer-big/tags", tags("newer-big", [("latest", "20GB"), ("14b", "9.1GB"), ("32b", "20GB"),
                                                                ("32b-q2_K", "11GB")]))
        self.page("/library/tiny/tags", tags("tiny", [("4b", "2.5GB")]))
        self.page("/library/huge/tags", tags("huge", [("120b", "70GB"), ("120b-q2_K", "22GB")]))
        self.page(self.search(c="embedding", o="newest"), "".join([
            card("vec-2", "October 15, 2026", ["270m", "740m"], ["embedding", "vision"]),
            card("chatty", "October 20, 2026", ["8b"], ["tools"]),                   # not an embedder
        ]))
        self.page("/library/vec-2/tags", tags("vec-2", [("270m", "304MB"), ("740m", "1.3GB")]))

    def run_script(self, *args, **env):
        e = {**os.environ, "LLM_LINEUP": str(self.lineup), "OLLAMA_WEB": f"file://{self.web}",
             "TODAY": "2026-11-10", **env}
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], check=False, env=e,
                              capture_output=True, text=True, timeout=60)

    def test_candidates_are_newer_local_used_and_the_right_size(self):
        self.standard()
        r = self.run_script("--summary")
        self.assertEqual(r.returncode, 1, r.stderr)
        lines = {line.split("\t")[1].split(" ")[0]: line for line in r.stdout.splitlines()}
        self.assertIn("WARN", lines["reasoner"])
        self.assertIn("newer-big:32b (20 GB, 2026-11-02)", lines["reasoner"])   # largest plain tag that fits
        for bad in ("cloudy", "tiny", "huge", "niche", "older", "q2_K", "big:27b ("):
            self.assertNotIn(bad, lines["reasoner"])
        self.assertIn("vec-2:740m (1 GB, 2026-10-15)", lines["embed"])
        self.assertNotIn("chatty", lines["embed"])
        self.assertEqual(len(r.stdout.splitlines()), 2)      # one line per role, first listed only

    def test_nothing_newer_is_info_and_exit_0(self):
        self.standard()
        self.lineup.write_text("reasoner newer-big:32b 20\n")
        self.page(self.search(q="newer-big"), card("newer-big", "November 9, 2026", ["32b"], ["thinking"]))
        r = self.run_script("--summary")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(r.stdout.startswith("INFO\treasoner `newer-big:32b`: nothing newer fits 24 GB"))

    def test_budgets_are_configurable(self):
        self.standard()
        r = self.run_script("--summary", MODEL_MAX_GB="10", MODEL_MIN_RATIO="0")
        self.assertIn("newer-big:14b (9 GB", r.stdout)
        self.assertIn("tiny:4b", r.stdout)

    def test_report_and_out_file(self):
        self.standard()
        out = self.d / "reports"
        r = self.run_script("--out", str(out))
        self.assertIn("## reasoner — `big:27b` (updated 2026-10-01, budget 24 GB)", r.stdout)
        self.assertIn("| `newer-big:32b` | 20.0 GB | 2026-11-02 | 50,000 | thinking, tools |", r.stdout)
        f = out / "model-versions-2026-11-10.md"
        self.assertEqual(f.read_text().strip(), r.stdout.strip())
        self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600)

    def test_fetch_failure_is_exit_2_and_a_warn_line(self):
        r = self.run_script("--summary")                     # no fixture pages at all
        self.assertEqual(r.returncode, 2)
        self.assertTrue(r.stdout.startswith("WARN\tmodel check incomplete"))

    def test_missing_lineup_and_bad_usage(self):
        self.assertEqual(self.run_script(LLM_LINEUP=str(self.d / "nope")).returncode, 2)
        self.assertEqual(self.run_script("--bogus").returncode, 2)
        self.assertEqual(self.run_script("--help").returncode, 0)

    def test_check_only(self):
        src = SCRIPT.read_text()
        for forbidden in ("ollama pull", "subprocess", "/api/pull", "write_text(\"", "LINEUP.write"):
            self.assertNotIn(forbidden, src)


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv else 1
    sys.argv = [sys.argv[0]]
    sys.exit(0 if unittest.main(verbosity=verbosity, exit=False).result.wasSuccessful() else 1)
