#!/usr/bin/env bash
#
# dev-audit.sh — read-only audit of every git repo under ~/dev.
#
# The repeatable version of an audit that had been run three times by hand
# (WORKSPACE_AUDIT_2026-09-01.md, LICENSING.md, PROJECTS_META_NOTES.md), each
# time producing a markdown snapshot that went stale the day it was written.
#
# Checks four things, all of them rules already written in ~/dev/CLAUDE.md:
#   git      - uncommitted work, unpushed commits, repos with no remote, bloat
#   policy   - LICENSE, copyright spelling, .gitignore coverage, CI presence
#   privacy  - secrets and personal data in TRACKED files
#   disk     - dependency dirs, >100 MB files, repos with no off-machine copy
#   gate     - the commit/push security gate is registered, intact, not bypassed
#
# THIS TOOL NEVER WRITES TO A SCANNED REPO. No commits, no pushes, no gc, no
# .gitignore patching, no --fix mode. Every git call goes through git_ro() in
# audit/lib.sh, which passes --no-optional-locks so the audit cannot even leave
# a stale index.lock behind. See docs/dev-audit.md.
#
# Reports land OUTSIDE this repo (default ~/dev/audit-reports/) because
# dotfiles is public and a finding like "repo X has a tracked .env" must not be
# published. See docs/dev-audit.md § Why reports live outside the repo.
#
# Usage: dev-audit.sh [--only git|policy|privacy|disk|gate] [--out DIR]
#                     [--github] [--history] [--quiet] [--no-report] [--help]
#
# --history also scans git history, not just HEAD, for paths that were committed
# and later deleted. Slow; off by default. See docs/dev-audit.md.

# shellcheck source-path=SCRIPTDIR
set -u  # deliberately no -e: one failing check must not abort the sweep

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_DIR="$SCRIPT_DIR/audit"

DEV_ROOT="${DEV_ROOT:-$HOME/dev}"
OUT_DIR="${DEV_AUDIT_OUT:-$DEV_ROOT/audit-reports}"
ONLY=""
USE_GITHUB=0
SCAN_HISTORY=0
QUIET=0
WRITE_REPORT=1
STAMP="$(date +%Y-%m-%d)"

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --only)      ONLY="${2:-}"; shift 2 ;;
    --out)       OUT_DIR="${2:-}"; shift 2 ;;
    --github)    USE_GITHUB=1; shift ;;
    --history)   SCAN_HISTORY=1; shift ;;
    --quiet)     QUIET=1; shift ;;
    --no-report) WRITE_REPORT=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -d "$DEV_ROOT" ] || { echo "DEV_ROOT does not exist: $DEV_ROOT" >&2; exit 2; }

# shellcheck source=audit/lib.sh
. "$AUDIT_DIR/lib.sh"

# --- output location --------------------------------------------------------
# Refuse to write findings inside any git repo. This is the guard that keeps a
# report naming tracked secrets out of a public repo, and it is checked at
# runtime rather than trusted to the default.
if [ "$WRITE_REPORT" = 1 ]; then
  mkdir -p "$OUT_DIR" || exit 1
  if git --no-optional-locks -C "$OUT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "refusing to write findings into a git repo: $OUT_DIR" >&2
    echo "audit findings name secrets and private paths; keep them out of version control." >&2
    exit 3
  fi
  FINDINGS_TSV="$OUT_DIR/findings-$STAMP.tsv"
  : > "$FINDINGS_TSV"
  chmod 600 "$FINDINGS_TSV" 2>/dev/null || true
else
  FINDINGS_TSV=""
fi
export FINDINGS_TSV QUIET DEV_ROOT SCAN_HISTORY

# --- optional GitHub metadata ------------------------------------------------
# One bulk call, cached. Used to tell public from private, which is the
# difference between "an email in this file is fine" and "it is published".
GH_CACHE=""
if [ "$USE_GITHUB" = 1 ]; then
  if command -v gh >/dev/null 2>&1; then
    GH_CACHE="$(mktemp)"
    gh repo list --limit 500 --json name,visibility \
      --jq '.[] | [.name, .visibility] | @tsv' > "$GH_CACHE" 2>/dev/null \
      || { echo "gh repo list failed; continuing without visibility data" >&2; GH_CACHE=""; }
  else
    echo "gh not found; continuing without visibility data" >&2
  fi
fi
export GH_CACHE

# --- run ---------------------------------------------------------------------
# shellcheck source=/dev/null # modules are discovered at runtime; each is linted on its own
for m in "$AUDIT_DIR"/[0-9][0-9]-*.sh; do . "$m"; done

# Repo count is established once here rather than inside a module, so --only
# still reports the real scope.
while IFS= read -r _r; do
  is_skipped "$(basename "$_r")" >/dev/null && N_SKIP=$((N_SKIP + 1)) || N_REPOS=$((N_REPOS + 1))
done < <(list_repos)

[ "$QUIET" = 1 ] || printf "${C_BOLD}dev-audit${C_RESET}  %s  (read-only)\n" "$DEV_ROOT"

run_if() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

run_if git     && audit_git
run_if policy  && audit_policy
run_if privacy && audit_privacy
run_if disk    && audit_disk
run_if gate    && audit_gate

# --- summary ------------------------------------------------------------------
if [ "$QUIET" != 1 ]; then
  printf "\n${C_BOLD}Summary${C_RESET}  %d repos, %d skipped  |  ${C_RED}%d FAIL${C_RESET}  ${C_YELLOW}%d WARN${C_RESET}  %d INFO\n" \
    "$N_REPOS" "$N_SKIP" "$N_FAIL" "$N_WARN" "$N_INFO"
fi

if [ "$WRITE_REPORT" = 1 ]; then
  REPORT="$OUT_DIR/audit-$STAMP.md"
  "$AUDIT_DIR/render-report.sh" "$FINDINGS_TSV" "$N_REPOS" "$N_SKIP" "$DEV_ROOT" > "$REPORT"
  chmod 600 "$REPORT" 2>/dev/null || true
  [ "$QUIET" = 1 ] || printf "\nReport: %s\nData:   %s\n" "$REPORT" "$FINDINGS_TSV"
fi

[ -n "$GH_CACHE" ] && rm -f "$GH_CACHE"

# 0 = clean, 1 = at least one FAIL. WARN alone does not fail the run, so this
# is usable from a scheduler without crying wolf about dirty working trees.
[ "$N_FAIL" -gt 0 ] && exit 1
exit 0
