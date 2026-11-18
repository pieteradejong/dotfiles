#!/usr/bin/env python3
"""test-ci-status.py — tests for scripts/ci-status.py.

Hermetic: a stub `gh` on GH answers `gh repo list` and `gh api <path>` from fixture JSON in a temp
dir and logs every call, so nothing reaches GitHub. Repo names are invented. One test asserts every
call the script made was a read (`repo list`, or `api` with no method, field or input flag).

Usage:  scripts/test-ci-status.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "ci-status.py"
OWNER = "octo-test"

STUB = r'''#!/usr/bin/env python3
import json, os, sys, urllib.parse
d = os.environ["FIX"]
with open(os.path.join(d, "calls.log"), "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
a = sys.argv[1:]
if a[:2] == ["repo", "list"]:
    key = "repo-list"
elif a and a[0] == "api":
    key = "api-" + urllib.parse.quote(a[1], safe="")
else:
    sys.stderr.write("stub gh: unexpected " + " ".join(a)); sys.exit(4)
p = os.path.join(d, key + ".json")
e = os.path.join(d, key + ".err")
if os.path.exists(e):
    sys.stderr.write(open(e).read()); sys.exit(1)
if not os.path.exists(p):
    sys.stderr.write("HTTP 404: Not Found (" + key + ")"); sys.exit(1)
sys.stdout.write(open(p).read())
'''


def run(wid, name, conclusion, created, status="completed", rid=None):
    return {"id": rid or abs(hash((wid, created, conclusion))) % 10**9, "workflow_id": wid, "name": name,
            "status": status, "conclusion": conclusion, "created_at": created + "T06:00:00Z"}


def wf(wid, name, path=None, state="active"):
    return {"id": wid, "name": name, "state": state, "path": path or f".github/workflows/{wid}.yml"}


class CiStatus(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name).resolve()
        self.fix = self.d / "fix"
        self.fix.mkdir()
        gh = self.d / "gh"
        gh.write_text(STUB)
        gh.chmod(0o755)
        self.gh = gh
        self.skip = self.d / "skiplist.conf"
        self.skip.write_text("# test\n")
        self.repos = []

    def tearDown(self):
        self.tmp.cleanup()

    # --- fixture helpers ------------------------------------------------------------------------
    def put(self, key, obj):
        (self.fix / (key + ".json")).write_text(json.dumps(obj))

    def api(self, path, obj):
        self.put("api-" + urllib.parse.quote(path, safe=""), obj)

    def api_err(self, path, msg="HTTP 502: Bad Gateway"):
        (self.fix / ("api-" + urllib.parse.quote(path, safe="") + ".err")).write_text(msg)

    def repo(self, name, workflows, runs=(), branch="main", private=True, fork=False, archived=False, jobs=None):
        self.repos.append({"name": name, "defaultBranchRef": {"name": branch} if branch else None,
                           "isPrivate": private, "isFork": fork, "isArchived": archived})
        self.put("repo-list", self.repos)
        self.api(f"repos/{OWNER}/{name}/actions/workflows?per_page=100", {"workflows": list(workflows)})
        self.api(f"repos/{OWNER}/{name}/actions/runs?branch={branch}&per_page=50&exclude_pull_requests=true",
                 {"workflow_runs": list(runs)})
        for rid, js in (jobs or {}).items():
            self.api(f"repos/{OWNER}/{name}/actions/runs/{rid}/jobs?per_page=100", {"jobs": js})

    def go(self, *args, **env):
        e = dict(os.environ, GH=str(self.gh), FIX=str(self.fix), OWNER=OWNER, TODAY="2026-11-17",
                 SKIPLIST_FILE=str(self.skip), CI_WORKERS="3")
        e.update(env)
        return subprocess.run([sys.executable, str(SCRIPT), *args], check=False, capture_output=True, text=True,
                              env=e, timeout=60, cwd=self.d)

    def rows(self, *args):
        out = self.d / "out"
        r = self.go("--out", str(out), *args)
        tsv = (out / "ci-status-2026-11-17.tsv").read_text().splitlines()
        cols = tsv[0].split("\t")
        return r, {x["repo"]: x for x in (dict(zip(cols, ln.split("\t"))) for ln in tsv[1:])}

    def calls(self):
        p = self.fix / "calls.log"
        return [json.loads(ln) for ln in p.read_text().splitlines()] if p.exists() else []

    # --- statuses -------------------------------------------------------------------------------
    def test_green(self):
        self.repo("alpha", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-16")])
        r, rows = self.rows()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(rows["alpha"]["status"], "green")
        self.assertEqual(rows["alpha"]["last_run"], "2026-11-16")

    def test_red_names_workflow_failed_jobs_and_first_failed_step(self):
        self.repo("beta", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-16", rid=77)], jobs={77: [
            {"name": "tests", "conclusion": "failure", "steps": [
                {"name": "checkout", "conclusion": "success"},
                {"name": "Test suite", "conclusion": "failure"},
                {"name": "after", "conclusion": "failure"}]},
            {"name": "lint", "conclusion": "success", "steps": []},
            {"name": "scaffold", "conclusion": "timed_out", "steps": [{"name": "Scaffold test", "conclusion": "timed_out"}]},
        ]})
        r, rows = self.rows()
        self.assertEqual(r.returncode, 1)
        b = rows["beta"]
        self.assertEqual(b["status"], "red")
        self.assertIn("CI (failure, 2026-11-16: tests → Test suite; scaffold → Scaffold test)", b["detail"])
        self.assertNotIn("lint", b["detail"])
        self.assertNotIn("after", b["detail"])

    def test_red_without_job_detail_still_red(self):
        self.repo("gamma", [wf(1, "test")], [run(1, "test", "startup_failure", "2026-11-03", rid=5)], jobs={5: []})
        _, rows = self.rows()
        self.assertEqual(rows["gamma"]["status"], "red")
        self.assertIn("test (startup_failure, 2026-11-03)", rows["gamma"]["detail"])

    def test_every_red_conclusion_counts(self):
        for i, c in enumerate(("failure", "timed_out", "startup_failure", "action_required")):
            self.repo(f"r{i}", [wf(1, "CI")], [run(1, "CI", c, "2026-11-10", rid=100 + i)], jobs={100 + i: []})
        _, rows = self.rows()
        self.assertEqual({rows[f"r{i}"]["status"] for i in range(4)}, {"red"})

    def test_newer_success_supersedes_older_failure(self):
        self.repo("delta", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-01"), run(1, "CI", "success", "2026-11-02")])
        _, rows = self.rows()
        self.assertEqual(rows["delta"]["status"], "green")

    def test_newer_failure_beats_older_success_whatever_the_list_order(self):
        self.repo("delta2", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-01"),
                                             run(1, "CI", "failure", "2026-11-02", rid=9)], jobs={9: []})
        _, rows = self.rows()
        self.assertEqual(rows["delta2"]["status"], "red")

    def test_cancelled_and_skipped_runs_are_ignored(self):
        self.repo("eps", [wf(1, "CI")], [run(1, "CI", "cancelled", "2026-11-05"), run(1, "CI", "skipped", "2026-11-04"),
                                          run(1, "CI", "success", "2026-11-03")])
        self.repo("eps2", [wf(1, "CI")], [run(1, "CI", "cancelled", "2026-11-05"),
                                           run(1, "CI", "failure", "2026-11-03", rid=11)], jobs={11: []})
        _, rows = self.rows()
        self.assertEqual(rows["eps"]["status"], "green")
        self.assertEqual(rows["eps2"]["status"], "red")

    def test_in_progress_run_does_not_hide_the_last_result(self):
        self.repo("zeta", [wf(1, "CI")], [run(1, "CI", None, "2026-11-17", status="in_progress"),
                                           run(1, "CI", "failure", "2026-11-16", rid=12)], jobs={12: []})
        _, rows = self.rows()
        self.assertEqual(rows["zeta"]["status"], "red")

    def test_one_red_workflow_among_green_ones_is_red_and_named_alone(self):
        # The case the one-latest-run survey missed: a newer green run of another workflow hid it.
        self.repo("eta", [wf(1, "Python CI"), wf(2, "security")],
                  [run(2, "security", "success", "2026-10-22"), run(1, "Python CI", "failure", "2026-10-21", rid=13)],
                  jobs={13: [{"name": "build", "conclusion": "failure", "steps": [{"name": "Run pytest", "conclusion": "failure"}]}]})
        _, rows = self.rows()
        self.assertEqual(rows["eta"]["status"], "red")
        self.assertIn("Python CI (failure", rows["eta"]["detail"])
        self.assertNotIn("security", rows["eta"]["detail"])

    def test_disabled_deleted_and_dynamic_workflows_do_not_count(self):
        self.repo("theta", [wf(1, "CI"), wf(2, "old", state="disabled_manually"),
                            wf(3, "pages", path="dynamic/pages/pages-build-deployment")],
                  [run(1, "CI", "success", "2026-11-10"), run(2, "old", "failure", "2026-11-11"),
                   run(3, "pages", "failure", "2026-11-12"), run(99, "deleted", "failure", "2026-11-13")])
        _, rows = self.rows()
        self.assertEqual(rows["theta"]["status"], "green")
        self.assertEqual(rows["theta"]["workflows"], "1")

    def test_none_when_no_workflow_or_only_dynamic_ones(self):
        self.repo("iota", [])
        self.repo("kappa", [wf(3, "Dependency Graph", path="dynamic/dependabot/update-graph")])
        r, rows = self.rows()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(rows["iota"]["status"], "none")
        self.assertEqual(rows["kappa"]["status"], "none")

    def test_stale_never_ran_ran_long_ago_or_no_default_branch(self):
        self.repo("lam", [wf(1, "CI")], [])
        self.repo("mu", [wf(1, "CI")], [run(1, "CI", "success", "2026-08-01")])    # 108 days
        self.repo("mu2", [wf(1, "CI")], [run(1, "CI", "success", "2026-08-20")])   # 89 days: still green
        self.repo("nu", [wf(1, "CI")], branch=None)
        _, rows = self.rows()
        self.assertEqual(rows["lam"]["status"], "stale")
        self.assertIn("no completed run on main", rows["lam"]["detail"])
        self.assertEqual(rows["mu"]["status"], "stale")
        self.assertIn("over 90 days", rows["mu"]["detail"])
        self.assertEqual(rows["mu2"]["status"], "green")
        self.assertEqual(rows["nu"]["status"], "stale")

    def test_stale_days_is_configurable(self):
        self.repo("mu", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-01")])
        r = self.go("--summary", CI_STALE_DAYS="7")
        self.assertIn("1 stale", r.stdout)

    def test_an_old_red_run_stays_red_not_stale(self):
        self.repo("xi", [wf(1, "CI")], [run(1, "CI", "failure", "2026-01-01", rid=14)], jobs={14: []})
        _, rows = self.rows()
        self.assertEqual(rows["xi"]["status"], "red")

    def test_default_branch_is_used_for_runs(self):
        self.repo("omi", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-10")], branch="master")
        _, rows = self.rows()
        self.assertEqual(rows["omi"]["status"], "green")
        self.assertTrue(any("branch=master" in " ".join(c) for c in self.calls()))

    # --- scope ----------------------------------------------------------------------------------
    def test_forks_archived_and_skiplist_repos_are_left_out(self):
        self.repo("mine", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-10")])
        self.repo("forked", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-10")], fork=True)
        self.repo("old", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-10")], archived=True)
        self.repo("secret-family", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-10")])
        self.skip.write_text("skip:secret-family:do-not-touch\nfork:mine:not a skip row\n")
        r, rows = self.rows()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(set(rows), {"mine"})
        self.assertNotIn("secret-family", r.stdout)
        touched = " ".join(" ".join(c) for c in self.calls())
        for absent in ("forked", "old", "secret-family"):
            self.assertNotIn(f"/{absent}/", touched, f"{absent} was queried")

    def test_repo_list_asks_for_sources_only_and_no_archived(self):
        self.repo("a", [])
        self.go()
        first = self.calls()[0]
        self.assertEqual(first[:3], ["repo", "list", OWNER])
        self.assertIn("--source", first)
        self.assertIn("--no-archived", first)

    def test_missing_skiplist_is_not_fatal(self):
        self.repo("a", [])
        r = self.go(SKIPLIST_FILE=str(self.d / "nope.conf"))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_only(self):
        self.repo("a", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-10")])
        self.repo("b", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-10", rid=3)], jobs={3: []})
        r = self.go("--only", "a")
        self.assertEqual(r.returncode, 0)
        self.assertIn("1 own repos", r.stdout)
        self.assertFalse(any("/b/" in " ".join(c) for c in self.calls()))
        self.assertEqual(self.go("--only", "a", "--only", "b").returncode, 1)
        u = self.go("--only", "nope")
        self.assertEqual(u.returncode, 2)
        self.assertIn("not an own, active repo: nope", u.stderr)

    # --- errors ---------------------------------------------------------------------------------
    def test_api_error_for_one_repo_is_error_exit_2_and_others_still_reported(self):
        self.repo("ok", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-10")])
        self.repo("broken", [wf(1, "CI")], [])
        self.api_err(f"repos/{OWNER}/broken/actions/runs?branch=main&per_page=50&exclude_pull_requests=true")
        r, rows = self.rows()
        self.assertEqual(r.returncode, 2)
        self.assertEqual(rows["ok"]["status"], "green")
        self.assertEqual(rows["broken"]["status"], "error")
        self.assertIn("502", rows["broken"]["detail"])
        s = self.go("--summary")
        self.assertIn("WARN\tCI status unknown: broken", s.stdout)

    def test_jobs_api_error_marks_the_repo_error_not_green(self):
        self.repo("j", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-10", rid=8)])   # no jobs fixture
        _, rows = self.rows()
        self.assertEqual(rows["j"]["status"], "error")

    def test_non_json_answer_is_an_error(self):
        self.repo("nj", [wf(1, "CI")], [])
        (self.fix / ("api-" + urllib.parse.quote(f"repos/{OWNER}/nj/actions/workflows?per_page=100", safe="") + ".json")).write_text("<html>")
        _, rows = self.rows()
        self.assertEqual(rows["nj"]["status"], "error")
        self.assertIn("not JSON", rows["nj"]["detail"])

    def test_repo_list_failure_is_exit_2_with_a_warn_summary(self):
        (self.fix / "repo-list.err").write_text("gh: not logged in")
        r = self.go("--summary")
        self.assertEqual(r.returncode, 2)
        self.assertTrue(r.stdout.startswith("WARN\tCI status not read"), r.stdout)
        self.assertIn("not logged in", r.stderr)

    def test_missing_gh_binary_is_exit_2(self):
        r = self.go(GH=str(self.d / "no-such-gh"))
        self.assertEqual(r.returncode, 2)

    def test_bad_usage_and_help(self):
        self.assertEqual(self.go("--bogus").returncode, 2)
        h = self.go("--help")
        self.assertEqual(h.returncode, 0)
        self.assertIn("--summary", h.stdout)

    # --- output ---------------------------------------------------------------------------------
    def test_summary_levels(self):
        self.repo("sec", [wf(1, "security")], [run(1, "security", "failure", "2026-11-10", rid=1)], jobs={1: []})
        self.repo("leaks", [wf(1, "Gitleaks")], [run(1, "Gitleaks", "failure", "2026-11-10", rid=2)], jobs={2: []})
        self.repo("app", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-10", rid=3)], jobs={3: []})
        self.repo("fine", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-10")])
        r = self.go("--summary")
        lines = r.stdout.strip().splitlines()
        self.assertIn("FAIL\tCI red: sec — security (failure)", lines)
        self.assertTrue(any(ln.startswith("FAIL\tCI red: leaks") for ln in lines))
        self.assertTrue(any(ln.startswith("WARN\tCI red: app") for ln in lines))
        self.assertEqual(lines[-1], "INFO\tCI: 3 red · 1 green (of 4 own repos)")
        self.assertFalse(any("fine" in ln for ln in lines))
        for ln in lines:
            self.assertRegex(ln, r"^(FAIL|WARN|INFO)\t")

    def test_summary_lines_are_stable_across_run_dates(self):
        jobs = [{"name": "tests", "conclusion": "failure", "steps": [{"name": "Run 2026-01-01 job", "conclusion": "failure"}]}]
        self.repo("wk", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-09", rid=21)], jobs={21: jobs})
        first = self.go("--summary").stdout
        self.repos = []
        self.repo("wk", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-16", rid=21)], jobs={21: jobs})
        second = self.go("--summary").stdout
        self.assertEqual(first, second)
        self.assertIn("WARN\tCI red: wk — CI (failure: tests → Run 2026-01-01 job)", first)  # a date in a step name stays
        md = self.go().stdout
        self.assertIn("CI (failure, 2026-11-16: tests", md)   # the report keeps the date

    def test_markdown_sections_order_and_escaping(self):
        self.repo("pipe", [wf(1, "a|b")], [run(1, "a|b", "failure", "2026-11-10", rid=4)], jobs={4: []})
        self.repo("st", [wf(1, "CI")], [])
        self.repo("no", [])
        self.repo("gr", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-10")])
        r = self.go()
        md = r.stdout
        self.assertIn("4 own repos (octo-test, no forks, no archived): 1 red · 1 stale · 1 none · 1 green", md)
        self.assertLess(md.index("## red (1)"), md.index("## stale (1)"))
        self.assertLess(md.index("## stale (1)"), md.index("## none (1)"))
        self.assertLess(md.index("## none (1)"), md.index("## green (1)"))
        self.assertIn("a\\|b (failure", md)
        self.assertIn("| st | private | — | no completed run on main |", md)

    def test_out_files_mode_600_and_match_stdout(self):
        self.repo("a", [wf(1, "CI")], [run(1, "CI", "success", "2026-11-10")], private=False)
        out = self.d / "reports"
        r = self.go("--out", str(out))
        md = out / "ci-status-2026-11-17.md"
        tsv = out / "ci-status-2026-11-17.tsv"
        for f in (md, tsv):
            self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600, f)
        self.assertEqual(md.read_text().strip(), r.stdout.strip())
        self.assertEqual(tsv.read_text().splitlines()[0],
                         "repo\tvisibility\tbranch\tstatus\tworkflows\tlast_run\tdetail")
        self.assertIn("a\tpublic\tmain\tgreen\t1\t2026-11-10\t", tsv.read_text())

    def test_out_inside_a_git_repo_is_refused_before_any_api_call(self):
        self.repo("a", [])
        g = self.d / "somerepo"
        (g / ".git").mkdir(parents=True)
        r = self.go("--out", str(g / "reports"))
        self.assertEqual(r.returncode, 3)
        self.assertFalse((g / "reports").exists())
        self.assertEqual(self.calls(), [])

    def test_only_reads(self):
        self.repo("a", [wf(1, "CI")], [run(1, "CI", "failure", "2026-11-10", rid=6)], jobs={6: []})
        self.repo("b", [])
        self.go()
        calls = self.calls()
        self.assertTrue(calls)
        for c in calls:
            if c[0] == "repo":
                self.assertEqual(c[1], "list")
                continue
            self.assertEqual(c[0], "api", c)
            self.assertEqual(len(c), 2, f"api call with extra flags: {c}")
            self.assertTrue(c[1].startswith(f"repos/{OWNER}/"), c)

    def test_parallel_workers_give_the_same_rows(self):
        for i in range(12):
            ok = i % 3
            self.repo(f"p{i:02d}", [wf(1, "CI")], [run(1, "CI", "success" if ok else "failure", "2026-11-10", rid=200 + i)],
                      jobs={200 + i: []})
        a = self.go(CI_WORKERS="1").stdout
        b = self.go(CI_WORKERS="8").stdout
        self.assertEqual(a, b)
        self.assertIn("4 red · 8 green", a)


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv else 1
    sys.argv = [sys.argv[0]]
    sys.exit(0 if unittest.main(verbosity=verbosity, exit=False).result.wasSuccessful() else 1)
