#!/usr/bin/env python3
"""audit-dashboard.py — one local HTML page over the weekly maintenance output.

Reads what the weekly jobs already write and renders a self-contained dashboard:
audit trend, findings breakdown (repo x check), disk cleanup, and an action list.
No network: charts are inline SVG, the page loads nothing from outside.

  security-audit-YYYY-MM-DD.md   scripts/security-audit.sh   trend, top-level FAILs
  findings-YYYY-MM-DD.tsv        scripts/dev-audit.sh        breakdown, per-check trend
  ~/.weekly-disk-cleanup.log     bin/weekly-disk-cleanup.sh  space reclaimed per run

Usage: audit-dashboard.py [--reports DIR] [--cleanup-log FILE] [--out FILE]
  --reports      directory holding the reports (default: $DEV_ROOT/audit-reports)
  --cleanup-log  disk cleanup log (default: ~/.weekly-disk-cleanup.log)
  --out          output file (default: <reports>/dashboard.html), written mode 600

Exit: 0 written, 2 usage error, 3 refused (output would land inside a git repo).
The page holds the same detail as the reports, so it never goes inside a git repo
and is never published (docs/policy/ai-and-external-services.md).
"""

import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
TOTALS_RE = re.compile(r"\*\*(\d+) FAIL · (\d+) WARN · (\d+) info\*\*")
SECTION_RE = re.compile(r"^## (\d+)\. (.+)$")
BULLET_RE = re.compile(r"^- \*\*(FAIL|WARN)\*\* (.+)$")
SIZE_RE = re.compile(r"^([\d.]+)\s*([BKMGTP]?)i?B?$")
UNITS = {"": 1, "B": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}

# dotaudit check -> the kind of fix it needs. Checks not listed land in "Other".
FIX_GROUPS = [
    ("Rotate exposed credentials",
     "Rotate at the provider first; only then remove the value from the tree and history, or archive the repo.",
     {"aws-access-key", "openai-key", "google-api-key", "private-key-block", "gitleaks",
      "secret-assignment", "service-account-json", "env-file", "history-env-file"}),
    ("Unbacked-up work",
     "Push it, or give it a remote. This disk is the only copy.",
     {"unpushed", "no-remote", "no-offmachine-copy", "behind", "no-upstream"}),
    ("Personal data",
     "Committer identity must be the noreply address; personal values out of tracked files.",
     {"committer-email", "email", "home-path"}),
    (".gitignore gaps",
     "Add the baseline entries (docs/policy/repo-standards.md).",
     {"gitignore-env", "gitignore-gaps"}),
    ("Security CI missing",
     "Call security-reusable.yml from the repo's CI. Never in forks or upstream clones.",
     {"no-security-ci"}),
    ("Pin dependencies and Actions",
     "Exact version pins; Actions pinned by commit SHA.",
     {"unpinned-deps", "unpinned-action"}),
    ("Licensing",
     "LICENSE present and matching the manifest. Never relicense a fork.",
     {"no-license", "license-mismatch", "copyright-drift"}),
    ("Media and large files",
     "No media or large binaries in git.",
     {"tracked-media", "large-files", "large-repo", "git-bloat"}),
]


# --- parsing --------------------------------------------------------------------------------------

def file_date(path):
    m = DATE_RE.search(path.name)
    return m.group(1) if m else ""


def parse_report(path):
    """security-audit-*.md -> {date, fail, warn, info, sections: [(title, [(sev, text)])]}"""
    rep = {"date": file_date(path), "fail": 0, "warn": 0, "info": 0, "sections": []}
    for line in path.read_text(errors="replace").splitlines():
        m = TOTALS_RE.search(line)
        if m and not rep["sections"]:
            rep["fail"], rep["warn"], rep["info"] = (int(g) for g in m.groups())
            continue
        m = SECTION_RE.match(line)
        if m:
            rep["sections"].append((f"{m.group(1)}. {m.group(2)}", []))
            continue
        m = BULLET_RE.match(line)
        if m and rep["sections"]:
            rep["sections"][-1][1].append((m.group(1), m.group(2)))
    return rep


def parse_findings(path):
    """findings-*.tsv -> [(sev, area, repo, check, detail)]"""
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) >= 5 and parts[0] in ("FAIL", "WARN", "INFO"):
            rows.append((parts[0], parts[1], parts[2], parts[3], "\t".join(parts[4:])))
    return rows


