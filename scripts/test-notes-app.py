#!/usr/bin/env python3
"""test-notes-app.py — tests for scripts/notes-app.py (D73).

Starts the real server on a free port (--port 0 --no-open) over a fixture notes folder in a temp
dir: awkward file names (colon, question mark, spaces, parentheses, non-ASCII), a nested folder,
a dot-file, a binary file, a symlink pointing outside, and a note holding a <script> tag. Checks
search (AND, phrase, title-first ranking, case), the note page, escaping, the guards (token,
cookie name, Host, ids, POST, CSP, loopback bind), the index refresh, and that nothing in the
folder changes. No network beyond loopback.

Usage:  scripts/test-notes-app.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import hashlib
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.parse import quote

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "notes-app.py"
EVIL = "<script>alert(1)</script>"

NOTES = {
    "dentist": "Dentist appointment Tuesday.\nAsk about the crown and the bill.\n",
    "side ideas": "Tax software for freelancers.\nA dentist booking tool?\n",
    "bob - travel agent": "Bob knows a travel consultant in Oslo.\n",
    "Pizza  recipes": "Dough. Sauce.\n",
    "projects:ideas i'm thinking about": "Something about the tax code.\n",
    "what is a good question?": "Time. Weather.\n",
    "(draft )checklist": "Keys, wallet, phone.\n",
    "café notes": "Ünïcödé text: crème brûlée.\n",
    "xss": f"Look at this {EVIL} thing\n",
    "sub/nested note": "Nested folder text about the dentist and taxes.\n",
}


def note_id(rel, src=0):
    return hashlib.sha1(f"{src}:{rel}".encode()).hexdigest()[:12]


class NotesAppTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        t = Path(cls.tmp.name)
        cls.notes = t / "notes"
        (cls.notes / "sub").mkdir(parents=True)
        base = time.time() - 10_000
        for i, (name, text) in enumerate(NOTES.items()):
            f = cls.notes / name
            f.write_text(text)
            os.utime(f, (base + i * 100, base + i * 100))  # later in NOTES = more recent
        (cls.notes / ".DS_Store").write_bytes(b"\0\0dentist")
        (cls.notes / "binary").write_bytes(b"dentist\0\x01\x02")
        (t / "outside.txt").write_text("OUTSIDE-SECRET dentist\n")
        (cls.notes / "link").symlink_to(t / "outside.txt")
        cls.before = cls.digest()
        env = dict(os.environ, HOME=str(t))
        cls.proc = subprocess.Popen([sys.executable, str(SCRIPT), "--port", "0", "--no-open",
                                     "--notes", str(cls.notes)], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = cls.proc.stdout.readline()
        m = re.search(r"http://127\.0\.0\.1:(\d+)/\?t=([A-Za-z0-9_\-]+)", line)
        if not m:
            cls.proc.kill()
            raise RuntimeError(f"no URL line: {line!r} {cls.proc.stderr.read()}")
        cls.port, cls.token = int(m.group(1)), m.group(2)
        cls.first_line = line

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
        for f in sorted(cls.notes.rglob("*")):
            h.update(str(f).encode())
            if f.is_file() and not f.is_symlink():
                h.update(f.read_bytes())
                h.update(str(f.stat().st_mtime_ns).encode())
        return h.hexdigest()

    def get(self, path, token=True, host=None, cookie=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        headers = {"Host": host or f"127.0.0.1:{self.port}"}
        if cookie:
            headers["Cookie"] = cookie
        elif token:
            headers["Cookie"] = f"na={self.token}"
        c.request("GET", path, headers=headers)
        r = c.getresponse()
        body = r.read().decode(errors="replace")
        c.close()
        return r, body

    def search(self, q):
        r, body = self.get(f"/api/search?q={quote(q)}")
        self.assertEqual(r.status, 200)
        return [x["title"] for x in json.loads(body)]

    # --- index ------------------------------------------------------------------------------

    def test_indexes_text_notes_only(self):
        self.assertIn(f"({len(NOTES)} notes:", self.first_line)
        _, body = self.get("/")
        self.assertIn(f"{len(NOTES)} notes in", body)
        self.assertIn("1 skipped", body)                         # binary (the symlink and dot-file are not counted)
        titles = re.findall(r'class="t" href="/n/[0-9a-f]{12}">([^<]*)<', body)
        self.assertEqual(len(titles), len(NOTES))
        for skipped in (".DS_Store", "binary", "link"):
            self.assertNotIn(skipped, titles)
        self.assertNotIn("OUTSIDE-SECRET", body)

    def test_recent_first_on_home(self):
        _, body = self.get("/")
        titles = re.findall(r'class="t" href="/n/[0-9a-f]{12}">([^<]*)<', body)
        self.assertEqual(titles[0], "sub/nested note")
        self.assertEqual(titles[-1], "dentist")

    # --- search -----------------------------------------------------------------------------

    def test_title_matches_rank_first_then_recency(self):
        self.assertEqual(self.search("dentist"), ["dentist", "sub/nested note", "side ideas"])

    def test_and_across_terms(self):
        self.assertEqual(self.search("dentist tax"), ["sub/nested note", "side ideas"])
        self.assertEqual(self.search("dentist oslo"), [])

    def test_phrase(self):
        self.assertEqual(self.search('"travel consultant"'), ["bob - travel agent"])
        self.assertEqual(self.search('"consultant travel"'), [])

    def test_case_and_unicode(self):
        self.assertEqual(self.search("DENTIST APPOINTMENT"), ["dentist"])
        self.assertEqual(self.search("brûlée"), ["café notes"])

    def test_symlink_target_never_searched(self):
        self.assertEqual(self.search("OUTSIDE-SECRET"), [])

    def test_results_page_highlights_and_links(self):
        r, body = self.get(f"/?q={quote('tax')}")
        self.assertEqual(r.status, 200)
        self.assertIn("<mark>Tax</mark>", body)
        self.assertIn(f'href="/n/{note_id("side ideas")}?q=tax"', body)
        self.assertIn('value="tax"', body)

    # --- note page --------------------------------------------------------------------------

    def test_awkward_names_open(self):
        for rel in ("projects:ideas i'm thinking about", "what is a good question?",
                    "(draft )checklist", "café notes", "sub/nested note", "Pizza  recipes"):
            r, body = self.get(f"/n/{note_id(rel)}")
            self.assertEqual(r.status, 200, rel)
            self.assertIn(NOTES[rel].split()[0].replace("'", "&#x27;"), body, rel)

    def test_note_page_highlights(self):
        _, body = self.get(f"/n/{note_id('dentist')}?q=crown")
        self.assertIn("<mark>crown</mark>", body)
        self.assertIn("← results", body)

    def test_untrusted_text_escaped(self):
        for path in (f"/n/{note_id('xss')}", "/?q=look", "/", f"/?q={quote(EVIL)}"):
            _, body = self.get(path)
            self.assertNotIn(EVIL, body, path)
        _, body = self.get("/?q=look")
        self.assertIn("&lt;script&gt;", body)

    def test_bad_ids_and_paths(self):
        for p in ("/n/../outside.txt", "/n/..%2Foutside.txt", "/n/dentist", "/n/" + "0" * 12,
                  "/n/" + note_id("dentist").upper(), "/notes/dentist", "/link", "/sub/nested%20note"):
            r, body = self.get(p)
            self.assertEqual(r.status, 404, p)
            self.assertNotIn("OUTSIDE-SECRET", body)

    # --- guards -----------------------------------------------------------------------------

    def test_token_required(self):
        self.assertEqual(self.get("/", token=False)[0].status, 403)
        self.assertEqual(self.get("/", cookie="na=wrong")[0].status, 403)
        self.assertEqual(self.get("/", cookie=f"ma={self.token}")[0].status, 403)  # maintenance-app's cookie name
        self.assertEqual(self.get("/api/search?q=dentist", token=False)[0].status, 403)

    def test_token_in_url_becomes_cookie(self):
        r, _ = self.get(f"/?t={self.token}", token=False)
        self.assertEqual(r.status, 303)
        self.assertEqual(r.getheader("Location"), "/")
        cookie = r.getheader("Set-Cookie")
        self.assertTrue(cookie.startswith(f"na={self.token};"), cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)

    def test_foreign_host_rejected(self):
        self.assertEqual(self.get("/", host="evil.test")[0].status, 403)
        self.assertEqual(self.get("/", host=f"localhost:{self.port}")[0].status, 200)

    def test_security_headers(self):
        r, _ = self.get("/")
        csp = r.getheader("Content-Security-Policy")
        self.assertIn("default-src 'none'", csp)
        self.assertIn("form-action 'self'", csp)
        self.assertNotIn("script-src", csp)  # the page has no script
        self.assertEqual(r.getheader("X-Content-Type-Options"), "nosniff")
        self.assertEqual(r.getheader("Cache-Control"), "no-store")

    def test_post_not_allowed(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request("POST", "/", body="x", headers={"Host": f"127.0.0.1:{self.port}", "Cookie": f"na={self.token}"})
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

    def test_missing_folder_exit_2(self):
        r = subprocess.run([sys.executable, str(SCRIPT), "--no-open", "--notes", str(self.notes / "nope")],
                           capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(r.returncode, 2)
        self.assertIn("is not a folder", r.stderr)

    # --- last: the index follows the folder, and the app wrote nothing ----------------------

    def test_zy_index_refreshes(self):
        """A note added while the app runs is found on the next request (the test adds it, not the app)."""
        f = self.notes / "added later"
        f.write_text("zeppelin\n")
        try:
            self.assertEqual(self.search("zeppelin"), ["added later"])
        finally:
            f.unlink()
        self.assertEqual(self.search("zeppelin"), [])

    def test_zz_nothing_written(self):
        self.get("/")
        self.get("/?q=dentist")
        self.get(f"/n/{note_id('dentist')}")
        self.assertEqual(self.digest(), self.before)


APPLE = [
    {"id": "x-coredata://A/ICNote/p1", "title": "Groceries", "folder": "Notes", "created": "2026-01-02T10:00:00.000Z",
     "modified": "2026-11-01T09:00:00.000Z", "text": "milk, eggs, dentist floss", "html": "<p>ignored html marker HTMLONLY</p>"},
    {"id": "x-coredata://A/ICNote/p2", "title": "dentist", "folder": "Health", "created": "2025-05-05T08:00:00.000Z",
     "modified": "2026-10-01T09:00:00.000Z", "text": "Apple copy of the dentist plan: travel consultant later"},
    {"id": "x-coredata://A/ICNote/p3", "title": f"Trip {EVIL}", "folder": f"Travel {EVIL}",
     "created": "2026-03-03T00:00:00.000Z", "modified": "not a date", "text": f"Body {EVIL} Lisbon"},
]


class TwoSources(unittest.TestCase):
    """A notes folder plus an Apple-Notes-like JSON Lines export, both given with --source."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        t = Path(cls.tmp.name)
        cls.folder, cls.export = t / "notes", t / "export" / "notes.jsonl"
        cls.folder.mkdir()
        cls.export.parent.mkdir()
        (cls.folder / "dentist").write_text("Folder copy: dentist appointment Tuesday.\n")
        (cls.folder / "lisbon trip").write_text("Pack for Lisbon.\n")
        lines = [json.dumps(d) for d in APPLE] + ["{not json", json.dumps({"title": 5, "text": "x"}), ""]
        cls.export.write_text("\n".join(lines) + "\n")
        cls.export.chmod(0o444)
        cls.before = (cls.export.stat().st_mode, hashlib.sha256(cls.export.read_bytes()).hexdigest())
        cls.proc = subprocess.Popen([sys.executable, str(SCRIPT), "--port", "0", "--no-open",
                                     "--source", str(cls.folder), "--source", str(cls.export),
                                     "--source", str(t / "missing.jsonl")],
                                    env=dict(os.environ, HOME=str(t)),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = cls.proc.stdout.readline()
        m = re.search(r"http://127\.0\.0\.1:(\d+)/\?t=([A-Za-z0-9_\-]+)", line)
        if not m:
            cls.proc.kill()
            raise RuntimeError(f"no URL line: {line!r} {cls.proc.stderr.read()}")
        cls.port, cls.token, cls.first_line = int(m.group(1)), m.group(2), line

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=10)
        cls.proc.stdout.close()
        cls.proc.stderr.close()
        cls.export.chmod(0o644)
        cls.tmp.cleanup()

    get = NotesAppTest.get

    def api(self, q, src=None):
        r, body = self.get(f"/api/search?q={quote(q)}" + (f"&src={src}" if src is not None else ""))
        self.assertEqual(r.status, 200)
        return [(x["title"], x["source"]) for x in json.loads(body)]

    def test_counts_and_missing_source(self):
        self.assertIn("(5 notes:", self.first_line)
        self.assertIn("Apple Notes 3", self.first_line)
        _, body = self.get("/")
        self.assertIn("Apple Notes: 3 notes in", body)
        self.assertIn("2 skipped (unreadable lines)", body)        # the bad JSON and the non-string title
        self.assertIn("not found", body)                            # missing.jsonl, the rest still serve
        self.assertIn("export from", body)

    def test_both_sources_labelled_title_first(self):
        hits = self.api("dentist")
        self.assertEqual(hits[:2], [("dentist", "~/notes"), ("dentist", "Apple Notes · Health")]
                         if hits[0][1] == "~/notes" else [("dentist", "Apple Notes · Health"), ("dentist", "~/notes")])
        self.assertIn(("Groceries", "Apple Notes · Notes"), hits[2:])  # body match ranks after titles

    def test_src_filter(self):
        self.assertEqual(self.api("dentist", src=1), [("dentist", "Apple Notes · Health"), ("Groceries", "Apple Notes · Notes")])
        self.assertEqual(self.api("dentist", src=0), [("dentist", "~/notes")])
        self.assertEqual(len(self.api("dentist", src=9)), 3)          # unknown src: all

    def test_and_phrase_across_sources(self):
        self.assertEqual(self.api('"travel consultant" dentist'), [("dentist", "Apple Notes · Health")])
        self.assertEqual(sorted(t for t, _ in self.api("lisbon")), ["Trip <script>alert(1)</script>", "lisbon trip"])

    def test_html_field_never_indexed(self):
        self.assertEqual(self.api("HTMLONLY"), [])

    def test_escaping_title_folder_text(self):
        hit = next(x for x in json.loads(self.get("/api/search?q=lisbon")[1]) if x["title"].startswith("Trip"))
        r, body = self.get(f"/n/{hit['id']}")
        self.assertEqual(r.status, 200)
        self.assertNotIn(EVIL, body)
        self.assertEqual(body.count("&lt;script&gt;"), 4)          # <title>, heading, folder label, text
        for path in ("/?q=lisbon", "/"):
            self.assertNotIn(EVIL, self.get(path)[1], path)

    def test_note_page_dates(self):
        hit = next(x for x in json.loads(self.get("/api/search?q=groceries")[1]))
        _, body = self.get(f"/n/{hit['id']}?q=floss&src=1")
        self.assertIn("created 2026-01-02 10:00", body)
        self.assertIn("<mark>floss</mark>", body)
        self.assertIn("src=1", body)                                 # back link keeps the filter

    def test_filter_links(self):
        _, body = self.get("/?q=dentist")
        self.assertIn('href="/?q=dentist&amp;src=1"', body)
        self.assertIn("<strong>All</strong>", body)

    def test_zy_rewritten_export_reread(self):
        """The export is rebuilt by replacing the file (new inode); the next request sees it."""
        new = self.export.with_name("next.jsonl")
        new.write_text(json.dumps({"id": "n1", "title": "Zeppelin", "text": "new export", "folder": "Notes"}) + "\n")
        old = self.export.with_name("old.jsonl")
        os.link(self.export, old)
        os.replace(new, self.export)
        try:
            self.assertEqual(self.api("zeppelin"), [("Zeppelin", "Apple Notes · Notes")])
            self.assertEqual(self.api("groceries"), [])
        finally:
            os.replace(old, self.export)
        self.assertEqual(self.api("groceries"), [("Groceries", "Apple Notes · Notes")])

    def test_zz_export_unchanged(self):
        self.get("/?q=dentist")
        self.assertEqual((self.export.stat().st_mode, hashlib.sha256(self.export.read_bytes()).hexdigest()), self.before)


