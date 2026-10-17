#!/bin/bash
#
# prompt-followup.sh — Claude Code UserPromptSubmit hook: what every prompt owes.
#
# Runs on every prompt typed in a session whose working directory is under
# ~/dev. It prints three lines, which Claude Code adds to the turn's context:
# where this repo's decisions go, where its open items go (and how many are
# open), and that the files written are to be checked with doc-dupes. The
# standing instruction behind it: every command in the workspace is followed
# up by documenting decisions and TODOs in markdown, then checking those
# documents for redundancy (~/dev/CLAUDE.md § Hard rules, design-decisions D37).
#
# Orientation, not enforcement — the Stop hook (stop-log-check.sh) is the
# enforcing half: it refuses to end a turn whose changes or closing summary
# are not covered. This hook is what makes the rule fire on EVERY prompt,
# including ones that change nothing; the Stop hook only has evidence to act
# on when something changed or open work was named.
#
# Read-only in the repo; never exits non-zero; silent outside ~/dev, in exempt
# repos (scratch, forks, the skip list) and on any failure. Which file is the
# decision log and which repos are exempt come from security/lib/logs.sh.
#
# Contract (Claude Code hooks): the event arrives as JSON on stdin (session_id,
# cwd, prompt). Plain stdout with exit 0 is added to the context.
#
# Env:  DEV_ROOT   the workspace (default ~/dev)
#
# Registered in claude/settings.json under "UserPromptSubmit". Tested by
# scripts/test-logs.sh.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="${DEV_ROOT:-$HOME/dev}"
DEV_ROOT="$(cd "$DEV_ROOT" 2>/dev/null && pwd -P)" || exit 0

input="$(cat 2>/dev/null || true)"
cwd=""
command -v jq >/dev/null 2>&1 && cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"
cwd="$(cd "$cwd" 2>/dev/null && pwd -P)" || exit 0
case "$cwd/" in "$DEV_ROOT"/*) ;; *) exit 0 ;; esac

# shellcheck source=security/lib/logs.sh
. "$HOOK_DIR/../../security/lib/logs.sh" 2>/dev/null || exit 0

count_open() { grep -cE '^[[:space:]]*[-*] \[ \]' "$1" 2>/dev/null | tr -d ' '; }

if top="$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
  logs_exempt "$top" >/dev/null && exit 0
  if dec="$(logs_decisions_file "$top")"; then
    dec_state="$dec (last: $(logs_last_decision "$top/$dec" | cut -c1-70))"
  else
    dec_state="docs/DECISIONS.md (create it on the first entry)"
  fi
  if [ -f "$top/TODO.md" ]; then
    todo_state="TODO.md ($(count_open "$top/TODO.md") open)"
  else
    todo_state="TODO.md (create it on the first item; workspace-level items: ~/dev/TODO.md)"
  fi
else
  logs_exempt "$cwd" >/dev/null && exit 0   # scratch and _to_delete, also when not a repo
  dec_state="dotfiles/docs/design-decisions.md (workspace tooling) or the private DECISIONS.md"
  # shellcheck disable=SC2088 # a path to show, not to expand
  todo_state="~/dev/TODO.md ($(count_open "$DEV_ROOT/TODO.md") open)"
fi

printf 'followup (~/dev/CLAUDE.md § Session workflow, steps 3–6): end this turn in markdown —\n'
printf '  decisions → %s   |   open items → %s\n' "$dec_state" "$todo_state"
printf '  then run doc-dupes on the files you wrote; chat and commit messages are not a record.\n'
exit 0
