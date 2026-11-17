#!/usr/bin/env python3
"""test-latest-deps.py — tests for scripts/latest-deps.py.

Hermetic: each case builds a fixture projects tree of throwaway git repos, a fixture PyPI
(file://), a fixture do-not-touch register, skip list and holds, a cache and an output dir,
all inside one temp dir. Every fixture git command goes through git(), which refuses a path
outside that temp dir, and runs under an identity-only GIT_CONFIG_GLOBAL. The projects' init.sh
and test.sh are stubs whose verdict depends on what requirements.txt pins, so each verdict can
be forced. NVM_DIR points at nothing, so nvm is never used.

Usage:  scripts/test-latest-deps.py [--verbose]     Exit: 0 all passed, 1 otherwise.
"""

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "latest-deps.py"


def write(path, text, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mode:
        path.chmod(mode)


def tree_hash(d):
    """Content and names of every file under d, .git included (mtimes of dirs ignored)."""
    h = hashlib.sha256()
    for p in sorted(d.rglob("*")):
        if p.is_file():
            h.update(str(p.relative_to(d)).encode())
            h.update(p.read_bytes())
    return h.hexdigest()


class Fixture:
    def __init__(self, tmp):
        self.tmp = Path(tmp).resolve()
        self.root = self.tmp / "projects"
        self.reg = self.tmp / "pypi"
        self.out = self.tmp / "out"
        self.cache = self.tmp / "cache"
        self.priv = self.tmp / "private"
        for d in (self.root, self.reg, self.priv):
            d.mkdir(parents=True)
        self.gitcfg = self.tmp / "gitconfig"
        write(self.gitcfg, "[user]\n    name = t\n    email = t@users.noreply.github.com\n")
        write(self.priv / "do-not-touch.md", "# register\n- `projects/memorial` — never.\n")
        write(self.priv / "skip.txt", "# name<TAB>reason\nslowpoke\tneeds a GPU\n")
        write(self.priv / "holds.tsv", "")

    def genv(self):
        return {**os.environ, "GIT_CONFIG_GLOBAL": str(self.gitcfg), "GIT_CONFIG_NOSYSTEM": "1"}

    def git(self, repo, *args):
        r = Path(repo).resolve()
        if self.tmp not in r.parents:
            raise RuntimeError(f"fixture git outside the sandbox: {r}")
        return subprocess.run(["git", "-C", str(r), *args], check=True, capture_output=True,
                              text=True, env=self.genv())

    def pypi(self, name, latest, versions=()):
        rel = {v: [{"yanked": False}] for v in (*versions, latest)}
        write(self.reg / f"{name}.json", json.dumps({"info": {"version": latest}, "releases": rel}))

    def project(self, name, req, test_body="exit 0", owner="pieteradejong", origin=True, test=True):
        d = self.root / name
        write(d / "requirements.txt", req)
        write(d / "init.sh", "#!/bin/sh\necho init >> \"$LATEST_DEPS_LOG\"\n", 0o755)
        if test:
            write(d / "test.sh", f"#!/bin/sh\necho \"test $* in $(pwd)\" >> \"$LATEST_DEPS_LOG\"\n{test_body}\n", 0o755)
        self.git(d, "init", "-q")
        if origin:
            self.git(d, "remote", "add", "origin", f"git@github.com:{owner}/{name}.git")
        self.git(d, "add", "-A")
        self.git(d, "commit", "-qm", "fixture")
        return d

    def env(self, **extra):
        e = self.genv()
        e.update({
            "PROJECTS_ROOT": str(self.root), "LATEST_DEPS_OUT": str(self.out),
            "LATEST_DEPS_CACHE": str(self.cache), "LATEST_DEPS_SKIP": str(self.priv / "skip.txt"),
            "LATEST_DEPS_HOLDS": str(self.priv / "holds.tsv"),
            "DNT_REGISTER": str(self.priv / "do-not-touch.md"), "LATEST_DEPS_OWNER": "pieteradejong",
            "PYPI_URL": f"file://{self.reg}", "NPM_REGISTRY": f"file://{self.tmp / 'npm'}",
            "NVM_DIR": str(self.tmp / "no-nvm"), "TODAY": "2030-01-05",
            "LATEST_DEPS_LOG": str(self.tmp / "calls.log"),
            "LATEST_DEPS_OWNERS": str(self.priv / "owners.txt"), "LATEST_DEPS_ARGS": str(self.priv / "args.tsv"),
            "LATEST_DEPS_EXPO_EXTRA": "",
        })
        e.update(extra)
        return e

    def run(self, *args, **extra):
        return subprocess.run([sys.executable, str(SCRIPT), *args], check=False, capture_output=True,
                              text=True, env=self.env(**extra), timeout=120)

    def tsv(self):
        lines = (self.out / "latest-deps-2030-01-05.tsv").read_text().splitlines()
        cols = lines[0].split("\t")
        rows = [dict(zip(cols, x.split("\t"))) for x in lines[1:]]
        return {r["project"]: r for r in rows}

    def calls(self):
        p = self.tmp / "calls.log"
        return p.read_text() if p.is_file() else ""


# test.sh bodies: fail when the bumped version is in the clone's requirements.txt.
FAIL_IF = "grep -q '{pin}' requirements.txt && exit 1; exit 0"


class Verdicts(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self._tmp.name)
        self.f.pypi("alpha", "2.0.0", ["1.0.0"])   # major available
        self.f.pypi("beta", "1.0.1", ["1.0.0"])    # patch available
        self.f.pypi("gamma", "1.0.0")              # current

    def tearDown(self):
        self._tmp.cleanup()

    def test_each_verdict_and_report(self):
        f = self.f
        f.project("fine", "beta==1.0.0\n")
        f.project("broke", "beta==1.0.0\n", FAIL_IF.format(pin="beta==1.0.1"))
        f.project("halfway", "alpha==1.0.0\nbeta==1.0.0\n", FAIL_IF.format(pin="alpha==2.0.0"))
        f.project("red", "beta==1.0.0\n", "exit 1")
        f.project("still", "gamma==1.0.0\n", "touch ran-tests; exit 0")
        f.project("gated", "beta==1.0.0\n", "# runs ~/dev/dotfiles/security/gate.sh scan-tree\n"
                  + FAIL_IF.format(pin="beta==1.0.1"))
        p = f.run()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        r = f.tsv()
        self.assertEqual(r["fine"]["verdict"], "ok")
        self.assertEqual(r["fine"]["applied"], "all")
        self.assertEqual(r["broke"]["verdict"], "broken-by-latest")
        self.assertEqual(r["halfway"]["verdict"], "ok-patch-minor")
        self.assertIn("alpha@2.0.0", r["halfway"]["note"])
        self.assertEqual(r["red"]["verdict"], "already-failing")
        self.assertEqual(r["still"]["verdict"], "current")
        self.assertEqual(r["gated"]["verdict"], "needs-ci")
        self.assertNotIn(str(f.cache / "still"), f.calls(), "a current project runs no tests")
        for name in ("latest-deps-2030-01-05.md", "latest-deps-2030-01-05.tsv"):
            self.assertEqual(stat.S_IMODE((f.out / name).stat().st_mode), 0o600)
        md = (f.out / "latest-deps-2030-01-05.md").read_text()
        self.assertIn("| broke | broken-by-latest |", md)
        self.assertIn("## broke — broken-by-latest", md)

    def test_real_checkout_untouched_and_cache_emptied(self):
        d = self.f.project("fine", "alpha==1.0.0\nbeta==1.0.0\n", FAIL_IF.format(pin="alpha==2.0.0"))
        write(d / ".env", "TOKEN=fixture-not-a-secret\n")  # gitignored-style file: never copied
        before = tree_hash(d)
        p = self.f.run()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(tree_hash(d), before, "the project, .git included, is byte-identical")
        self.assertEqual(list(self.f.cache.iterdir()), [], "every clone is deleted")
        self.assertIn(f"in {self.f.cache}", self.f.calls(), "tests ran in the clone, not the project")
        self.assertNotIn(f"in {d}\n", self.f.calls())

    def test_ci_flag_only_when_supported(self):
        self.f.project("withci", "beta==1.0.0\n", '# usage: ./test.sh [--ci]\n[ "$1" = --ci ] || exit 1')
        self.f.project("plain", "beta==1.0.0\n", '[ -z "$1" ] || exit 1')
        p = self.f.run()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        r = self.f.tsv()
        self.assertEqual((r["withci"]["verdict"], r["plain"]["verdict"]), ("ok", "ok"))
        self.assertIn("test --ci in", self.f.calls())

    def test_timeout_is_an_error(self):
        self.f.project("slow", "beta==1.0.0\n", "grep -q 'beta==1.0.1' requirements.txt && sleep 30; exit 0")
        p = self.f.run(LATEST_DEPS_CMD_TIMEOUT="2")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.f.tsv()["slow"]["verdict"], "error")
        self.assertIn("timed out", self.f.tsv()["slow"]["note"])

    def test_holds_keep_a_pin_current(self):
        self.f.project("held", "alpha==1.0.0\n", FAIL_IF.format(pin="alpha==2.0.0"))
        write(self.f.priv / "holds.tsv", "held\talpha\t<2.0.0\tbreaks the API\tDECISIONS 3\n")
        p = self.f.run()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.f.tsv()["held"]["verdict"], "current")


