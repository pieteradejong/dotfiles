#!/usr/bin/env python3
"""latest-deps.py — test every own project against the latest stable packages, in a throwaway clone.

The exact pins stay as they are. For each project in scope this script:
  1. makes a throwaway `git clone --shared` of the committed HEAD under LATEST_DEPS_CACHE
     (nothing is written to the project or its .git; origin is set to the project's origin URL)
  2. sets it up (./init.sh, or npm ci / a .venv + pip install) and runs ./test.sh as pinned
  3. bumps every npm and PyPI pin to latest stable (template-versions.py's rules and holds:
     @types/node follows .nvmrc, Expo follows npm latest, D78), sets up again, runs ./test.sh again
  4. if that fails and there are majors, starts over with the patch/minor bumps only
  5. deletes the clone
Then the Expo phase (D78; skip it with --no-expo, run only it with --expo-only). Every Expo app
in scope (a package.json that lists expo, at the root or up to two levels down, e.g.
mobile/ or apps/mobile/), plus the extra repos in LATEST_DEPS_EXPO_EXTRA, goes to the latest
stable Expo: expo to npm `latest` (SDK majors included) and every package that release's
bundledNativeModules.json names to the version it names. Range pins (^53, ~51) become exact.
It is tested the same way in a clone. When that passes and the real checkout is clean, the
bump is written into the checkout, uncommitted, and ./init.sh (else npm ci) and ./test.sh run
there; if they fail, package.json and package-lock.json are put back byte for byte and set up
again. Never commits. Expo verdicts: applied · reverted (passed in the clone, failed in the
checkout, restored) · passed-dirty (passed, not written: uncommitted work in the checkout) ·
broken-by-latest · already-failing · needs-ci · error · current · skipped.
./test.sh gets --ci when it accepts it (that skips its local gate scan, which blocks any
uncommitted bump for want of a CHANGELOG line). Node comes from the project's .nvmrc via nvm.

Scope: every git repo directly under PROJECTS_ROOT with an origin owner in LATEST_DEPS_OWNER
(comma-separated) or the owners file, a
package.json, requirements*.txt or pyproject.toml, and a test.sh. Skipped, with the reason in
the report: other owners (forks, upstream clones), no origin, any project the do-not-touch
register names, scratch/, the skip list, and repos with no exact pin to bump.

Verdicts, one per project:
  current           nothing to bump; no tests run
  ok                pinned passes and latest passes
  ok-patch-minor    latest fails with the majors, passes with patch/minor only
  broken-by-latest  pinned passes, latest fails even with patch/minor only
  already-failing   the pinned run fails, so the latest run cannot be judged
  needs-ci          test.sh runs the gate and has no --ci, and the latest run failed: the
                    failure may be only the gate's CHANGELOG rule (add --ci to that test.sh)
  error             clone, setup or a registry fetch failed, or a command timed out
  skipped           out of scope (reason given), or the time budget ran out

Usage:  scripts/latest-deps.py                       run, write the report, print its paths
        scripts/latest-deps.py --project NAME ...    only these projects
        scripts/latest-deps.py --dry-run             scope and planned bumps; clones nothing
        scripts/latest-deps.py --no-expo             leave out the Expo phase
        scripts/latest-deps.py --expo-only           run only the Expo phase
        scripts/latest-deps.py --jobs N              projects in parallel (default 1)
        scripts/latest-deps.py --summary             LEVEL<TAB>text lines from the newest
                                                     report (for security-audit.sh and the
                                                     daily report); runs nothing
        scripts/latest-deps.py --apply NAME          write the bumps that passed in the newest
                                                     report into the real checkout, uncommitted
        scripts/latest-deps.py -h | --help
--apply refuses a dirty tree, takes only the versions the report tested (all for ok, the
patch/minor ones for ok-patch-minor) and never commits. Afterwards: ./init.sh, ./test.sh, a
CHANGELOG line, and a DECISIONS entry for any major.
Exit:   run: 0 every project ok, current or skipped · 1 any broken-by-latest, needs-ci,
        already-failing or error · 2 bad usage, a missing register, or the run aborted
        --summary: 0 · 2 no report  --apply: 0 written · 1 refused · 2 bad usage
Output: LATEST_DEPS_OUT/latest-deps-YYYY-MM-DD.{md,tsv} and expo-YYYY-MM-DD.{md,tsv}, mode 600
Env:    PROJECTS_ROOT (~/dev/projects) · LATEST_DEPS_OWNER (pieteradejong; comma-separated)
        LATEST_DEPS_OWNERS (…/private/registers/latest-deps-owners.txt: more owners, one a line)
        LATEST_DEPS_ARGS (…/private/registers/latest-deps-args.tsv: name<TAB>test.sh arguments,
          replacing the --ci guess for that project, e.g. a live check to leave out)
        LATEST_DEPS_EXPO_EXTRA (~/dev/templates/rn-supabase; colon-separated repos outside
          PROJECTS_ROOT that get the Expo phase only)
        LATEST_DEPS_OUT (~/dev/audit-reports/latest-deps)
        LATEST_DEPS_CACHE (~/Library/Caches/latest-deps; wiped per project)
        LATEST_DEPS_SKIP (~/dev/dotfiles/private/registers/latest-deps-skip.txt: name<TAB>reason)
        LATEST_DEPS_HOLDS (…/private/registers/latest-deps-holds.tsv: VERSION_HOLDS.tsv format,
          with the project name, or *, in the first column)
        DNT_REGISTER (…/private/registers/do-not-touch.md; required)
        LATEST_DEPS_CMD_TIMEOUT seconds per command (900) · LATEST_DEPS_BUDGET seconds for the
        whole run (14400) · NVM_DIR (~/.nvm) · TODAY YYYY-MM-DD
        NPM_REGISTRY, PYPI_URL, JSDELIVR_URL as in template-versions.py (file:// = fixtures)
"""

