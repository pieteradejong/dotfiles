#!/usr/bin/env python3
"""daily-report.py — one markdown report a day of what the Mac's jobs did and what work was done.

Reads, never changes: the launchd register, `launchctl list`, each job's own log or report, the
git repos under ~/dev, the workspace's TODO / DECISIONS / CHANGELOG / SESSIONS / register files,
and the modification times of Claude Code transcripts. Writes two files (mode 600, directory 700):

  <out>/daily-YYYY-MM-DD.md     the report (markdown, Pieter's default format)
  <out>/daily-YYYY-MM-DD.json   the same data; the markdown is rendered from it, and
                                scripts/maintenance-app.py reads it

Sections: Needs action · Scheduled jobs · Administrative work · Git work · Claude sessions.
The window is the time since the previous report (state in $DAILY_STATE_DIR), else 24 h, so a
missed day is covered by the next run. Administrative work is a diff of the checkbox, decision,
changelog and register lines against the previous run's snapshot, because ~/dev itself is not a
git repo and uncommitted work counts too.

What it never does (D70): run a git command in a `skip:` repo of the audit skiplist; read a
repo's remote by running git (it parses .git/config); list file names from the backup report or
any transcript content; write inside a git repo; send anything off the Mac. The Google Drive copy
comes from the nightly ~/dev backup, which already syncs ~/dev/audit-reports/.

Usage:  scripts/daily-report.py                write the report, notify, update the state
        scripts/daily-report.py --stdout       print the markdown; write nothing, keep the state
        scripts/daily-report.py --json         print the JSON; write nothing, keep the state
        scripts/daily-report.py --summary      also print the one-line summary
        options: --out DIR  --since ISO  --no-notify  -h
Exit:   0 nothing needs action · 1 something needs action · 2 incomplete (a source unreadable,
        named in the report) or bad usage · 3 refused (output directory inside a git repo)
Env:    DEV_ROOT (~/dev) · DAILY_OUT (<DEV_ROOT>/audit-reports/daily) · DAILY_STATE_DIR
        (~/.cache/daily-report) · LAUNCHD_REGISTER · SKIPLIST_FILE · LAUNCHCTL (launchctl) ·
        LAUNCH_AGENTS_DIR · AUDIT_LOG · CLEANUP_LOG · BACKUP_REPORT · RCDEV_LOG_DIR ·
        CLAUDE_PROJECTS · GIT (git) · OWNER (pieteradejong) · NOTIFY_BIN · WEEKLY_CHECK_BIN ·
        NOW (ISO, for tests)
"""

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HOME = Path.home()
DEV_ROOT = Path(os.environ.get("DEV_ROOT") or HOME / "dev")
OUT = Path(os.environ.get("DAILY_OUT") or DEV_ROOT / "audit-reports" / "daily")
STATE_DIR = Path(os.environ.get("DAILY_STATE_DIR") or HOME / ".cache" / "daily-report")
REGISTER = Path(os.environ.get("LAUNCHD_REGISTER") or REPO / "private" / "registers" / "launchd.md")
SKIPLIST = Path(os.environ.get("SKIPLIST_FILE") or REPO / "private" / "audit" / "skiplist.conf")
LAUNCHCTL = os.environ.get("LAUNCHCTL", "launchctl")
AGENTS_DIR = Path(os.environ.get("LAUNCH_AGENTS_DIR") or HOME / "Library" / "LaunchAgents")
AUDIT_LOG = Path(os.environ.get("AUDIT_LOG") or HOME / "Library/Logs/security-audit/security-audit.log")
CLEANUP_LOG = Path(os.environ.get("CLEANUP_LOG") or HOME / ".weekly-disk-cleanup.log")
BACKUP_REPORT = Path(os.environ.get("BACKUP_REPORT") or HOME / "docs/.backup/reports/latest.md")
RCDEV_LOGS = Path(os.environ.get("RCDEV_LOG_DIR") or HOME / "Library/Logs/claude-remote-control")
CLAUDE_PROJECTS = Path(os.environ.get("CLAUDE_PROJECTS") or HOME / ".claude" / "projects")
GIT = os.environ.get("GIT", "git")
OWNER = os.environ.get("OWNER", "pieteradejong")
NOTIFY = os.environ.get("NOTIFY_BIN") or str(REPO / "bin" / "notify-local")
CHECK_BIN = os.environ.get("WEEKLY_CHECK_BIN") or str(REPO / "bin" / "weekly-cleanup-check")
PREFIX = "com.pieterdejong."
MAX_DEPTH = 4
PRUNE = {"node_modules", ".venv", "venv", "vendor", ".git", "__pycache__", "dist", "build", ".next"}
WEEKDAYS = ["mondays", "tuesdays", "wednesdays", "thursdays", "fridays", "saturdays", "sundays"]
ADMIN_FILES = ["TODO.md", "docs/TODO.md", "DECISIONS.md", "docs/DECISIONS.md", "docs/design-decisions.md",
               "CHANGELOG.md", "SESSIONS.md", "docs/SESSIONS.md"]