def parse_size(text):
    m = SIZE_RE.match(text.strip())
    if not m:
        return None
    return float(m.group(1)) * UNITS[m.group(2)]


def parse_cleanup_log(path):
    """~/.weekly-disk-cleanup.log -> [{date, sections: {name: reclaimed_bytes}}], last run per day."""
    if not path.is_file():
        return []
    runs, cur, section = {}, None, None
    for line in path.read_text(errors="replace").splitlines():
        if "Weekly disk cleanup - " in line:
            cur, section = None, None
            if "DRY RUN" in line:
                continue
            tok = line.split("Weekly disk cleanup - ", 1)[1].split()
            try:
                day = time.strftime("%Y-%m-%d", time.strptime(f"{tok[1]} {tok[2]} {tok[-1]}", "%b %d %Y"))
            except (IndexError, ValueError):
                continue
            cur = runs[day] = {"date": day, "sections": {}}
        elif cur is None:
            continue
        elif line.startswith("--- ") and line.endswith(" ---"):
            section = line[4:-4].strip()
            cur["sections"].setdefault(section, {})
        elif section and line.startswith(("Before:", "After:")):
            key, _, val = line.partition(":")
            size = parse_size(val)
            if size is not None:
                cur["sections"][section][key] = size
    out = []
    for day in sorted(runs):
        reclaimed = {}
        for name, s in runs[day]["sections"].items():
            if "Before" in s and "After" in s:
                reclaimed[name] = max(0.0, s["Before"] - s["After"])
        out.append({"date": day, "sections": reclaimed})
    return out


# --- rendering helpers ----------------------------------------------------------------------------

def esc(s):
    return html.escape(str(s), quote=True)


def human(n):
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit in ("B", "K") else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}T"


def delta(now, before):
    if before is None:
        return ""
    d = now - before
    if d == 0:
        return '<span class="d0">±0</span>'
    return f'<span class="{"dup" if d > 0 else "ddown"}">{"+" if d > 0 else "−"}{abs(d)}</span>'


