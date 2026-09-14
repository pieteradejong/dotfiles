#!/bin/bash
#
# github-security-sweep.sh — GitHub-side protection for every repo I own.
#
#   github-security-sweep.sh            dry run: show current state and what would change
#   github-security-sweep.sh --apply    enable what is missing
#   github-security-sweep.sh --check    exit 1 if anything is missing (for the weekly audit)
#
#   --owner NAME   GitHub account to sweep (default: pieteradejong)
#   --out DIR      where the TSV goes (default: ~/dev/audit-reports; never a git repo)
#   --quiet        no table on stdout
#
# Per repo (owned, not a fork, not archived, not on the private skip list):
#   secret scanning                 enabled   (public repos; private needs a paid add-on)
#   secret scanning push protection enabled   (same)
#   Dependabot vulnerability alerts enabled   (all repos; alerts only, never PRs)
#
# SETTINGS ONLY. This script never commits to, clones, or pushes any repo.
# Why these settings: docs/policy/security-and-privacy.md § GitHub baseline.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIPLIST_FILE="${SKIPLIST_FILE:-$DOTFILES_DIR/private/audit/skiplist.conf}"

MODE=dry-run
OWNER=pieteradejong
OUT_DIR="$HOME/dev/audit-reports"
QUIET=0

usage() { sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply; shift ;;
    --check) MODE=check; shift ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --out)   OUT_DIR="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "gh is required" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated (gh auth login)" >&2; exit 2; }

# Fail closed on the skip list: without it a do-not-touch repo would be swept.
if [ ! -f "$SKIPLIST_FILE" ]; then
  echo "skip list not found: $SKIPLIST_FILE (clone the private companion repo into dotfiles/private/)" >&2
  exit 2
fi
SKIP_NAMES=" $(grep -E '^skip:' "$SKIPLIST_FILE" | cut -d: -f2 | tr '\n' ' ') "

mkdir -p "$OUT_DIR" || exit 2
if git --no-optional-locks -C "$OUT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "refusing to write into a git repo: $OUT_DIR" >&2
  exit 3
fi
TSV="$OUT_DIR/github-security-$(date +%Y-%m-%d).tsv"
printf 'repo\tvisibility\tsecret_scanning\tpush_protection\tdependabot_alerts\taction\tresult\n' > "$TSV"
chmod 600 "$TSV" 2>/dev/null

N_OK=0; N_DRIFT=0; N_FIXED=0; N_ERR=0; N_SKIP=0; N_UNAVAIL=0

row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$TSV"
  [ "$QUIET" = 1 ] || printf '%-40s %-8s ss=%-11s pp=%-11s dep=%-8s %-28s %s\n' "$@"
}

read_state() { # <slug> -> "secret_scanning<TAB>push_protection<TAB>dependabot"
  local slug="$1" ss dep
  ss="$(gh api "repos/$slug" --jq '[(.security_and_analysis.secret_scanning.status // "unavailable"), (.security_and_analysis.secret_scanning_push_protection.status // "unavailable")] | @tsv' 2>/dev/null)" \
    || ss="$(printf 'error\terror')"
  if gh api "repos/$slug/vulnerability-alerts" --silent >/dev/null 2>&1; then dep=enabled; else dep=disabled; fi
  printf '%s\t%s' "$ss" "$dep"
}

gh repo list "$OWNER" --limit 1000 --json name,nameWithOwner,visibility,isFork,isArchived,owner \
  --jq '.[] | [.name, .nameWithOwner, .visibility, .isFork, .isArchived, .owner.login] | @tsv' > "$OUT_DIR/.sweep-repos.$$" 2>/dev/null \
  || { echo "gh repo list failed" >&2; rm -f "$OUT_DIR/.sweep-repos.$$"; exit 2; }

while IFS="$(printf '\t')" read -r name slug vis fork archived login; do
  [ "$login" = "$OWNER" ] || continue
  if [ "$fork" = true ] || [ "$archived" = true ]; then N_SKIP=$((N_SKIP + 1)); continue; fi
  case "$SKIP_NAMES" in *" $name "*) N_SKIP=$((N_SKIP + 1)); row "$slug" "$vis" - - - skipped "on private skip list"; continue ;; esac

  state="$(read_state "$slug")"
  ss="$(printf '%s' "$state" | cut -f1)"; pp="$(printf '%s' "$state" | cut -f2)"; dep="$(printf '%s' "$state" | cut -f3)"

  need_ss=0; need_dep=0
  case "$ss:$pp" in
    enabled:enabled) ;;
    unavailable:*|*:unavailable) [ "$vis" = PUBLIC ] && need_ss=1 ;;   # public repos always have it; private needs the add-on
    *) need_ss=1 ;;
  esac
  [ "$dep" = enabled ] || need_dep=1

  if [ "$need_ss" = 0 ] && [ "$need_dep" = 0 ]; then
    if [ "$ss" = unavailable ]; then
      N_UNAVAIL=$((N_UNAVAIL + 1)); row "$slug" "$vis" "$ss" "$pp" "$dep" none "ok (secret scanning not offered for this private repo)"
    else
      N_OK=$((N_OK + 1)); row "$slug" "$vis" "$ss" "$pp" "$dep" none ok
    fi
    continue
  fi

  action=""
  [ "$need_ss" = 1 ] && action="enable-secret-scanning"
  [ "$need_dep" = 1 ] && action="${action:+$action+}enable-dependabot-alerts"

  if [ "$MODE" != apply ]; then
    N_DRIFT=$((N_DRIFT + 1)); row "$slug" "$vis" "$ss" "$pp" "$dep" "$action" "would change"
    continue
  fi

  err=""
  if [ "$need_ss" = 1 ]; then
    printf '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}' \
      | gh api -X PATCH "repos/$slug" --input - --silent >/dev/null 2>&1 || err="secret-scanning PATCH failed"
  fi
  if [ "$need_dep" = 1 ]; then
    gh api -X PUT "repos/$slug/vulnerability-alerts" --silent >/dev/null 2>&1 || err="${err:+$err; }dependabot PUT failed"
  fi
  state="$(read_state "$slug")"
  ss="$(printf '%s' "$state" | cut -f1)"; pp="$(printf '%s' "$state" | cut -f2)"; dep="$(printf '%s' "$state" | cut -f3)"
  if [ -n "$err" ]; then
    N_ERR=$((N_ERR + 1)); row "$slug" "$vis" "$ss" "$pp" "$dep" "$action" "ERROR: $err"
  else
    N_FIXED=$((N_FIXED + 1)); row "$slug" "$vis" "$ss" "$pp" "$dep" "$action" applied
  fi
done < "$OUT_DIR/.sweep-repos.$$"
rm -f "$OUT_DIR/.sweep-repos.$$"

printf '\n%s: %d ok, %d not offered (private), %d %s, %d applied, %d error(s), %d skipped (forks/archived/skip list)\nReport: %s\n' \
  "$MODE" "$N_OK" "$N_UNAVAIL" "$N_DRIFT" "$([ "$MODE" = apply ] && echo 'drift' || echo 'need changes')" "$N_FIXED" "$N_ERR" "$N_SKIP" "$TSV"

case "$MODE" in
  check) [ "$N_DRIFT" -eq 0 ] ;;
  apply) [ "$N_ERR" -eq 0 ] ;;
  *)     exit 0 ;;
esac