class Scope(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self._tmp.name)
        self.f.pypi("beta", "1.0.1", ["1.0.0"])

    def tearDown(self):
        self._tmp.cleanup()

    def test_skip_rules(self):
        f = self.f
        f.project("mine", "beta==1.0.0\n")
        f.project("forked", "beta==1.0.0\n", owner="someone-else")
        f.project("loner", "beta==1.0.0\n", origin=False)
        f.project("memorial", "beta==1.0.0\n")
        f.project("slowpoke", "beta==1.0.0\n")
        f.project("untested", "beta==1.0.0\n", test=False)
        (f.root / "scratch" / ".git").mkdir(parents=True)
        (f.root / "notes").mkdir()  # not a repo: ignored silently
        before = tree_hash(f.root / "memorial")
        p = f.run("--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("1 in scope, 6 skipped", p.stdout)
        self.assertIn("- mine: 1 bump(s)", p.stdout)
        for name, why in (("forked", "owner someone-else"), ("loner", "no origin"),
                          ("memorial", "do-not-touch register"), ("slowpoke", "skip list: needs a GPU"),
                          ("untested", "no test.sh"), ("scratch", "scratch/")):
            self.assertIn(f"- {name}: skipped ({why}", p.stdout)
        self.assertNotIn("notes", p.stdout)
        self.assertFalse(f.cache.exists(), "--dry-run clones nothing")
        self.assertEqual(f.calls(), "")
        f.run()
        self.assertEqual(tree_hash(f.root / "memorial"), before)
        self.assertEqual(f.tsv()["memorial"]["verdict"], "skipped")

    def test_missing_register_and_usage(self):
        (self.f.priv / "do-not-touch.md").unlink()
        p = self.f.run()
        self.assertEqual(p.returncode, 2)
        self.assertIn("do-not-touch register missing", p.stderr)
        self.assertEqual(self.f.run("--bogus").returncode, 2)
        self.assertEqual(self.f.run("--jobs", "0").returncode, 2)
        write(self.f.priv / "do-not-touch.md", "x\n")
        p = self.f.run("--project", "nope")
        self.assertEqual(p.returncode, 2)
        self.assertIn("not a project repo", p.stderr)


class SummaryAndApply(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self._tmp.name)
        self.f.pypi("alpha", "2.0.0", ["1.0.0"])
        self.f.pypi("beta", "1.0.1", ["1.0.0"])

    def tearDown(self):
        self._tmp.cleanup()

    def test_summary_lines_and_age(self):
        self.assertEqual(self.f.run("--summary").returncode, 2)
        self.f.project("fine", "beta==1.0.0\n")
        self.f.project("broke", "beta==1.0.0\n", FAIL_IF.format(pin="beta==1.0.1"))
        self.f.run()
        p = self.f.run("--summary")
        self.assertEqual(p.returncode, 0)
        self.assertIn("WARN\tbroke: broken-by-latest", p.stdout)
        self.assertIn("INFO\tlatest-deps 2030-01-05: 1 broken-by-latest · 1 ok", p.stdout)
        self.assertNotIn("days old", p.stdout)
        p = self.f.run("--summary", TODAY="2030-01-20")
        self.assertIn("WARN\tnewest latest-deps report is 15 days old", p.stdout)

    def test_apply_takes_only_what_passed(self):
        d = self.f.project("halfway", "alpha==1.0.0\nbeta==1.0.0  # keep\n", FAIL_IF.format(pin="alpha==2.0.0"))
        self.f.project("broke", "beta==1.0.0\n", FAIL_IF.format(pin="beta==1.0.1"))
        self.f.run()
        p = self.f.run("--apply", "broke")
        self.assertEqual(p.returncode, 1)
        self.assertIn("REFUSED", p.stdout)
        write(d / "stray.txt", "dirty\n")
        p = self.f.run("--apply", "halfway")
        self.assertEqual(p.returncode, 1)
        self.assertIn("dirty tree", p.stdout)
        (d / "stray.txt").unlink()
        p = self.f.run("--apply", "halfway")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual((d / "requirements.txt").read_text(), "alpha==1.0.0\nbeta==1.0.1  # keep\n")
        self.assertEqual(self.f.git(d, "log", "--oneline").stdout.count("\n"), 1, "never commits")
        # The pin moved since the report: refuse rather than apply an untested jump.
        self.f.git(d, "commit", "-qam", "bump beta")
        p = self.f.run("--apply", "halfway")
        self.assertEqual(p.returncode, 1)
        self.assertIn("the report tested from", p.stdout)


# A stub npm: `install --save-exact … name@ver` rewrites package.json and package-lock.json in the
# current directory; anything else (npm ci) only logs. Every call is logged with its directory.
NPM_STUB = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["LATEST_DEPS_LOG"], "a") as fh:
    fh.write("npm " + " ".join(args) + " in " + os.getcwd() + "\\n")
