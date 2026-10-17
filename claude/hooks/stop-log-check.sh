#!/bin/bash
#
# stop-log-check.sh — Claude Code Stop hook: are this session's changes covered?
#
# Runs every time the assistant is about to finish a turn. It looks at what the
# session changed in the current repo and, once per change set, refuses to let
# the turn end until the decision log, changelog and TODO list are either
# updated or the assistant has said why no entry is owed. It asks the question;
# it does not answer it — "is this a decision worth recording" stays a judgment
# (private DECISIONS #8, superseded by #12).
#
# What it checks (rules: docs/policy/repo-standards.md § Changelog,
# ai-instructions.md § Decisions need verification, § Open items live in TODO.md,
# § Logs are checked for redundancy):
#   - behaviour-relevant files changed, CHANGELOG.md not touched
#   - behaviour-relevant files changed, the decision log not touched
#   - a decision entry added this session has no Verified: line (NOT YET is fine)
#   - a changelog line added this session cites a decision that does not exist
#   - the closing summary names open work (NOT YET, TODO, "still open", …) or a
#     new decision entry is NOT YET, and no TODO.md was touched — repo or ~/dev
#   - a TODO.md, decision log or CHANGELOG.md touched this session now holds a
#     duplicate or near-duplicate entry (bin/doc-dupes)
#
# At the workspace root (~/dev itself, or a directory under it that is in no
# repo) only the last two apply, against ~/dev/TODO.md, over the files the
# transcript shows written there.
#
# Contract (Claude Code hooks): the event arrives as JSON on stdin
# (session_id, cwd, transcript_path, stop_hook_active). Printing
# {"decision":"block","reason":…} on stdout with exit 0 keeps the turn open and
# shows the reason to the assistant. Exit 0 with no output lets it end.
#
# Never loops: stop_hook_active is true when the assistant is already continuing
# because of this hook, and then it always lets the turn end. Never nags: one
# block per change set (the changed paths plus the open-work lines that matched),
# remembered in <state>/<session_id>.ack. Never wedges: any failure (no jq, no
# git, no repo, malformed input) exits 0 silently.
#
# "What changed" is measured against the baseline the SessionStart hook wrote
# (<state>/<session_id>.base), or against HEAD when there is none, plus every
# file the transcript shows an Edit/Write call on. Shared logic:
# security/lib/logs.sh. Exempt repos (scratch, forks, the skip list) are skipped.
#
# Env:  CLAUDE_LOGS_STATE_DIR   (default ~/.local/state/claude-logs)
#       DEV_ROOT                (default ~/dev)
#
# Registered in claude/settings.json under "Stop". Tested by scripts/test-logs.sh.

set -u

STATE_DIR="${CLAUDE_LOGS_STATE_DIR:-$HOME/.local/state/claude-logs}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_DUPES="$HOOK_DIR/../../bin/doc-dupes"
DEV_ROOT="${DEV_ROOT:-$HOME/dev}"
DEV_ROOT="$(cd "$DEV_ROOT" 2>/dev/null && pwd -P || printf '%s' "$DEV_ROOT")"

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

[ "$(field .stop_hook_active)" = true ] && exit 0
sid="$(field .session_id)"
cwd="$(field .cwd)"
transcript="$(field .transcript_path)"
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"
cd "$cwd" 2>/dev/null || exit 0

# shellcheck source=security/lib/logs.sh
. "$HOOK_DIR/../../security/lib/logs.sh" 2>/dev/null || exit 0

root_mode=0
if top="$(git --no-optional-locks rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
  logs_exempt "$top" >/dev/null && exit 0
