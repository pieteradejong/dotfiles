#!/usr/bin/env python3
"""test-template-versions.py — tests for scripts/template-versions.py.

Hermetic: each case builds a fixture templates tree and fixture registry answers
(npm, PyPI, endoflife.date, jsDelivr, GitHub) in a temp dir, and points the script
at them through file:// bases, so nothing is fetched and the real ~/dev/templates is
never read. --apply cases use stub init.sh / test.sh scripts and a stub npm on PATH.

Usage:  scripts/test-template-versions.py [--verbose]     Exit: 0 all passed, 1 otherwise.
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
SCRIPT = REPO / "scripts" / "template-versions.py"

SHA = "a" * 40
CI = f"""\
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@{SHA} # v7.0.1
      - uses: actions/setup-python@{SHA} # v7.0.0
        with:
          python-version: ['3.14', '3.13']
  security:
    uses: pieteradejong/dotfiles/.github/workflows/security-reusable.yml@main
"""


def write(path, text, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mode:
        path.chmod(mode)


class Fixture:
    def __init__(self, tmp):
        self.tmp = Path(tmp)
        self.root = self.tmp / "templates"
        self.reg = self.tmp / "reg"
        self.bin = self.tmp / "bin"
        for d in ("npm", "pypi", "eol", "jsd", "gh"):
            (self.reg / d).mkdir(parents=True)
        self.bin.mkdir()
        write(self.reg / "eol" / "nodejs.json", json.dumps([
            {"cycle": "26", "lts": "2026-10-28"}, {"cycle": "25", "lts": False}, {"cycle": "24", "lts": "2025-10-28"}]))
        write(self.reg / "eol" / "python.json", json.dumps([{"cycle": "3.15"}, {"cycle": "3.14"}]))
        self.gh("actions/checkout", "v7.0.1")
        self.gh("actions/setup-python", "v7.1.0")
        write(self.root / "VERSION_HOLDS.tsv",
              "# comment\n*\ttypescript\t<6.1.0\ttypescript-eslint peer\tts-web 1\n")

    def npm(self, name, latest, versions=()):
        q = urllib.parse.quote(name, safe="")
        write(self.reg / "npm" / f"{q}.latest.json", json.dumps({"version": latest}))
        write(self.reg / "npm" / f"{q}.doc.json", json.dumps({"versions": {v: {} for v in (*versions, latest)}}))

    def pypi(self, name, latest, versions=()):
        rel = {v: [{"yanked": False}] for v in (*versions, latest)}
        write(self.reg / "pypi" / f"{name}.json", json.dumps({"info": {"version": latest}, "releases": rel}))

    def gh(self, repo, tag):
        write(self.reg / "gh" / "repos" / repo / "releases" / "latest", json.dumps({"tag_name": tag}))

    def env(self, templates, **extra):
        e = dict(os.environ)
        e.update({
            "TEMPLATES_ROOT": str(self.root), "TEMPLATE_LIST": " ".join(templates), "TODAY": "2030-01-02",
            "NPM_REGISTRY": f"file://{self.reg / 'npm'}", "PYPI_URL": f"file://{self.reg / 'pypi'}",
            "EOL_URL": f"file://{self.reg / 'eol'}", "JSDELIVR_URL": f"file://{self.reg / 'jsd'}",
            "GITHUB_API": f"file://{self.reg / 'gh'}", "PATH": f"{self.bin}:{os.environ['PATH']}",
        })
        e.update(extra)
        return e

    def run(self, templates, *args, **extra):
        return subprocess.run([sys.executable, str(SCRIPT), *args], check=False, capture_output=True, text=True,
                              env=self.env(templates, **extra), timeout=120)


class Check(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def node_template(self):
        t = self.f.root / "web"
        write(t / ".nvmrc", "24\n")
        write(t / "package.json", json.dumps({
            "dependencies": {"react": "19.3.0", "left": "1.2.3", "zero": "0.4.1", "loose": "^1.0.0"},
            "devDependencies": {"typescript": "6.0.3", "@types/node": "24.1.0", "eslint": "10.13.0"}}))
        write(t / ".github" / "workflows" / "ci.yml", CI)
        self.f.npm("react", "19.3.1")
        self.f.npm("left", "1.2.3")
        self.f.npm("zero", "0.5.0")
        self.f.npm("typescript", "7.0.2", ["6.0.3", "6.1.0"])
        self.f.npm("@types/node", "26.6.6", ["24.1.0", "24.19.4", "25.0.0"])
        self.f.npm("eslint", "11.0.0")
        return "web"

    def rows(self, out_dir):
        lines = (out_dir / "template-versions-2030-01-02.tsv").read_text().splitlines()
        cols = lines[0].split("\t")
        return {r["name"]: r for r in (dict(zip(cols, x.split("\t"))) for x in lines[1:])}

    def test_npm_classes_holds_and_types_node(self):
        t = self.node_template()
        out = self.f.tmp / "out"
        p = self.f.run([t], "--out", str(out))
        self.assertEqual(p.returncode, 1, p.stderr)
        r = self.rows(out)
        self.assertEqual((r["react"]["class"], r["react"]["target"]), ("patch", "19.3.1"))
        self.assertEqual(r["left"]["class"], "current")
        self.assertEqual(r["zero"]["class"], "major", "0.x minor step counts as major")
        self.assertEqual((r["typescript"]["class"], r["typescript"]["target"]), ("held", "6.0.3"))
        self.assertIn("hold <6.1.0", r["typescript"]["note"])
        self.assertEqual((r["@types/node"]["target"], r["@types/node"]["class"]), ("24.19.4", "minor"))
        self.assertEqual(r["eslint"]["class"], "major")
        self.assertIn("not an exact pin", r["loose"]["note"])
        self.assertEqual((r[".nvmrc"]["target"], r[".nvmrc"]["class"]), ("26", "major"))
        self.assertEqual(r["actions/setup-python"]["class"], "minor")
        self.assertEqual(r["actions/checkout"]["class"], "current")
        self.assertEqual(r["runs-on"]["pinned"], "ubuntu-latest")
        self.assertEqual(r["CI matrix / Dockerfile"]["class"], "minor")
        for name in ("template-versions-2030-01-02.md", "template-versions-2030-01-02.tsv"):
            self.assertEqual(stat.S_IMODE((out / name).stat().st_mode), 0o600)
        self.assertIn("wrote ", p.stderr)

    def test_expo_follows_bundled_native_modules(self):
        t = self.f.root / "rn"
        write(t / "package.json", json.dumps({"dependencies": {
            "expo": "58.0.14", "react-native": "0.88.0", "@react-native-async-storage/async-storage": "2.2.0",
            "zod": "4.1.0"}}))
        self.f.npm("expo", "59.0.1", ["58.0.14", "58.0.22", "59.0.0-beta.1"])
        self.f.npm("react-native", "0.89.0")
        self.f.npm("@react-native-async-storage/async-storage", "3.1.1")
        self.f.npm("zod", "4.2.0")
        write(self.f.reg / "jsd" / "expo@58.0.22" / "bundledNativeModules.json", json.dumps({
            "react-native": "0.88.1", "@react-native-async-storage/async-storage": "2.2.0"}))
        out = self.f.tmp / "out"
        self.f.run(["rn"], "--out", str(out))
        r = self.rows(out)
        self.assertEqual((r["expo"]["target"], r["expo"]["class"]), ("58.0.22", "patch"))
        self.assertEqual((r["react-native"]["target"], r["react-native"]["class"]), ("0.88.1", "minor"))
        self.assertEqual(r["@react-native-async-storage/async-storage"]["class"], "held")
        self.assertEqual(r["zod"]["target"], "4.2.0")

    def test_python_pins_comments_extras_pyproject(self):
        t = self.f.root / "py"
        write(t / "requirements.txt", "fastapi==0.143.3\nuvicorn[standard]==0.32.1  # server\n-r other.txt\n")
        write(t / "requirements-dev.txt", "httpx2==2.13.1  # starlette TestClient backend\n")
        write(t / "pyproject.toml", '[project]\nname = "x"\ndependencies = ["SQLAlchemy[asyncio]==2.1.5"]\n'
              '[project.optional-dependencies]\ndev = ["pytest==9.1.1"]\n'
              '[build-system]\nrequires = ["hatchling==1.32.4"]\n')
        write(t / "Dockerfile", "FROM python:3.14-slim\n")
        for n, v in (("fastapi", "0.162.0"), ("uvicorn", "0.32.1"), ("httpx2", "2.16.0"),
                     ("sqlalchemy", "2.1.6"), ("pytest", "9.2.0"), ("hatchling", "1.33.0")):
            self.f.pypi(n, v)
        out = self.f.tmp / "out"
        self.f.run(["py"], "--out", str(out))
        r = self.rows(out)
        self.assertEqual(r["fastapi"]["class"], "major")
        self.assertEqual(r["uvicorn[standard]"]["class"], "current")
        self.assertEqual((r["httpx2"]["pinned"], r["httpx2"]["target"]), ("2.13.1", "2.16.0"))
        self.assertEqual(r["SQLAlchemy[asyncio]"]["class"], "patch")
        self.assertEqual(r["pytest"]["file"], "pyproject.toml")
        self.assertEqual(r["hatchling"]["class"], "minor")
        self.assertEqual(r["CI matrix / Dockerfile"]["pinned"], "3.14")

    def test_unpinned_action_fails_and_summary(self):
        t = self.f.root / "bad"
        write(t / ".github" / "workflows" / "ci.yml", "jobs:\n  a:\n    runs-on: ubuntu-24.04\n"
              "    steps:\n      - uses: actions/checkout@v4\n")
        good = self.f.root / "good"
        write(good / "package.json", json.dumps({"dependencies": {"left": "1.2.3"}}))
        self.f.npm("left", "1.2.3")
        p = self.f.run(["bad", "good"], "--summary")
        self.assertEqual(p.returncode, 1)
        self.assertIn("FAIL\tbad: unpinned action actions/checkout@v4", p.stdout)
        self.assertIn("INFO\tgood: packages current (0 held)", p.stdout)
        p = self.f.run(["good"])
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        # A runner or action row is by-hand work: its own WARN, never counted as a bump to --apply.
        t = self.node_template()
        p = self.f.run([t], "--summary")
        self.assertIn("WARN\tweb: runner runs-on ubuntu-latest -> ubuntu-<version> (by hand: pin a runner version)", p.stdout)
        self.assertIn("WARN\tweb: 2 major · 1 minor · 1 patch to take (1 held)", p.stdout)

    def test_missing_template_fetch_error_and_usage(self):
        p = self.f.run(["nope"])
        self.assertEqual(p.returncode, 1)
        self.assertIn("template directory missing", p.stdout)
        t = self.f.root / "web"
        write(t / "package.json", json.dumps({"dependencies": {"unknown-pkg": "1.0.0"}}))
        p = self.f.run(["web"])
        self.assertEqual(p.returncode, 2)
        self.assertIn("fetch failed", p.stdout)
        self.assertEqual(self.f.run(["web"], "--bogus").returncode, 2)
        self.assertEqual(self.f.run(["web"], "--dry-run").returncode, 2)
        self.assertEqual(self.f.run(["web"], "--template", "other").returncode, 2)
        self.assertEqual(self.f.run(["web"], TEMPLATES_ROOT=str(self.f.tmp / "none")).returncode, 2)
        h = self.f.run(["web"], "--help")
        self.assertEqual(h.returncode, 0)
        self.assertIn("Usage:", h.stdout)

    def test_bad_holds_file_is_usage_error(self):
        write(self.f.root / "VERSION_HOLDS.tsv", "*\ttypescript\tlatest\n")
        write(self.f.root / "web" / "package.json", "{}")
        self.assertEqual(self.f.run(["web"]).returncode, 2)


class Apply(unittest.TestCase):
    """--apply on a Python template: stub init.sh, and a test.sh whose verdict the case picks."""

    REQ = "alpha==1.0.0\nbeta==1.0.0  # keep this comment\n"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self._tmp.name)
        self.t = self.f.root / "py"
        write(self.t / "requirements.txt", self.REQ)
        write(self.t / "LICENSE", "Copyright (c) <YEAR> <HOLDER>\n")
        # Like the real init.sh: fills the LICENSE placeholders, which must not stick in a template.
        write(self.t / "init.sh", "#!/bin/sh\necho init >> calls.log\n"
              "sed -i.bak 's/<YEAR> <HOLDER>/2030 Someone/' LICENSE && rm -f LICENSE.bak\n", 0o755)
        self.f.pypi("alpha", "2.0.0", ["1.0.0"])
        self.f.pypi("beta", "1.0.1", ["1.0.0"])

    def tearDown(self):
        self._tmp.cleanup()

    def write_test_sh(self, body):
        write(self.t / "test.sh", f"#!/bin/sh\n{body}\n", 0o755)

    def test_all_applied(self):
        self.write_test_sh("exit 0")
        p = self.f.run(["py"], "--apply")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("APPLIED all 2", p.stdout)
        self.assertEqual((self.t / "requirements.txt").read_text(),
                         "alpha==2.0.0\nbeta==1.0.1  # keep this comment\n")
        self.assertEqual((self.t / "LICENSE").read_text(), "Copyright (c) <YEAR> <HOLDER>\n")

    def test_major_rejected_rest_applied(self):
        self.write_test_sh("grep -q 'alpha==2' requirements.txt && { echo 'boom: alpha 2 broke it'; exit 1; }; exit 0")
        p = self.f.run(["py"], "--apply")
        self.assertEqual(p.returncode, 1)
        self.assertIn("REJECTED majors: alpha@2.0.0", p.stdout)
        self.assertIn("boom: alpha 2 broke it", p.stdout)
        self.assertEqual((self.t / "requirements.txt").read_text(),
                         "alpha==1.0.0\nbeta==1.0.1  # keep this comment\n")

    def test_failure_restores_byte_identical(self):
        self.write_test_sh("echo always broken; exit 1")
        p = self.f.run(["py"], "--apply")
        self.assertEqual(p.returncode, 1)
        self.assertIn("FAILED, restored", p.stdout)
        self.assertEqual((self.t / "requirements.txt").read_text(), self.REQ)
        self.assertGreaterEqual((self.t / "calls.log").read_text().count("init"), 3, "init.sh after restore")
        self.assertEqual((self.t / "LICENSE").read_text(), "Copyright (c) <YEAR> <HOLDER>\n")

    def test_dry_run_changes_nothing(self):
        self.write_test_sh("exit 0")
        p = self.f.run(["py"], "--apply", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("plan: alpha 1.0.0 -> 2.0.0 (major)", p.stdout)
        self.assertEqual((self.t / "requirements.txt").read_text(), self.REQ)
        self.assertFalse((self.t / "calls.log").exists())

    def test_npm_install_split_by_section(self):
        t = self.f.root / "web"
        write(t / "package.json", json.dumps({"dependencies": {"react": "19.3.0"},
                                              "devDependencies": {"eslint": "10.13.0"}}))
        write(t / "init.sh", "#!/bin/sh\nexit 0\n", 0o755)
        write(t / "test.sh", "#!/bin/sh\nexit 0\n", 0o755)
        self.f.npm("react", "19.3.1")
        self.f.npm("eslint", "10.14.0")
        log = self.f.tmp / "npm.log"
        write(self.f.bin / "npm", f'#!/bin/sh\necho "$@" >> {log}\n', 0o755)
        p = self.f.run(["web"], "--apply")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        calls = log.read_text()
        self.assertIn("install --save-exact --save-prod --no-audit --no-fund react@19.3.1", calls)
        self.assertIn("install --save-exact --save-dev --no-audit --no-fund eslint@10.14.0", calls)

    def test_own_repo_keeps_manifests_reverts_strays(self):
        self.write_test_sh("echo touched >> README.md; exit 0")
        write(self.t / "README.md", "readme\n")
        # A throwaway repo with its own global config (identity only), as test-security-tools.sh does.
        cfg = self.f.tmp / "gitconfig"
        write(cfg, "[user]\n    name = t\n    email = t@users.noreply.github.com\n")
        env = {**os.environ, "GIT_CONFIG_GLOBAL": str(cfg), "GIT_CONFIG_NOSYSTEM": "1"}
        for args in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "fixture"]):
            subprocess.run(["git", "-C", str(self.t), *args], check=True, capture_output=True, env=env)
        p = self.f.run(["py"], "--apply")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("reverted files the run changed outside the manifests: README.md", p.stdout)
        self.assertEqual((self.t / "README.md").read_text(), "readme\n")
        self.assertIn("alpha==2.0.0", (self.t / "requirements.txt").read_text())
        self.assertEqual((self.t / "LICENSE").read_text(), "Copyright (c) <YEAR> <HOLDER>\n")

    def test_refuses_dirty_own_repo(self):
        self.write_test_sh("exit 0")
        subprocess.run(["git", "init", "-q", str(self.t)], check=True)
        p = self.f.run(["py"], "--apply")
        self.assertEqual(p.returncode, 1)
        self.assertIn("REFUSED", p.stdout)
        self.assertEqual((self.t / "requirements.txt").read_text(), self.REQ)


if __name__ == "__main__":
    verbosity = 2 if "--verbose" in sys.argv else 1
    sys.argv = [a for a in sys.argv if a != "--verbose"]
    unittest.main(verbosity=verbosity)
