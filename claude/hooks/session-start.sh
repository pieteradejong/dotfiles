#!/bin/bash
#
# session-start.sh — Claude Code SessionStart hook.
#
# Orientation, not enforcement. Two jobs:
#
#   1. Print what is up in the repository the session starts in — `whatsup
#      --brief`: git state (a dirty tree, a detached HEAD, unpushed work), the
#      decision log's last entry and open Verified items, the changelog's
#      [Unreleased] count, open TODO items — so the state is in context before
#      the first edit rather than discovered at commit time. At the workspace
#      root (~/dev, not a repo) it prints the workspace TODO and the recently
#      active repos; anywhere else outside a repo it prints nothing.
#   2. Record a baseline (HEAD and what was already dirty) under
#      ~/.local/state/claude-logs/<session_id>.base, so the Stop hook
#      (stop-log-check.sh) can tell what this session changed.
#
# Read-only in the repo: it runs no command that writes there, touches the
# network, or changes git config, which is what makes it safe in do-not-touch
# repos. The baseline lives under ~/.local/state, never inside a repo, and is
# not written for exempt repos (scratch, forks, the skip list).
#
# Until 2026-10-13 this hook printed nothing when the repo was clean (Rule of
# Silence). It now always prints the brief in a repo — the summary is wanted
# every time, not only when something is wrong (design-decisions.md D33).
#
# It never exits non-zero. A hook that can wedge a session is worse than no
# hook, so every step is guarded and failure is treated as "nothing to say".
#
# Implements ~/dev/CLAUDE.md § Session workflow, step 1.
#
# Registered in claude/settings.json:
#   "hooks": { "SessionStart": [ { "hooks": [ { "type": "command",
#     "command": "~/dev/dotfiles/claude/hooks/session-start.sh", "timeout": 10 } ] } ] }
#
# Env:  CLAUDE_LOGS_STATE_DIR  (default ~/.local/state/claude-logs)
#       DEV_ROOT               (default ~/dev)
#
# Tested by scripts/test-logs.sh.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHATSUP="$HOOK_DIR/../../bin/whatsup"
STATE_DIR="${CLAUDE_LOGS_STATE_DIR:-$HOME/.local/state/claude-logs}"

input="$(cat 2>/dev/null || true)"

if top="$(git --no-optional-locks rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
  sid=""
  command -v jq >/dev/null 2>&1 && sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  if [ -n "$sid" ]; then
    # shellcheck source=security/lib/logs.sh
    if . "$HOOK_DIR/../../security/lib/logs.sh" 2>/dev/null && ! logs_exempt "$top" >/dev/null; then
      logs_write_baseline "$top" "$STATE_DIR" "$sid" || true
    fi
  fi
fi

[ -x "$WHATSUP" ] && NO_COLOR=1 "$WHATSUP" --brief 2>/dev/null
exit 0
