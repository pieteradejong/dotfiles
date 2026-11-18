#!/usr/bin/env python3
"""ci-status.py — does every own GitHub repo's CI actually pass on its default branch? (D79)

dotaudit checks that a workflow EXISTS (no-security-ci) and that it lints (workflow-lint); this
reads what GitHub ran. For each own, non-fork, non-archived repo it lists the active workflows and
the recent runs on the default branch, takes the newest completed run of each workflow (cancelled
and skipped runs do not count either way), and gives the repo one status:

  red     the newest counted run of at least one workflow failed (failure, timed_out,
          startup_failure, action_required). The row names the workflow, then each failed job
          and its first failed step.
  stale   it has active workflows but none has a counted run in the last CI_STALE_DAYS (90), or
          none at all: nobody knows whether it is still green.
  none    no active workflow file (dynamic GitHub-managed ones such as Pages do not count).
  green   otherwise.
  error   the GitHub API failed for this repo; the report is incomplete.

Read-only: GET requests through `gh api` with the token gh already holds; nothing is changed on
GitHub and no repo content is fetched. Skip-list `skip:` repos (private/audit/skiplist.conf) are
left out by name, like every other audit.

Usage:  scripts/ci-status.py                 markdown report on stdout
        scripts/ci-status.py --summary       LEVEL<TAB>text lines (security-audit.sh section 11):
                                             FAIL a red security workflow (name has security,
                                             gitleaks or codeql), WARN any other red repo or an
                                             API error, INFO the counts. No run dates, so a
                                             repo that stays red is not "new" every week
        scripts/ci-status.py --out DIR       also write ci-status-YYYY-MM-DD.md and .tsv, mode 600
                                             (refused inside a git repo)
        scripts/ci-status.py --only NAME     one repo (repeatable)
        scripts/ci-status.py -h | --help
Exit:   0 no red repo · 1 at least one red · 2 incomplete (an API error) or bad usage ·
        3 refused (--out inside a git repo)
Env:    GH (gh) · OWNER (pieteradejong) · CI_STALE_DAYS (90) · CI_WORKERS (8) · CI_RUNS (50:
        runs read per repo) · SKIPLIST_FILE · TODAY YYYY-MM-DD (for tests)
"""

import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GH = os.environ.get("GH", "gh")
OWNER = os.environ.get("OWNER", "pieteradejong")
STALE_DAYS = int(os.environ.get("CI_STALE_DAYS", "90"))
WORKERS = int(os.environ.get("CI_WORKERS", "8"))
RUNS = int(os.environ.get("CI_RUNS", "50"))
SKIPLIST = Path(os.environ.get("SKIPLIST_FILE") or REPO / "private" / "audit" / "skiplist.conf")
TODAY = date.fromisoformat(os.environ["TODAY"]) if os.environ.get("TODAY") else date.today()

RED = {"failure", "timed_out", "startup_failure", "action_required"}
IGNORED = {"cancelled", "skipped", "neutral", "stale", None, ""}
SECURITY_RE = re.compile(r"security|gitleaks|codeql", re.IGNORECASE)
ORDER = ("red", "error", "stale", "none", "green")


class ApiError(RuntimeError):
    pass


