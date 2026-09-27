#!/usr/bin/env bash
#
# 20-policy.sh — does each repo follow the repo standards?
#
# Nothing here is a new standard. Every check id is a row in
# docs/policy/repo-standards.md § Enforcement, which names the rule it enforces
# and whether the commit/push gate also blocks it. The gate blocks what a commit
# or push INTRODUCES; this module FAILs what is already there, so existing debt
# stays visible until the repo is next touched and fixed. The check table is in
# dotfiles/docs/dev-audit.md.
#
# Forks are skipped: repo-standards.md § Licensing says never relicense or
# reshape someone else's repo, so reporting "peppol-commons has no MIT LICENSE"
# is noise, not signal.

# CANONICAL_HOLDER ("Peter" and "Pieter Arthur" both exist in the tree and are
# drift, not intent), MEDIA_EXT_ERE, IMAGE_EXT_ERE, IMAGE_MAX_BYTES,
# JS_LOCKFILES, PY_LOCKFILES, NPM_RANGE_ERE, ACTION_PINNED_ERE, SECURITY_CI_ERE
# and OWN_GITHUB_OWNER live in security/patterns.sh, shared with the gate so the
# two can never disagree about what the standard is.
# shellcheck source-path=SCRIPTDIR/../../security
# shellcheck source=patterns.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/security/patterns.sh"

# Paths every repo's .gitignore should cover, from repo-standards.md
# § .gitignore baseline. Tested with `git check-ignore` - what git actually
# does - rather than by grepping the .gitignore text, which misses negations and
# directory scoping. .env.example is deliberately absent: it is meant to be
# committed.
GITIGNORE_BASELINE=".env sub/.env .env.local sub/.env.local .DS_Store __pycache__/x.pyc .venv/x venv/x node_modules/x sub/node_modules/x .mypy_cache/x .ruff_cache/x .pytest_cache/x .vscode/x .idea/x debug.log"

audit_policy() {
  # Category for every finding below. Declared here, not at file scope:
  # dev-audit.sh sources all modules before running any, so a global would
  # be overwritten by whichever module was sourced last. `local` is
  # dynamically scoped in bash, so the check_* helpers still see it.
  local CAT=policy
  hdr "Policy compliance (repo-standards.md)"
  local repo name reason tracked

  while IFS= read -r repo; do
    name="$(repo_name "$repo")"
    is_skipped "$name" >/dev/null && continue
    if reason="$(is_fork "$name")"; then
      note "SKIP $name (policy checks: $reason)"
      continue
    fi

    # One ls-files per repo, shared by the checks below. Paths unquoted
    # (core.quotepath=off) so a non-ASCII filename still matches its rule.
    tracked="$(git_ro "$repo" -c core.quotepath=off ls-files)"

    check_license     "$repo" "$name"
    check_gitignore   "$repo" "$name"
    check_security_ci "$repo" "$name" "$tracked"
    check_pins        "$repo" "$name" "$tracked"
    check_lockfiles   "$repo" "$name" "$tracked"
    check_media       "$repo" "$name" "$tracked"
    check_actions     "$repo" "$name" "$tracked"
  done < <(list_repos)
}