else
  cwd="$(pwd -P)"
  case "$cwd/" in "$DEV_ROOT"/*) top="$DEV_ROOT"; root_mode=1 ;; *) exit 0 ;; esac
  logs_exempt "$cwd" >/dev/null && exit 0   # scratch and _to_delete, also when not a repo
fi

base=""
case "$sid" in
  ''|*[!A-Za-z0-9_.-]*) sid="" ;;
  *) [ "$root_mode" = 0 ] && [ -f "$STATE_DIR/$sid.base" ] && base="$STATE_DIR/$sid.base" ;;
esac
head=HEAD
if [ "$root_mode" = 0 ]; then
  [ -n "$base" ] || base="$(logs_newest_baseline "$top" "$STATE_DIR" 2>/dev/null || true)"
  head="$(sed -n '1s/^HEAD //p' "$base" 2>/dev/null)"
  [ -n "$head" ] && [ "$head" != EMPTY ] && git --no-optional-locks cat-file -e "$head^{commit}" 2>/dev/null || head=HEAD
  changed="$( { logs_changed_paths "$top" "$base"; logs_transcript_paths "$top" "$transcript"; } | awk 'NF' | LC_ALL=C sort -u)"
else
  changed="$(logs_transcript_paths "$top" "$transcript" | logs_outside_repos "$top" | awk 'NF' | LC_ALL=C sort -u)"
fi

# The closing summary: does it name work left open?
last_text="$(logs_transcript_last_text "$transcript")"
open_lines="$(printf '%s\n' "$last_text" | LC_ALL=C grep -E -- "$LOGS_OPEN_WORK_ERE" | head -n 5 || true)"
[ -n "$changed" ] || [ -n "$open_lines" ] || exit 0

nondoc="$(printf '%s\n' "$changed" | LC_ALL=C grep -vE -- "$CHANGELOG_EXEMPT_ERE" || true)"
touched() { printf '%s\n' "$changed" | grep -qx -- "$1"; }
first3() { printf '%s\n' "$1" | awk 'NF { c++; if (c <= 3) s = s (c > 1 ? ", " : "") $0 } END { if (c > 3) s = s " (+" (c - 3) " more)"; printf "%s", s }'; }

dec=""
[ "$root_mode" = 0 ] && dec="$(logs_decisions_file "$top" || true)"
reasons=""
add() { reasons="${reasons}- $1"$'\n'; }

if [ "$root_mode" = 0 ] && [ -n "$nondoc" ]; then
  n="$(printf '%s\n' "$nondoc" | wc -l | tr -d ' ')"
  if ! touched CHANGELOG.md; then
    if [ -f "$top/CHANGELOG.md" ]; then
      add "$n file(s) changed with no CHANGELOG.md change: $(first3 "$nondoc"). Add a line under ## [Unreleased] (Added / Changed / Fixed / Removed), naming the decision entry when there is one."
    else
      add "$n file(s) changed and this repo has no CHANGELOG.md: $(first3 "$nondoc"). Create it (Keep a Changelog shape, a ## [Unreleased] block) with a line for this change."
    fi
  elif [ -f "$top/CHANGELOG.md" ] && ! logs_has_unreleased "$top/CHANGELOG.md"; then
    add "CHANGELOG.md has no '## [Unreleased]' heading; this session's entry must go under one."
  fi
  if [ -z "$dec" ]; then
    add "No decision log in this repo. If this session closed off an alternative someone could reopen, create docs/DECISIONS.md with a numbered entry (Date, Context, Decision, Verified). Otherwise say so."
  elif ! touched "$dec"; then
    add "No entry added to $dec this session. Confirm in your reply that no alternative was closed off, or add a numbered entry with a Verified: line."
  fi
fi

new_not_yet=0
if [ -n "$dec" ] && touched "$dec"; then
  old_nums="$(git --no-optional-locks show "$head:$dec" 2>/dev/null | LC_ALL=C sed -nE 's/^## +(ADR-)?D?0*([0-9]+)([.:]|[[:space:]]|$).*/\2/p' | LC_ALL=C sort -u)"
  logs_decisions "$top/$dec" | while IFS=$'\t' read -r num status _ title; do
    printf '%s\n' "$old_nums" | grep -qx -- "$num" && continue
    printf '%s\t%s\t%s\n' "$num" "$status" "$title"
  done > "${TMPDIR:-/tmp}/stop-log-check.$$" 2>/dev/null
  while IFS=$'\t' read -r num status title; do
    [ -n "$num" ] || continue
    [ "$status" = none ] && add "Entry $num in $dec (\"$title\") has no Verified: line. Add the command run and its output, or 'Verified: NOT YET'."
    [ "$status" = "NOT YET" ] && new_not_yet=1
  done < "${TMPDIR:-/tmp}/stop-log-check.$$"
  rm -f "${TMPDIR:-/tmp}/stop-log-check.$$"