import concurrent.futures as cf
import datetime as dt
import importlib.util
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("template_versions", HERE / "template-versions.py")
tv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tv)

HOME = Path.home()
PRIVATE = HERE.parent / "private" / "registers"
ROOT = Path(os.environ.get("PROJECTS_ROOT", str(HOME / "dev" / "projects")))
OWNER = os.environ.get("LATEST_DEPS_OWNER", "pieteradejong")
OWNERS_FILE = Path(os.environ.get("LATEST_DEPS_OWNERS", str(PRIVATE / "latest-deps-owners.txt")))
ARGS_FILE = Path(os.environ.get("LATEST_DEPS_ARGS", str(PRIVATE / "latest-deps-args.tsv")))
EXPO_EXTRA = [Path(x).expanduser() for x in
              os.environ.get("LATEST_DEPS_EXPO_EXTRA", str(HOME / "dev" / "templates" / "rn-supabase")).split(":") if x]
OUT = Path(os.environ.get("LATEST_DEPS_OUT", str(HOME / "dev" / "audit-reports" / "latest-deps")))
CACHE = Path(os.environ.get("LATEST_DEPS_CACHE", str(HOME / "Library" / "Caches" / "latest-deps")))
SKIP_FILE = Path(os.environ.get("LATEST_DEPS_SKIP", str(PRIVATE / "latest-deps-skip.txt")))
HOLDS_FILE = Path(os.environ.get("LATEST_DEPS_HOLDS", str(PRIVATE / "latest-deps-holds.tsv")))
DNT = Path(os.environ.get("DNT_REGISTER", str(PRIVATE / "do-not-touch.md")))
CMD_TIMEOUT = int(os.environ.get("LATEST_DEPS_CMD_TIMEOUT", "900"))
BUDGET = int(os.environ.get("LATEST_DEPS_BUDGET", "14400"))
NVM_SH = Path(os.environ.get("NVM_DIR", str(HOME / ".nvm"))) / "nvm.sh"
MANIFEST_GLOBS = ["package.json", "requirements*.txt", "pyproject.toml"]
ORDER = ["broken-by-latest", "needs-ci", "error", "already-failing", "ok-patch-minor", "ok", "current", "skipped"]
BAD = {"broken-by-latest", "needs-ci", "error", "already-failing"}
EXPO_ORDER = ["broken-by-latest", "needs-ci", "error", "already-failing", "reverted", "passed-dirty",
              "applied", "current", "skipped"]
EXPO_BAD = BAD | {"reverted"}
RANGE = re.compile(r"^[~^>=<\s]+")
TAIL = 30


def today():
    return os.environ.get("TODAY") or dt.date.today().isoformat()


# --- scope ---------------------------------------------------------------------------------------

