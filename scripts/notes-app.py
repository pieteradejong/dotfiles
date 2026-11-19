#!/usr/bin/env python3
"""notes-app.py — local, read-only full-text search over plain-text notes and note exports (D73).
Started by bin/notes-app.

Sources (each only ever read):
  - a folder of plain-text files (flat or nested; the file name is the title), and/or
  - a JSON Lines export, one object per note with `title` and `text` and optionally `folder`,
    `created`, `modified` and `id`: an Apple Notes export, for example. Read with open(), never
    through sqlite, so it can't touch the export's store.
Which sources: every --source PATH (a folder or a .jsonl file; repeatable); else --notes DIR or
$NOTES_DIR; else the file ~/.config/notes-app/sources ($NOTES_APP_SOURCES), one path per line,
`#` lines ignored; else ~/notes. The sources file lives on this Mac only, so this public script
names no private path. A missing source is shown as "not found" and the rest still serve.

Serves:
  /                 the sources with their counts and export age, recent notes, or with ?q= the
                    results with highlighted snippets; ?src=N keeps one source
  /n/<id>           one note, escaped, matches highlighted, with its source, folder and dates
  /api/search?q=    the results as JSON (id, title, source, modified, snippet)

Search: case-insensitive; every term must match (AND); "quoted words" match as a phrase. A note
whose title holds more of the terms ranks first, then the more recently modified. A source is
re-read when it changes: a folder's listing, or a JSONL file's inode, mtime or size (checked on
each request).

Local and read-only by construction (docs/policy/secure-development.md), reusing maintenance-app's
handler (D71): 127.0.0.1 only, a per-run token (URL once, then an HttpOnly SameSite=Strict cookie
named `na`), a Host-header allowlist, CSP default-src 'none' (form-action 'self' for the search
box), GET/HEAD only, and nothing is written. A note is addressed by a 12-hex id (sha1 of its source
and its path or export id) looked up in the in-memory index, so a request path never becomes a
file path. In folders, symlinks, dot-files, binary files and files over 2 MB are skipped; in an
export, lines without a string title and text are skipped and counted.

Always on (D81): launchd com.pieterdejong.notesapp runs `--port 8749 --no-open --token-file
~/.config/notes-app/token`. The token is then kept in that file (mode 600, made on first start,
refused if others can read it) and never printed; `notes-app --port 8749 --token-file ... --print-url`
gives the bookmark URL.

Usage:  notes-app [--port N] [--no-open] [--source PATH ...] [--notes DIR] [--token-file F [--print-url]]
Exit:   0 on Ctrl-C · 2 usage error, port taken, or no source found
"""

import argparse
import hashlib
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys
import threading
from datetime import datetime
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

REPO = Path(__file__).resolve().parent.parent
MAX_BYTES = 2 * 1024 * 1024
MAX_JSONL = 64 * 1024 * 1024
RECENT = 50
RESULTS = 200
SNIP = 90
ID_RE = re.compile(r"^[0-9a-f]{12}$")
CSP = ("default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'self'; "
       "frame-ancestors 'none'; base-uri 'none'")


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, REPO / "scripts" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MA = _load("maintenance_app", "maintenance-app.py")
esc = MA.esc

CSS = MA.CSS + """
form.q{display:flex;gap:8px;margin:0 0 14px}form.q input[type=search]{flex:1;font-size:16px;padding:6px 10px;
border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg)}
form.q button{padding:6px 14px;border-radius:6px;border:1px solid var(--line);background:var(--card);color:var(--fg)}
ol.res{padding-left:0}ol.res li{list-style:none;padding:8px 0;border-bottom:1px solid var(--line)}
ol.res .t{font-weight:600}ol.res .m{color:var(--mut);font-size:12px;margin-left:8px}
ol.res .s{color:var(--mut);font-size:13px;margin-top:2px;white-space:pre-wrap;overflow-wrap:anywhere}
.filt{margin:0 0 10px}.filt a,.filt strong{margin-right:2px}.srcs{padding-left:18px;margin:0 0 10px}
mark{background:var(--warnbg);color:inherit;border-radius:2px}
pre.note{white-space:pre-wrap;overflow-wrap:anywhere;font-size:14px;line-height:1.5}
"""


