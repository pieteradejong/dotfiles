#!/usr/bin/env python3
"""model-versions.py — newer local models that could replace one in the llm lineup.

Reads config/llm/lineup. For each role it reads the ollama.com library: the 20 most recently
updated models in the role's category (embed → embedding, reasoner → thinking, coder / fast /
general → tools), and the lineup model's own "Updated" date. A model is a candidate when it is
  - updated after the lineup model (and is not the same family),
  - runnable locally: it lists a parameter size (a cloud-only model lists none, only `cloud`),
  - used: at least MODEL_MIN_DOWNLOADS downloads,
  - the right size: a plain size tag (`family:27b`, not a quant variant) whose download fits the
    role's budget — MODEL_MAX_GB for chat roles (the largest that leaves room in 32 GB), and
    EMBED_MAX_GB for embed — and is at least MODEL_MIN_RATIO (0.5) of the lineup model's listed
    size, so a 9B is not offered as a replacement for a 27B.
"Updated" is ollama.com's last change to the family (a new tag counts), so it is a hint, not
a release date.
Check only: it never pulls, never edits the lineup. Swapping a model is a decision with its own
measurements (speed, memory, answer quality); this only says where to look.

Only ollama.com is contacted, and only to read public library pages: no model, prompt or local
data is sent anywhere.

Usage:  scripts/model-versions.py                 markdown report on stdout
        scripts/model-versions.py --summary       one LEVEL<TAB>text line per role (security-audit.sh)
        scripts/model-versions.py --out DIR       also write model-versions-YYYY-MM-DD.md (mode 600)
        scripts/model-versions.py -h | --help
Exit:   0 nothing newer fits · 1 at least one candidate · 2 bad usage, no lineup, or a fetch failed
Env:    LLM_LINEUP (default: config/llm/lineup beside this repo's scripts/)
        OLLAMA_WEB (https://ollama.com) — a file:// base reads fixtures instead: the page for
        <path>?<query> is <base>/<urllib.parse.quote(path?query, safe="")>.html
        MODEL_MAX_GB (24) · EMBED_MAX_GB (2) · MODEL_MIN_DOWNLOADS (10000) · MODEL_MIN_RATIO (0.5)
        TODAY YYYY-MM-DD
"""

import argparse
import html
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import date, datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LINEUP = Path(os.environ.get("LLM_LINEUP", REPO / "config" / "llm" / "lineup"))
WEB = os.environ.get("OLLAMA_WEB", "https://ollama.com").rstrip("/")
CHAT_MAX_GB = float(os.environ.get("MODEL_MAX_GB", "24"))
EMBED_MAX_GB = float(os.environ.get("EMBED_MAX_GB", "2"))
MIN_DOWNLOADS = int(os.environ.get("MODEL_MIN_DOWNLOADS", "10000"))
MIN_RATIO = float(os.environ.get("MODEL_MIN_RATIO", "0.5"))
TODAY = os.environ.get("TODAY") or date.today().isoformat()
CATEGORY = {"embed": "embedding", "reasoner": "thinking", "coder": "tools", "fast": "tools", "general": "tools"}
SIZE_RE = re.compile(r"^(?:e)?\d+(?:\.\d+)?[mb](?:-a\d+(?:\.\d+)?b)?$", re.IGNORECASE)
CAPS = {"vision", "tools", "thinking", "embedding", "audio", "cloud"}


class FetchError(RuntimeError):
    pass


_cache: dict[str, str] = {}


