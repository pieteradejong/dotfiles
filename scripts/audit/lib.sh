#!/usr/bin/env bash
#
# lib.sh — shared helpers for dev-audit.sh
#
# Sourced, never executed. Everything here is deliberately bash 3.2 compatible:
# macOS still ships /bin/bash 3.2, so no associative arrays, no `mapfile`, no
# `${var,,}`. The Debian test container runs bash 5, so both have to work.
#
# The one rule this file exists to enforce: every git invocation goes through
# git_ro(). See the comment on that function.
#
# shellcheck disable=SC2034 # colors and counters are used by the modules that source this

# --- output -----------------------------------------------------------------
# Colors only when stdout is a terminal, so a redirected report stays clean.
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"
  C_DIM="\033[2m"; C_BOLD="\033[1m"; C_RESET="\033[0m"
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

# Counters. Incremented by finding(); must stay in the main shell, so every
# loop that calls finding() uses `done < <(...)` rather than a pipe.
N_FAIL=0
N_WARN=0
N_INFO=0
N_SKIP=0
N_REPOS=0

# FINDINGS_TSV is set by dev-audit.sh before any module runs.
: "${FINDINGS_TSV:=}"

# finding <FAIL|WARN|INFO> <category> <repo> <check> <message>
#
# The single place a result is recorded. Appends a TSV row for the machine
# readable artifact and prints one line for the human watching.
#
# <message> must never contain a matched secret value — see 30-privacy.sh.
finding() {
  local sev="$1" cat="$2" repo="$3" check="$4" msg="$5"
  local color=""
  case "$sev" in
    FAIL) color="$C_RED";    N_FAIL=$((N_FAIL + 1)) ;;
    WARN) color="$C_YELLOW"; N_WARN=$((N_WARN + 1)) ;;
    INFO) color="$C_DIM";    N_INFO=$((N_INFO + 1)) ;;
  esac
  [ -n "$FINDINGS_TSV" ] && printf '%s\t%s\t%s\t%s\t%s\n' \
    "$sev" "$cat" "$repo" "$check" "$msg" >> "$FINDINGS_TSV"
  [ "${QUIET:-0}" = "1" ] && return 0
  printf "${color}%-4s${C_RESET} %-28s %-22s %s\n" "$sev" "$repo" "$check" "$msg"
}

note() { [ "${QUIET:-0}" = "1" ] || printf "${C_DIM}%s${C_RESET}\n" "$*"; }
hdr()  { [ "${QUIET:-0}" = "1" ] || printf "\n${C_BOLD}%s${C_RESET}\n" "$*"; }

# --- git --------------------------------------------------------------------
# git_ro <repo> <args...>
#
# EVERY git call in this tool goes through here. Two reasons, both load-bearing:
#
#   1. --no-optional-locks. The hand-run sweep on 2026-09-01 left a stale
#      .git/index.lock in 92 repos, which blocks every subsequent git command in
#      them with "another git process seems to be running". A read-only audit
#      must never be able to do that.
#   2. It is the single choke point that makes "this tool cannot write to your
#      repos" a property you can verify by reading one function instead of
#      auditing every call site.
#
# Returns git's exit status; stderr is dropped because half these commands are
# expected to fail (no upstream, no commits yet) and that is a finding, not an
# error to show the user.
git_ro() {
  local repo="$1"; shift
  git --no-optional-locks -C "$repo" "$@" 2>/dev/null
}

# --- skip list --------------------------------------------------------------
# The real list names do-not-touch repos, so it lives in the private companion
# repo cloned at dotfiles/private/. skiplist.example.conf next to this file
# shows the format. FAIL CLOSED: without the list, a do-not-touch repo would
# silently be scanned like any other, which is the one thing a skip exists to
# prevent. Tests pass SKIPLIST_FILE explicitly.
SKIPLIST_FILE="${SKIPLIST_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/private/audit/skiplist.conf}"
if [ ! -f "$SKIPLIST_FILE" ]; then
  echo "skip list not found: $SKIPLIST_FILE" >&2
  echo "clone the private companion repo into dotfiles/private/, or set SKIPLIST_FILE." >&2
  exit 2
fi