fi

if touched CHANGELOG.md && [ -n "$dec" ]; then
  missing="$(git --no-optional-locks diff "$head" -- CHANGELOG.md 2>/dev/null | grep '^+' | logs_refs_missing "$top/$dec" | tr '\n' ' ')"
  [ -n "${missing// /}" ] && add "CHANGELOG.md cites decision(s) ${missing}that have no entry in $dec."
fi

# Open work named, no TODO written — in the repo or at the workspace level.
todo_touched=0
touched TODO.md && todo_touched=1
[ "$root_mode" = 0 ] && logs_transcript_paths "$DEV_ROOT" "$transcript" | grep -qx TODO.md && todo_touched=1
if [ "$todo_touched" = 0 ] && { [ -n "$open_lines" ] || [ "$new_not_yet" = 1 ]; }; then
  # shellcheck disable=SC2088 # a path to show, not to expand
  if [ "$root_mode" = 1 ]; then where="~/dev/TODO.md"
  elif [ -f "$top/TODO.md" ]; then where="TODO.md (or ~/dev/TODO.md for a workspace-level item)"
  else where="TODO.md — create it at the repo root (or use ~/dev/TODO.md for a workspace-level item)"; fi
  if [ "$new_not_yet" = 1 ] && [ -z "$open_lines" ]; then why="A decision entry added this session is Verified: NOT YET"
  else why="Your reply names open work ($(first3 "$(printf '%s\n' "$open_lines" | cut -c1-80)"))"; fi
  add "$why, and no TODO.md was touched. Put each open item in $where as '- [ ] <item> — <date>, <the decision or report it points to>', or say in one line that no item is owed."
fi

# Redundancy: the logs this session touched must not now hold duplicates.
if [ -x "$DOC_DUPES" ]; then
  for f in TODO.md "$dec" "$([ "$root_mode" = 0 ] && touched CHANGELOG.md && printf 'CHANGELOG.md')"; do
    [ -n "$f" ] && touched "$f" && [ -f "$top/$f" ] || continue
    opt=""; [ "$f" = TODO.md ] && [ "$root_mode" = 0 ] && opt="--workspace"
    # shellcheck disable=SC2086 # $opt is one flag or nothing
    DEV_ROOT="$DEV_ROOT" "$DOC_DUPES" --quiet $opt "$top/$f" 2>/dev/null | head -n 8 | while IFS=$'\t' read -r loc kind text; do
      [ -n "$loc" ] && printf '%s\t%s\t%s\n' "${loc#"$top"/}" "$kind" "$text"
    done > "${TMPDIR:-/tmp}/stop-log-check.$$" 2>/dev/null
    while IFS=$'\t' read -r loc kind text; do
      [ -n "$loc" ] && add "$loc: $kind — $text. Merge or remove the duplicate."
    done < "${TMPDIR:-/tmp}/stop-log-check.$$"
    rm -f "${TMPDIR:-/tmp}/stop-log-check.$$"
  done
fi

[ -n "$reasons" ] || exit 0

# One nudge per change set. The ack is keyed on the set of changed paths plus
# the open-work lines that matched, so a new file or a newly named open item
# reopens the question and a reply that says "no entry owed" closes it.
key="$(printf '%s\n%s\n' "$changed" "$open_lines" | cksum | cut -d' ' -f1)"
if [ -n "$sid" ]; then
  ack="$STATE_DIR/$sid.ack"
  [ -f "$ack" ] && [ "$(cat "$ack" 2>/dev/null)" = "$key" ] && exit 0
  mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$key" > "$ack" 2>/dev/null && chmod 600 "$ack" 2>/dev/null
fi

where_name="$(basename "$top")"; [ "$root_mode" = 1 ] && where_name="the workspace (~/dev)"
reason="stop-log-check (~/dev/CLAUDE.md § Session workflow, steps 3–6): before finishing, cover this session's changes in $where_name:
${reasons}Compare any entry you added against the existing ones for the same subject — doc-dupes catches repeated wording, not repeated meaning. If an item is not owed (formatting, typo, pure refactor, no alternative closed off, nothing left open), say so in one line in your reply and finish; this check will not ask again for the same set of changed files."
jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
exit 0