CUT = 160


def now():
    v = os.environ.get("NOW")
    return datetime.fromisoformat(v) if v else datetime.now().replace(microsecond=0)


def cut(s, n=CUT):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def rel(p):
    p = Path(p)
    for base, label in ((DEV_ROOT, "~/dev"), (HOME, "~")):
        try:
            r = p.relative_to(base)
            return label if str(r) == "." else f"{label}/{r}"
        except ValueError:
            pass
    return str(p)


def mtime(p):
    try:
        return datetime.fromtimestamp(Path(p).stat().st_mtime).replace(microsecond=0)
    except OSError:
        return None


def read(p):
    return Path(p).read_text(errors="replace")


def load_dashboard():
    """audit-dashboard.py's cleanup-log parser, reused rather than copied."""
    spec = importlib.util.spec_from_file_location("audit_dashboard", REPO / "scripts" / "audit-dashboard.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- scheduled jobs ---------------------------------------------------------------------------

def parse_register(path):
    """launchd.md § Agents table -> [{label, installed, trigger}] for our own agents."""
    rows = []
    for line in read(path).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        m = re.fullmatch(r"`([^`]+)`", cells[0])
        if m and m.group(1).startswith(PREFIX):
            rows.append({"label": m.group(1), "installed": cells[1].lower() == "yes", "trigger": cells[2]})
    return rows


def cadence(trigger):
    t = trigger.lower()
    if "keepalive" in t:
        return {"kind": "always"}
    m = re.search(r"(\d{1,2}):(\d{2})", t)
    hour, minute = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    for i, day in enumerate(WEEKDAYS):
        if day in t:
            return {"kind": "weekly", "weekday": i, "hour": hour, "minute": minute}
    if "daily" in t:
        return {"kind": "daily", "hour": hour, "minute": minute}
    if "watchpaths" in t or "every" in t:
        return {"kind": "watch"}
    return {"kind": "unknown"}


def due_in(cad, since, until):
    """The scheduled time that fell inside the window, or None."""
    if cad["kind"] not in ("daily", "weekly"):
        return None
    d = since.date()
    while d <= until.date():
        at = datetime(d.year, d.month, d.day, cad["hour"], cad["minute"])
        if since < at <= until and (cad["kind"] == "daily" or at.weekday() == cad["weekday"]):
            return at
        d += timedelta(days=1)
    return None


def launchctl_list():
    """label -> (pid or None, last exit int or None); None when launchctl can't be run."""
    try:
        r = subprocess.run([LAUNCHCTL, "list"], capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[2].startswith(PREFIX):
            pid = None if parts[0] == "-" else parts[0]
            try:
                code = int(parts[1])
            except ValueError:
                code = None
            out[parts[2]] = (pid, code)
    return out


def ev_audit():
    lines = [ln for ln in read(AUDIT_LOG).splitlines() if ln.strip()]
    f = lines[-1].split("\t")
    n = [int(re.match(r"\d+", x).group()) if re.match(r"\d+", x) else 0 for x in f[1:5]]
    ev = {"ran": datetime.strptime(f[0], "%Y-%m-%d %H:%M:%S"),
          "result": f"{n[0]} FAIL, {n[1]} WARN ({n[2]} new, {n[3]} resolved)", "ok_exit": {0, 1}}
    report = f[5] if len(f) > 5 else ""
    if report and not report.startswith(str(DEV_ROOT / "audit-reports")):
        ev["note"] = "the log's last line points at a report outside ~/dev/audit-reports (a test run?)"
    if n[2]:
        ev["act"] = f"security audit: {n[2]} new FAIL/WARN — read the report's 'Since last run'"
    return ev


def ev_cleanup():
    runs = load_dashboard().parse_cleanup_log(CLEANUP_LOG)
    if not runs:
        return {"ran": mtime(CLEANUP_LOG), "result": "no completed run in the log"}
    last = runs[-1]
    mb = sum(last["sections"].values()) / 1e6
    verdict = last["check"] or cleanup_check()  # runs from before the Self-check line: judge now
    ev = {"ran": mtime(CLEANUP_LOG), "result": f"{mb:,.0f} MB reclaimed, Self-check {verdict or 'n/a'}"}
    if verdict and verdict != "OK":
        ev["act"] = f"weekly cleanup Self-check: {verdict} — weekly-cleanup-check"
    return ev


def cleanup_check():
    """bin/weekly-cleanup-check's verdict on the log, the same one maintenance-status shows."""
    try:
        r = subprocess.run([CHECK_BIN], env=dict(os.environ, LOG_FILE=str(CLEANUP_LOG)),
                           capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    m = re.search(r"^Self-check: (.+)$", r.stdout, re.MULTILINE)
    return m.group(1).strip() if m else ""


def ev_backup():
    text = read(BACKUP_REPORT)
    m = re.search(r"^# Backup run (\d{4}-\d{2}-\d{2} \d{2}:\d{2})", text, re.MULTILINE)
    ev = {"ran": datetime.strptime(m.group(1), "%Y-%m-%d %H:%M") if m else mtime(BACKUP_REPORT)}
    targets, bad = [], []
    for line in text.splitlines():
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(c) >= 8 and c[1] in ("OK", "FAIL", "DRY"):
            targets.append(f"{c[0]} {c[1]}")
            if c[1] == "FAIL":
                bad.append(f"{c[0]} ({c[6]}, {c[7]} errors)")
    ev["result"] = ", ".join(targets) or "no target table"
    if bad:
        ev["failed"] = True
        ev["act"] = "docs backup failed: " + "; ".join(bad) + f" — {rel(BACKUP_REPORT)}"
    return ev


def ev_logfile(path, since):
    """Generic: activity in a job's own log, as counts only (never its lines: they hold file names)."""
    ran = mtime(path)
    if ran is None:
        return {"ran": None, "result": "no log yet"}
    n = errs = 0
    for line in read(path).splitlines():
        m = re.match(r"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})", line)
        if m and datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}") > since:
            n += 1
            errs += bool(re.search(r"\b(error|fail(ed)?|traceback)\b", line, re.IGNORECASE))
    res = f"{n} log line(s) in the window" + (f", {errs} with an error" if errs else "") if n else "no activity in the window"
    ev = {"ran": ran, "result": res}
    if errs:
        ev["act"] = f"{path.name}: {errs} error line(s) in the window — {rel(path)}"
    return ev


def stdout_path(label):
    try:
        with open(AGENTS_DIR / f"{label}.plist", "rb") as fh:
            p = plistlib.load(fh)
        return Path(p["StandardOutPath"]) if p.get("StandardOutPath") else None
    except (OSError, plistlib.InvalidFileException, KeyError, ValueError):
        return None


def job_status(row, lc, since, until, incomplete):
    label, short = row["label"], row["label"][len(PREFIX):]
    cad = cadence(row["trigger"])
    job = {"label": label, "name": short, "trigger": row["trigger"], "cadence": cad["kind"],
           "status": "ok", "last_exit": None, "last_run": None, "result": "", "note": ""}
    if not row["installed"]:
        job.update(status="pending", result="written, not installed (register)")
        return job, None
    if short == "dailyreport":
        job.update(status="ok", result="this report")
        return job, None
    pid, code = (lc or {}).get(label, (None, None))
    job["last_exit"] = code
    if lc is not None and label not in lc:
        job.update(status="failed", result="installed but not loaded (launchctl list)")
        return job, f"{short}: installed but not loaded"
    sources = {"securityaudit": (AUDIT_LOG, ev_audit), "weeklycleanup": (CLEANUP_LOG, ev_cleanup),
               "docsbackup": (BACKUP_REPORT, ev_backup)}
    try:
        if short in sources:
            src, fn = sources[short]
            ev = fn() if src.exists() else {"ran": None, "result": "no log yet"}
        elif short.startswith("rcdev"):
            log = RCDEV_LOGS / ("projects.log" if short.endswith("projects") else "dev.log")
            ev = {"ran": mtime(log), "result": "running" if pid else "not running"}
        else:
            out = stdout_path(label)
            ev = ev_logfile(out, since) if out else {"ran": None, "result": "no StandardOutPath in its plist"}
    except (OSError, ValueError, IndexError, AttributeError) as e:
        incomplete.append(f"{short} log ({type(e).__name__})")
        ev = {"ran": None, "result": "log unreadable"}
    job["last_run"] = ev["ran"].isoformat(sep=" ") if ev.get("ran") else None
    job["result"], job["note"] = ev.get("result", ""), ev.get("note", "")
    # A finding from a run before the window was reported the day it happened; don't repeat it daily.
    act = ev.get("act") if ev.get("ran") and ev["ran"] > since else None
    due = due_in(cad, since, until)
    if cad["kind"] == "always":
        if not pid:
            job["status"] = "failed"
            act = act or f"{short}: not running (KeepAlive job)"
        else:
            job["status"] = "running"
    elif ev.get("failed") or (pid is None and code not in (None, 0) and code not in ev.get("ok_exit", {0})):
        job["status"] = "failed"
        act = act or f"{short}: last run exited {code}"
    elif due and not (ev.get("ran") and ev["ran"] >= due - timedelta(minutes=5)):
        job["status"] = "missing"
        act = act or f"{short}: due {due:%a %H:%M} but no run since"
    elif cad["kind"] == "weekly" and not due:
        job["status"] = "not due"
    elif cad["kind"] == "watch" and ev["result"].startswith("no activity"):
        job["status"] = "idle"
    return job, act


# --- repos ------------------------------------------------------------------------------------

def skip_names():
    try:
        return {ln.split(":")[1] for ln in read(SKIPLIST).splitlines() if ln.startswith("skip:")}
    except OSError:
        return set()


def origin_owner(repo):
    """The owner in [remote "origin"] url, from .git/config — no git command."""
    try:
        cfg = read(repo / ".git" / "config")
    except OSError:
        return ""
    m = re.search(r'\[remote "origin"\][^\[]*?url\s*=\s*(\S+)', cfg)
    if not m:
        return ""
    url = re.sub(r"^git@[^:]+:", "", m.group(1))
    url = re.sub(r"^[a-z+]+://[^/]+/", "", url)
    return url.split("/")[0]


def find_repos(skip):
    """Own repos (origin owner = OWNER) under DEV_ROOT, depth-limited; never enters a skip repo."""
    own, others = [], 0
    root_depth = len(DEV_ROOT.parts)
    for d, dirs, _ in os.walk(DEV_ROOT):
        p = Path(d)
        dirs[:] = sorted(x for x in dirs if x not in PRUNE and x not in skip and not x.startswith("._"))
        if len(p.parts) - root_depth >= MAX_DEPTH:
            dirs[:] = []
        if (p / ".git").is_dir():
            if origin_owner(p) == OWNER:
                own.append(p)
            else:
                others += 1
    return own, others


def git(repo, *args):
    r = subprocess.run([GIT, "--no-optional-locks", "-C", str(repo), *args],
                       capture_output=True, text=True, timeout=30, check=False)
    return r.stdout if r.returncode == 0 else ""


def repo_state(repo, since):
    branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD").strip() or "?"
    log = git(repo, "log", "--branches", f"--since={since.isoformat()}", "--pretty=%h%x09%s")
    commits = [{"sha": a, "subject": cut(b)} for a, _, b in (ln.partition("\t") for ln in log.splitlines()) if a]
    dirty = len([ln for ln in git(repo, "status", "--porcelain").splitlines() if ln.strip()])
    unpushed = git(repo, "rev-list", "--count", "--branches", "--not", "--remotes").strip()
    return {"repo": rel(repo), "branch": branch, "commits": commits, "dirty": dirty,
            "unpushed": int(unpushed) if unpushed.isdigit() else 0}


# --- administrative work ----------------------------------------------------------------------

def admin_files(repos):
    files = []
    for base in [DEV_ROOT, *repos]:
        files += [base / f for f in ADMIN_FILES if (base / f).is_file()]
        files += sorted((base / "registers").glob("*.md")) if (base / "registers").is_dir() else []
    return sorted(set(files))


def extract(path):
    """The lines the report diffs, per kind. Keys are the normalised line text."""
    text = read(path)
    name = path.name
    out = {"todo_open": [], "todo_done": [], "decisions": {}, "changelog": [], "changes": [],
           "sha": hashlib.sha256(text.encode()).hexdigest(), "lines": len(text.splitlines())}
    if name == "TODO.md":
        for m in re.finditer(r"^\s*- \[([ xX])\] (.+)$", text, re.MULTILINE):
            (out["todo_done"] if m.group(1) in "xX" else out["todo_open"]).append(cut(m.group(2), 300))
    elif name in ("DECISIONS.md", "design-decisions.md"):
        heads = list(re.finditer(r"^#{2,3} (.+)$", text, re.MULTILINE))
        for i, m in enumerate(heads):
            body = text[m.end(): heads[i + 1].start() if i + 1 < len(heads) else len(text)]
            # "**Verified.**" = yes; "**Verified: PARTIAL.**" / "Verified: NOT YET" = that word.
            v = re.search(r"Verified(?::\**\s*([A-Za-z][A-Za-z ]*?))?\s*[.*\n(]", body)
            out["decisions"][cut(m.group(1))] = ((v.group(1) or "yes").strip()) if v else ""
        for m in re.finditer(r"^\| *(D?\d+) *\| *([^|]+)\|", text, re.MULTILINE):
            out["decisions"][cut(f"{m.group(1)} · {m.group(2).strip()}")] = ""
    elif name == "CHANGELOG.md":
        m = re.search(r"^## \[Unreleased\]\s*$(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
        if m:
            out["changelog"] = [cut(x) for x in re.findall(r"^\s*- (.+)$", m.group(1), re.MULTILINE)]
    if path.parent.name == "registers":
        m = re.search(r"^## Changes\s*$(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
        if m:
            out["changes"] = [cut(x) for x in re.findall(r"^- (.+)$", m.group(1), re.MULTILINE)]
    return out


def diff_admin(files, prev, window_dates):
    admin = {"decisions": [], "changelog": [], "registers": [], "todo_opened": [], "todo_ticked": [],
             "baseline": not prev}
    snap = {}
    for f in files:
        try:
            cur = extract(f)
        except OSError:
            continue
        key = str(f)
        snap[key] = cur
        old = prev.get(key)
        shown = rel(f)
        if old is None and prev:
            old = {"todo_open": [], "todo_done": [], "decisions": {}, "changelog": [], "changes": [],
                   "sha": "", "lines": 0}
        if old is None:  # first run ever: only what is dated inside the window
            for h, v in cur["decisions"].items():
                if any(d in h for d in window_dates):
                    admin["decisions"].append({"file": shown, "title": h, "verified": v})
            continue
        for h, v in cur["decisions"].items():
            if h not in old["decisions"]:
                admin["decisions"].append({"file": shown, "title": h, "verified": v})
        admin["changelog"] += [{"file": shown, "line": x} for x in cur["changelog"] if x not in old["changelog"]]
        new_changes = [x for x in cur["changes"] if x not in old["changes"]]
        admin["registers"] += [{"file": shown, "line": x} for x in new_changes]
        if f.parent.name == "registers" and cur["sha"] != old["sha"] and not new_changes:
            admin["registers"].append({"file": shown, "line": f"edited ({old['lines']} → {cur['lines']} lines)"})
        prev_all = set(old["todo_open"]) | set(old["todo_done"])
        new_open = [x for x in cur["todo_open"] if x not in prev_all]
        new_done = [x for x in cur["todo_done"] if x not in prev_all]
        ticked = [x for x in cur["todo_done"] if x in old["todo_open"]]
        vanished_open = [x for x in old["todo_open"] if x not in cur["todo_open"] and x not in cur["todo_done"]]
        ticked += new_done[: len(vanished_open)]  # a tick that also reworded the line
        admin["todo_opened"] += [{"file": shown, "item": cut(x)} for x in new_open]
        admin["todo_ticked"] += [{"file": shown, "item": cut(x)} for x in ticked]
    return admin, snap


# --- Claude sessions --------------------------------------------------------------------------

def session_logs(files, window_dates):
    out = []
    for f in files:
        if f.name != "SESSIONS.md":
            continue
        lines = read(f).splitlines()
        for i, ln in enumerate(lines):
            m = re.match(r"^## (\d{4}-\d{2}-\d{2}) [—-] (.+)$", ln)
            if m and m.group(1) in window_dates:
                first = next((x for x in lines[i + 1:] if x.strip()), "")
                out.append({"file": rel(f), "date": m.group(1), "title": cut(m.group(2)),
                            "first": cut(re.sub(r"\*\*", "", first)) if not first.startswith("## ") else ""})
    return out


def claude_sessions(since):
    """Transcripts touched in the window, counted per project directory. Never opened."""
    counts = {}
    if not CLAUDE_PROJECTS.is_dir():
        return []
    for d in CLAUDE_PROJECTS.iterdir():
        if not d.is_dir():
            continue
        n = sum(1 for t in d.glob("*.jsonl") if (mtime(t) or since) > since)
        if n:
            # "-Users-me-dev-projects" -> "~/dev/projects", kept only when that path exists
            # (a hyphen in a project name decodes ambiguously; then the raw name is shown).
            guess = "/" + d.name.lstrip("-").replace("-", "/")
            name = rel(guess) if Path(guess).is_dir() else d.name
            counts[name] = counts.get(name, 0) + n
    return [{"project": k, "sessions": v} for k, v in sorted(counts.items(), key=lambda kv: -kv[1])]


# --- assemble ---------------------------------------------------------------------------------

def collect(since=None, state=None):
    until = now()
    state = state if state is not None else load_state()
    if since is None:
        last = state.get("until")
        since = datetime.fromisoformat(last) if last else until - timedelta(hours=24)
    window_dates, d = [], since.date()
    while d <= until.date():
        window_dates.append(d.isoformat())
        d += timedelta(days=1)
    incomplete, act = [], []

    try:
        rows = parse_register(REGISTER)
    except OSError:
        rows = []
        incomplete.append("launchd register")
    lc = launchctl_list()
    if lc is None:
        incomplete.append("launchctl list")
    if not rows and lc:
        rows = [{"label": k, "installed": True, "trigger": ""} for k in sorted(lc)]
    jobs = []
    for row in rows:
        job, a = job_status(row, lc, since, until, incomplete)
        jobs.append(job)
        if a:
            act.append(a)

    skip = skip_names()
    repos, n_other = find_repos(skip)
    # Git work is today's commits. Standing dirty/unpushed state is the weekly dotaudit's job, so it
    # is only counted here; fresh commits not yet on GitHub are flagged.
    git_rows, standing = [], {"dirty": 0, "unpushed": 0}
    for r in repos:
        try:
            st = repo_state(r, since)
        except (OSError, subprocess.TimeoutExpired):
            incomplete.append(f"git in {rel(r)}")
            continue
        standing["dirty"] += bool(st["dirty"])
        standing["unpushed"] += bool(st["unpushed"])
        if st["commits"]:
            git_rows.append(st)
    fresh = [g for g in git_rows if g["unpushed"]]
    if fresh:
        act.append(f"today's commits not on GitHub yet in {len(fresh)} repo(s): "
                   + ", ".join(f"{g['repo']} ({g['unpushed']} unpushed)" for g in fresh[:6])
                   + (" …" if len(fresh) > 6 else ""))

    files = admin_files(repos)
    admin, snap = diff_admin(files, state.get("snapshot") or {}, window_dates)
    sessions = {"logs": session_logs(files, window_dates), "claude": claude_sessions(since)}
    if incomplete:
        act.append("report incomplete: " + ", ".join(incomplete))
    data = {
        "date": until.date().isoformat(), "generated": until.isoformat(sep=" "),
        "window": {"since": since.isoformat(sep=" "), "until": until.isoformat(sep=" ")},
        "needs_action": act, "incomplete": incomplete, "jobs": jobs, "admin": admin, "git": git_rows,
        "repos_scanned": len(repos), "repos_not_own": n_other, "repos_skipped": sorted(skip),
        "standing": standing,
        "sessions": sessions,
    }
    data["counts"] = counts(data)
    return data, snap


def counts(d):
    a = d["admin"]
    return {"needs_action": len(d["needs_action"]),
            "jobs_ok": sum(j["status"] in ("ok", "running", "not due", "idle") for j in d["jobs"]),
            "jobs_bad": sum(j["status"] in ("failed", "missing") for j in d["jobs"]),
            "decisions": len(a["decisions"]), "changelog": len(a["changelog"]), "registers": len(a["registers"]),
            "todo_opened": len(a["todo_opened"]), "todo_ticked": len(a["todo_ticked"]),
            "commits": sum(len(g["commits"]) for g in d["git"]),
            "claude_sessions": sum(s["sessions"] for s in d["sessions"]["claude"]),
            "session_logs": len(d["sessions"]["logs"])}


def summary(d):
    c = d["counts"]
    head = f"{c['needs_action']} to act on" if c["needs_action"] else "nothing to act on"
    return (f"{head} · jobs {c['jobs_ok']} ok, {c['jobs_bad']} failed/missing · "
            f"{c['decisions']} decisions, {c['todo_ticked']} TODO ticked, {c['todo_opened']} opened · "
            f"{c['commits']} commits · {c['claude_sessions']} Claude sessions")


# --- markdown ---------------------------------------------------------------------------------

def md_cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def render_md(d):
    c, a = d["counts"], d["admin"]
    L = [f"# Daily report — {d['date']}", "",
         (f"Window: {d['window']['since']} → {d['window']['until']}. Made by `dotfiles/scripts/daily-report.py` "
         "(D70); read-only. Visualised by `maintenance-app`."), "", f"**{summary(d)}**", "", "## Needs action", ""]
    L += [f"- {x}" for x in d["needs_action"]] or ["Nothing."]
    L += ["", "## Scheduled jobs", "", "| Job | Schedule | Status | Last run | Exit | Result |", "|---|---|---|---|---|---|"]
    for j in d["jobs"]:
        res = j["result"] + (f" — {j['note']}" if j["note"] else "")
        L.append(f"| `{j['name']}` | {md_cell(j['trigger'])} | {j['status']} | {j['last_run'] or '—'} | "
                 f"{'—' if j['last_exit'] is None else j['last_exit']} | {md_cell(res)} |")
    if not d["jobs"]:
        L.append("| — | — | — | — | — | no jobs found |")
    L += ["", "## Administrative work", ""]
    if a["baseline"]:
        L += [("First run: the snapshot was recorded now, so TODO, CHANGELOG and register changes are "
              "reported from the next run on. Decisions below are those dated inside the window."), ""]
    L += [(f"Decisions {c['decisions']} · CHANGELOG lines {c['changelog']} · register changes {c['registers']} · "
          f"TODO opened {c['todo_opened']}, ticked {c['todo_ticked']}"), ""]
    for title, key, fmt in (
        ("Decisions", "decisions", lambda x: f"{x['title']}" + (f" — Verified: {x['verified']}" if x["verified"] else "")),
        ("TODO ticked", "todo_ticked", lambda x: x["item"]),
        ("TODO opened", "todo_opened", lambda x: x["item"]),
        ("CHANGELOG [Unreleased]", "changelog", lambda x: x["line"]),
        ("Registers", "registers", lambda x: x["line"]),
    ):
        if a[key]:
            L += [f"### {title}", ""] + [f"- `{x['file']}`: {fmt(x)}" for x in a[key]] + [""]
    L += ["## Git work", "",
          (f"{d['repos_scanned']} own repos scanned; {d['repos_not_own']} with another owner left out; "
          f"skip-listed (no git run): {', '.join(d['repos_skipped']) or 'none'}. Standing state (the weekly "
          f"dotaudit covers it): {d['standing']['dirty']} with uncommitted changes, "
          f"{d['standing']['unpushed']} with unpushed commits."), ""]
    if d["git"]:
        L += ["| Repo | Branch | Commits | Dirty | Unpushed |", "|---|---|---|---|---|"]
        L += [f"| `{g['repo']}` | `{g['branch']}` | {len(g['commits'])} | {g['dirty']} | {g['unpushed']} |" for g in d["git"]]
        L.append("")
        for g in d["git"]:
            if g["commits"]:
                L += [f"**{g['repo']}**", ""] + [f"- `{x['sha']}` {x['subject']}" for x in g["commits"]] + [""]
    else:
        L += ["No commits in the window.", ""]
    s = d["sessions"]
    L += ["## Claude sessions", ""]
    L += [f"- `{x['file']}` {x['date']} — {x['title']}" + (f": {x['first']}" if x["first"] else "") for x in s["logs"]] \
        or ["No session-log entries dated in the window."]
    L += ["", f"Transcripts touched in the window (counts only): {c['claude_sessions']}", ""]
    L += [f"- `{x['project']}`: {x['sessions']}" for x in s["claude"]]
    return "\n".join(L).rstrip() + "\n"


# --- state and output -------------------------------------------------------------------------

def load_state():
    try:
        return json.loads((STATE_DIR / "state.json").read_text())
    except (OSError, ValueError):
        return {}


def write_private(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def inside_git_repo(directory):
    d = Path(directory)
    while not d.exists():
        d = d.parent
    try:
        r = subprocess.run([GIT, "--no-optional-locks", "-C", str(d), "rev-parse", "--git-dir"],
                           capture_output=True, check=False)
    except FileNotFoundError:
        return False
    return r.returncode == 0


def main(argv):
    p = argparse.ArgumentParser(description="Write the daily maintenance and work report (markdown + JSON).")
    p.add_argument("--out", type=Path, default=OUT)
    p.add_argument("--since", help="window start, ISO (default: the previous report, else 24 h)")
    p.add_argument("--stdout", action="store_true", help="print the markdown; write nothing")
    p.add_argument("--json", action="store_true", help="print the JSON; write nothing")
    p.add_argument("--summary", action="store_true", help="print the one-line summary")
    p.add_argument("--no-notify", action="store_true")
    try:
        args = p.parse_args(argv)
        since = datetime.fromisoformat(args.since) if args.since else None
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    except ValueError:
        print(f"daily-report: --since is not an ISO date/time: {args.since}", file=sys.stderr)
        return 2
    dry = args.stdout or args.json
    if not dry and inside_git_repo(args.out):
        print(f"daily-report: refusing to write inside a git repo: {args.out}", file=sys.stderr)
        return 3
    state = load_state()
    data, snap = collect(since, state)
    if args.json:
        print(json.dumps(data, indent=2))
    elif args.stdout:
        print(render_md(data), end="")
    else:
        base = args.out / f"daily-{data['date']}"
        write_private(base.with_suffix(".json"), json.dumps(data, indent=2) + "\n")
        write_private(base.with_suffix(".md"), render_md(data))
        write_private(STATE_DIR / "state.json", json.dumps({"until": data["window"]["until"].replace(" ", "T"),
                                                            "snapshot": snap}) + "\n")
        print(f"Daily report: {base}.md")
        if not args.no_notify and os.access(NOTIFY, os.X_OK):
            subprocess.run([NOTIFY, "Daily report", summary(data)], check=False, timeout=20)
    if args.summary:
        print(summary(data))
    if data["incomplete"]:
        return 2
    return 1 if data["needs_action"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
