#!/usr/bin/env python3
"""test-docs.py — the policy docs link together and stay indexed.

Checks, over every docs/**/*.md in this repo:
  links      every relative link resolves to a file, and every #anchor to a heading
             (GitHub slug rules), in the same file or the target .md
  private    no link from a public doc resolves into private/
  indexed    every docs/policy/*.md is linked from docs/policy/security-and-privacy.md
             and listed in claude/dev-CLAUDE.md
  synced     the live workspace CLAUDE.md is byte-identical to claude/dev-CLAUDE.md
             (skipped with a note when it does not exist, e.g. in CI)
  self-test  a fixture with a broken link and a broken anchor is reported, so a
             checker that silently finds nothing fails

Usage:  scripts/test-docs.py [--verbose]
        scripts/test-docs.py -h | --help
Exit:   0 all passed · 1 a check failed · 2 bad usage
Env:    DEV_CLAUDE_MD  live workspace CLAUDE.md (default: ~/dev/CLAUDE.md)
"""

import os
import re
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO = SCRIPT_DIR.parent
DOCS = REPO / "docs"
POLICY = DOCS / "policy"
POLICY_INDEX = POLICY / "security-and-privacy.md"
DEV_CLAUDE_SRC = REPO / "claude" / "dev-CLAUDE.md"
DEV_CLAUDE_LIVE = Path(os.environ.get("DEV_CLAUDE_MD", Path.home() / "dev" / "CLAUDE.md"))
PRIVATE = REPO / "private"

FENCE = re.compile(r"^(```|~~~).*?^\1", re.MULTILINE | re.DOTALL)
CODE_SPAN = re.compile(r"`[^`\n]*`")
LINK = re.compile(r"(?<!!)\[[^\]\n]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING = re.compile(r"^#{1,6}\s+(.+?)\s*#*\s*$", re.MULTILINE)


def strip_code(text):
    return CODE_SPAN.sub("", FENCE.sub("", text))


def slug(heading):
    """GitHub's anchor for a heading: lowercase, drop punctuation, spaces to hyphens."""
    s = heading.strip().lower().replace("`", "")
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)  # a link in a heading keeps its text
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def anchors(path, cache={}):  # noqa: B006 — deliberate per-run memo
    if path not in cache:
        seen, out = {}, set()
        for h in HEADING.findall(FENCE.sub("", path.read_text(encoding="utf-8"))):
            base = slug(h)
            n = seen.get(base, 0)
            out.add(base if n == 0 else f"{base}-{n}")
            seen[base] = n + 1
        cache[path] = out
    return cache[path]


def check_links(files):
    """Return (problems, links_checked). Problems name file and target, never content."""
    problems, count = [], 0
    for f in files:
        for target in LINK.findall(strip_code(f.read_text(encoding="utf-8"))):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target):  # http:, mailto:, …
                continue
            count += 1
            path_part, _, frag = target.partition("#")
            dest = (f.parent / path_part).resolve() if path_part else f
            rel = str(f.relative_to(REPO)) if REPO in f.parents else f.name
            if PRIVATE in dest.parents or dest == PRIVATE:
                problems.append(f"private: {rel} links into private/: {target}")
                continue
            if not dest.exists():
                problems.append(f"links: {rel}: missing file: {target}")
                continue
            if frag and dest.suffix == ".md" and frag not in anchors(dest):
                problems.append(f"links: {rel}: missing anchor: {target}")
    return problems, count


def self_test():
    with tempfile.TemporaryDirectory() as d:
        a, b = Path(d, "a.md"), Path(d, "b.md")
        b.write_text("# Real heading\n## Dup\n## Dup\n", encoding="utf-8")
        a.write_text(
            "[ok](b.md#real-heading) [ok](b.md#dup-1) [ok](#top)\n# Top\n"
            "[bad](nope.md) [bad](b.md#no-such-heading)\n"
            "`[in code](nope.md)`\n```\n[in fence](nope.md)\n```\n",
            encoding="utf-8",
        )
        problems, count = check_links([a])
    expected = {"links: a.md: missing file: nope.md", "links: a.md: missing anchor: b.md#no-such-heading"}
    return set(problems) == expected and count == 5, problems


def main(argv):
    verbose = False
    for arg in argv:
        if arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        if arg == "--verbose":
            verbose = True
        else:
            print(f"unknown argument: {arg}", file=sys.stderr)
            return 2

    results = []  # (ok, label, details)

    ok, got = self_test()
    results.append((ok, "self-test: broken link and anchor in a fixture are reported", [] if ok else got))

    files = sorted(DOCS.rglob("*.md"))
    problems, count = check_links(files)
    link_problems = [p for p in problems if p.startswith("links:")]
    private_problems = [p for p in problems if p.startswith("private:")]
    results.append((not link_problems, f"links: {count} relative links in {len(files)} docs resolve", link_problems))
    results.append((not private_problems, "private: no public doc links into private/", private_problems))

    index = POLICY_INDEX.read_text(encoding="utf-8")
    claude = DEV_CLAUDE_SRC.read_text(encoding="utf-8")
    unindexed = []
    for p in sorted(POLICY.glob("*.md")):
        if p != POLICY_INDEX and f"]({p.name}" not in index:
            unindexed.append(f"indexed: {p.name} not linked from {POLICY_INDEX.name}")
        if f"`dotfiles/docs/policy/{p.name}`" not in claude:
            unindexed.append(f"indexed: {p.name} not listed in claude/dev-CLAUDE.md")
    results.append((not unindexed, "indexed: every policy doc is linked and listed", unindexed))

    if DEV_CLAUDE_LIVE.exists():
        same = DEV_CLAUDE_LIVE.read_bytes() == DEV_CLAUDE_SRC.read_bytes()
        results.append((same, "synced: workspace CLAUDE.md matches claude/dev-CLAUDE.md",
                        [] if same else ["synced: copy claude/dev-CLAUDE.md to the workspace CLAUDE.md"]))
    else:
        print("  - SKIP: synced: no workspace CLAUDE.md on this machine")

    failed = 0
    for ok, label, details in results:
        print(f"  {'✓ PASS' if ok else '✗ FAIL'}: {label}")
        if not ok or verbose:
            for d in details:
                print(f"      {d}")
        failed += not ok
    print(f"\n  {len(results) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