def fetch(path_qs: str) -> str:
    if path_qs in _cache:
        return _cache[path_qs]
    if WEB.startswith("file://"):
        p = Path(WEB[len("file://"):]) / (urllib.parse.quote(path_qs, safe="") + ".html")
        try:
            text = p.read_text(encoding="utf-8")
        except OSError as e:
            raise FetchError(f"{path_qs}: no fixture {p.name}") from e
    else:
        req = urllib.request.Request(WEB + path_qs, headers={"User-Agent": "model-versions (dotfiles)"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                text = r.read().decode("utf-8", "replace")
        except OSError as e:
            raise FetchError(f"{WEB}{path_qs}: {e}") from e
    _cache[path_qs] = text
    return text


def read_lineup(path: Path) -> list[tuple[str, str, float]]:
    """(role, tag, download GB) per line, first listed per role only (that one holds the role)."""
    seen, out = set(), []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split("#", 1)[0].split()
        if len(parts) >= 2 and parts[0] not in seen:
            seen.add(parts[0])
            try:
                gb = float(parts[2]) if len(parts) > 2 else 0.0
            except ValueError:
                gb = 0.0
            out.append((parts[0], parts[1], gb))
    return out


def cards(page: str) -> list[dict]:
    """Model cards on a search page: name, updated (date), sizes, caps, downloads."""
    out = []
    for m in re.finditer(r'<a href="/library/([^"/:?]+)"(.*?)</li>', page, re.DOTALL):
        name, body = m.group(1), m.group(2)
        upd = re.search(r'title="Updated ([A-Z][a-z]+ \d{1,2}, \d{4})"', body)
        dl = re.search(r'title="([\d,]+) downloads"', body)
        badges = [html.unescape(b).strip().lower() for b in re.findall(r"<span[^>]*>([^<]{1,20})</span>", body)]
        out.append({
            "name": name,
            "updated": datetime.strptime(upd.group(1), "%B %d, %Y").date() if upd else None,
            "downloads": int(dl.group(1).replace(",", "")) if dl else 0,
            "caps": sorted(CAPS & set(badges)),
            "sizes": [b for b in badges if SIZE_RE.match(b)],
        })
    return out


def tag_sizes(family: str) -> dict[str, float]:
    """tag → download GB from the family's tags page."""
    page = fetch(f"/library/{family}/tags")
    out = {}
    for m in re.finditer(r'href="/library/' + re.escape(family) + r':([^"]+)"[^>]*class="md:hidden.*?•\s*([\d.]+)\s*(GB|MB|TB)',
                         page, re.DOTALL):
        gb = float(m.group(2)) * {"MB": 1 / 1024, "GB": 1, "TB": 1024}[m.group(3)]
        out.setdefault(m.group(1), gb)
    return out


def updated_of(family: str) -> date | None:
    for c in cards(fetch("/search?" + urllib.parse.urlencode({"q": family}))):
        if c["name"] == family:
            return c["updated"]
    return None


def check_role(role: str, tag: str, our_gb: float = 0.0) -> dict:
    family = tag.split(":", 1)[0]
    budget = EMBED_MAX_GB if role == "embed" else CHAT_MAX_GB
    floor = our_gb * MIN_RATIO
    ours = updated_of(family)
    newest = cards(fetch("/search?" + urllib.parse.urlencode({"c": CATEGORY.get(role, "tools"), "o": "newest"})))
    found = []
    for c in newest:
        if c["name"] == family or not c["sizes"] or c["downloads"] < MIN_DOWNLOADS:
            continue
        if role == "embed" and "embedding" not in c["caps"]:
            continue
        if role != "embed" and "embedding" in c["caps"]:
            continue
        if ours and c["updated"] and c["updated"] <= ours:
            continue
        sizes = tag_sizes(c["name"])
        fits = [(sizes[s], s) for s in c["sizes"] if s in sizes and floor <= sizes[s] <= budget]
        if not fits:
            continue
        gb, size = max(fits)  # the largest plain size tag that fits
        found.append({**c, "tag": f"{c['name']}:{size}", "gb": gb})
    return {"role": role, "tag": tag, "updated": ours, "budget": budget, "candidates": found}


def report(results: list[dict]) -> str:
    lines = [f"# Local model lineup vs ollama.com — {TODAY}", "",
             (f"Lineup: `{LINEUP}`. Candidates: updated after the lineup model, a local size tag within "
             f"budget and at least {MIN_RATIO:g}× the lineup model's size, at least {MIN_DOWNLOADS:,} "
             "downloads. Check only; nothing was pulled."), ""]
    for r in results:
        when = r["updated"].isoformat() if r["updated"] else "unknown"
        lines += [f"## {r['role']} — `{r['tag']}` (updated {when}, budget {r['budget']:g} GB)", ""]
        if not r["candidates"]:
            lines += ["Nothing newer fits.", ""]
            continue
        lines += ["| Candidate | Download | Updated | Downloads | Capabilities |", "|---|---|---|---|---|"]
        for c in r["candidates"]:
            lines.append(f"| `{c['tag']}` | {c['gb']:.1f} GB | {c['updated'] or '?'} | {c['downloads']:,} | "
                         f"{', '.join(c['caps']) or '—'} |")
        lines.append("")
    lines += [("To act on a candidate: read its model card, measure speed and memory here, then change "
              "the lineup and run `llm update`."), ""]
    return "\n".join(lines)


def summary(results: list[dict]) -> list[str]:
    out = []
    for r in results:
        if r["candidates"]:
            names = ", ".join(f"{c['tag']} ({c['gb']:.0f} GB, {c['updated']})" for c in r["candidates"][:4])
            more = f" +{len(r['candidates']) - 4} more" if len(r["candidates"]) > 4 else ""
            out.append(f"WARN\t{r['role']} `{r['tag']}`: newer local candidate(s): {names}{more}")
        else:
            out.append(f"INFO\t{r['role']} `{r['tag']}`: nothing newer fits {r['budget']:g} GB")
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="model-versions.py", add_help=False)
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("-h", "--help", action="store_true")
    try:
        a = ap.parse_args(argv)
    except SystemExit:
        return 2
    if a.help:
        print(__doc__.strip())
        return 0
    if not LINEUP.is_file():
        print(f"model-versions.py: no lineup at {LINEUP}", file=sys.stderr)
        return 2
    try:
        results = [check_role(role, tag, gb) for role, tag, gb in read_lineup(LINEUP)]
    except FetchError as e:
        print(f"model-versions.py: fetch failed — {e}", file=sys.stderr)
        if a.summary:
            print(f"WARN\tmodel check incomplete: {e}")
        return 2
    text = report(results)
    if a.out:
        old = os.umask(0o077)
        try:
            Path(a.out).mkdir(parents=True, exist_ok=True)
            p = Path(a.out) / f"model-versions-{TODAY}.md"
            p.write_text(text, encoding="utf-8")
            os.chmod(p, 0o600)
        finally:
            os.umask(old)
    print("\n".join(summary(results)) if a.summary else text)
    return 1 if any(r["candidates"] for r in results) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
