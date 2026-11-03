#!/usr/bin/env python3
"""template-versions.py — every pin in the curated templates against the latest stable release.

Reads the eight curated templates under TEMPLATES_ROOT (the table in templates/CLAUDE.md).
The Tier 2 own-repo bases and rn-supabase-legacy are never read. For each template:
  npm       package.json dependencies + devDependencies, against the npm registry
  pypi      requirements*.txt and pyproject.toml (project, optional and group deps,
            build-system), against PyPI
  node      .nvmrc against the newest Node LTS (endoflife.date)
  python    the CI python-version matrix and a Dockerfile python: tag, against the
            newest Python release (endoflife.date)
  action    SHA-pinned `uses:` lines: the `# vX.Y.Z` comment against the action's
            latest GitHub release. An unpinned `uses:` (not @<40-hex>, not this
            account's reusable workflow) is a FAIL
  runner    `runs-on: ubuntu-latest` is a WARN; pin a version
Every row is classed current | patch | minor | major | held. In a 0.x package a minor
step counts as major and a 0.0.x step as minor (semver: those are the breaking ones).
A target is held below latest by:
  - a row in TEMPLATE_HOLDS (TSV: template or *, package, bound like <6.1.0 or <=6.0.3,
    reason, decision ref; # comments): the target is the newest release inside the bound
  - @types/node: the newest release in the .nvmrc major
  - Expo templates: expo itself goes to the newest release of its pinned SDK major, and
    every package that SDK's bundledNativeModules.json names goes to the version it names
    (the base of its ~ range), not npm latest

Usage:  scripts/template-versions.py                        check, markdown table on stdout
        scripts/template-versions.py --quiet                rows that need action only
        scripts/template-versions.py --out DIR              also write template-versions-
                                                            YYYY-MM-DD.{md,tsv} (mode 600)
                                                            and print both paths
        scripts/template-versions.py --summary              one LEVEL<TAB>text line per
                                                            template (for security-audit.sh)
        scripts/template-versions.py --apply [--dry-run]    bump the npm and pypi rows
        scripts/template-versions.py --template ts-web/minimal-mvp ...   only these
        scripts/template-versions.py -h | --help
--apply, one template at a time: refuses a template that is its own git repo with a dirty
tree; snapshots package.json / package-lock.json / requirements*.txt / pyproject.toml and
LICENSE; writes every bump (majors included: npm install --save-exact, or the == pins
rewritten); runs ./init.sh then ./test.sh --ci (--ci skips only the template's local gate
scan, which blocks any uncommitted bump without a CHANGELOG line). After every run it
puts LICENSE back (init.sh fills its placeholders) and, in an own-repo template, reverts
any other tracked file changed outside the manifests. On failure it restores the snapshot and retries with
patch/minor only; on a second failure it restores again and marks the template failed;
./init.sh runs after every restore. node, python, action and runner rows are reported,
never applied. Never commits, never runs ./test.sh --integration. Run it under the Node
major the template's .nvmrc names (nvm use). --dry-run prints the plan and runs nothing.
Exit:   check: 0 everything current or held · 1 a bump is available or a FAIL
        --apply: 0 every planned bump applied and tested · 1 a major rejected or a template
        failed · 2 bad usage, missing TEMPLATES_ROOT, or a fetch that failed
Env:    TEMPLATES_ROOT  (default ~/dev/templates)
        TEMPLATE_HOLDS  (default $TEMPLATES_ROOT/VERSION_HOLDS.tsv)
        TEMPLATE_LIST   space-separated template paths, replacing the curated eight
        NPM_REGISTRY (https://registry.npmjs.org) · PYPI_URL (https://pypi.org/pypi)
        EOL_URL (https://endoflife.date/api) · JSDELIVR_URL (https://cdn.jsdelivr.net/npm)
        GITHUB_API (https://api.github.com) — a file:// base reads fixtures instead:
        npm <base>/<quoted name>.latest.json and .doc.json, pypi <base>/<name>.json,
        the others at their URL path
        TEMPLATE_CMD_TIMEOUT seconds per init.sh/test.sh (1800) · TODAY YYYY-MM-DD
"""