def line_chart(labels, series, height=220):
    """series: [(name, css_var, [values])] -> inline SVG line chart."""
    w, h, pl, pr, pt, pb = 640, height, 40, 12, 12, 28
    vmax = max([v for _, _, vals in series for v in vals] + [1])
    n = len(labels)

    def x(i):
        return pl + (i * (w - pl - pr) / (n - 1) if n > 1 else (w - pl - pr) / 2)

    def y(v):
        return pt + (h - pt - pb) * (1 - v / vmax)

    parts = [f'<svg viewBox="0 0 {w} {h}" class="chart" role="img">']
    for k in range(5):
        v = vmax * k / 4
        parts.append(f'<line x1="{pl}" x2="{w - pr}" y1="{y(v):.1f}" y2="{y(v):.1f}" class="grid"/>'
                     f'<text x="{pl - 6}" y="{y(v) + 4:.1f}" class="ax" text-anchor="end">{v:.0f}</text>')
    step = max(1, n // 8)
    for i, lab in enumerate(labels):
        if i % step == 0 or i == n - 1:
            parts.append(f'<text x="{x(i):.1f}" y="{h - 8}" class="ax" text-anchor="middle">{esc(lab[5:])}</text>')
    for name, color, vals in series:
        pts = " ".join(f"{x(i):.1f},{y(v):.1f}" for i, v in enumerate(vals))
        parts.append(f'<polyline points="{pts}" fill="none" stroke="var({color})" stroke-width="2"/>')
        for i, v in enumerate(vals):
            parts.append(f'<circle cx="{x(i):.1f}" cy="{y(v):.1f}" r="3" fill="var({color})">'
                         f'<title>{esc(name)} {esc(labels[i])}: {v}</title></circle>')
    parts.append("</svg>")
    legend = "".join(f'<span class="key"><i style="background:var({c})"></i>{esc(nm)}</span>'
                     for nm, c, _ in series)
    return f'<div class="legend">{legend}</div>' + "".join(parts)


def sparkline(vals, color="--fail"):
    w, h = 120, 32
    vmax = max(vals + [1])
    n = len(vals)
    pts = " ".join(f"{(i * w / (n - 1) if n > 1 else w / 2):.1f},{h - 2 - (h - 4) * v / vmax:.1f}"
                   for i, v in enumerate(vals))
    return (f'<svg viewBox="0 0 {w} {h}" class="spark"><polyline points="{pts}" fill="none" '
            f'stroke="var({color})" stroke-width="1.5"/></svg>')


def stacked_bars(labels, stacks, colors):
    """stacks: [{name: value}] per label -> SVG stacked columns (bytes)."""
    w, h, pl, pr, pt, pb = 640, 220, 48, 12, 12, 28
    names = sorted({k for s in stacks for k in s}, key=lambda k: -sum(s.get(k, 0) for s in stacks))
    vmax = max([sum(s.values()) for s in stacks] + [1])
    n = len(labels)
    bw = (w - pl - pr) / max(n, 1)
    parts = [f'<svg viewBox="0 0 {w} {h}" class="chart" role="img">']
    for k in range(5):
        v = vmax * k / 4
        yy = pt + (h - pt - pb) * (1 - v / vmax)
        parts.append(f'<line x1="{pl}" x2="{w - pr}" y1="{yy:.1f}" y2="{yy:.1f}" class="grid"/>'
                     f'<text x="{pl - 6}" y="{yy + 4:.1f}" class="ax" text-anchor="end">{human(v)}</text>')
    step = max(1, n // 8)
    for i, (lab, s) in enumerate(zip(labels, stacks)):
        base = 0.0
        x0 = pl + i * bw + bw * 0.15
        for j, name in enumerate(names):
            v = s.get(name, 0)
            if v <= 0:
                continue
            y1 = pt + (h - pt - pb) * (1 - (base + v) / vmax)
            hh = (h - pt - pb) * v / vmax
            parts.append(f'<rect x="{x0:.1f}" y="{y1:.1f}" width="{bw * 0.7:.1f}" height="{hh:.1f}" '
                         f'fill="var({colors[j % len(colors)]})"><title>{esc(lab)} {esc(name)}: '
                         f'{human(v)}</title></rect>')
            base += v
        if i % step == 0 or i == n - 1:
            parts.append(f'<text x="{x0 + bw * 0.35:.1f}" y="{h - 8}" class="ax" '
                         f'text-anchor="middle">{esc(lab[5:])}</text>')
    parts.append("</svg>")
    legend = "".join(f'<span class="key"><i style="background:var({colors[j % len(colors)]})"></i>'
                     f'{esc(nm)}</span>' for j, nm in enumerate(names))
    return f'<div class="legend">{legend}</div>' + "".join(parts)


# --- sections -------------------------------------------------------------------------------------

def tiles(reports, findings, cleanup, n_actions):
    def tile(label, value, sub=""):
        return f'<div class="tile"><div class="tl">{esc(label)}</div><div class="tv">{value}</div><div class="ts">{sub}</div></div>'

    out = []
    if reports:
        cur, prev = reports[-1], (reports[-2] if len(reports) > 1 else None)
        out.append(tile("Audit FAIL", cur["fail"], delta(cur["fail"], prev and prev["fail"]) + f' · {esc(cur["date"])}'))
        out.append(tile("Audit WARN", cur["warn"], delta(cur["warn"], prev and prev["warn"])))
    if findings:
        (_, rows), prev = findings[-1], (findings[-2][1] if len(findings) > 1 else None)
        nf = sum(r[0] == "FAIL" for r in rows)
        pf = sum(r[0] == "FAIL" for r in prev) if prev else None
        nr = len({r[2] for r in rows if r[0] != "INFO"})
        out.append(tile("dotaudit FAIL", nf, delta(nf, pf) + f" · {nr} repos/dirs affected"))
    if cleanup:
        last = cleanup[-1]
        out.append(tile("Last cleanup", human(sum(last["sections"].values())), f'reclaimed · {esc(last["date"])}'))
    out.append(tile("Open actions", f'<span id="open-count">{n_actions}</span>', "ticked off in this browser"))
    return f'<div class="tiles">{"".join(out)}</div>'


def trend_section(reports, findings):
    parts = ['<section id="trend"><h2>Trend</h2>']
    if reports:
        labels = [r["date"] for r in reports]
        parts.append("<h3>Weekly security audit</h3>")
        parts.append(line_chart(labels, [("FAIL", "--fail", [r["fail"] for r in reports]),
                                         ("WARN", "--warn", [r["warn"] for r in reports])]))
    else:
        parts.append('<p class="empty">No security-audit reports yet.</p>')
    if findings:
        labels = [d for d, _ in findings]
        parts.append("<h3>dotaudit</h3>")
        parts.append(line_chart(labels, [
            ("FAIL", "--fail", [sum(r[0] == "FAIL" for r in rows) for _, rows in findings]),
            ("WARN", "--warn", [sum(r[0] == "WARN" for r in rows) for _, rows in findings])]))
        counts = []
        for _, rows in findings:
            c = {}
            for r in rows:
                if r[0] != "INFO":
                    c[r[3]] = c.get(r[3], 0) + 1
            counts.append(c)
        latest = counts[-1]
        top = sorted(latest, key=lambda k: -latest[k])[:16]
        parts.append(f'<h3>Per check, FAIL+WARN over {len(findings)} runs</h3><div class="multiples">')
        for chk in top:
            vals = [c.get(chk, 0) for c in counts]
            prev = vals[-2] if len(vals) > 1 else None
            parts.append(f'<div class="mult"><div class="mt">{esc(chk)}</div>{sparkline(vals)}'
                         f'<div class="mv">{vals[-1]} {delta(vals[-1], prev)}</div></div>')
        parts.append("</div>")
    parts.append("</section>")
    return "".join(parts)


def breakdown_section(findings):
    parts = ['<section id="breakdown"><h2>Findings breakdown</h2>']
    if not findings:
        return "".join(parts) + '<p class="empty">No dotaudit findings files yet.</p></section>'
    date, rows = findings[-1]
    rows = [r for r in rows if r[0] != "INFO"]
    by_check, by_repo, cells = {}, {}, {}
    for sev, _, repo, chk, detail in rows:
        bc = by_check.setdefault(chk, [0, 0])
        br = by_repo.setdefault(repo, [0, 0])
        i = 0 if sev == "FAIL" else 1
        bc[i] += 1
        br[i] += 1
        cells.setdefault(repo, {}).setdefault(chk, []).append([sev, detail])
    checks = sorted(by_check, key=lambda k: (-by_check[k][0], -sum(by_check[k])))
    repos = sorted(by_repo, key=lambda k: (-by_repo[k][0], -sum(by_repo[k]), k))
    vmax = max([sum(v) for v in by_check.values()] + [1])

    parts.append(f"<h3>By check · {esc(date)}</h3><div class=\"bars\">")
    for chk in checks:
        f, w = by_check[chk]
        parts.append(f'<div class="bar"><span class="bl">{esc(chk)}</span><span class="bt">'
                     f'<i class="bf" style="width:{100 * f / vmax:.1f}%"></i>'
                     f'<i class="bw" style="width:{100 * w / vmax:.1f}%"></i></span>'
                     f'<span class="bn">{f} / {w}</span></div>')
    parts.append('</div><p class="note">Counts are FAIL / WARN.</p>')

    parts.append(f'<h3>Repo × check · {len(repos)} repos</h3>'
                 '<input id="repo-filter" type="search" placeholder="Filter repos…">'
                 '<div class="heat-wrap"><table class="heat"><thead><tr><th>repo</th>')
    for chk in checks:
        parts.append(f'<th class="rot"><span>{esc(chk)}</span></th>')
    parts.append("</tr></thead><tbody>")
    for repo in repos:
        parts.append(f'<tr data-repo="{esc(repo.lower())}"><th>{esc(repo)}</th>')
        for chk in checks:
            items = cells.get(repo, {}).get(chk)
            if not items:
                parts.append("<td></td>")
                continue
            cls = "hf" if any(s == "FAIL" for s, _ in items) else "hw"
            parts.append(f'<td class="{cls}" data-r="{esc(repo)}" data-c="{esc(chk)}">{len(items)}</td>')
        parts.append("</tr>")
    parts.append('</tbody></table></div><div id="cell-detail" class="detail">Click a cell for its findings.</div>')
    parts.append(f'<script type="application/json" id="cells">{json_embed(cells)}</script></section>')
    return "".join(parts)


def disk_section(cleanup):
    parts = ['<section id="disk"><h2>Disk cleanup</h2>']
    runs = [r for r in cleanup if r["sections"]]
    if not runs:
        return "".join(parts) + '<p class="empty">No cleanup runs with sizes in the log.</p></section>'
    colors = ["--c1", "--c2", "--c3", "--c4", "--c5", "--c6", "--c7", "--c8"]
    parts.append("<h3>Reclaimed per run</h3>")
    parts.append(stacked_bars([r["date"] for r in runs], [r["sections"] for r in runs], colors))
    names = sorted({k for r in runs for k in r["sections"]})
    parts.append('<div class="heat-wrap"><table class="plain"><thead><tr><th>run</th>')
    parts.append("".join(f"<th>{esc(n)}</th>" for n in names) + "<th>total</th></tr></thead><tbody>")
    for r in reversed(runs[-12:]):
        parts.append(f"<tr><th>{esc(r['date'])}</th>")
        parts.append("".join(f"<td>{human(r['sections'][n]) if n in r['sections'] else ''}</td>" for n in names))
        parts.append(f"<td><b>{human(sum(r['sections'].values()))}</b></td></tr>")
    parts.append("</tbody></table></div></section>")
    return "".join(parts)


def build_actions(reports, findings):
    """-> [(title, hint, [(key, label, detail)])]"""
    groups = [(t, h, checks, []) for t, h, checks in FIX_GROUPS]
    other = ("Other", "See docs/dev-audit.md for what the check means.", set(), [])
    audit = ("Weekly audit FAILs", "From the latest security-audit report; each line says what to do.", set(), [])
    if reports:
        for title, items in reports[-1]["sections"]:
            if title.startswith("2."):  # the dotaudit summary; its findings are listed per repo below
                continue
            for sev, text in items:
                if sev == "FAIL":
                    audit[3].append((f"audit|{title}|{text}", title.split(". ", 1)[-1], text))
    if findings:
        for sev, _, repo, chk, detail in findings[-1][1]:
            if sev != "FAIL":
                continue
            item = (f"find|{repo}|{chk}|{detail}", f"{repo} · {chk}", detail)
            for g in groups:
                if chk in g[2]:
                    g[3].append(item)
                    break
            else:
                other[3].append(item)
    return [(t, h, items) for t, h, _, items in [audit, *groups, other] if items]


def actions_section(actions):
    parts = [('<section id="actions"><h2>Action list</h2>'
             '<label class="toggle"><input type="checkbox" id="hide-done"> hide done</label>'
             '<p class="note">FAILs only, grouped by the fix they need. Ticks live in this browser\'s '
             'storage and are matched by text, so an item that is still failing next week stays ticked '
             'only if its wording is unchanged.</p>')]
    if not actions:
        return "".join(parts) + '<p class="empty">Nothing failing.</p></section>'
    for title, hint, items in actions:
        parts.append(f'<details open class="group"><summary><b>{esc(title)}</b> '
                     f'<span class="cnt">{len(items)}</span></summary><p class="hint">{esc(hint)}</p><ul>')
        for key, label, detail in sorted(items, key=lambda i: i[1].lower()):
            parts.append(f'<li><label><input type="checkbox" data-key="{esc(key)}"> '
                         f'<b>{esc(label)}</b> <span class="dt">{esc(detail)}</span></label></li>')
        parts.append("</ul></details>")
    parts.append("</section>")
    return "".join(parts)


def json_embed(obj):
    return json.dumps(obj, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


CSS = """
:root{--bg:#fafaf9;--fg:#1c1917;--mut:#78716c;--card:#fff;--line:#e7e5e4;--fail:#dc2626;--warn:#d97706;
--failbg:#fecaca;--warnbg:#fde68a;--c1:#2563eb;--c2:#0d9488;--c3:#9333ea;--c4:#ea580c;--c5:#65a30d;
--c6:#db2777;--c7:#0891b2;--c8:#a16207;--up:#dc2626;--down:#16a34a}
@media (prefers-color-scheme:dark){:root{--bg:#1c1917;--fg:#f5f5f4;--mut:#a8a29e;--card:#292524;
--line:#44403c;--fail:#f87171;--warn:#fbbf24;--failbg:#7f1d1d;--warnbg:#78350f;--c1:#60a5fa;--c2:#2dd4bf;
--c3:#c084fc;--c4:#fb923c;--c5:#a3e635;--c6:#f472b6;--c7:#22d3ee;--c8:#facc15;--up:#f87171;--down:#4ade80}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
header{padding:20px 16px 8px;max-width:1100px;margin:auto}header h1{margin:0 0 4px;font-size:22px}
nav{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);z-index:5}
nav div{max-width:1100px;margin:auto;padding:8px 16px;display:flex;gap:16px;flex-wrap:wrap}
nav a{color:var(--fg);text-decoration:none;font-weight:600}nav a:hover{text-decoration:underline}
main{max-width:1100px;margin:auto;padding:0 16px 48px}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin:16px 0}
h2{margin:0 0 8px;font-size:18px}h3{margin:18px 0 6px;font-size:14px;color:var(--mut)}
.mut,.note,.hint,.empty{color:var(--mut)}.note,.hint{font-size:12px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:16px 0}
.tile{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}
.tl{font-size:12px;color:var(--mut)}.tv{font-size:26px;font-weight:700}.ts{font-size:12px;color:var(--mut)}
.dup{color:var(--up);font-weight:600}.ddown{color:var(--down);font-weight:600}.d0{color:var(--mut)}
.chart{width:100%;height:auto;max-height:260px}.grid{stroke:var(--line)}.ax{fill:var(--mut);font-size:11px}
.legend{display:flex;gap:14px;font-size:12px;flex-wrap:wrap}.key i{display:inline-block;width:10px;
height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}
.multiples{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px}
.mult{border:1px solid var(--line);border-radius:8px;padding:8px}.mt{font-size:12px;font-weight:600;
overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.spark{width:100%;height:32px}.mv{font-size:13px}
.bars{display:grid;gap:3px}.bar{display:grid;grid-template-columns:150px 1fr 70px;gap:8px;align-items:center;
font-size:12px}.bl{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.bt{display:flex;height:12px;
background:var(--bg);border-radius:3px;overflow:hidden}.bf{background:var(--fail)}.bw{background:var(--warn)}
.bn{color:var(--mut);text-align:right}
#repo-filter{width:100%;max-width:320px;padding:6px 8px;margin:4px 0 8px;border:1px solid var(--line);
border-radius:6px;background:var(--bg);color:var(--fg)}
.heat-wrap{overflow:auto;max-height:70vh;border:1px solid var(--line);border-radius:6px}
table{border-collapse:collapse;font-size:12px}th,td{padding:3px 6px;border-bottom:1px solid var(--line)}
.heat thead th{position:sticky;top:0;background:var(--card);z-index:2}.heat tbody th{position:sticky;left:0;
background:var(--card);text-align:left;white-space:nowrap;font-weight:500;z-index:1}
.heat .rot{height:120px;vertical-align:bottom;white-space:nowrap;padding:0 2px}
.heat .rot span{writing-mode:vertical-rl;transform:rotate(180deg);font-weight:500}
.heat td{text-align:center;min-width:24px;cursor:default}.hf{background:var(--failbg);cursor:pointer!important}
.hw{background:var(--warnbg);cursor:pointer!important}.heat td.sel{outline:2px solid var(--fg)}
.detail{margin-top:8px;padding:10px;border:1px dashed var(--line);border-radius:6px;font-size:12px}
.detail .s{font-weight:700}.detail .FAIL{color:var(--fail)}.detail .WARN{color:var(--warn)}
table.plain th{text-align:left;font-weight:500}table.plain td{text-align:right}
.group{border-top:1px solid var(--line);padding:6px 0}.group summary{cursor:pointer}
.cnt{background:var(--failbg);border-radius:9px;padding:0 7px;font-size:12px;margin-left:4px}
.group ul{list-style:none;padding-left:4px;margin:4px 0}.group li{padding:2px 0;font-size:13px}
.dt{color:var(--mut)}li.done{opacity:.45;text-decoration:line-through}body.hide-done li.done{display:none}
.toggle{float:right;font-size:12px;color:var(--mut)}
@media (max-width:600px){.bar{grid-template-columns:100px 1fr 56px}}
"""

JS = """
(function(){
  var KEY='audit-dashboard:done', done={};
  try{done=JSON.parse(localStorage.getItem(KEY)||'{}')||{};}catch(e){done={};}
  function save(){try{localStorage.setItem(KEY,JSON.stringify(done));}catch(e){}}
  var boxes=document.querySelectorAll('input[data-key]'), cnt=document.getElementById('open-count');
  function recount(){var n=0;boxes.forEach(function(b){if(!b.checked)n++;});if(cnt)cnt.textContent=n;}
  boxes.forEach(function(b){
    var li=b.closest('li');b.checked=!!done[b.dataset.key];li.classList.toggle('done',b.checked);
    b.addEventListener('change',function(){
      if(b.checked)done[b.dataset.key]=1;else delete done[b.dataset.key];
      li.classList.toggle('done',b.checked);save();recount();});
  });
  recount();
  var hide=document.getElementById('hide-done');
  if(hide){try{hide.checked=localStorage.getItem(KEY+':hide')==='1';}catch(e){}
    document.body.classList.toggle('hide-done',hide.checked);
    hide.addEventListener('change',function(){document.body.classList.toggle('hide-done',hide.checked);
      try{localStorage.setItem(KEY+':hide',hide.checked?'1':'0');}catch(e){}});}
  var f=document.getElementById('repo-filter');
  if(f)f.addEventListener('input',function(){var q=f.value.toLowerCase();
    document.querySelectorAll('.heat tbody tr').forEach(function(tr){
      tr.style.display=tr.dataset.repo.indexOf(q)>=0?'':'none';});});
  var data=document.getElementById('cells'), cells=data?JSON.parse(data.textContent):{};
  var det=document.getElementById('cell-detail'), sel=null;
  document.querySelectorAll('.heat td[data-r]').forEach(function(td){
    td.addEventListener('click',function(){
      if(sel)sel.classList.remove('sel');sel=td;td.classList.add('sel');
      var items=(cells[td.dataset.r]||{})[td.dataset.c]||[];
      det.textContent='';var h=document.createElement('b');h.textContent=td.dataset.r+' · '+td.dataset.c;
      det.appendChild(h);var ul=document.createElement('ul');
      items.forEach(function(it){var li=document.createElement('li');var s=document.createElement('span');
        s.className='s '+it[0];s.textContent=it[0]+' ';li.appendChild(s);
        li.appendChild(document.createTextNode(it[1]));ul.appendChild(li);});
      det.appendChild(ul);});
  });
})();
"""


def render(reports, findings, cleanup, generated):
    actions = build_actions(reports, findings)
    n_actions = sum(len(items) for _, _, items in actions)
    body = [
        "<header><h1>Weekly maintenance</h1>",
        (f'<div class="mut">Generated {esc(generated)} by <code>dotfiles/scripts/audit-dashboard.py</code> · '
         f"{len(reports)} audit reports · {len(findings)} dotaudit runs · {len(cleanup)} cleanup runs · "
         "local only, do not publish</div></header>"),
        ('<nav><div><a href="#trend">Trend</a><a href="#breakdown">Breakdown</a>'
         '<a href="#disk">Disk</a><a href="#actions">Actions</a></div></nav><main>'),
        tiles(reports, findings, cleanup, n_actions),
        trend_section(reports, findings),
        breakdown_section(findings),
        disk_section(cleanup),
        actions_section(actions),
        "</main>",
    ]
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<meta name=\"referrer\" content=\"no-referrer\">"
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
            "style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:\">"
            f"<title>Weekly maintenance</title><style>{CSS}</style></head><body>"
            + "".join(body) + f"<script>{JS}</script></body></html>\n")


# --- main -----------------------------------------------------------------------------------------

def inside_git_repo(directory):
    try:
        r = subprocess.run(["git", "--no-optional-locks", "-C", str(directory), "rev-parse", "--git-dir"],
                           capture_output=True, check=False)
    except FileNotFoundError:
        return False
    return r.returncode == 0


def main(argv):
    dev_root = Path(os.environ.get("DEV_ROOT") or Path.home() / "dev")
    p = argparse.ArgumentParser(add_help=True, description="Render the weekly maintenance dashboard.")
    p.add_argument("--reports", type=Path, default=dev_root / "audit-reports")
    p.add_argument("--cleanup-log", type=Path, default=Path.home() / ".weekly-disk-cleanup.log")
    p.add_argument("--out", type=Path)
    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    if not args.reports.is_dir():
        print(f"no reports directory: {args.reports}", file=sys.stderr)
        return 2
    out = args.out or args.reports / "dashboard.html"
    if inside_git_repo(out.parent):
        print(f"refusing to write the dashboard into a git repo: {out.parent}", file=sys.stderr)
        return 3

    reports = [parse_report(f) for f in sorted(args.reports.glob("security-audit-*.md"), key=file_date)]
    findings = [(file_date(f), parse_findings(f)) for f in sorted(args.reports.glob("findings-*.tsv"), key=file_date)]
    cleanup = parse_cleanup_log(args.cleanup_log)
    page = render(reports, findings, cleanup, datetime.now().astimezone().strftime("%Y-%m-%d %H:%M"))

    fd, tmp = tempfile.mkstemp(dir=out.parent, prefix=".dashboard.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(page)
        os.chmod(tmp, 0o600)
        os.replace(tmp, out)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    print(f"Dashboard: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
