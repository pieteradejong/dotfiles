#!/usr/bin/env python3
"""claude-md-check.py — the facts the CLAUDE.md sources state about this Mac are still true.

Checks claude/CLAUDE.md (global) and claude/dev-CLAUDE.md (workspace), the repo
sources; the live copies are test-docs.py's `synced` check, not this one.
  versions  every row of a markdown table whose second column is headed
            "Version", plus a few known prose claims (macOS, Darwin, zsh, VS Code,
            "Python is Homebrew-managed (3.x)", "Ruby 2.x is the system fallback"),
            is compared with the installed tool. A stated version matches when its
            components are a prefix of the installed one ("5.9" matches 5.9.2).
            FAIL on drift, on a tool not on PATH, on a probe that errors, prints no
            version or times out. A row with no known probe is a note, not a FAIL.
  dates     an "as of", "checked", "last checked" or "verified" followed by a
            YYYY-MM-DD or "Mon[th] YYYY" date older than MAX_AGE_DAYS: WARN.
            Future dates and anything inside code is ignored.
  size      a file longer than MAX_LINES lines: WARN (every line loads every session).

Usage:  scripts/claude-md-check.py                    every check
        scripts/claude-md-check.py --quiet            WARN, FAIL and fixes only
        scripts/claude-md-check.py --list             the claims found, no probes run
        scripts/claude-md-check.py --apply            rewrite drifted versions in the
                                                      source files, keeping the stated
                                                      precision; prints each file written
        scripts/claude-md-check.py --apply --dry-run  the diff only, nothing written
        scripts/claude-md-check.py -h | --help
Exit:   0 no FAIL · 1 at least one FAIL (with --apply: one not fixed) · 2 bad usage,
        missing source, or --apply aimed at a live copy. WARN never fails the run.
Env:    GLOBAL_CLAUDE_SRC  global source   (default: <repo>/claude/CLAUDE.md)
        DEV_CLAUDE_SRC     workspace source (default: <repo>/claude/dev-CLAUDE.md)
        GLOBAL_CLAUDE_MD   live global copy --apply refuses (default: ~/.claude/CLAUDE.md)
        DEV_CLAUDE_MD      live workspace copy --apply refuses (default: ~/dev/CLAUDE.md)
        MAX_AGE_DAYS (90) · MAX_LINES (200) · PROBE_TIMEOUT seconds (10)
        TODAY              YYYY-MM-DD, for tests (default: today)
"""

import datetime as dt
import difflib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HOME = Path.home()

VER = r"\d+(?:\.\d+)+"
FIRST_VER = re.compile(VER)

# Table name (lowercased, parenthetical dropped) -> (argv, regex with one group, or None for FIRST_VER).
PROBES = {
    "homebrew": (["brew", "--version"], rf"Homebrew ({VER})"),
    "npm": (["npm", "-v"], None),
    "pnpm": (["pnpm", "-v"], None),
    "yarn": (["yarn", "-v"], None),
    "pip / pip3": (["pip3", "--version"], rf"pip ({VER})"),
    "cargo": (["cargo", "--version"], rf"cargo ({VER})"),
    "gem": (["gem", "-v"], None),
    "node.js": (["node", "-v"], None),
    "python": (["python3", "--version"], rf"Python ({VER})"),
    "go": (["go", "version"], rf"go({VER})"),
    "rust": (["rustc", "--version"], rf"rustc ({VER})"),
    "swift": (["swift", "--version"], rf"Swift version ({VER})"),
    "ruby": (["ruby", "-v"], rf"ruby ({VER})"),
    "java": (["java", "-version"], rf'version "({VER})'),
    "php": (["php", "-v"], rf"PHP ({VER})"),
    "git": (["git", "--version"], rf"git version ({VER})"),
    "gh": (["gh", "--version"], rf"gh version ({VER})"),
    "docker cli": (["docker", "--version"], rf"Docker version ({VER})"),
    "docker compose plugin": (["docker", "compose", "version"], rf"version v?({VER})"),
    "colima": (["colima", "version"], rf"colima version v?({VER})"),
    "kubectl": (["kubectl", "version", "--client"], rf"Client Version: v?({VER})"),
    "terraform": (["terraform", "version"], rf"Terraform v({VER})"),
    "supabase cli": (["supabase", "--version"], None),
    "jq": (["jq", "--version"], rf"jq-({VER})"),
    "curl": (["curl", "--version"], rf"curl ({VER})"),
    "wget": (["wget", "--version"], rf"Wget ({VER})"),
}

# Prose claims: (name, line regex with a `ver` group, argv, output regex or None).
PROSE = [
    ("macOS", rf"\*\*OS\*\*:\s*macOS\s+(?P<ver>{VER}|\d+)", ["sw_vers", "-productVersion"], None),
    ("Darwin", rf"\bDarwin\s+(?P<ver>{VER})", ["uname", "-r"], None),
    ("zsh", rf"\*\*Shell\*\*:\s*zsh\s+(?P<ver>{VER})", ["zsh", "--version"], rf"zsh ({VER})"),
    ("VS Code", rf"\*\*VS Code\*\*\s+(?P<ver>{VER})", ["code", "--version"], None),
    ("python3 (prose)", rf"Python is Homebrew-managed \((?P<ver>{VER})\)", ["python3", "--version"],
     rf"Python ({VER})"),
    ("ruby (prose)", rf"\bRuby (?P<ver>{VER}) is the system fallback", ["ruby", "-v"], rf"ruby ({VER})"),
]