import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CURATED = [
    "py-fastapi/minimal-mvp",
    "py-fastapi/production-ready",
    "ts-web/minimal-mvp",
    "ts-web/production-ready",
    "node-express/minimal-mvp",
    "node-express/production-ready",
    "rn-supabase",
    "vercel-stack",
]
OWN_WORKFLOWS = "pieteradejong/"
MANIFESTS = ["package.json", "package-lock.json", "requirements*.txt", "pyproject.toml"]
# init.sh fills LICENSE's <YEAR>/<HOLDER> on first run: right in a scaffold, wrong in the template.
SIDE_EFFECTS = ["LICENSE"]
STABLE = re.compile(r"^\d+(\.\d+)*(\.post\d+)?$")
ORDER = {"major": 0, "minor": 1, "patch": 2, "held": 3, "current": 4}

ROOT = Path(os.environ.get("TEMPLATES_ROOT", str(Path.home() / "dev" / "templates")))
HOLDS_FILE = Path(os.environ.get("TEMPLATE_HOLDS", str(ROOT / "VERSION_HOLDS.tsv")))
NPM = os.environ.get("NPM_REGISTRY", "https://registry.npmjs.org").rstrip("/")
PYPI = os.environ.get("PYPI_URL", "https://pypi.org/pypi").rstrip("/")
EOL = os.environ.get("EOL_URL", "https://endoflife.date/api").rstrip("/")
JSDELIVR = os.environ.get("JSDELIVR_URL", "https://cdn.jsdelivr.net/npm").rstrip("/")
GITHUB = os.environ.get("GITHUB_API", "https://api.github.com").rstrip("/")
CMD_TIMEOUT = int(os.environ.get("TEMPLATE_CMD_TIMEOUT", "1800"))


class FetchError(Exception):
    pass


# --- versions ------------------------------------------------------------------------------------

def vtuple(v):
    """'1.4.1.post1' -> (1, 4, 1, 1); '0.143.3' -> (0, 143, 3, 0). Non-numeric parts end the parse."""
    main, _, post = v.partition(".post")
    nums = []
    for part in main.split("."):
        m = re.match(r"\d+", part)
        if not m:
            break
        nums.append(int(m.group()))
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums[:3]) + (int(post) if post.isdigit() else 0,)


def classify(pinned, target):
    if target == pinned or vtuple(target) <= vtuple(pinned):
        return "current"
    a, b = vtuple(pinned), vtuple(target)
    if a[0] != b[0]:
        return "major"
    if a[0] == 0:
        if a[1] != b[1]:
            return "major"
        return "minor" if a[2] != b[2] else "patch"
    return "minor" if a[1] != b[1] else "patch"


def in_bound(v, bound):
    op, ver = re.match(r"(<=|<)\s*(\S+)", bound).groups()
    return vtuple(v) <= vtuple(ver) if op == "<=" else vtuple(v) < vtuple(ver)


def newest(versions, pred=lambda v: True):
    ok = [v for v in versions if STABLE.match(v) and pred(v)]
    return max(ok, key=vtuple) if ok else None


# --- fetching ------------------------------------------------------------------------------------

_cache = {}