# --- LICENSE ----------------------------------------------------------------
# repo-standards.md § Licensing: "Public repo => LICENSE in the first commit." A public repo
# with no LICENSE is all-rights-reserved by default, which is the opposite of
# what a personal repo on GitHub is for.
check_license() {
  local repo="$1" name="$2" lic vis holder declared f
  lic=""
  for f in "$repo"/LICENSE*; do [ -e "$f" ] && { lic="$f"; break; }; done
  vis="$(repo_visibility "$name")"

  if [ -z "$lic" ]; then
    case "$vis" in
      PUBLIC)  finding FAIL "$CAT" "$name" no-license "public repo with no LICENSE = all rights reserved" ;;
      PRIVATE) finding INFO "$CAT" "$name" no-license "private repo, no LICENSE (harmless)" ;;
      *)       finding WARN "$CAT" "$name" no-license "no LICENSE file (visibility unknown; try --github)" ;;
    esac
    return 0
  fi

  # A LICENSE file that is not a license. templates/node-express/base-api's
  # LICENSE is 251 bytes of captured terminal output from an interrupted CLI
  # prompt ("Looks like there's already a license file for this project.",
  # ANSI escapes, "Exiting..."), and the repo is public. Every other check here
  # treats the file's existence as satisfying the rule, so this passed silently.
  # Test: a real license names a license or asserts rights, in more than a line.
  if ! LC_ALL=C grep -qiE 'licen[sc]e|copyright|all rights reserved|permission is hereby|CC0|public domain' "$lic" 2>/dev/null \
     || [ "$(LC_ALL=C tr -cd '\033' < "$lic" 2>/dev/null | wc -c | tr -d ' ')" -gt 0 ]; then
    finding FAIL "$CAT" "$name" license-malformed \
      "$(basename "$lic") does not parse as a license (no license text, or contains terminal escapes)"
  fi

  # Copyright holder spelling.
  holder="$(LC_ALL=C grep -m1 -oE 'Copyright \(c\) [0-9]{4} .*' "$lic" 2>/dev/null | sed 's/^Copyright (c) [0-9]\{4\} //')"
  if [ -n "$holder" ] && [ "$holder" != "$CANONICAL_HOLDER" ]; then
    finding WARN "$CAT" "$name" copyright-drift "LICENSE says '$holder', canonical is '$CANONICAL_HOLDER'"
  fi

  # Manifest must agree with the LICENSE file. `npm init -y` writes "ISC";
  # a repo claiming two licenses is worse than one claiming none.
  declared=""
  if [ -f "$repo/package.json" ]; then
    declared="$(LC_ALL=C sed -n 's/.*"license"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$repo/package.json" | head -1)"
  fi
  if [ -z "$declared" ] && [ -f "$repo/pyproject.toml" ]; then
    declared="$(LC_ALL=C sed -n 's/^[[:space:]]*license[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$repo/pyproject.toml" | head -1)"
  fi
  if [ -n "$declared" ]; then
    if LC_ALL=C grep -qi 'MIT License' "$lic" 2>/dev/null && [ "$declared" != "MIT" ]; then
      finding WARN "$CAT" "$name" license-mismatch "LICENSE is MIT but manifest says '$declared'"
    fi
  fi
}

# --- .gitignore -------------------------------------------------------------
check_gitignore() {
  local repo="$1" name="$2" p missing=""
  if [ ! -f "$repo/.gitignore" ]; then
    finding FAIL "$CAT" "$name" no-gitignore "no .gitignore at all"
    return 0
  fi
  for p in $GITIGNORE_BASELINE; do
    git_ro "$repo" check-ignore -q "$p" || missing="$missing $p"
  done

  # .env is separated out of the general gaps list and raised to FAIL. The rest
  # of the baseline is hygiene - an unignored __pycache__ costs disk. An
  # unignored .env is the single most common way a credential reaches a remote,
  # and the baseline names it first. Reporting it at the same WARN level as
  # node_modules is what let seven repos sit in that state, one of which does
  # track a live .env. .env.local is the same file under the name most
  # frameworks load it by, so it is raised with it.
  local envs="" rest=""
  for p in $missing; do
    case "$p" in
      .env|.env.local) envs="$envs $p" ;;
      *) rest="$rest $p" ;;
    esac
  done
  [ -n "$envs" ] && \
    finding FAIL "$CAT" "$name" gitignore-env "not ignored:$envs - a stray commit publishes it"
  missing="$rest"

  [ -n "${missing// /}" ] && \
    finding WARN "$CAT" "$name" gitignore-gaps "not ignored:$missing"
  return 0
}

# _files <tracked> <ERE> — the tracked paths matching ERE, one per line.
_files() { printf '%s\n' "$1" | LC_ALL=C grep -E -- "$2"; }

# _list <newline-separated paths> — "a, b, c (+N more)" for a finding message.
_list() {
  printf '%s\n' "$1" | awk 'NF { n++; if (n <= 5) s = s (n > 1 ? ", " : "") $0 }
    END { if (n > 5) s = s " (+" (n - 5) " more)"; printf "%s", s }'
}

# --- security CI ------------------------------------------------------------
# CLAUDE.md hard rule: "Every repo's CI includes gitleaks via the reusable
# workflow." The reusable workflow is now security-reusable.yml: gitleaks over
# full history plus the gate itself over what was pushed, the backstop for
# commits that never passed through this machine's gate (web edits, --no-verify,
# another machine). A workflow that calls only gitleaks-reusable.yml is
# secrets-only and does not satisfy it.
check_security_ci() {
  local repo="$1" name="$2" tracked="$3" wf f found=""
  wf="$(_files "$tracked" '^\.github/workflows/[^/]+\.ya?ml$')"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    LC_ALL=C grep -qE -- "$SECURITY_CI_ERE" "$repo/$f" 2>/dev/null && { found="$f"; break; }
  done <<EOF
$wf
EOF
  [ -n "$found" ] && return 0
  if [ -z "$wf" ]; then
    finding FAIL "$CAT" "$name" no-security-ci "no .github/workflows - add a job calling security-reusable.yml"
  else
    finding FAIL "$CAT" "$name" no-security-ci "no workflow calls security-reusable.yml (gitleaks + gate)"
  fi
}

