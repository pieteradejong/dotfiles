#!/usr/bin/env python3
"""maintenance-app.py — a local web app over the daily reports (D71). Started by bin/maintenance-app.

Reads ~/dev/audit-reports/daily/daily-*.json (written by scripts/daily-report.py) and serves:

  /                  today's tiles and Needs action, the job grid (jobs x last 30 days),
                     administrative work and activity per day, the list of days
  /day/YYYY-MM-DD    one day's report, its markdown rendered (escape first, then a small subset)
  /day/YYYY-MM-DD.md that day's markdown, as text
  /live              "today so far": daily-report.py's collector run in memory; writes nothing
  /dashboard         the weekly audit dashboard (dashboard.html beside the reports)
  /api/days, /api/day/YYYY-MM-DD   the same data as JSON

Local and read-only by construction (docs/policy/secure-development.md):
  - binds 127.0.0.1 only; no POST, no handler writes anything;
  - every request needs this run's random token: given once in the URL that is opened, then an
    HttpOnly SameSite=Strict cookie. A missing or wrong token is 403;
  - a Host header other than 127.0.0.1:<port> or localhost:<port> is 403 (DNS rebinding);
  - a day is matched against ^\\d{4}-\\d{2}-\\d{2}$, so no path reaches outside the reports;
  - all report text is HTML-escaped (commit subjects and TODO lines are untrusted text);
  - CSP default-src 'none': the page loads nothing from anywhere, inline style and script only.

Usage:  maintenance-app [--port N] [--no-open] [--reports DIR]
        --port 0 (the default) picks a free port; the URL with the token is printed and opened.
Exit:   0 on Ctrl-C · 2 usage error or the port is taken
"""

import argparse
import hmac
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

REPO = Path(__file__).resolve().parent.parent
DEV_ROOT = Path(os.environ.get("DEV_ROOT") or Path.home() / "dev")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
GRID_DAYS = 30
CSP = ("default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; "
       "form-action 'none'; frame-ancestors 'none'; base-uri 'none'")
STATUS_CLASS = {"ok": "s-ok", "running": "s-ok", "idle": "s-idle", "not due": "s-idle",
                "pending": "s-pend", "failed": "s-bad", "missing": "s-bad"}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, REPO / "scripts" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DASH = load("audit_dashboard", "audit-dashboard.py")
esc = DASH.esc

CSS = DASH.CSS + """
.grid-wrap{overflow:auto;border:1px solid var(--line);border-radius:6px}
table.jobs td.c{width:18px;height:18px;padding:0;border:1px solid var(--card)}
table.jobs td.c a{display:block;width:100%;height:18px}
table.jobs th.d{font-weight:400;color:var(--mut);font-size:10px;writing-mode:vertical-rl;transform:rotate(180deg)}
.s-ok{background:var(--down)}.s-bad{background:var(--fail)}.s-idle{background:var(--line)}
.s-pend{background:var(--warnbg)}.s-none{background:transparent}
.pill{display:inline-block;border-radius:9px;padding:0 8px;font-size:12px;color:#fff}
.act li{list-style:none;padding:3px 0}.act input{margin-right:8px}.act li.done{opacity:.45;text-decoration:line-through}
.md table{margin:6px 0}.md td,.md th{text-align:left;vertical-align:top}.md code{font-size:12px}
.days a{margin-right:10px}.live{float:right;font-size:13px}
"""

JS = """
(function(){var KEY='maintenance-app:done',done={};
try{done=JSON.parse(localStorage.getItem(KEY)||'{}')||{};}catch(e){done={};}
document.querySelectorAll('.act input[data-k]').forEach(function(b){var k=b.dataset.k;
 if(done[k]){b.checked=true;b.parentNode.classList.add('done');}
 b.addEventListener('change',function(){if(b.checked){done[k]=1;}else{delete done[k];}
  b.parentNode.classList.toggle('done',b.checked);try{localStorage.setItem(KEY,JSON.stringify(done));}catch(e){}});});
})();
"""


