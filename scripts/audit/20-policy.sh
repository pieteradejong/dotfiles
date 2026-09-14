#!/usr/bin/env bash
#
# 20-policy.sh — does each repo follow the rules already written in CLAUDE.md?
#
# Nothing here is a new standard. Every check maps to a line in
# ~/dev/CLAUDE.md that is currently enforced only when somebody remembers to
# look. The mapping is in dotfiles/docs/dev-audit.md.
#
# Forks are skipped: CLAUDE.md says never relicense or reshape someone else's
# repo, so reporting "peppol-commons has no MIT LICENSE" is noise, not signal.


# The canonical spelling, from CLAUDE.md § Licensing. "Peter" and
# "Pieter Arthur" both exist in the tree today and are drift, not intent.
CANONICAL_HOLDER="Pieter de Jong"

# Paths every repo's .gitignore should cover, from CLAUDE.md § Before committing.
# Tested with `git check-ignore` - what git actually does - rather than by
# grepping the .gitignore text, which misses negations and directory scoping.
GITIGNORE_BASELINE=".env sub/.env .DS_Store __pycache__/x.pyc .venv/x venv/x node_modules/x sub/node_modules/x"

audit_policy() {
  # Category for every finding below. Declared here, not at file scope:
  # dev-audit.sh sources all modules before running any, so a global would
  # be overwritten by whichever module was sourced last. `local` is
  # dynamically scoped in bash, so the check_* helpers still see it.
  local CAT=policy
  hdr "Policy compliance (CLAUDE.md)"
  local repo name reason

  while IFS= read -r repo; do
    name="$(repo_name "$repo")"
    is_skipped "$name" >/dev/null && continue
    if reason="$(is_fork "$name")"; then
      note "SKIP $name (policy checks: $reason)"
      continue
    fi

    check_license  "$repo" "$name"
    check_gitignore "$repo" "$name"
    check_ci        "$repo" "$name"
  done < <(list_repos)
}

# --- LICENSE ----------------------------------------------------------------
# CLAUDE.md: "Public repo => LICENSE file, in the first commit." A public repo
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
  # and CLAUDE.md names it first in the before-committing list. Reporting it at
  # the same WARN level as node_modules is what let seven repos sit in that
  # state, one of which does track a live .env.
  case " $missing " in
    *' .env '*)
      finding FAIL "$CAT" "$name" gitignore-env ".env is not ignored - a stray commit publishes it"
      missing="$(printf '%s' "$missing" | sed 's/ \.env\([[:space:]]\|$\)/\1/')"
      ;;
  esac

  [ -n "${missing// /}" ] && \
    finding WARN "$CAT" "$name" gitignore-gaps "not ignored:$missing"
  return 0
}

# --- CI ---------------------------------------------------------------------
# Informational only. CLAUDE.md does not require CI everywhere - one-off
# scripts and dormant experiments legitimately have none - but the coverage
# number is the thing PROJECTS_META_NOTES.md tracks by hand today.
check_ci() {
  local repo="$1" name="$2"
  if [ ! -d "$repo/.github/workflows" ]; then
    finding INFO "$CAT" "$name" no-ci "no .github/workflows"
  fi
}