def _get(url):
    if url in _cache:
        return _cache[url]
    try:
        if url.startswith("file://"):
            data = Path(url[7:]).read_text()  # fixture names stay %-quoted on disk
        else:
            req = urllib.request.Request(url, headers={
                "User-Agent": "template-versions/1",
                "Accept": "application/vnd.npm.install-v1+json, application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                data = r.read().decode()
        _cache[url] = json.loads(data)
    except (OSError, urllib.error.URLError, ValueError) as e:
        raise FetchError(f"{url}: {e}") from None
    return _cache[url]


def _npm_url(base, name, kind):
    if base.startswith("file://"):
        return f"{base}/{urllib.parse.quote(name, safe='')}.{kind}.json"
    quoted = name.replace("/", "%2f")
    return f"{base}/{quoted}/latest" if kind == "latest" else f"{base}/{quoted}"


def npm_latest(name):
    return _get(_npm_url(NPM, name, "latest"))["version"]


def npm_versions(name):
    return list(_get(_npm_url(NPM, name, "doc")).get("versions", {}))


def pypi_doc(name):
    return _get(f"{PYPI}/{name}.json" if PYPI.startswith("file://") else f"{PYPI}/{name}/json")


def pypi_latest(name):
    return pypi_doc(name)["info"]["version"]


def pypi_versions(name):
    rel = pypi_doc(name).get("releases", {})
    return [v for v, files in rel.items() if not files or not all(f.get("yanked") for f in files)]


def eol(product):
    return _get(f"{EOL}/{product}.json")


def gh_latest_tag(repo):
    return _get(f"{GITHUB}/repos/{repo}/releases/latest")["tag_name"]


def bundled_native_modules(expo_version):
    return _get(f"{JSDELIVR}/expo@{expo_version}/bundledNativeModules.json")


# --- holds ---------------------------------------------------------------------------------------

def load_holds():
    holds = []
    if not HOLDS_FILE.is_file():
        return holds
    for n, line in enumerate(HOLDS_FILE.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 3 or not re.match(r"(<=|<)\s*\d", cols[2]):
            raise SystemExit(f"{HOLDS_FILE}:{n}: want template<TAB>package<TAB><bound>[<TAB>reason<TAB>ref]")
        holds.append({"template": cols[0], "package": cols[1], "bound": cols[2].strip(),
                      "reason": cols[3] if len(cols) > 3 else "", "ref": cols[4] if len(cols) > 4 else ""})
    return holds


def hold_for(holds, template, package):
    for h in holds:
        if h["package"] == package and h["template"] in ("*", template):
            return h
    return None


# --- manifests -----------------------------------------------------------------------------------

REQ_LINE = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*==\s*([^\s;#]+)")


def norm_py(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def python_pins(tdir):
    pins = []  # (name, extras, version, file)
    for f in sorted(tdir.glob("requirements*.txt")):
        for line in f.read_text().splitlines():
            m = REQ_LINE.match(line)
            if m:
                pins.append((m.group(1), m.group(2) or "", m.group(3), f.name))
    py = tdir / "pyproject.toml"
    if py.is_file():
        doc = tomllib.loads(py.read_text())
        specs = list(doc.get("project", {}).get("dependencies", []))
        for group in doc.get("project", {}).get("optional-dependencies", {}).values():
            specs += group
        for group in doc.get("dependency-groups", {}).values():
            specs += [s for s in group if isinstance(s, str)]
        specs += doc.get("build-system", {}).get("requires", [])
        for s in specs:
            m = REQ_LINE.match(s)
            if m:
                pins.append((m.group(1), m.group(2) or "", m.group(3), "pyproject.toml"))
    return pins


def npm_pins(tdir):
    pj = tdir / "package.json"
    if not pj.is_file():
        return []
    doc = json.loads(pj.read_text())
    pins = []
    for section in ("dependencies", "devDependencies"):
        for name, spec in doc.get(section, {}).items():
            pins.append((name, spec, section))
    return pins


def workflows(tdir):
    wf = tdir / ".github" / "workflows"
    return sorted(wf.glob("*.y*ml")) if wf.is_dir() else []


# --- the check -----------------------------------------------------------------------------------

def row(template, kind, name, pinned, target, cls, note="", file="", section=""):
    return {"template": template, "kind": kind, "name": name, "pinned": pinned, "target": target,
            "class": cls, "note": note, "file": file, "section": section}


def check_npm(t, tdir, holds, errors):
    pins = npm_pins(tdir)
    if not pins:
        return []
    nvmrc = (tdir / ".nvmrc").read_text().strip() if (tdir / ".nvmrc").is_file() else ""
    exact = [(n, s, sec) for n, s, sec in pins if re.match(r"^\d", s)]
    names = [n for n, _, _ in exact]
    expo_pin = next((s for n, s, _ in exact if n == "expo"), None)
    bnm, expo_target = {}, None
    try:
        if expo_pin:
            major = vtuple(expo_pin)[0]
            expo_target = newest(npm_versions("expo"), lambda v: vtuple(v)[0] == major)
            bnm = bundled_native_modules(expo_target)
    except FetchError as e:
        errors.append(str(e))
    with cf.ThreadPoolExecutor(8) as ex:
        latest = dict(zip(names, ex.map(_safe(npm_latest, errors), names)))
    rows = []
    for name, spec, section in pins:
        if not re.match(r"^\d", spec):
            rows.append(row(t, "npm", name, spec, spec, "current", "not an exact pin (policy: exact)", "package.json", section))
            continue
        lat = latest.get(name)
        if lat is None:
            continue
        target, note = lat, ""
        h = hold_for(holds, t, name)
        try:
            if name == "expo" and expo_target:
                target, note = expo_target, f"newest of SDK {vtuple(spec)[0]}"
            elif name in bnm:
                target = re.sub(r"^[~^>=<\s]+", "", bnm[name])
                note = f"expo@{expo_target} bundledNativeModules"
            elif name == "@types/node" and nvmrc.isdigit():
                target = newest(npm_versions(name), lambda v: vtuple(v)[0] == int(nvmrc)) or spec
                note = f".nvmrc {nvmrc}"
            if h and not in_bound(target, h["bound"]):
                target = newest(npm_versions(name), lambda v, b=h["bound"]: in_bound(v, b)) or spec
                note = f"hold {h['bound']}: {h['reason']}".strip()
        except FetchError as e:
            errors.append(str(e))
            continue
        cls = classify(spec, target)
        if cls == "current" and target != lat and vtuple(lat) > vtuple(spec):
            cls = "held"
        rows.append(row(t, "npm", name, spec, target, cls, (note + (f"; latest {lat}" if target != lat else "")).strip("; "),
                        "package.json", section))
    return rows


def _safe(fn, errors):
    def wrapped(arg):
        try:
            return fn(arg)
        except FetchError as e:
            errors.append(str(e))
            return None
    return wrapped


def check_pypi(t, tdir, holds, errors):
    pins = python_pins(tdir)
    names = sorted({norm_py(n) for n, _, _, _ in pins})
    with cf.ThreadPoolExecutor(8) as ex:
        latest = dict(zip(names, ex.map(_safe(pypi_latest, errors), names)))
    rows = []
    for name, extras, ver, file in pins:
        lat = latest.get(norm_py(name))
        if lat is None:
            continue
        target, note = lat, ""
        h = hold_for(holds, t, name)
        if h and not in_bound(target, h["bound"]):
            try:
                target = newest(pypi_versions(norm_py(name)), lambda v, b=h["bound"]: in_bound(v, b)) or ver
            except FetchError as e:
                errors.append(str(e))
                continue
            note = f"hold {h['bound']}: {h['reason']}; latest {lat}".strip()
        cls = classify(ver, target)
        if cls == "current" and target != lat and vtuple(lat) > vtuple(ver):
            cls = "held"
        rows.append(row(t, "pypi", name + extras, ver, target, cls, note, file))
    return rows


def check_runtimes(t, tdir, errors):
    rows = []
    try:
        nvmrc = tdir / ".nvmrc"
        if nvmrc.is_file():
            pinned = nvmrc.read_text().strip()
            lts = [c for c in eol("nodejs") if c.get("lts")]
            if lts and pinned.isdigit():
                best = max(lts, key=lambda c: vtuple(str(c["cycle"])))
                cls = "major" if int(str(best["cycle"])) > int(pinned) else "current"
                rows.append(row(t, "node", ".nvmrc", pinned, str(best["cycle"]), cls,
                                f"newest LTS since {best['lts']}" if cls != "current" else "", ".nvmrc"))
        pys = []
        for wf in workflows(tdir):
            for m in re.finditer(r"python-version:\s*\[([^\]]*)\]|python-version:\s*['\"]?(3\.\d+)", wf.read_text()):
                pys += re.findall(r"3\.\d+", m.group(1) or m.group(2))
        df = tdir / "Dockerfile"
        if df.is_file():
            pys += re.findall(r"FROM\s+python:(3\.\d+)", df.read_text())
        if pys:
            newest_py = max((str(c["cycle"]) for c in eol("python")), key=vtuple)
            top = max(pys, key=vtuple)
            cls = "minor" if vtuple(newest_py) > vtuple(top) else "current"
            rows.append(row(t, "python", "CI matrix / Dockerfile", top, newest_py, cls, "", "ci.yml"))
    except FetchError as e:
        errors.append(str(e))
    return rows


USES = re.compile(r"uses:\s*([^\s@#]+)@(\S+)(?:\s*#\s*(v?[\d.]+))?")


def check_actions(t, tdir, errors):
    rows, fails = [], []
    seen = {}
    for wf in workflows(tdir):
        text = wf.read_text()
        for m in USES.finditer(text):
            ref, at, comment = m.groups()
            if ref.startswith((OWN_WORKFLOWS, "./")):
                continue
            if not re.fullmatch(r"[0-9a-f]{40}", at):
                fails.append(f"{t}: unpinned action {ref}@{at} in {wf.name} (policy: pin by commit SHA)")
                continue
            repo = "/".join(ref.split("/")[:2])
            if (repo, comment) in seen:
                continue
            seen[(repo, comment)] = True
            try:
                tag = gh_latest_tag(repo)
            except FetchError as e:
                errors.append(str(e))
                continue
            pinned = (comment or "?").lstrip("v")
            cls = classify(pinned, tag.lstrip("v")) if comment else "major"
            rows.append(row(t, "action", repo, pinned, tag.lstrip("v"), cls,
                            "update the SHA and the # comment by hand" if cls != "current" else "", wf.name))
        if re.search(r"runs-on:\s*ubuntu-latest", text):
            rows.append(row(t, "runner", "runs-on", "ubuntu-latest", "ubuntu-<version>", "minor",
                            "pin a runner version", wf.name))
    return rows, fails


def check(templates, holds):
    rows, fails, errors = [], [], []
    for t in templates:
        tdir = ROOT / t
        if not tdir.is_dir():
            fails.append(f"{t}: template directory missing under {ROOT}")
            continue
        rows += check_npm(t, tdir, holds, errors)
        rows += check_pypi(t, tdir, holds, errors)
        rows += check_runtimes(t, tdir, errors)
        r, f = check_actions(t, tdir, errors)
        rows += r
        fails += f
    return rows, fails, errors


# --- output --------------------------------------------------------------------------------------

def actionable(r):
    return r["class"] in ("major", "minor", "patch")


def render_md(rows, fails, errors, today, quiet):
    out = [f"# Template dependency drift — {today}", "",
           f"Generated by `dotfiles/scripts/template-versions.py` over `{ROOT}`.", ""]
    counts = {}
    for r in rows:
        counts[r["class"]] = counts.get(r["class"], 0) + 1
    out.append("**" + " · ".join(f"{counts.get(c, 0)} {c}" for c in ORDER) + f" · {len(fails)} FAIL**")
    out.append("")
    for f in fails:
        out.append(f"- **FAIL** {f}")
    for e in errors:
        out.append(f"- **ERROR** fetch failed: {e}")
    if fails or errors:
        out.append("")
    for t in dict.fromkeys(r["template"] for r in rows):
        trs = [r for r in rows if r["template"] == t and (actionable(r) or not quiet)]
        if not trs:
            continue
        trs.sort(key=lambda r: (ORDER[r["class"]], r["kind"], r["name"]))
        out += [f"## {t}", "", "| kind | name | pinned | target | class | note |", "|---|---|---|---|---|---|"]
        for r in trs:
            out.append(f"| {r['kind']} | {r['name']} | {r['pinned']} | {r['target']} | {r['class']} | {r['note']} |")
        out.append("")
    return "\n".join(out) + "\n"


def render_tsv(rows):
    cols = ["template", "kind", "name", "pinned", "target", "class", "note", "file", "section"]
    return "\t".join(cols) + "\n" + "".join("\t".join(r[c] for c in cols) + "\n" for r in rows)


def summary(rows, fails, errors, templates):
    lines = [f"FAIL\t{f}" for f in fails] + [f"WARN\tfetch failed: {e}" for e in errors]
    for t in templates:
        mine = [r for r in rows if r["template"] == t]
        pkgs = [r for r in mine if r["kind"] in ("npm", "pypi")]
        n = {c: sum(1 for r in pkgs if r["class"] == c) for c in ("major", "minor", "patch")}
        held = sum(1 for r in mine if r["class"] == "held")
        if any(n.values()):
            lines.append(f"WARN\t{t}: {n['major']} major · {n['minor']} minor · {n['patch']} patch to take"
                         f" ({held} held) — template-versions.py --apply --template {t}")
        elif mine:
            lines.append(f"INFO\t{t}: packages current ({held} held)")
        for r in mine:
            if r["kind"] not in ("npm", "pypi") and actionable(r):
                lines.append(f"WARN\t{t}: {r['kind']} {r['name']} {r['pinned']} -> {r['target']}"
                             f" (by hand: {r['note'] or 'see the decision log'})")
    return "\n".join(lines) + "\n"


def write_private(path, text):
    path.write_text(text)
    os.chmod(path, 0o600)


# --- apply ---------------------------------------------------------------------------------------

def run(cmd, cwd, log):
    log.append(f"$ {' '.join(cmd)}")
    try:
        p = subprocess.run(cmd, check=False, cwd=cwd, capture_output=True, text=True, timeout=CMD_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        log.append(str(e))
        return False
    log.append((p.stdout + p.stderr).rstrip())
    return p.returncode == 0


def snapshot(tdir, dest):
    for pat in MANIFESTS + SIDE_EFFECTS:
        for f in tdir.glob(pat):
            shutil.copy2(f, dest / f.name)


def restore(tdir, dest, manifests=True):
    """Copy the snapshot back: everything, or (manifests=False) only the init.sh side effects."""
    for f in dest.iterdir():
        if manifests or f.name in SIDE_EFFECTS:
            shutil.copy2(f, tdir / f.name)


def undo_side_effects(tdir, dest, is_git):
    """After a run: put back what init.sh personalised, and in an own-repo template any other
    tracked file it changed outside the manifests. Returns the files put back by git."""
    restore(tdir, dest, manifests=False)
    if not is_git:
        return []
    st = subprocess.run(["git", "-C", str(tdir), "diff", "--name-only"], check=False, capture_output=True, text=True)
    keep = {p.name for pat in MANIFESTS for p in tdir.glob(pat)}
    stray = [f for f in st.stdout.split() if f not in keep]
    if stray:
        subprocess.run(["git", "-C", str(tdir), "checkout", "--", *stray], check=False, capture_output=True)
    return stray


def rewrite_python(tdir, bumps):
    for f in list(tdir.glob("requirements*.txt")) + [tdir / "pyproject.toml"]:
        if not f.is_file():
            continue
        text = orig = f.read_text()
        for r in bumps:
            name, target = r["name"].split("[")[0], r["target"]
            pat = rf"(^|[\"'\s]){re.escape(name)}(\[[^\]]*\])?(\s*==\s*){re.escape(r['pinned'])}(?=[\s\"';#,]|$)"
            text = re.sub(pat, lambda m, n=name, v=target: f"{m.group(1)}{n}{m.group(2) or ''}{m.group(3)}{v}",
                          text, flags=re.MULTILINE | re.IGNORECASE)
        if text != orig:
            f.write_text(text)


def install_cmds(bumps):
    cmds = []
    for section, flag in (("dependencies", "--save-prod"), ("devDependencies", "--save-dev")):
        specs = [f"{r['name']}@{r['target']}" for r in bumps if r["kind"] == "npm" and r["section"] == section]
        if specs:
            cmds.append(["npm", "install", "--save-exact", flag, "--no-audit", "--no-fund", *specs])
    return cmds


def attempt(tdir, bumps, log):
    for cmd in install_cmds(bumps):
        if not run(cmd, tdir, log):
            return False
    py = [r for r in bumps if r["kind"] == "pypi"]
    if py:
        rewrite_python(tdir, py)
    # --ci: every template's test.sh skips its local gate scan with it, which would always block an
    # uncommitted bump for want of a CHANGELOG line; the gate runs on the commit instead.
    return run(["./init.sh"], tdir, log) and run(["./test.sh", "--ci"], tdir, log)


def note_stray(files):
    if files:
        print("  reverted files the run changed outside the manifests: " + ", ".join(files))


def tail(log, n=15):
    return "\n".join("\n".join(log).splitlines()[-n:])


def apply(templates, rows, dry):
    rc = 0
    for t in templates:
        tdir = ROOT / t
        bumps = [r for r in rows if r["template"] == t and r["kind"] in ("npm", "pypi") and actionable(r)]
        manual = [r for r in rows if r["template"] == t and r["kind"] not in ("npm", "pypi") and actionable(r)]
        print(f"\n## {t}")
        for r in manual:
            print(f"- manual: {r['kind']} {r['name']} {r['pinned']} -> {r['target']} ({r['note']})")
        if not bumps:
            print("- nothing to apply")
            continue
        for r in bumps:
            print(f"- plan: {r['name']} {r['pinned']} -> {r['target']} ({r['class']})")
        if dry:
            for cmd in install_cmds(bumps):
                print("  would run: " + " ".join(cmd))
            if any(r["kind"] == "pypi" for r in bumps):
                print("  would rewrite the == pins, then ./init.sh && ./test.sh")
            continue
        is_git = (tdir / ".git").exists()
        if is_git:
            st = subprocess.run(["git", "-C", str(tdir), "status", "--porcelain"],
                                check=False, capture_output=True, text=True)
            if st.stdout.strip():
                print("- REFUSED: own git repo with a dirty tree; commit or stash first")
                rc = 1
                continue
        with tempfile.TemporaryDirectory() as snap:
            snap = Path(snap)
            snapshot(tdir, snap)
            log = []
            if attempt(tdir, bumps, log):
                print(f"- APPLIED all {len(bumps)}; ./init.sh and ./test.sh --ci passed")
                note_stray(undo_side_effects(tdir, snap, is_git))
                continue
            first = tail(log)
            restore(tdir, snap)
            majors = [r for r in bumps if r["class"] == "major"]
            rest = [r for r in bumps if r["class"] != "major"]
            if majors and rest:
                log = []
                if attempt(tdir, rest, log):
                    note_stray(undo_side_effects(tdir, snap, is_git))
                    print(f"- APPLIED {len(rest)} patch/minor; REJECTED majors: "
                          + ", ".join(f"{r['name']}@{r['target']}" for r in majors))
                    print("  first attempt ended with:\n" + "\n".join("    " + x for x in first.splitlines()))
                    rc = 1
                    continue
                first = tail(log)
                restore(tdir, snap)
            run(["./init.sh"], tdir, [])
            note_stray(undo_side_effects(tdir, snap, is_git))
            print("- FAILED, restored; last output:\n" + "\n".join("    " + x for x in first.splitlines()))
            rc = 1
    return rc


# --- main ----------------------------------------------------------------------------------------

def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip())
        return 0
    quiet = dry = do_apply = do_summary = False
    out_dir, only = None, []
    it = iter(argv)
    for a in it:
        if a == "--quiet":
            quiet = True
        elif a == "--dry-run":
            dry = True
        elif a == "--apply":
            do_apply = True
        elif a == "--summary":
            do_summary = True
        elif a in ("--out", "--template"):
            v = next(it, None)
            if not v:
                print(f"{a} needs a value", file=sys.stderr)
                return 2
            if a == "--out":
                out_dir = Path(v)
            else:
                only.append(v.rstrip("/"))
        else:
            print(f"unknown argument: {a} (see --help)", file=sys.stderr)
            return 2
    if dry and not do_apply:
        print("--dry-run only goes with --apply", file=sys.stderr)
        return 2
    if not ROOT.is_dir():
        print(f"TEMPLATES_ROOT not found: {ROOT}", file=sys.stderr)
        return 2
    templates = os.environ["TEMPLATE_LIST"].split() if os.environ.get("TEMPLATE_LIST") else CURATED
    if only:
        unknown = [o for o in only if o not in templates]
        if unknown:
            print(f"not a curated template: {', '.join(unknown)}", file=sys.stderr)
            return 2
        templates = only
    today = os.environ.get("TODAY") or dt.date.today().isoformat()
    try:
        holds = load_holds()
    except SystemExit as e:
        print(e, file=sys.stderr)
        return 2
    rows, fails, errors = check(templates, holds)

    if do_apply:
        if errors:
            print("\n".join(f"fetch failed: {e}" for e in errors), file=sys.stderr)
            return 2
        return apply(templates, rows, dry)

    md = render_md(rows, fails, errors, today, quiet)
    if do_summary:
        sys.stdout.write(summary(rows, fails, errors, templates))
    else:
        sys.stdout.write(md)
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        md_path = out_dir / f"template-versions-{today}.md"
        tsv_path = out_dir / f"template-versions-{today}.tsv"
        write_private(md_path, md)
        write_private(tsv_path, render_tsv(rows))
        print(f"wrote {md_path}\nwrote {tsv_path}", file=sys.stderr)
    if errors:
        return 2
    return 1 if fails or any(actionable(r) for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