# --- data -------------------------------------------------------------------------------------

def days(reports):
    out = []
    for f in sorted(reports.glob("daily-*.json")):
        day = f.stem[len("daily-"):]
        if not DAY_RE.match(day):
            continue
        try:
            out.append(json.loads(f.read_text()))
        except (OSError, ValueError):
            continue
    return out


def day_data(reports, day):
    if not DAY_RE.match(day):
        return None
    f = reports / f"daily-{day}.json"
    try:
        return json.loads(f.read_text())
    except (OSError, ValueError):
        return None


# --- markdown (escape first, then a small subset) ---------------------------------------------

def inline(s):
    s = esc(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)


def render_markdown(text):
    out, para, table, in_list = [], [], [], False

    def flush():
        nonlocal para, table, in_list
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para = []
        if table:
            rows = [r for r in table if not re.fullmatch(r"\|[\s\-:|]+\|", r)]
            cells = [[c.strip() for c in re.split(r"(?<!\\)\|", r.strip().strip("|"))] for r in rows]
            body = "".join("<tr>" + "".join(f"<{'th' if i == 0 else 'td'}>{inline(c.replace(chr(92) + '|', '|'))}"
                                            f"</{'th' if i == 0 else 'td'}>" for c in row) + "</tr>"
                           for i, row in enumerate(cells))
            out.append(f'<div class="grid-wrap"><table class="plain">{body}</table></div>')
            table = []
        if in_list:
            out.append("</ul>")
            in_list = False

    for line in text.splitlines():
        m = re.match(r"^(#{1,4}) (.+)$", line)
        if m:
            flush()
            n = min(len(m.group(1)) + 1, 4)
            out.append(f"<h{n}>{inline(m.group(2))}</h{n}>")
        elif line.startswith("|"):
            if para or in_list:
                flush()
            table.append(line)
        elif re.match(r"^\s*- ", line):
            if para or table:
                flush()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(re.sub(r'^\s*- ', '', line))}</li>")
        elif not line.strip():
            flush()
        else:
            if table or in_list:
                flush()
            para.append(line)
    flush()
    return '<div class="md">' + "\n".join(out) + "</div>"


# --- pages ------------------------------------------------------------------------------------

def page(title, body):
    nav = ('<nav><div><a href="/">Overview</a><a href="/live">Today so far</a>'
           '<a href="/dashboard">Weekly audit dashboard</a></div></nav>')
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            f"<title>{esc(title)}</title><style>{CSS}</style></head><body>"
            f"<header><h1>{esc(title)}</h1></header>{nav}<main>{body}</main><script>{JS}</script></body></html>\n")


def tiles(d):
    c = d["counts"]
    items = [("To act on", c["needs_action"], ""), ("Jobs ok", c["jobs_ok"], f"{c['jobs_bad']} failed or missing"),
             ("Decisions", c["decisions"], f"{c['changelog']} CHANGELOG lines"),
             ("TODO ticked", c["todo_ticked"], f"{c['todo_opened']} opened"),
             ("Commits", c["commits"], f"{len(d['git'])} repos"),
             ("Claude sessions", c["claude_sessions"], f"{c['session_logs']} log entries")]
    return '<div class="tiles">' + "".join(
        f'<div class="tile"><div class="tl">{esc(a)}</div><div class="tv">{esc(b)}</div>'
        f'<div class="ts">{esc(s)}</div></div>' for a, b, s in items) + "</div>"


def needs_action(d):
    if not d["needs_action"]:
        return '<p class="mut">Nothing to act on.</p>'
    return '<ul class="act">' + "".join(
        f'<li><label><input type="checkbox" data-k="{esc(d["date"] + ":" + a)}">{esc(a)}</label></li>'
        for a in d["needs_action"]) + "</ul>"