if args and args[0] == "install":
    sec = "devDependencies" if "--save-dev" in args else "dependencies"
    doc = json.load(open("package.json"))
    for spec in (a for a in args[1:] if not a.startswith("-")):
        name, _, ver = spec.rpartition("@")
        doc.setdefault(sec, {})[name] = ver
    json.dump(doc, open("package.json", "w"), indent=2)
    open("package-lock.json", "w").write(json.dumps({"lock": doc}) + "\\n")
"""


class Expo(unittest.TestCase):
    """D78: Expo apps go to npm latest and are written into a clean checkout when ./test.sh passes."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        f = self.f = Fixture(self._tmp.name)
        npm = f.tmp / "npm"
        for name, latest in (("expo", "59.0.1"),):
            write(npm / f"{name}.latest.json", json.dumps({"version": latest}))
            write(npm / f"{name}.doc.json", json.dumps({"versions": {v: {} for v in ("58.0.1", "58.0.9", "59.0.1")}}))
        for v, rn in (("59.0.1", "0.89.0"), ("58.0.9", "0.88.4")):
            write(f.tmp / "jsd" / f"expo@{v}" / "bundledNativeModules.json",
                  json.dumps({"react-native": rn, "expo-router": f"~{v[:2]}.0.3"}))
        write(f.tmp / "bin" / "npm", NPM_STUB, 0o755)

    def tearDown(self):
        self._tmp.cleanup()

    def run_expo(self, *args, **extra):
        env = {"JSDELIVR_URL": f"file://{self.f.tmp / 'jsd'}",
               "PATH": f"{self.f.tmp / 'bin'}:{os.environ['PATH']}"}
        env.update(extra)
        return self.f.run("--expo-only", *args, **env)

    def app(self, name, deps, test_body="exit 0", sub="mobile", **kw):
        d = self.f.project(name, "gamma==1.0.0\n", test_body, **kw)
        write(d / sub / "package.json", json.dumps({"name": name, "dependencies": deps}, indent=2))
        self.f.git(d, "add", "-A")
        self.f.git(d, "commit", "-qm", "app")
        return d

    def expo_tsv(self):
        lines = (self.f.out / "expo-2030-01-05.tsv").read_text().splitlines()
        cols = lines[0].split("\t")
        rows = [dict(zip(cols, x.split("\t"))) for x in lines[1:]]
        out = {}
        for r in rows:
            out.setdefault(r["project"], []).append(r)
        return out

    def test_applied_into_clean_checkout_never_committed(self):
        d = self.app("app", {"expo": "~58.0.1", "react-native": "0.88.0", "expo-router": "58.0.3", "zod": "4.0.0"})
        p = self.run_expo()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        rows = self.expo_tsv()["app/mobile"]
        self.assertEqual(rows[0]["verdict"], "applied")
        got = {r["name"]: (r["target"], r["class"]) for r in rows}
        self.assertEqual(got, {"expo": ("59.0.1", "major"), "react-native": ("0.89.0", "major"),
                               "expo-router": ("59.0.3", "major")})
        deps = json.loads((d / "mobile/package.json").read_text())["dependencies"]
        self.assertEqual(deps, {"expo": "59.0.1", "react-native": "0.89.0", "expo-router": "59.0.3", "zod": "4.0.0"})
        self.assertEqual(self.f.git(d, "log", "--oneline").stdout.count("\n"), 2, "never commits")
        calls = self.f.calls()
        self.assertIn(f"in {self.f.cache}", calls, "tested in a clone first")
        self.assertIn(f"in {d}\n", calls, "then ./test.sh in the checkout")
        self.assertIn("npm install --save-exact --save-prod --no-audit --no-fund", calls)
        self.assertEqual(list(self.f.cache.iterdir()), [])
        md = (self.f.out / "expo-2030-01-05.md").read_text()
        self.assertIn("| app/mobile | applied | expo ~58.0.1→59.0.1, 3 package(s) |", md)
        s = self.f.run("--summary")
        self.assertEqual(s.returncode, 2, "no latest-deps report from --expo-only")
        self.f.run("--no-expo", JSDELIVR_URL=f"file://{self.f.tmp / 'jsd'}")
        s = self.f.run("--summary")
        self.assertIn("WARN\tExpo app/mobile: bumped to latest, uncommitted", s.stdout)
        self.assertIn("INFO\texpo 2030-01-05: 1 applied", s.stdout)

    def test_reverted_when_the_checkout_fails(self):
        body = 'case "$(pwd)" in *cache*) exit 0 ;; esac; grep -q 59.0.1 mobile/package.json && exit 1; exit 0'
        d = self.app("app", {"expo": "58.0.1"}, body)
        before = (d / "mobile/package.json").read_bytes()
        p = self.run_expo()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertEqual(self.expo_tsv()["app/mobile"][0]["verdict"], "reverted")
        self.assertEqual((d / "mobile/package.json").read_bytes(), before, "manifest restored byte for byte")
        self.assertFalse((d / "mobile/package-lock.json").exists(), "a lock that wasn't there is not left behind")

    def test_broken_dirty_current_and_hold(self):
        f = self.f
        broke = self.app("broke", {"expo": "58.0.1"}, "grep -rq 59.0.1 mobile/package.json && exit 1; exit 0")
        before = tree_hash(broke)
        dirty = self.app("dirty", {"expo": "58.0.1"})
        write(dirty / "notes.txt", "uncommitted work\n")
        self.app("fresh", {"expo": "59.0.1", "react-native": "0.89.0"}, sub=".")
        self.app("held", {"expo": "58.0.1", "react-native": "0.88.0"})
        write(f.priv / "holds.tsv", "held\texpo\t<59.0.0\tSDK 59 migration open\tDECISIONS 9\n")
        p = self.run_expo()
        self.assertEqual(p.returncode, 1)
        r = self.expo_tsv()
        self.assertEqual(r["broke/mobile"][0]["verdict"], "broken-by-latest")
        self.assertEqual(tree_hash(broke), before, "a broken bump never reaches the checkout")
        self.assertEqual(r["dirty/mobile"][0]["verdict"], "passed-dirty")
        self.assertEqual(json.loads((dirty / "mobile/package.json").read_text())["dependencies"]["expo"], "58.0.1")
        self.assertEqual(r["fresh"][0]["verdict"], "current")
        held = {x["name"]: x["target"] for x in r["held/mobile"]}
        self.assertEqual(held, {"expo": "58.0.9", "react-native": "0.88.4"})

    def test_range_pin_made_exact_owners_and_args(self):
        f = self.f
        write(f.priv / "owners.txt", "# extra owners\nmy-org\n")
        write(f.priv / "args.tsv", "orgapp\t--no-live\n")
        d = self.app("orgapp", {"expo": "^59.0.1", "react-native": "0.89.0"},
                     '[ "$1" = --no-live ] || exit 1', owner="my-org")
        p = self.run_expo()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        rows = self.expo_tsv()["orgapp/mobile"]
        self.assertEqual([(x["name"], x["class"], x["verdict"]) for x in rows], [("expo", "pin", "applied")])
        self.assertEqual(json.loads((d / "mobile/package.json").read_text())["dependencies"]["expo"], "59.0.1")
        self.assertIn("test --no-live in", f.calls())
        p = self.f.run("--no-expo", "--expo-only")
        self.assertEqual(p.returncode, 2)

    def test_dry_run_lists_expo_plan_and_touches_nothing(self):
        d = self.app("app", {"expo": "58.0.1"})
        before = tree_hash(d)
        p = self.f.run("--dry-run", JSDELIVR_URL=f"file://{self.f.tmp / 'jsd'}")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("- Expo app/mobile: 1 bump(s)", p.stdout)
        self.assertIn("expo 58.0.1→59.0.1 (major)", p.stdout)
        self.assertEqual(tree_hash(d), before)
        self.assertFalse(self.f.cache.exists())


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv else 1
    sys.argv = [sys.argv[0]]
    unittest.main(verbosity=verbosity)