# --- exact version pins -----------------------------------------------------
# CLAUDE.md hard rule: "Exact version pins — no ^ or ~." A range means the next
# `npm install` on another machine can pull code nobody reviewed. Counts and
# file names only; the specs themselves are not secret but the report stays
# short.
#
# peerDependencies are NOT checked: a peer spec declares which host versions a
# package is compatible with - it installs nothing - and an exact peer pin
# breaks every consumer on the next patch release.
check_pins() {
  local repo="$1" name="$2" tracked="$3" f n total=0 files="" out
  # package.json. Without jq nothing can be parsed, and a silent pass would
  # look exactly like a clean repo.
  if ! command -v jq >/dev/null 2>&1 && _files "$tracked" '(^|/)package\.json$' >/dev/null; then
    finding WARN "$CAT" "$name" unpinned-deps-skipped "jq not installed; package.json pins not checked"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$repo/$f" ] || continue
    # Matched inside jq, as the gate does, so both read package.json the same way.
    n="$(jq -r --arg re "$NPM_RANGE_ERE" '[(.dependencies, .devDependencies, .optionalDependencies) // {} | to_entries[] | .value
           | select(type == "string")
           | select(test("^(workspace:|file:|link:|git\\+|git:|github:|https?:)") | not)
           | sub("^npm:(@[^/]+/)?[^@]+@"; "")
           | select(test($re))] | length' "$repo/$f" 2>/dev/null)" || true
    n="${n:-0}"
    [ "$n" -gt 0 ] 2>/dev/null && { total=$((total + n)); files="$files$f"$'\n'; }
  done <<EOF
$(_files "$tracked" '(^|/)package\.json$' | LC_ALL=C grep -vE '(^|/)node_modules/')
EOF
  # requirements*.txt, and requirements/*.txt. Options (-r, -e, -c, --hash...)
  # and direct references (name @ url) are not version specs.
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$repo/$f" ] || continue
    n="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$repo/$f" \
         | LC_ALL=C grep -vE '^[[:space:]]*($|-)|[[:space:]]@[[:space:]]|://' \
         | LC_ALL=C grep -cvE '==')" || true
    n="${n:-0}"
    [ "$n" -gt 0 ] 2>/dev/null && { total=$((total + n)); files="$files$f"$'\n'; }
  done <<EOF
$(_files "$tracked" '(^|/)requirements[^/]*\.txt$|(^|/)requirements/[^/]+\.txt$')
EOF
  # pyproject.toml, via tomllib: a TOML parser, because the same dependency can
  # be spelled five ways and a regex over the text gets at least one wrong.
  local py
  py="$(_files "$tracked" '(^|/)pyproject\.toml$')"
  if [ -n "$py" ]; then
    if ! python3 -c 'import tomllib' 2>/dev/null; then
      finding WARN "$CAT" "$name" unpinned-deps-skipped "python3 has no tomllib (needs 3.11+); pyproject.toml pins not checked"
    else
      out="$(cd "$repo" && printf '%s\n' "$py" | python3 -c '
import re, sys, tomllib
EXACT = re.compile(r"^(==)?\s*[0-9][0-9A-Za-z.+!-]*$")
def pep508_ok(s):
    return "==" in s or " @ " in s
def poetry_ok(v):
    if isinstance(v, str):
        return bool(EXACT.match(v.strip()))
    if isinstance(v, dict):
        if any(k in v for k in ("path", "git", "url")):
            return True
        return poetry_ok(v.get("version", ""))
    if isinstance(v, list):
        return all(poetry_ok(x) for x in v)
    return False
for path in sys.stdin.read().split():
    try:
        with open(path, "rb") as fh:
            d = tomllib.load(fh)
    except Exception:
        continue
    bad = 0
    proj = d.get("project", {})
    specs = list(proj.get("dependencies", []))
    for group in proj.get("optional-dependencies", {}).values():
        specs += group
    for group in d.get("dependency-groups", {}).values():
        specs += [s for s in group if isinstance(s, str)]
    bad += sum(1 for s in specs if isinstance(s, str) and not pep508_ok(s))
    poetry = d.get("tool", {}).get("poetry", {})
    tables = [poetry.get("dependencies", {}), poetry.get("dev-dependencies", {})]
    tables += [g.get("dependencies", {}) for g in poetry.get("group", {}).values()]
    for t in tables:
        bad += sum(1 for k, v in t.items() if k != "python" and not poetry_ok(v))
    if bad:
        print(f"{bad}\t{path}")