def job_grid(all_days):
    recent = all_days[-GRID_DAYS:]
    names = []
    for d in recent:
        names += [j["name"] for j in d["jobs"] if j["name"] not in names]
    head = "<tr><th></th>" + "".join(f'<th class="d">{esc(d["date"][5:])}</th>' for d in recent) + "</tr>"
    rows = []
    for n in names:
        cells = []
        for d in recent:
            j = next((x for x in d["jobs"] if x["name"] == n), None)
            st = j["status"] if j else "none"
            tip = f'{d["date"]} {n}: {st}' + (f' — {j["result"]}' if j and j["result"] else "")
            cells.append(f'<td class="c {STATUS_CLASS.get(st, "s-none")}" title="{esc(tip)}">'
                         f'<a href="/day/{esc(d["date"])}" aria-label="{esc(tip)}"></a></td>')
        rows.append(f"<tr><th>{esc(n)}</th>{''.join(cells)}</tr>")
    legend = "".join(f'<span class="key"><i class="{c}"></i>{esc(s)}</span>'
                     for s, c in (("ok / running", "s-ok"), ("failed / missing", "s-bad"),
                                  ("not due / idle", "s-idle"), ("pending", "s-pend")))
    return (f'<div class="legend">{legend}</div><div class="grid-wrap"><table class="jobs">{head}'
            f'{"".join(rows)}</table></div>')


def trends(all_days):
    labels = [d["date"] for d in all_days]
    c = [d["counts"] for d in all_days]
    if len(labels) < 2:
        return '<p class="mut">Trends appear from the second daily report on.</p>'
    admin = DASH.line_chart(labels, [("decisions", "--c1", [x["decisions"] for x in c]),
                                     ("TODO ticked", "--c5", [x["todo_ticked"] for x in c]),
                                     ("TODO opened", "--c4", [x["todo_opened"] for x in c]),
                                     ("CHANGELOG lines", "--c3", [x["changelog"] for x in c]),
                                     ("register changes", "--c7", [x["registers"] for x in c])])
    activity = DASH.line_chart(labels, [("commits", "--c2", [x["commits"] for x in c]),
                                        ("Claude sessions", "--c6", [x["claude_sessions"] for x in c]),
                                        ("to act on", "--fail", [x["needs_action"] for x in c])])
    return f"<h3>Administrative work per day</h3>{admin}<h3>Activity per day</h3>{activity}"


def overview(reports):
    all_days = days(reports)
    if not all_days:
        return page("Maintenance", "<section><p>No daily report yet. Run "
                    "<code>~/dev/dotfiles/scripts/daily-report.py</code>, or open "
                    '<a href="/live">today so far</a>.</p></section>')
    d = all_days[-1]
    links = " ".join(f'<a href="/day/{esc(x["date"])}">{esc(x["date"])}</a>' for x in reversed(all_days))
    body = (f'<p class="mut">Latest report {esc(d["date"])} (window {esc(d["window"]["since"])} → '
            f'{esc(d["window"]["until"])}).</p>{tiles(d)}'
            f'<section><h2>Needs action</h2>{needs_action(d)}</section>'
            f'<section><h2>Scheduled jobs, last {GRID_DAYS} days</h2>{job_grid(all_days)}</section>'
            f'<section><h2>Trends</h2>{trends(all_days)}</section>'
            f'<section class="days"><h2>Days</h2>{links}</section>')
    return page("Maintenance", body)


def day_page(d, md_text, live=False):
    title = "Today so far" if live else f"Daily report {d['date']}"
    raw = "" if live else f'<a class="live" href="/day/{esc(d["date"])}.md">raw markdown</a>'
    return page(title, f"{tiles(d)}<section>{raw}{render_markdown(md_text)}</section>")


# --- server -----------------------------------------------------------------------------------