# --- index ------------------------------------------------------------------------------------

def home_rel(path):
    p, h = str(path), str(Path.home())
    return "~" + p[len(h):] if p == h or p.startswith(h + "/") else p


def parse_time(v, fallback):
    """An ISO timestamp from an export ('2026-10-24T12:34:56.000Z') as epoch seconds."""
    try:
        return datetime.fromisoformat(str(v)).timestamp()  # 3.11+ reads a trailing Z
    except (TypeError, ValueError):
        return fallback


class Source:
    """One place notes come from: a folder of plain-text files, or a JSON Lines export
    (one object per note with title, text and optionally folder, created, modified, id), such
    as an Apple Notes export. Both are only ever read."""

    def __init__(self, index, path):
        self.index, self.path = index, Path(path).expanduser()
        self.kind = "jsonl" if self.path.suffix == ".jsonl" else "folder"
        self.name = "Apple Notes" if self.kind == "jsonl" else home_rel(self.path)
        self.sig, self.notes, self.skipped, self.error, self.exported = None, {}, 0, "", None

    def _signature(self):
        if self.kind == "jsonl":
            st = self.path.stat()  # follows the hard link / symlink the export publishes
            return (st.st_ino, st.st_mtime_ns, st.st_size)
        out, stack = [], [self.path]
        while stack:
            d = stack.pop()
            try:
                entries = list(os.scandir(d))
            except OSError:
                continue
            for e in entries:
                if e.name.startswith(".") or e.is_symlink():
                    continue
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                elif e.is_file(follow_symlinks=False):
                    st = e.stat(follow_symlinks=False)
                    out.append((os.path.relpath(e.path, self.path), st.st_mtime_ns, st.st_size))
        return sorted(out)

    def _id(self, key):
        return hashlib.sha1(f"{self.index}:{key}".encode()).hexdigest()[:12]

    def _note(self, key, title, text, mtime, folder="", created=""):
        return {"id": self._id(key), "src": self.index, "source": self.name, "title": title,
                "folder": folder, "created": created, "mtime": mtime, "text": text,
                "lower": text.lower(), "tlower": title.lower(),
                "label": f"{self.name} · {folder}" if folder else self.name}

    def refresh(self):
        """Re-read only when the listing (folder) or the file's inode/mtime/size (jsonl) changed."""
        ok = self.path.is_file() if self.kind == "jsonl" else self.path.is_dir()
        if not ok:
            self.sig, self.notes, self.skipped, self.error = None, {}, 0, "not found"
            return
        sig = self._signature()
        if sig == self.sig:
            return
        notes, skipped = {}, 0
        if self.kind == "folder":
            for rel, mtime_ns, size in sig:
                if size > MAX_BYTES:
                    skipped += 1
                    continue
                try:
                    raw = (self.path / rel).read_bytes()
                except OSError:
                    skipped += 1
                    continue
                if b"\0" in raw[:8192]:
                    skipped += 1
                    continue
                x = self._note(rel, rel, raw.decode("utf-8", errors="replace"), mtime_ns / 1e9)
                notes[x["id"]] = x
            self.exported = None
        else:
            if sig[2] > MAX_JSONL:
                self.sig, self.notes, self.skipped, self.error = sig, {}, 0, "export over 64 MB"
                return
            with self.path.open(encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh):
                    if not line.strip():
                        continue
                    try:
                        d = json.loads(line)
                        title, text = d.get("title"), d.get("text")
                        if not isinstance(title, str) or not isinstance(text, str):
                            raise TypeError("title/text")
                    except (ValueError, TypeError, AttributeError):
                        skipped += 1
                        continue
                    folder = d.get("folder") if isinstance(d.get("folder"), str) else ""
                    created = d.get("created") if isinstance(d.get("created"), str) else ""
                    x = self._note(str(d.get("id") or n), title or "(untitled)", text,
                                   parse_time(d.get("modified"), sig[1] / 1e9), folder, created)
                    notes[x["id"]] = x
            self.exported = sig[1] / 1e9
        self.sig, self.notes, self.skipped, self.error = sig, notes, skipped, ""