def git_ro(repo, *args):
    """Read-only git against a real project: only these subcommands are ever allowed."""
    assert args[0] in ("remote", "status", "rev-parse"), args
    if args[0] == "remote":
        assert args[1] == "get-url", args
    p = subprocess.run(["git", "-C", str(repo), *args], check=False, capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def owner_of(url):
    s = re.sub(r"^git@[^:]+:", "", url)
    s = re.sub(r"^(ssh|https?)://[^/]+/", "", s)
    return s.split("/")[0]


def owners():
    out = {o.strip() for o in OWNER.split(",") if o.strip()}
    if OWNERS_FILE.is_file():
        out |= {ln.strip() for ln in OWNERS_FILE.read_text().splitlines()
                if ln.strip() and not ln.lstrip().startswith("#")}
    return out


def args_register():
    out = {}
    if ARGS_FILE.is_file():
        for line in ARGS_FILE.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            name, _, args = line.partition("\t")
            out[name.strip()] = shlex.split(args)
    return out


def dnt_names():
    if not DNT.is_file():
        raise SystemExit(f"do-not-touch register missing: {DNT} (DNT_REGISTER); refusing to run")
    return set(re.findall(r"projects/([A-Za-z0-9._-]+)", DNT.read_text()))


def skip_list():
    out = {}
    if SKIP_FILE.is_file():
        for line in SKIP_FILE.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            name, _, reason = line.partition("\t")
            out[name.strip()] = reason.strip() or "skip list"
    return out


def has_manifest(d):
    return any(any(d.glob(g)) for g in MANIFEST_GLOBS)


def discover(only=()):
    """-> (in_scope [(name, path, origin_url)], skipped [(name, reason)])"""
    dnt, skips, own = dnt_names(), skip_list(), owners()
    scope, skipped = [], []
    for d in sorted(p for p in ROOT.iterdir() if p.is_dir()):
        name = d.name
        if only and name not in only:
            continue
        if not (d / ".git").exists():
            continue
        if name == "scratch":
            skipped.append((name, "scratch/"))
            continue
        if name in dnt:
            skipped.append((name, "do-not-touch register"))
            continue
        url = git_ro(d, "remote", "get-url", "origin")
        if not url:
            skipped.append((name, "no origin"))
            continue
        if owner_of(url) not in own:
            skipped.append((name, f"owner {owner_of(url)} (fork or upstream clone)"))
            continue
        if name in skips:
            skipped.append((name, f"skip list: {skips[name]}"))
            continue
        if not (d / "test.sh").is_file():
            skipped.append((name, "no test.sh"))
            continue
        if not has_manifest(d):
            skipped.append((name, "no package.json, requirements*.txt or pyproject.toml"))
            continue
        scope.append((name, d, url))
    return scope, skipped


# --- bumps ---------------------------------------------------------------------------------------

def plan_bumps(name, d, holds):
    errors = []
    rows = tv.check_npm(name, d, holds, errors) + tv.check_pypi(name, d, holds, errors)
    bumps = [r for r in rows if tv.actionable(r)]
    loose = sum(1 for r in rows if "not an exact pin" in r["note"])
    return bumps, loose, errors


def test_flags(d, name=None):
    """-> (./test.sh arguments, gate-without---ci). The args register wins over the --ci guess."""
    text = (d / "test.sh").read_text(errors="replace")
    supports_ci = "--ci" in text
    calls_gate = "gate.sh" in text
    reg = args_register().get(name or d.name)
    if reg is not None:
        return reg, calls_gate and "--ci" not in reg
    return (["--ci"] if supports_ci else []), calls_gate and not supports_ci


# --- running in the clone ------------------------------------------------------------------------

def in_cache(path):
    c, p = CACHE.resolve(), Path(path).resolve()
    if p != c and c not in p.parents:
        raise RuntimeError(f"refusing to work outside {CACHE}: {path}")


def child_env():
    env = dict(os.environ)
    env.update({"CI": "1", "LATEST_DEPS": "1", "NO_COLOR": "1", "npm_config_fund": "false",
                "npm_config_audit": "false", "npm_config_update_notifier": "false"})
    return env


def wrap(cmd, cwd):
    """Run under the Node of the project's .nvmrc when nvm is installed."""
    if not NVM_SH.is_file():
        return cmd
    here = Path(cwd).resolve()
    found = any((p / ".nvmrc").is_file() for p in (here, *here.parents))
    use = "nvm use --silent" if found else "nvm use --silent default"
    script = f'. {shlex.quote(str(NVM_SH))} --no-use; {use} >/dev/null 2>&1; exec "$@"'
    return ["bash", "-c", script, "latest-deps", *cmd]


def in_checkout(root, path):
    r, p = Path(root).resolve(), Path(path).resolve()
    if p != r and r not in p.parents:
        raise RuntimeError(f"refusing to work outside {root}: {path}")


def run(cmd, cwd, log, timeout=None, root=None):
    """-> 'ok' | 'fail' | 'timeout'. Kills the whole process group afterwards (dev servers).
    Runs only inside the cache, or, with root (the Expo apply step, D78), inside that checkout."""
    if root is None:
        in_cache(cwd)
    else:
        in_checkout(root, cwd)
    log.append(f"$ {shlex.join(cmd)}")
    try:
        p = subprocess.Popen(wrap(cmd, cwd), cwd=cwd, env=child_env(), stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, text=True,
                             errors="replace", start_new_session=True)
    except OSError as e:
        log.append(str(e))
        return "fail"
    try:
        out, _ = p.communicate(timeout=timeout or CMD_TIMEOUT)
        status = "ok" if p.returncode == 0 else "fail"
    except subprocess.TimeoutExpired:
        out, status = "", "timeout"
        log.append(f"timed out after {timeout or CMD_TIMEOUT}s")
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        if p.poll() is None:
            p.wait()
    log.extend((out or "").rstrip().splitlines()[-200:])
    return status


def setup_cmds(c):
    if (c / "init.sh").is_file():
        return [["bash", "./init.sh"]]
    cmds = []
    if (c / "package.json").is_file():
        cmds.append(["npm", "ci"] if (c / "package-lock.json").is_file() else ["npm", "install"])
    reqs = sorted(c.glob("requirements*.txt"))
    if reqs or (c / "pyproject.toml").is_file():
        cmds.append(["python3", "-m", "venv", ".venv"])
        if reqs:
            for r in reqs:
                cmds.append([".venv/bin/pip", "install", "-q", "-r", r.name])
        else:
            cmds.append([".venv/bin/pip", "install", "-q", "."])
    return cmds


def setup(c, log, root=None):
    for cmd in setup_cmds(c):
        st = run(cmd, c, log, root=root)
        if st != "ok":
            return st
    return "ok"


def test(c, args, log, root=None):
    return run(["bash", "./test.sh", *args], c, log, root=root)


def bump(c, bumps, log):
    for cmd in tv.install_cmds(bumps):
        st = run(cmd, c, log)
        if st != "ok":
            return st
    py = [r for r in bumps if r["kind"] == "pypi"]
    if py:
        tv.rewrite_python(c, py)
    return setup(c, log)


def _rm_readonly(func, path, _exc):
    os.chmod(path, stat.S_IWRITE | stat.S_IREAD | stat.S_IEXEC)
    func(path)


def wipe(c):
    in_cache(c)
    if c.exists():
        shutil.rmtree(c, onerror=_rm_readonly)


def clone(name, src, url, log):
    c = CACHE / name
    wipe(c)
    CACHE.mkdir(parents=True, exist_ok=True)
    in_cache(c)
    log.append(f"$ git clone --shared {src} {c}")
    p = subprocess.run(["git", "clone", "--quiet", "--shared", str(src), str(c)],
                       check=False, capture_output=True, text=True)
    if p.returncode != 0:
        log.append(p.stderr.strip())
        return None
    subprocess.run(["git", "-C", str(c), "remote", "set-url", "origin", url], check=False, capture_output=True)
    return c


def reset_clone(c, log):
    in_cache(c)
    log.append("$ git checkout -- . (back to HEAD's manifests)")
    subprocess.run(["git", "-C", str(c), "checkout", "--", "."], check=False, capture_output=True)


def result(name, verdict, note="", bumps=(), applied="", log=None):
    return {"project": name, "verdict": verdict, "note": note, "bumps": list(bumps),
            "applied": applied, "log": "\n".join((log or [])[-TAIL:])}


def one(name, src, url, holds, deadline):
    if time.monotonic() > deadline:
        return result(name, "skipped", "time budget ran out (LATEST_DEPS_BUDGET)")
    bumps, loose, errors = plan_bumps(name, src, holds)
    loose_note = f"{loose} non-exact pin(s) not tested" if loose else ""
    if errors:
        return result(name, "error", "registry fetch failed: " + errors[0], bumps)
    if not bumps:
        return result(name, "current", loose_note)
    ci, gate_no_ci = test_flags(src, name)
    log = []
    c = clone(name, src, url, log)
    if c is None:
        return result(name, "error", "clone failed", bumps, log=log)
    try:
        st = setup(c, log)
        if st != "ok":
            return result(name, "error", f"pinned setup {st}", bumps, log=log)
        st = test(c, ci, log)
        if st != "ok":
            return result(name, "already-failing" if st == "fail" else "error",
                          "pinned ./test.sh " + ("fails" if st == "fail" else "timed out"), bumps, log=log)
        st = bump(c, bumps, log)
        if st == "ok":
            st = test(c, ci, log)
        if st == "ok":
            return result(name, "ok", loose_note, bumps, "all")
        first = log[:]
        majors = [r for r in bumps if r["class"] == "major"]
        rest = [r for r in bumps if r["class"] != "major"]
        if majors and rest:
            reset_clone(c, log)
            st2 = setup(c, log)
            if st2 == "ok":
                st2 = bump(c, rest, log)
            if st2 == "ok":
                st2 = test(c, ci, log)
            if st2 == "ok":
                return result(name, "ok-patch-minor",
                              "majors break it: " + ", ".join(f"{r['name']}@{r['target']}" for r in majors),
                              bumps, "patch-minor", first)
        if gate_no_ci:
            return result(name, "needs-ci", "test.sh runs the gate without a --ci flag; "
                          "the failure may be only its CHANGELOG rule", bumps, log=first)
        if st == "timeout":
            return result(name, "error", "latest ./test.sh timed out", bumps, log=first)
        return result(name, "broken-by-latest",
                      "patch/minor alone also fail" if majors and rest else "", bumps, log=first)
    finally:
        wipe(c)


# --- the Expo phase (D78) ------------------------------------------------------------------------

SKIP_PARTS = {"node_modules", ".git", "dist", "build", ".expo", "vendor"}


def expo_dirs(d):
    """Directories in d (itself, or up to two levels down) whose package.json lists expo."""
    out = []
    for pj in [d / "package.json", *sorted(d.glob("*/package.json")), *sorted(d.glob("*/*/package.json"))]:
        if not pj.is_file() or SKIP_PARTS & set(pj.relative_to(d).parts):
            continue
        try:
            doc = json.loads(pj.read_text())
        except (OSError, ValueError):
            continue
        if "expo" in (doc.get("dependencies") or {}) or "expo" in (doc.get("devDependencies") or {}):
            out.append(pj.parent)
    return out


def expo_bumps(name, edir, holds):
    """expo -> latest stable (or inside a hold), its bundled native modules -> the versions that
    release names. Range pins become exact even when the version is already right ("pin")."""
    doc = json.loads((edir / "package.json").read_text())
    target = tv.expo_latest(name, holds)
    want = {k: RANGE.sub("", v) for k, v in tv.bundled_native_modules(target).items()}
    want["expo"] = target
    bumps = []
    for section in ("dependencies", "devDependencies"):
        for pkg, spec in (doc.get(section) or {}).items():
            if pkg not in want or not re.match(r"^\d", want[pkg]):
                continue
            base = RANGE.sub("", spec)
            if not re.match(r"^\d+\.\d+", base):
                continue  # workspace:, file:, git URLs, "*"
            exact = bool(re.match(r"^\d", spec))
            if base == want[pkg]:
                if exact:
                    continue
                cls = "pin"
            elif tv.vtuple(base) > tv.vtuple(want[pkg]):
                continue  # pinned past what the SDK names: never downgrade
            else:
                cls = tv.classify(base, want[pkg])
            bumps.append({"kind": "npm", "name": pkg, "pinned": spec, "target": want[pkg], "class": cls,
                          "section": section, "file": "package.json", "note": f"expo@{target}"})
    return bumps


def expo_scope(scope):
    """(name, src, url) of the projects in scope plus the extra repos (owner-checked)."""
    out = list(scope)
    own, dnt = owners(), dnt_names()
    for d in EXPO_EXTRA:
        if not (d / ".git").exists() or not (d / "test.sh").is_file() or d.name in dnt:
            continue
        url = git_ro(d, "remote", "get-url", "origin")
        if url and owner_of(url) in own and all(src != d for _, src, _ in out):
            out.append((d.name, d, url))
    return out


def expo_label(name, src, edir):
    rel = edir.relative_to(src)
    return name if str(rel) == "." else f"{name}/{rel}"


def install_in(edir, bumps, log, root=None):
    for cmd in tv.install_cmds(bumps):
        st = run(cmd, edir, log, root=root)
        if st != "ok":
            return st
    return "ok"


def expo_apply_real(label, src, edir, bumps, args, log):
    """Write the tested bump into the real checkout, set up and test there; restore on failure."""
    snap = {f: (f.read_bytes() if f.is_file() else None) for f in (edir / "package.json", edir / "package-lock.json")}
    log.append(f"--- applying in the checkout {src}")
    st = install_in(edir, bumps, log, root=src)
    if st == "ok":
        st = setup(src, log, root=src)
    if st == "ok":
        st = test(src, args, log, root=src)
    if st == "ok":
        changed = [ln[3:] for ln in (git_ro(src, "status", "--porcelain") or "").splitlines()]
        rel = edir.relative_to(src)
        mine = {str(rel / "package.json").removeprefix("./"), str(rel / "package-lock.json").removeprefix("./")}
        other = [f for f in changed if f not in mine]
        note = "written into the checkout, uncommitted: commit it with a CHANGELOG line"
        if other:
            note += "; setup also changed " + ", ".join(other[:5])
        return result(label, "applied", note, bumps, "all", log)
    for f, data in snap.items():
        if data is None:
            f.unlink(missing_ok=True)  # created by the bump
        else:
            f.write_bytes(data)
    log.append("--- restored package.json / package-lock.json")
    setup(src, log, root=src)
    return result(label, "reverted", f"passed in a clone, checkout ./test.sh {st}; manifests restored",
                  bumps, log=log)


def expo_one(name, src, url, holds, deadline):
    out = []
    try:
        dirs = expo_dirs(src)
    except OSError as e:
        return [result(name, "error", str(e))]
    args, gate_no_ci = test_flags(src, name)
    for edir in dirs:
        label = expo_label(name, src, edir)
        if time.monotonic() > deadline:
            out.append(result(label, "skipped", "time budget ran out (LATEST_DEPS_BUDGET)"))
            continue
        try:
            bumps = expo_bumps(name, edir, holds)
        except (tv.FetchError, OSError, ValueError) as e:
            out.append(result(label, "error", f"registry fetch failed: {e}"))
            continue
        if not bumps:
            out.append(result(label, "current"))
            continue
        log = []
        c = clone(name, src, url, log)
        if c is None:
            out.append(result(label, "error", "clone failed", bumps, log=log))
            continue
        try:
            st = setup(c, log)
            if st != "ok":
                out.append(result(label, "error", f"pinned setup {st}", bumps, log=log))
                continue
            st = test(c, args, log)
            if st != "ok":
                out.append(result(label, "already-failing" if st == "fail" else "error",
                                  "pinned ./test.sh " + ("fails" if st == "fail" else "timed out"), bumps, log=log))
                continue
            st = install_in(c / edir.relative_to(src), bumps, log)
            if st == "ok":
                st = setup(c, log)
            if st == "ok":
                st = test(c, args, log)
        finally:
            wipe(c)
        if st != "ok":
            verdict = "needs-ci" if gate_no_ci else ("error" if st == "timeout" else "broken-by-latest")
            out.append(result(label, verdict, f"latest Expo: ./test.sh {st} in a clone", bumps, log=log))
            continue
        if git_ro(src, "status", "--porcelain"):
            out.append(result(label, "passed-dirty",
                              "passed in a clone; not written: the checkout has uncommitted changes", bumps))
            continue
        out.append(expo_apply_real(label, src, edir, bumps, args, log))
    return out


# --- report --------------------------------------------------------------------------------------

def bump_text(b):
    return f"{b['name']} {b['pinned']}→{b['target']} ({b['class']})"


def render_md(results, skipped, day):
    n = {v: sum(1 for r in results if r["verdict"] == v) for v in ORDER}
    n["skipped"] += len(skipped)
    lines = [f"# Latest-stable test run — {day}", "",
             " · ".join(f"{n[v]} {v}" for v in ORDER if n[v]), "",
             ("Each project was tested in a throwaway clone: ./test.sh as pinned, then with every pin "
              "on latest stable. Nothing in the projects was changed. `latest-deps.py --apply NAME` "
              "writes a passing set into the real checkout (uncommitted)."), "",
             "| Project | Verdict | Bumps | Note |", "|---|---|---|---|"]
    for r in sorted(results, key=lambda r: (ORDER.index(r["verdict"]), r["project"])):
        majors = sum(1 for b in r["bumps"] if b["class"] == "major")
        lines.append(f"| {r['project']} | {r['verdict']} | {len(r['bumps'])} ({majors} major) | "
                     f"{r['note'].replace('|', '/')} |")
    if skipped:
        lines += ["", "## Skipped", ""] + [f"- {name}: {why}" for name, why in skipped]
    for r in sorted(results, key=lambda r: r["project"]):
        if r["verdict"] in BAD or r["verdict"] == "ok-patch-minor":
            lines += ["", f"## {r['project']} — {r['verdict']}", ""]
            lines += [f"- {bump_text(b)}" for b in r["bumps"]]
            if r["log"]:
                lines += ["", "```", r["log"], "```"]
    return "\n".join(lines) + "\n"


TSV_COLS = ["project", "verdict", "applied", "kind", "name", "pinned", "target", "class", "section", "file", "note"]


def render_tsv(results, skipped):
    out = ["\t".join(TSV_COLS)]
    for r in sorted(results, key=lambda r: r["project"]):
        base = [r["project"], r["verdict"], r["applied"]]
        note = r["note"].replace("\t", " ")
        if not r["bumps"]:
            out.append("\t".join(base + ["-"] * 7 + [note]))
        for b in r["bumps"]:
            out.append("\t".join(base + [b["kind"], b["name"], b["pinned"], b["target"], b["class"],
                                         b["section"], b["file"], note]))
    for name, why in skipped:
        out.append("\t".join([name, "skipped", ""] + ["-"] * 7 + [why]))
    return "\n".join(out) + "\n"


def render_expo_md(results, day):
    n = {v: sum(1 for r in results if r["verdict"] == v) for v in EXPO_ORDER}
    lines = [f"# Expo on latest stable — {day}", "",
             " · ".join(f"{n[v]} {v}" for v in EXPO_ORDER if n[v]) or "no Expo apps in scope", "",
             ("Every Expo app moves to npm's latest expo and the versions its bundledNativeModules.json "
              "names (D78). Tested in a throwaway clone first; when that passes and the checkout is clean "
              "the bump is written there, uncommitted, and ./test.sh runs again — a failure restores the "
              "manifests."), "",
             "| App | Verdict | Bumps | Note |", "|---|---|---|---|"]
    for r in sorted(results, key=lambda r: (EXPO_ORDER.index(r["verdict"]), r["project"])):
        expo = next((b for b in r["bumps"] if b["name"] == "expo"), None)
        what = f"expo {expo['pinned']}→{expo['target']}, " if expo else ""
        lines.append(f"| {r['project']} | {r['verdict']} | {what}{len(r['bumps'])} package(s) | "
                     f"{r['note'].replace('|', '/')} |")
    for r in sorted(results, key=lambda r: r["project"]):
        if r["verdict"] in EXPO_BAD or r["verdict"] in ("applied", "passed-dirty"):
            lines += ["", f"## {r['project']} — {r['verdict']}", ""]
            lines += [f"- {bump_text(b)}" for b in r["bumps"]]
            if r["log"] and r["verdict"] in EXPO_BAD:
                lines += ["", "```", r["log"], "```"]
    return "\n".join(lines) + "\n"


def write_private(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(mode=0o600, exist_ok=True)
    path.chmod(0o600)
    path.write_text(text)


def newest_report():
    if not OUT.is_dir():
        return None
    reps = sorted(OUT.glob("latest-deps-????-??-??.tsv"))
    return reps[-1] if reps else None


def read_tsv(path):
    lines = path.read_text().splitlines()
    cols = lines[0].split("\t")
    return [dict(zip(cols, ln.split("\t"))) for ln in lines[1:] if ln.strip()]


def summary():
    rep = newest_report()
    if rep is None:
        print(f"WARN\tno latest-deps report yet in {OUT} — the weekly job has not run (latest-deps.py)")
        return 2
    day = rep.stem.removeprefix("latest-deps-")
    age = (dt.date.fromisoformat(today()) - dt.date.fromisoformat(day)).days
    if age > 8:
        print(f"WARN\tnewest latest-deps report is {age} days old ({rep.name}) — is the weekly job running?")
    verdicts = {}
    for r in read_tsv(rep):
        verdicts.setdefault(r["project"], (r["verdict"], r["note"]))
    for p, (v, note) in sorted(verdicts.items()):
        if v in BAD:
            print(f"WARN\t{p}: {v}" + (f" — {note}" if note else "") + f" (see {rep.name})")
    n = {v: sum(1 for x, _ in verdicts.values() if x == v) for v in ORDER}
    print("INFO\tlatest-deps " + day + ": " + " · ".join(f"{n[v]} {v}" for v in ORDER if n[v]))
    expo_summary()
    return 0


def expo_summary():
    reps = sorted(OUT.glob("expo-????-??-??.tsv")) if OUT.is_dir() else []
    if not reps:
        return
    verdicts = {}
    for r in read_tsv(reps[-1]):
        verdicts.setdefault(r["project"], (r["verdict"], r["note"]))
    for p, (v, note) in sorted(verdicts.items()):
        if v in EXPO_BAD:
            print(f"WARN\tExpo {p}: {v}" + (f" — {note}" if note else "") + f" (see {reps[-1].name})")
        elif v == "applied":
            print(f"WARN\tExpo {p}: bumped to latest, uncommitted — review, add a CHANGELOG line, commit")
        elif v == "passed-dirty":
            print(f"INFO\tExpo {p}: latest passes but was not written (uncommitted work in the checkout)")
    n = {v: sum(1 for x, _ in verdicts.values() if x == v) for v in EXPO_ORDER}
    print("INFO\texpo " + reps[-1].stem.removeprefix("expo-") + ": "
          + " · ".join(f"{n[v]} {v}" for v in EXPO_ORDER if n[v]))


# --- apply ---------------------------------------------------------------------------------------

def apply(name):
    rep = newest_report()
    if rep is None:
        print("no latest-deps report to apply from", file=sys.stderr)
        return 2
    rows = [r for r in read_tsv(rep) if r["project"] == name]
    if not rows:
        print(f"{name} is not in {rep.name}", file=sys.stderr)
        return 2
    verdict, applied = rows[0]["verdict"], rows[0]["applied"]
    if verdict not in ("ok", "ok-patch-minor"):
        print(f"REFUSED: {name} is {verdict} in {rep.name}; nothing passed to apply")
        return 1
    d = ROOT / name
    if git_ro(d, "status", "--porcelain"):
        print(f"REFUSED: {d} has a dirty tree; commit or stash first")
        return 1
    take = [r for r in rows if r["kind"] in ("npm", "pypi")
            and (applied == "all" or r["class"] != "major")]
    for r in take:
        cur = {n: s for n, s, _ in tv.npm_pins(d)} if r["kind"] == "npm" else \
              {n + e: v for n, e, v, _ in tv.python_pins(d)}
        if cur.get(r["name"]) != r["pinned"]:
            print(f"REFUSED: {r['name']} is {cur.get(r['name'])} now, the report tested from {r['pinned']}; "
                  "rerun latest-deps.py --project " + name)
            return 1
    for cmd in tv.install_cmds(take):
        print("$ " + shlex.join(cmd))
        if subprocess.run(cmd, cwd=d, check=False).returncode != 0:
            print("npm install failed; `git -C <repo> checkout -- package.json package-lock.json` undoes it")
            return 1
    py = [r for r in take if r["kind"] == "pypi"]
    if py:
        tv.rewrite_python(d, py)
    print(f"wrote {len(take)} bump(s) into {d}, uncommitted, as tested on {rep.stem.removeprefix('latest-deps-')}.")
    print("next: ./init.sh && ./test.sh, a CHANGELOG line, and a DECISIONS entry for any major.")
    return 0


# --- main ----------------------------------------------------------------------------------------

def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip())
        return 0
    dry = do_summary = no_expo = expo_only = False
    only, jobs, apply_to = [], 1, None
    it = iter(argv)
    for a in it:
        if a == "--dry-run":
            dry = True
        elif a == "--summary":
            do_summary = True
        elif a == "--no-expo":
            no_expo = True
        elif a == "--expo-only":
            expo_only = True
        elif a in ("--project", "--jobs", "--apply"):
            v = next(it, None)
            if not v:
                print(f"{a} needs a value", file=sys.stderr)
                return 2
            if a == "--project":
                only.append(v.rstrip("/"))
            elif a == "--apply":
                apply_to = v.rstrip("/")
            elif v.isdigit() and int(v) > 0:
                jobs = int(v)
            else:
                print("--jobs needs a positive number", file=sys.stderr)
                return 2
        else:
            print(f"unknown argument: {a} (see --help)", file=sys.stderr)
            return 2
    if do_summary:
        return summary()
    if apply_to:
        return apply(apply_to)
    if not ROOT.is_dir():
        print(f"PROJECTS_ROOT not found: {ROOT}", file=sys.stderr)
        return 2
    tv.HOLDS_FILE = HOLDS_FILE
    try:
        holds = tv.load_holds()
        scope, skipped = discover(only)
    except SystemExit as e:
        print(e, file=sys.stderr)
        return 2
    if no_expo and expo_only:
        print("--no-expo and --expo-only exclude each other", file=sys.stderr)
        return 2
    escope = [] if no_expo else [e for e in expo_scope(scope) if not only or e[0] in only]
    missing = [o for o in only if o not in {n for n, _, _ in escope} | {n for n, _, _ in scope} | {n for n, _ in skipped}]
    if missing:
        print(f"not a project repo under {ROOT}: {', '.join(missing)}", file=sys.stderr)
        return 2

    if dry:
        print(f"{len(scope)} in scope, {len(skipped)} skipped")
        for name, d, _ in scope:
            bumps, _loose, errors = plan_bumps(name, d, holds)
            ci, gate_no_ci = test_flags(d, name)
            flags = " ".join(ci) + (" needs-ci" if gate_no_ci else "")
            print(f"- {name}: {len(bumps)} bump(s){' ' + flags.strip() if flags.strip() else ''}"
                  + (f"; fetch failed: {errors[0]}" if errors else ""))
            for b in bumps:
                print(f"    {bump_text(b)}")
        for name, why in skipped:
            print(f"- {name}: skipped ({why})")
        for name, d, _ in escope:
            for edir in expo_dirs(d):
                try:
                    bumps = expo_bumps(name, edir, holds)
                except (tv.FetchError, OSError, ValueError) as e:
                    print(f"- Expo {expo_label(name, d, edir)}: fetch failed: {e}")
                    continue
                print(f"- Expo {expo_label(name, d, edir)}: {len(bumps)} bump(s)")
                for b in bumps:
                    print(f"    {bump_text(b)}")
        return 0

    deadline = time.monotonic() + BUDGET
    day = today()
    results = []
    if not expo_only:
        with cf.ThreadPoolExecutor(jobs) as ex:
            results = list(ex.map(lambda s: one(s[0], s[1], s[2], holds, deadline), scope))
        md, tsv = OUT / f"latest-deps-{day}.md", OUT / f"latest-deps-{day}.tsv"
        write_private(md, render_md(results, skipped, day))
        write_private(tsv, render_tsv(results, skipped))
        n = {v: sum(1 for r in results if r["verdict"] == v) for v in ORDER}
        print(" · ".join(f"{n[v]} {v}" for v in ORDER if n[v]) or "nothing in scope")
        print(f"wrote {md}\nwrote {tsv}")
    expo = []
    if not no_expo:
        # One project at a time: the apply step runs ./test.sh in real checkouts.
        for name, d, url in escope:
            expo += expo_one(name, d, url, holds, deadline)
        md, tsv = OUT / f"expo-{day}.md", OUT / f"expo-{day}.tsv"
        write_private(md, render_expo_md(expo, day))
        write_private(tsv, render_tsv(expo, []))
        n = {v: sum(1 for r in expo if r["verdict"] == v) for v in EXPO_ORDER}
        print("expo: " + (" · ".join(f"{n[v]} {v}" for v in EXPO_ORDER if n[v]) or "no Expo apps in scope"))
        print(f"wrote {md}\nwrote {tsv}")
    bad = any(r["verdict"] in BAD for r in results) or any(r["verdict"] in EXPO_BAD for r in expo)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