class App(BaseHTTPRequestHandler):
    server_version = "maintenance-app"
    sys_version = ""

    def log_message(self, fmt, *args):
        if os.environ.get("MAINTENANCE_APP_LOG"):
            super().log_message(fmt, *args)

    def send(self, code, body, ctype="text/html; charset=utf-8", extra=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        for k, v in (("Content-Type", ctype), ("Content-Length", str(len(data))),
                     ("Content-Security-Policy", CSP), ("X-Content-Type-Options", "nosniff"),
                     ("Referrer-Policy", "no-referrer"), ("Cache-Control", "no-store"), *extra):
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def authorised(self, query):
        cfg = self.server.cfg
        if self.headers.get("Host", "") not in cfg["hosts"]:
            return False
        cookie = re.search(r"(?:^|;\s*)ma=([A-Za-z0-9_\-]+)", self.headers.get("Cookie", ""))
        given = (query.get("t") or [""])[0] or (cookie.group(1) if cookie else "")
        return hmac.compare_digest(given.encode(), cfg["token"].encode())

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if not self.authorised(query):
            return self.send(403, "forbidden\n", "text/plain; charset=utf-8")
        cfg, path = self.server.cfg, url.path
        if "t" in query:  # take the token out of the address bar, keep it in a cookie
            cookie = f"ma={cfg['token']}; HttpOnly; SameSite=Strict; Path=/"
            return self.send(303, "", extra=(("Location", path or "/"), ("Set-Cookie", cookie)))
        reports = cfg["reports"]
        try:
            if path == "/":
                return self.send(200, overview(reports))
            if path == "/api/days":
                body = [{"date": d["date"], "counts": d["counts"]} for d in days(reports)]
                return self.send(200, json.dumps(body), "application/json")
            m = re.fullmatch(r"/api/day/([^/]+)", path)
            if m:
                d = day_data(reports, m.group(1))
                return self.send(200, json.dumps(d), "application/json") if d else self.send(404, "not found\n", "text/plain")
            m = re.fullmatch(r"/day/([^/]+?)(\.md)?", path)
            if m:
                d = day_data(reports, m.group(1))
                md = reports / f"daily-{m.group(1)}.md"
                if not d or not md.is_file():
                    return self.send(404, "not found\n", "text/plain; charset=utf-8")
                if m.group(2):
                    return self.send(200, md.read_text(errors="replace"), "text/plain; charset=utf-8")
                return self.send(200, day_page(d, md.read_text(errors="replace")))
            if path == "/live":
                rep = cfg["report_mod"]
                d, _ = rep.collect(None, rep.load_state())  # in memory: no file and no state written
                return self.send(200, day_page(d, rep.render_md(d), live=True))
            if path == "/dashboard":
                f = reports.parent / "dashboard.html"
                if not f.is_file():
                    return self.send(404, "no dashboard.html yet (scripts/audit-dashboard.py)\n", "text/plain")
                return self.send(200, f.read_bytes())
        except (OSError, ValueError, KeyError) as e:
            return self.send(500, f"error: {esc(type(e).__name__)}\n", "text/plain; charset=utf-8")
        return self.send(404, "not found\n", "text/plain; charset=utf-8")


def main(argv):
    rep = load("daily_report", "daily-report.py")
    p = argparse.ArgumentParser(description="Local web app over the daily maintenance reports.")
    p.add_argument("--port", type=int, default=0, help="0 (default): any free port")
    p.add_argument("--no-open", action="store_true")
    p.add_argument("--reports", type=Path, default=rep.OUT)
    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", args.port), App)
    except OSError as e:
        print(f"maintenance-app: cannot listen on 127.0.0.1:{args.port} ({e.strerror}); leave out --port", file=sys.stderr)
        return 2
    port = srv.server_address[1]
    token = secrets.token_urlsafe(24)
    srv.cfg = {"token": token, "reports": args.reports, "report_mod": rep,
               "hosts": {f"127.0.0.1:{port}", f"localhost:{port}"}}
    url = f"http://127.0.0.1:{port}/?t={token}"
    print(f"maintenance-app: {url}  (Ctrl-C stops it)", flush=True)
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