' 2>/dev/null)"
      while IFS="$(printf '\t')" read -r n f; do
        [ -n "$f" ] || continue
        total=$((total + n)); files="$files$f"$'\n'
      done <<EOF
$out
EOF
    fi
  fi
  [ "$total" -gt 0 ] && \
    finding FAIL "$CAT" "$name" unpinned-deps "$total dependency spec(s) not pinned to an exact version in: $(_list "$files")"
  return 0
}

# --- one package manager per project ----------------------------------------
# repo-standards.md § Dependencies: one package manager per project. Two
# lockfiles from the same ecosystem in one directory means two managers resolve
# the same manifest differently, and CI installs whichever it finds first.
check_lockfiles() {
  local repo="$1" name="$2" tracked="$3" group lf dirs=""
  for group in "$JS_LOCKFILES" "$PY_LOCKFILES"; do
    dirs="$dirs$(
      for lf in $group; do
        _files "$tracked" "(^|/)${lf//./\\.}\$" | sed -E 's#(^|/)[^/]+$##; s#^$#.#'
      done | LC_ALL=C sort | uniq -d
    )"$'\n'
  done
  dirs="$(printf '%s' "$dirs" | LC_ALL=C grep -v '^$')" || true
  [ -n "$dirs" ] && \
    finding FAIL "$CAT" "$name" multiple-lockfiles "lockfiles from two package managers in: $(_list "$dirs")"
  return 0
}

# --- media and weights --------------------------------------------------------
# CLAUDE.md hard rule: "No media or large binaries in git (video, audio,
# weights, big datasets) — not even private." Video, audio and model weights
# FAIL at any size; images only above IMAGE_MAX_BYTES, because icons and
# screenshots belong in a repo.
check_media() {
  local repo="$1" name="$2" tracked="$3" hits f sz big=""
  hits="$(printf '%s\n' "$tracked" | LC_ALL=C grep -iE -- "$MEDIA_EXT_ERE")" || true
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$repo/$f" ] || continue
    sz="$(wc -c < "$repo/$f" 2>/dev/null | tr -d ' ')"
    [ "${sz:-0}" -gt "$IMAGE_MAX_BYTES" ] && big="$big$f"$'\n'
  done <<EOF
$(printf '%s\n' "$tracked" | LC_ALL=C grep -iE -- "$IMAGE_EXT_ERE")
EOF
  hits="$(printf '%s\n%s' "$hits" "$big" | LC_ALL=C grep -v '^$')" || true
  [ -n "$hits" ] && \
    finding FAIL "$CAT" "$name" tracked-media "media, weights or images over $((IMAGE_MAX_BYTES / 1048576)) MB tracked: $(_list "$hits")"
  return 0
}

# --- Actions pinned by SHA ----------------------------------------------------
# supply-chain.md: a tag is a mutable pointer; whoever controls the action's repo
# can move it to new code that then runs with this repo's token. Own reusable
# workflows (OWN_GITHUB_OWNER/...) are exempt: they are this policy's own code,
# and security-reusable.yml is called @main on purpose so a rule change reaches
# every repo at once.
check_actions() {
  local repo="$1" name="$2" tracked="$3" f n total=0 files=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$repo/$f" ] || continue
    n="$(LC_ALL=C grep -E '^[[:space:]-]*uses:' "$repo/$f" \
         | sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//; s/[[:space:]]*$//' \
         | LC_ALL=C grep -vE -- "$ACTION_PINNED_ERE" \
         | LC_ALL=C grep -cvE "^${OWN_GITHUB_OWNER}/")" || true
    n="${n:-0}"
    [ "$n" -gt 0 ] 2>/dev/null && { total=$((total + n)); files="$files$f"$'\n'; }
  done <<EOF
$(_files "$tracked" '^\.github/workflows/[^/]+\.ya?ml$|(^|/)action\.ya?ml$')
EOF
  [ "$total" -gt 0 ] && \
    finding FAIL "$CAT" "$name" unpinned-action "$total action reference(s) not pinned to a commit SHA in: $(_list "$files")"
  return 0
}