class SourcesFile(unittest.TestCase):
    def test_parsing(self):
        spec = __import__("importlib.util").util.spec_from_file_location("na", SCRIPT)
        mod = __import__("importlib.util").util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "sources"
            f.write_text("# my sources\n\n~/notes\n  /tmp/a#b/x.jsonl  \n#~/ignored\n")
            self.assertEqual(mod.read_sources_file(f), [Path.home() / "notes", Path("/tmp/a#b/x.jsonl")])

    def test_sources_file_used_when_no_flags(self):
        with tempfile.TemporaryDirectory() as d:
            t = Path(d)
            (t / "n").mkdir()
            (t / "n" / "one").write_text("hello\n")
            (t / "sources").write_text(f"{t / 'n'}\n")
            env = {k: v for k, v in os.environ.items() if k != "NOTES_DIR"}
            env.update(HOME=str(t), NOTES_APP_SOURCES=str(t / "sources"))
            p = subprocess.Popen([sys.executable, str(SCRIPT), "--port", "0", "--no-open"], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertIn("(1 notes:", p.stdout.readline())
            finally:
                p.terminate()
                p.wait(timeout=10)
                p.stdout.close()
                p.stderr.close()

    def test_no_source_found_exit_2(self):
        with tempfile.TemporaryDirectory() as d:
            r = subprocess.run([sys.executable, str(SCRIPT), "--no-open", "--source", f"{d}/a.jsonl",
                                "--source", f"{d}/nope"], capture_output=True, text=True, timeout=30, check=False)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(r.stderr.count("is not a folder or a .jsonl file"), 2)


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv else 1
    sys.argv = [a for a in sys.argv if a != "--verbose"]
    sys.exit(0 if unittest.main(verbosity=verbosity, exit=False).result.wasSuccessful() else 1)