MONTHS = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
DATE_CLAIM = re.compile(
    r"\b(?:as of|last checked|checked|verified)\s+"
    r"(?:(?P<iso>\d{4}-\d{2}-\d{2})|(?P<mon>[A-Za-z]{3,9})\.?\s+(?P<year>\d{4}))",
    re.IGNORECASE)
FENCE_LINE = re.compile(r"^\s*(```|~~~)")
CODE_SPAN = re.compile(r"`[^`\n]*`")


class Usage(Exception):
    pass


def env_path(name, default):
    return Path(os.environ.get(name) or default)


def env_int(name, default):
    raw = os.environ.get(name, "")
    if not raw:
        return default
    if not raw.isdigit():
        raise Usage(f"{name} must be a whole number, got {raw!r}")
    return int(raw)


def today():
    raw = os.environ.get("TODAY", "")
    if not raw:
        return dt.date.today()
    try:
        return dt.date.fromisoformat(raw)
    except ValueError:
        raise Usage(f"TODAY must be YYYY-MM-DD, got {raw!r}") from None


def prose_lines(text):
    """(index, line) for every line outside a fenced block."""
    fenced = False
    for i, line in enumerate(text.split("\n")):
        if FENCE_LINE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            yield i, line


def split_cells(line):
    """Cells of a markdown table row with their (start, end) offsets; a pipe inside backticks is text."""
    cells, start, in_code = [], None, False
    for j, ch in enumerate(line):
        if ch == "`":
            in_code = not in_code
        elif ch == "|" and not in_code:
            if start is not None:
                cells.append((start, j))
            start = j + 1
    return cells


def table_name(cell):
    return re.sub(r"\s+", " ", re.sub(r"\([^)]*\)", "", cell)).strip().lower()


def find_claims(path):
    """Every version claim in a file: dict(file, line, name, stated, span, argv, rx)."""
    claims = []
    text = path.read_text(encoding="utf-8")
    version_table, header = False, ""
    for i, line in prose_lines(text):
        if line.lstrip().startswith("|"):
            cells = split_cells(line)
            if len(cells) < 2:
                continue
            first = line[cells[0][0]:cells[0][1]].strip()
            second = line[cells[1][0]:cells[1][1]]
            if re.fullmatch(r"\s*:?-+:?\s*", second):  # separator: the row above was the header
                version_table = header.strip().lower() == "version"
                continue
            header = second
            if not version_table:
                continue
            m = FIRST_VER.search(second)
            if not m:
                continue
            name = table_name(first)
            probe = PROBES.get(name)
            s = cells[1][0] + m.start()
            claims.append({"file": path, "line": i, "name": first, "stated": m.group(0),
                           "span": (s, s + len(m.group(0))),
                           "argv": probe[0] if probe else None, "rx": probe[1] if probe else None})
            continue
        version_table, header = False, ""
        for name, rx, argv, out_rx in PROSE:
            m = re.search(rx, line, re.IGNORECASE)
            if m:
                claims.append({"file": path, "line": i, "name": name, "stated": m.group("ver"),
                               "span": m.span("ver"), "argv": argv, "rx": out_rx})
    return claims


def probe(argv, rx, timeout):
    """(version, None) or (None, reason)."""
    if shutil.which(argv[0]) is None:
        return None, "not installed / not on PATH"
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, check=False)
    except subprocess.TimeoutExpired:
        return None, f"probe timed out after {timeout}s ({' '.join(argv)})"
    except OSError as e:
        return None, f"probe could not run ({e.strerror})"
    if r.returncode != 0:
        return None, f"probe failed with exit {r.returncode} ({' '.join(argv)})"
    out = r.stdout + r.stderr
    m = re.search(rx, out) if rx else FIRST_VER.search(out)
    if not m:
        return None, f"could not read a version from `{' '.join(argv)}`"
    return (m.group(1) if rx else m.group(0)), None


def matches(stated, actual):
    s, a = stated.split("."), actual.split(".")
    return a[:len(s)] == s


def restate(stated, actual):
    """The installed version at the precision the file states."""
    return ".".join(actual.split(".")[:max(len(stated.split(".")), 1)])


def stale_dates(path, now, max_age):
    out = []
    for i, line in prose_lines(path.read_text(encoding="utf-8")):
        for m in DATE_CLAIM.finditer(CODE_SPAN.sub("", line)):
            if m.group("iso"):
                try:
                    d = dt.date.fromisoformat(m.group("iso"))
                except ValueError:
                    continue
            else:
                mon = MONTHS.get(m.group("mon")[:3].lower())
                if not mon:
                    continue
                d = dt.date(int(m.group("year")), mon, 1)
            age = (now - d).days
            if age > max_age:
                out.append((i, m.group(0), age))
    return out