class Index:
    """Every note of every source, in memory; each source is re-read when it changes."""

    def __init__(self, paths):
        self.sources = [Source(i, p) for i, p in enumerate(paths)]
        self.lock = threading.Lock()
        self.notes = {}

    def refresh(self):
        with self.lock:
            for s in self.sources:
                s.refresh()
            merged = {}
            for s in self.sources:
                merged.update(s.notes)
            self.notes = merged

    def pool(self, src=None):
        return [x for x in self.notes.values() if src is None or x["src"] == src]

    def recent(self, n=RECENT, src=None):
        return sorted(self.pool(src), key=lambda x: -x["mtime"])[:n]

    def search(self, terms, n=RESULTS, src=None):
        if not terms:
            return []
        hits = []
        for x in self.pool(src):
            if all(t in x["tlower"] or t in x["lower"] for t in terms):
                hits.append((sum(t in x["tlower"] for t in terms), x["mtime"], x))
        hits.sort(key=lambda h: (-h[0], -h[1]))
        return [h[2] for h in hits[:n]]


def read_sources_file(path):
    """One path per line; blank lines and lines starting with # ignored; ~ expanded. No inline
    comments: a path may contain #."""
    out = []
    for line in Path(path).read_text(errors="replace").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(Path(line).expanduser())
    return out


def parse_query(q):
    """'tax "dentist bill" 2025' -> ['tax', 'dentist bill', '2025'] (lowercased, deduplicated)."""
    terms = []
    for phrase, word in re.findall(r'"([^"]+)"|(\S+)', q or ""):
        t = " ".join((phrase or word).lower().split())
        if t and t not in terms:
            terms.append(t)
    return terms[:12]


def highlight(text, terms):
    """Escape, then wrap each match in <mark>. Never inserts unescaped text."""
    if not terms:
        return esc(text)
    pat = re.compile("|".join(re.escape(t) for t in sorted(terms, key=len, reverse=True)), re.IGNORECASE)
    out, last = [], 0
    for m in pat.finditer(text):
        out.append(esc(text[last:m.start()]))
        out.append(f"<mark>{esc(m.group(0))}</mark>")
        last = m.end()
    out.append(esc(text[last:]))
    return "".join(out)