# _skiplist_field <repo-name> <mode>
# Reads skiplist.conf, format: <mode>:<repo-name>:<reason>
# Blank lines and # comments ignored. Returns the reason on stdout, or nothing.
_skiplist_field() {
  local name="$1" mode="$2" line rest m r reason
  [ -f "$SKIPLIST_FILE" ] || return 1
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    m="${line%%:*}"          # mode
    rest="${line#*:}"
    r="${rest%%:*}"          # repo name
    reason="${rest#*:}"      # everything after the second colon
    if [ "$m" = "$mode" ] && [ "$r" = "$name" ]; then
      printf '%s' "$reason"
      return 0
    fi
  done < "$SKIPLIST_FILE"
  return 1
}

# is_skipped <repo-name> — repo is excluded from the audit entirely.
# Prints the reason. Used for the do-not-touch repo, where we must not even
# run `git status`.
is_skipped() { _skiplist_field "$1" skip; }

# is_fork <repo-name> — repo is someone else's code. Excluded from policy
# checks only (licensing, .gitignore shape), because CLAUDE.md says never
# relicense or reshape a fork. Still gets git-hygiene and disk checks.
is_fork() { _skiplist_field "$1" fork; }

# --- discovery --------------------------------------------------------------
DEV_ROOT="${DEV_ROOT:-$HOME/dev}"

# list_repos — absolute path of every git repo under $DEV_ROOT, one per line.
#
# DEPTH, AND WHY IT IS A CORRECTNESS ISSUE, NOT A TUNING KNOB:
# This was maxdepth 3 until 2026-09-07, which found 94 repos and silently missed
# 21 — every repo grouped one level deeper than projects/<repo>: all 8
# templates/<stack>/<repo> sources, every repo under a client/org grouping
# directory, and a repo nested inside another repo.
#
# The miss was not merely an omission. list_non_repo_project_dirs() only checks
# for $d/.git directly beneath projects/<dir>, so the *parents* of those repos
# were reported as `not-a-repo` WARN — the report positively asserted they held
# no repo. And one of the missed client repos turned out to track live
# production credentials, invisible to every run made to date.
#
# maxdepth 5 finds 115. So does 4; 5 is one level of headroom, and costs nothing
# because the prune list below stops the expensive descents. Do not lower it.
list_repos() {
  find "$DEV_ROOT" -maxdepth 5 \
    \( -name node_modules -o -name _to_delete -o -name .venv -o -name venv \) -prune \
    -o -name .git -type d -print 2>/dev/null \
  | sed 's#/\.git$##' | LC_ALL=C sort
}

# list_non_repo_project_dirs — directories under projects/ that are not repos.
# Worth surfacing: a directory with real work in it and no git repo has no
# history and no off-machine copy.
#
# A grouping directory — one that is not itself a repo but contains repos
# (projects/<org>/<repo>) — is NOT a finding.
# Reporting it as `not-a-repo` is worse than saying nothing: it asserts there is
# no version control under that path when in fact there are five repos under it.
# That is exactly what happened before 2026-09-07; see list_repos().
list_non_repo_project_dirs() {
  local d
  for d in "$DEV_ROOT"/projects/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    case "$(basename "$d")" in _to_delete|.*) continue ;; esac
    [ -d "$d/.git" ] && continue
    # Contains a repo further down? Then it is a grouping dir, not a finding.
    if find "$d" -maxdepth 3 \
         \( -name node_modules -o -name .venv -o -name venv \) -prune \
         -o -name .git -type d -print 2>/dev/null | grep -q .; then
      continue
    fi
    printf '%s\n' "$d"
  done
}

repo_name() { basename "$1"; }

# --- sizes ------------------------------------------------------------------
# du -sk is the portable spelling (BSD and GNU agree); -sh formatting does not.
size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

human_kb() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k >= 1048576) printf "%.1f GB", k/1048576;
    else if (k >= 1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k;
  }'
}

# --- github metadata (opt-in) -----------------------------------------------
# Populated by dev-audit.sh --github into a plain "name<TAB>visibility" file.
# Without it, visibility is "unknown" and checks that depend on it soften from
# FAIL to INFO rather than guessing.
GH_CACHE="${GH_CACHE:-}"

repo_visibility() {
  local name="$1" line
  [ -n "$GH_CACHE" ] && [ -f "$GH_CACHE" ] || { printf 'unknown'; return; }
  line="$(LC_ALL=C grep -m1 "^${name}	" "$GH_CACHE" 2>/dev/null)" || true
  if [ -n "$line" ]; then printf '%s' "${line#*	}"; else printf 'no-remote-known'; fi
}