def rel(path):
    try:
        return str(path.resolve().relative_to(REPO))
    except ValueError:
        return str(path)


def main(argv):
    quiet = listing = apply = dry = False
    for a in argv:
        if a == "--quiet":
            quiet = True
        elif a == "--list":
            listing = True
        elif a == "--apply":
            apply = True
        elif a == "--dry-run":
            dry = True
        elif a in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            raise Usage(f"unknown argument: {a}")
    if dry and not apply:
        raise Usage("--dry-run only makes sense with --apply")
    if listing and apply:
        raise Usage("--list and --apply do not combine")

    sources = [env_path("GLOBAL_CLAUDE_SRC", REPO / "claude" / "CLAUDE.md"),
               env_path("DEV_CLAUDE_SRC", REPO / "claude" / "dev-CLAUDE.md")]
    lives = [env_path("GLOBAL_CLAUDE_MD", HOME / ".claude" / "CLAUDE.md"),
             env_path("DEV_CLAUDE_MD", HOME / "dev" / "CLAUDE.md")]
    for s in sources:
        if not s.is_file():
            raise Usage(f"source not found: {s}")
    if apply:
        live_set = {p.resolve() for p in lives if p.exists()}
        for s in sources:
            if s.resolve() in live_set:
                raise Usage(f"--apply edits the repo sources, never a live copy: {s}")
    max_age = env_int("MAX_AGE_DAYS", 90)
    max_lines = env_int("MAX_LINES", 200)
    timeout = env_int("PROBE_TIMEOUT", 10)
    now = today()

    fails = warns = 0

    def say(kind, msg):
        if kind in ("ok", "note") and quiet:
            return
        print(f"  {kind:<5} {msg}")

    claims = [c for s in sources for c in find_claims(s)]
    if listing:
        for c in claims:
            probe_s = " ".join(c["argv"]) if c["argv"] else "(no probe)"
            print(f"{rel(c['file'])}:{c['line'] + 1}\t{c['name']}\t{c['stated']}\t{probe_s}")
        print(f"{len(claims)} claims, {sum(1 for c in claims if c['argv'])} with a probe")
        return 0

    edits = {}  # file -> list of (line, span, new)
    cache = {}
    print("versions")
    for c in claims:
        where = f"{rel(c['file'])}:{c['line'] + 1}"
        if not c["argv"]:
            say("note", f"{c['name']}: no probe known, not checked ({where})")
            continue
        key = (tuple(c["argv"]), c["rx"])
        if key not in cache:
            cache[key] = probe(c["argv"], c["rx"], timeout)
        actual, why = cache[key]
        if why:
            fails += 1
            say("FAIL", f"{c['name']}: states {c['stated']}, {why} ({where})")
        elif matches(c["stated"], actual):
            say("ok", f"{c['name']} {c['stated']}")
        elif apply:
            new = restate(c["stated"], actual)
            edits.setdefault(c["file"], []).append((c["line"], c["span"], new))
            if dry:
                fails += 1
            say("fixed" if not dry else "FAIL", f"{c['name']}: {c['stated']} -> {new} ({where})"
                + (" [dry run]" if dry else ""))
        else:
            fails += 1
            say("FAIL", f"{c['name']}: states {c['stated']}, installed {actual} ({where})")

    print("dates")
    for s in sources:
        hits = stale_dates(s, now, max_age)
        for i, claim, age in hits:
            warns += 1
            say("WARN", f"{rel(s)}:{i + 1}: \"{claim}\" is {age} days old (limit {max_age})")
        if not hits:
            say("ok", f"{rel(s)}: no dated claim older than {max_age} days")

    print("size")
    for s in sources:
        n = len(s.read_text(encoding="utf-8").splitlines())
        if n > max_lines:
            warns += 1
            say("WARN", f"{rel(s)}: {n} lines (limit {max_lines})")
        else:
            say("ok", f"{rel(s)}: {n} lines")

    for path, changes in edits.items():
        old = path.read_text(encoding="utf-8")
        lines = old.split("\n")
        for i, (a, b), new in sorted(changes, key=lambda e: (e[0], -e[1][0])):
            lines[i] = lines[i][:a] + new + lines[i][b:]
        text = "\n".join(lines)
        if dry:
            sys.stdout.writelines(difflib.unified_diff(
                old.splitlines(keepends=True), text.splitlines(keepends=True),
                fromfile=f"a/{rel(path)}", tofile=f"b/{rel(path)}"))
        else:
            path.write_text(text, encoding="utf-8")
            print(f"wrote {path}", flush=True)
            print("  copy it to the live CLAUDE.md (scripts/test-docs.py checks the pair)", file=sys.stderr)

    print(f"claude-md-check: {fails} FAIL, {warns} WARN")
    return 1 if fails else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Usage as e:
        print(f"claude-md-check: {e}", file=sys.stderr)
        sys.exit(2)