def snippet(x, terms):
    """A window of the body around the first match (or its start), whitespace collapsed."""
    text = x["text"]
    pos = min((p for p in (x["lower"].find(t) for t in terms) if p >= 0), default=-1)
    if pos < 0:
        start = 0
    else:
        start = max(0, pos - SNIP // 2)
    piece = " ".join(text[start:start + SNIP * 2].split())
    return ("…" if start else "") + piece + ("…" if start + SNIP * 2 < len(text) else "")


def when(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


# --- pages ------------------------------------------------------------------------------------

def page(title, body, q=""):
    form = ('<form class="q" method="get" action="/" role="search">'
            f'<input type="search" name="q" value="{esc(q)}" placeholder="Search notes — words, &quot;a phrase&quot;" '
            'autofocus aria-label="Search notes"><button type="submit">Search</button></form>')
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            f"<title>{esc(title)}</title><style>{CSS}</style></head><body>"
            f'<header><h1><a href="/" style="color:inherit;text-decoration:none">Notes</a></h1></header>'
            f"<main>{form}{body}</main></body></html>\n")


def src_param(src):
    return f"&src={src}" if src is not None else ""


def result_list(items, terms, q="", src=None):
    qs = f"?q={quote(q)}{src_param(src)}" if terms else ""
    return '<ol class="res">' + "".join(
        f'<li><a class="t" href="/n/{x["id"]}{esc(qs)}">{highlight(x["title"], terms)}</a>'
        f'<span class="m">{esc(x["label"])} · {esc(when(x["mtime"]))}</span>'
        f'<div class="s">{highlight(snippet(x, terms), terms)}</div></li>' for x in items) + "</ol>"


def filters(idx, q, src):
    if len(idx.sources) < 2:
        return ""
    base = f"/?q={quote(q)}" if q else "/?"
    links = [("All", None)] + [(s.name, s.index) for s in idx.sources]
    return '<p class="filt">' + " · ".join(
        f"<strong>{esc(name)}</strong>" if i == src else
        f'<a href="{esc(base + (src_param(i) if i is not None else ""))}">{esc(name)}</a>'
        for name, i in links) + "</p>"


def source_lines(idx):
    out = []
    for s in idx.sources:
        if s.error:
            out.append(f"<li>{esc(s.name)}: <strong>{esc(s.error)}</strong> ({esc(home_rel(s.path))})</li>")
            continue
        line = f"{esc(s.name)}: {len(s.notes)} notes in {esc(home_rel(s.path))}"
        if s.skipped:
            line += (f", {s.skipped} skipped (binary or over 2 MB)" if s.kind == "folder"
                     else f", {s.skipped} skipped (unreadable lines)")
        if s.exported:
            days = int((datetime.now().timestamp() - s.exported) // 86400)
            line += f"; export from {esc(when(s.exported))} ({days} day{'' if days == 1 else 's'} old)"
        out.append(f"<li>{line}</li>")
    return '<ul class="mut srcs">' + "".join(out) + "</ul>"


def home(idx, q, src=None):
    terms = parse_query(q)
    if not terms:
        body = (source_lines(idx) + filters(idx, "", src)
                + f'<p class="mut">Most recently modified first.</p>{result_list(idx.recent(src=src), [])}')
        return page("Notes", body)
    hits = idx.search(terms, src=src)
    head = f'<p class="mut">{len(hits)} note{"s" if len(hits) != 1 else ""} match{"" if len(hits) != 1 else "es"} all of: ' \
           + ", ".join(f"<mark>{esc(t)}</mark>" for t in terms) + "</p>"
    body = filters(idx, q, src) + head + (result_list(hits, terms, q, src) if hits else "")
    return page(f"{q} — Notes", body, q)


def note_page(x, q, src=None):
    terms = parse_query(q)
    back = (f'<p><a href="/?q={esc(quote(q))}{esc(src_param(src))}">← results</a></p>' if terms
            else '<p><a href="/">← all notes</a></p>')
    meta = [esc(x["label"]), f"Modified {esc(when(x['mtime']))}"]
    if x["created"]:
        meta.append(f"created {esc(x['created'][:16].replace('T', ' '))}")
    meta.append(f"{len(x['text']):,} characters")
    body = (f'{back}<h2>{highlight(x["title"], terms)}</h2><p class="mut">{" · ".join(meta)}</p>'
            f'<section><pre class="note">{highlight(x["text"], terms)}</pre></section>')
    return page(f'{x["title"]} — Notes', body, q)


# --- server -----------------------------------------------------------------------------------

class NotesApp(MA.App):
    """maintenance-app's handler (send, authorised, HEAD, quiet logging) with notes routes."""

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if not self.authorised(query):
            return self.send(403, "forbidden\n", "text/plain; charset=utf-8")
        cfg, path = self.server.cfg, url.path
        if "t" in query:
            cookie = f"{cfg['cookie']}={cfg['token']}; HttpOnly; SameSite=Strict; Path=/"
            return self.send(303, "", extra=(("Location", path or "/"), ("Set-Cookie", cookie)))
        idx, q = cfg["index"], (query.get("q") or [""])[0][:300]
        sv = (query.get("src") or [""])[0]
        src = int(sv) if sv.isdigit() and int(sv) < len(idx.sources) else None
        try:
            idx.refresh()
            if path == "/":
                return self.send(200, home(idx, q, src))
            if path == "/api/search":
                terms = parse_query(q)
                body = [{"id": x["id"], "title": x["title"], "source": x["label"], "modified": when(x["mtime"]),
                         "snippet": snippet(x, terms)} for x in idx.search(terms, src=src)]
                return self.send(200, json.dumps(body), "application/json")
            m = re.fullmatch(r"/n/([^/]+)", path)
            if m and ID_RE.match(m.group(1)) and m.group(1) in idx.notes:
                return self.send(200, note_page(idx.notes[m.group(1)], q, src))
        except (OSError, ValueError, KeyError) as e:
            return self.send(500, f"error: {esc(type(e).__name__)}\n", "text/plain; charset=utf-8")
        return self.send(404, "not found\n", "text/plain; charset=utf-8")


TOKEN_MIN = 32  # secrets.token_urlsafe(24) is 32 characters


def load_token(path):
    """The always-on token (D81): read from `path`, or created there once at mode 600 (folder 700).
    Refused if group- or world-accessible or too short; the error says why. Returns (token, error)."""
    path = path.expanduser()
    if not path.exists():
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        token = secrets.token_urlsafe(24)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:  # another start won the race; read theirs
            return load_token(path)
        with os.fdopen(fd, "w") as f:
            f.write(token + "\n")
        return token, None
    if path.is_symlink() or not path.is_file():
        return None, f"{path} is not a regular file"
    if path.stat().st_mode & 0o077:
        return None, f"{path} is readable by others (mode {path.stat().st_mode & 0o777:o}); chmod 600 it"
    token = path.read_text(encoding="utf-8").strip()
    if len(token) < TOKEN_MIN or not re.fullmatch(r"[A-Za-z0-9_-]+", token):
        return None, f"{path} does not hold a token; delete it and a new one is made"
    return token, None


def main(argv):
    p = argparse.ArgumentParser(description="Local read-only search over plain-text notes and JSON Lines exports.")
    p.add_argument("--port", type=int, default=0, help="0 (default): any free port")
    p.add_argument("--no-open", action="store_true")
    p.add_argument("--token-file", type=Path,
                   help="keep the token in this file (mode 600, created if missing) instead of a new one "
                        "per run, so a bookmark keeps working; the token is then never printed")
    p.add_argument("--print-url", action="store_true",
                   help="with --token-file and --port: print the bookmark URL (token included) and exit")
    p.add_argument("--source", type=Path, action="append", default=[],
                   help="a notes folder or a .jsonl export; repeat for more")
    p.add_argument("--notes", type=Path, help="one notes folder (same as NOTES_DIR)")
    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    token = None
    if args.token_file:
        token, err = load_token(args.token_file)
        if err:
            print(f"notes-app: {err}", file=sys.stderr)
            return 2
    if args.print_url:
        if not (token and args.port):
            print("notes-app: --print-url needs --token-file and --port", file=sys.stderr)
            return 2
        print(f"http://127.0.0.1:{args.port}/?t={token}")
        return 0
    sources_file = Path(os.environ.get("NOTES_APP_SOURCES") or Path.home() / ".config" / "notes-app" / "sources")
    if args.source:
        paths = args.source
    elif args.notes or os.environ.get("NOTES_DIR"):
        paths = [args.notes or Path(os.environ["NOTES_DIR"])]
    elif sources_file.is_file():
        paths = read_sources_file(sources_file)
    else:
        paths = [Path.home() / "notes"]
    idx = Index([pth.expanduser() for pth in paths])
    idx.refresh()
    for src in idx.sources:
        if src.error:
            print(f"notes-app: {src.path} is not a folder or a .jsonl file ({src.error})", file=sys.stderr)
    if all(src.error for src in idx.sources):
        return 2
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", args.port), NotesApp)
    except OSError as e:
        print(f"notes-app: cannot listen on 127.0.0.1:{args.port} ({e.strerror}); leave out --port", file=sys.stderr)
        return 2
    port = srv.server_address[1]
    stable = token is not None
    token = token or secrets.token_urlsafe(24)
    srv.cfg = {"token": token, "cookie": "na", "csp": CSP, "index": idx,
               "hosts": {f"127.0.0.1:{port}", f"localhost:{port}"}}
    url = f"http://127.0.0.1:{port}/?t={token}"
    counts = ", ".join(f"{src.name} {len(src.notes)}" for src in idx.sources)
    # A stable token would sit in a launchd log for good, so it is never printed; --print-url gives it.
    shown = f"http://127.0.0.1:{port}/ (token in {args.token_file})" if stable else url
    print(f"notes-app: {shown}  ({len(idx.notes)} notes: {counts}; Ctrl-C stops it)", flush=True)
    if not args.no_open:
        subprocess.run(["open", url], check=False)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