def gh_json(*args):
    try:
        r = subprocess.run([GH, *args], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ApiError(f"{GH} {' '.join(args[:2])}: {e}") from e
    if r.returncode != 0:
        raise ApiError(f"{GH} {' '.join(args[:2])}: exit {r.returncode}: {r.stderr.strip()[:200]}")
    try:
        return json.loads(r.stdout or "null")
    except json.JSONDecodeError as e:
        raise ApiError(f"{GH} {' '.join(args[:2])}: not JSON: {e}") from e


def skip_names():
    try:
        return {ln.split(":")[1] for ln in SKIPLIST.read_text().splitlines() if ln.startswith("skip:")}
    except (OSError, IndexError):
        return set()


def list_repos():
    rows = gh_json("repo", "list", OWNER, "--limit", "1000", "--source", "--no-archived",
                   "--json", "name,defaultBranchRef,isPrivate,isFork,isArchived")
    out = []
    for r in rows or []:
        if r.get("isFork") or r.get("isArchived"):
            continue
        branch = (r.get("defaultBranchRef") or {}).get("name") or ""
        out.append({"name": r["name"], "branch": branch,
                    "visibility": "private" if r.get("isPrivate") else "public"})
    return sorted(out, key=lambda r: r["name"].lower())


def day(ts):
    return datetime.strptime(ts[:10], "%Y-%m-%d").date() if ts else None


def failed_detail(name, run_id):
    """'job → step' for each failed job of a run, first failed step only."""
    jobs = gh_json("api", f"repos/{OWNER}/{name}/actions/runs/{run_id}/jobs?per_page=100")
    parts = []
    for j in (jobs or {}).get("jobs", []):
        if j.get("conclusion") not in RED:
            continue
        step = next((s.get("name") for s in j.get("steps") or [] if s.get("conclusion") in RED), "")
        parts.append(f"{j.get('name')} → {step}" if step else str(j.get("name")))
    return parts


def check_repo(repo):
    name, branch = repo["name"], repo["branch"]
    row = dict(repo, status="", detail="", last="", workflows=0)
    try:
        wfs = gh_json("api", f"repos/{OWNER}/{name}/actions/workflows?per_page=100")
        active = [w for w in (wfs or {}).get("workflows", [])
                  if w.get("state") == "active" and str(w.get("path", "")).startswith(".github/workflows/")]
        row["workflows"] = len(active)
        if not active:
            row["status"] = "none"
            return row
        if not branch:
            row.update(status="stale", detail="no default branch")
            return row
        runs = gh_json("api", f"repos/{OWNER}/{name}/actions/runs?branch={branch}&per_page={RUNS}"
                              "&exclude_pull_requests=true")
        newest = {}  # workflow_id -> newest counted run
        for run in (runs or {}).get("workflow_runs", []):
            if run.get("status") != "completed" or run.get("conclusion") in IGNORED:
                continue
            wid = run.get("workflow_id")
            if wid not in newest or run.get("created_at", "") > newest[wid].get("created_at", ""):
                newest[wid] = run
        ids = {w.get("id") for w in active}
        counted = [r for wid, r in newest.items() if wid in ids]
        if not counted:
            row.update(status="stale", detail="no completed run on " + branch)
            return row
        last = max(day(r.get("created_at")) for r in counted)
        row["last"] = last.isoformat()
        red = sorted((r for r in counted if r.get("conclusion") in RED), key=lambda r: r.get("name") or "")
        if red:
            bits = []
            for r in red:
                d = failed_detail(name, r["id"])
                bits.append(f"{r.get('name')} ({r.get('conclusion')}, {day(r.get('created_at'))}"
                            + (": " + "; ".join(d) if d else "") + ")")
            row.update(status="red", detail=" · ".join(bits),
                       security=any(SECURITY_RE.search(r.get("name") or "") for r in red))
        elif last < TODAY - timedelta(days=STALE_DAYS):
            row.update(status="stale", detail=f"newest run {last}, over {STALE_DAYS} days ago")
        else:
            row["status"] = "green"
    except ApiError as e:
        row.update(status="error", detail=str(e))
    return row


def counts(rows):
    n = {s: 0 for s in ORDER}
    for r in rows:
        n[r["status"]] += 1
    return n


def render_md(rows):
    n = counts(rows)
    out = [f"# CI status — {TODAY.isoformat()}", "",
           f"{len(rows)} own repos ({OWNER}, no forks, no archived): "
           + " · ".join(f"{n[s]} {s}" for s in ORDER if n[s]), "",
           ("What each status means and what to do: `dotfiles/docs/maintenance.md` § CI status. "
            "Made by `dotfiles/scripts/ci-status.py` (D79)."), ""]
    for status in ORDER:
        sel = [r for r in rows if r["status"] == status]
        if not sel or status == "green":
            continue
        out += [f"## {status} ({len(sel)})", "", "| Repo | Visibility | Last run | Detail |", "|---|---|---|---|"]
        for r in sel:
            detail = r["detail"].replace("|", "\\|")
            out.append(f"| {r['name']} | {r['visibility']} | {r['last'] or '—'} | {detail or '—'} |")
        out.append("")
    green = [r["name"] for r in rows if r["status"] == "green"]
    if green:
        out += [f"## green ({len(green)})", "", ", ".join(green), ""]
    return "\n".join(out)


def render_tsv(rows):
    lines = ["repo\tvisibility\tbranch\tstatus\tworkflows\tlast_run\tdetail"]
    for r in rows:
        lines.append("\t".join([r["name"], r["visibility"], r["branch"], r["status"], str(r["workflows"]),
                                r["last"], r["detail"].replace("\t", " ")]))
    return "\n".join(lines) + "\n"


def summary(rows):
    """Run dates are left out, so a workflow that stays red is 'unchanged' in the audit's diff."""
    n = counts(rows)
    lines = []
    for r in rows:
        if r["status"] == "red":
            detail = re.sub(r", \d{4}-\d{2}-\d{2}(?=[:)])", "", r["detail"])
            lines.append(("FAIL" if r.get("security") else "WARN") + f"\tCI red: {r['name']} — {detail}")
        elif r["status"] == "error":
            lines.append(f"WARN\tCI status unknown: {r['name']} — {r['detail']}")
    lines.append("INFO\tCI: " + " · ".join(f"{n[s]} {s}" for s in ORDER if n[s]) + f" (of {len(rows)} own repos)")
    return "\n".join(lines)


def inside_git(path):
    p = path.resolve()
    for d in (p, *p.parents):
        if (d / ".git").exists():
            return True
    return False


def write_out(outdir, rows):
    outdir = Path(outdir).expanduser()
    if inside_git(outdir):
        print(f"refused: {outdir} is inside a git repo — audit output never goes there", file=sys.stderr)
        return False
    outdir.mkdir(parents=True, exist_ok=True)
    for ext, text in (("md", render_md(rows) + "\n"), ("tsv", render_tsv(rows))):
        f = outdir / f"ci-status-{TODAY.isoformat()}.{ext}"
        fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(f, 0o600)
    return True


def main(argv):
    ap = argparse.ArgumentParser(prog="ci-status.py", add_help=True,
                                 description="Latest CI result on the default branch of every own GitHub repo.")
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--only", action="append", default=[])
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    if a.out and inside_git(Path(a.out).expanduser()):
        print(f"refused: {a.out} is inside a git repo — audit output never goes there", file=sys.stderr)
        return 3
    try:
        repos = list_repos()
    except ApiError as e:
        print(f"ci-status: cannot list repos: {e}", file=sys.stderr)
        if a.summary:
            print(f"WARN\tCI status not read: {e}")
        return 2
    skip = skip_names()
    repos = [r for r in repos if r["name"] not in skip]
    if a.only:
        unknown = sorted(set(a.only) - {r["name"] for r in repos})
        if unknown:
            print(f"ci-status: not an own, active repo: {', '.join(unknown)}", file=sys.stderr)
            return 2
        repos = [r for r in repos if r["name"] in a.only]
    with ThreadPoolExecutor(max_workers=max(1, WORKERS)) as ex:
        rows = list(ex.map(check_repo, repos))
    print(summary(rows) if a.summary else render_md(rows))
    if a.out and not write_out(a.out, rows):
        return 3
    n = counts(rows)
    return 2 if n["error"] else (1 if n["red"] else 0)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
