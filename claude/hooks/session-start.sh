#!/bin/bash
#
# session-start.sh — Claude Code SessionStart hook.
#
# Orientation, not enforcement. It reports the state of the repository the
# session is starting in, so a dirty tree, a detached HEAD or unpushed work
# surfaces before the first edit rather than at commit time. Read-only: it runs
# no command that writes, touches the network, or changes git config, which is
# what makes it safe in do-not-touch repos.
#
# Rule of Silence: prints nothing when everything is normal, so a quiet start
# means a clean start. Whatever it writes to stdout is added to the session's
# context, so it stays to one short line per anomaly.
#
# It never exits non-zero. A hook that can wedge a session is worse than no
# hook, so every git call is guarded and failure is treated as "nothing to say".
#
# Implements ~/dev/CLAUDE.md § Session workflow, step 1.
#
# Registered in claude/settings.json:
#   "hooks": { "SessionStart": [ { "hooks": [ { "type": "command",
#     "command": "~/dev/dotfiles/claude/hooks/session-start.sh" } ] } ] }

set -u

# Much of ~/dev is not a git repo (the workspace root itself isn't). Nothing to report.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$toplevel" ] || exit 0
repo="$(basename "$toplevel")"

out=""
add() { out="${out}⚠ ${1}"$'\n'; }

# Uncommitted work. --porcelain so the count is stable across git versions.
dirty="$(git status --porcelain 2>/dev/null | grep -c '' || true)"
[ "${dirty:-0}" -gt 0 ] && add "${dirty} uncommitted file(s)"

# Branch, and whether local commits exist that the remote has never seen.
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ -z "$branch" ]; then
  add "detached HEAD at $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
elif upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
  ahead="$(git rev-list --count "${upstream}..HEAD" 2>/dev/null || true)"
  [ "${ahead:-0}" -gt 0 ] && add "${ahead} unpushed commit(s) on ${branch}"
else
  add "${branch} has no upstream"
fi

# Policy: every project has a .gitignore before its first commit.
[ -e "${toplevel}/.gitignore" ] || add "no .gitignore"

[ -n "$out" ] && printf 'Session start — %s\n%s' "$repo" "$out"

exit 0
