#!/usr/bin/env bash
#
# stop-notify.sh — Claude Code Stop hook: a Mac notification the moment a turn ends.
#
# Claude Code's own desktop alert comes from the Notification event, which for a
# finished turn only fires after about 60 s of idle (idle_prompt). This hook
# fires on Stop, so the banner appears as soon as Claude finishes responding.
# The phone side is Remote Control push, driven by claude/CLAUDE.md
# § Notifications — no third-party push service (design-decisions D84).
#
# The banner says "Finished in <directory name>" and nothing else: no prompt or
# transcript text. It goes through bin/notify-local, so nothing leaves the Mac.
#
# Never blocks or alters the turn: prints nothing on stdout, always exits 0.
#
# Contract (Claude Code hooks): the event arrives as JSON on stdin (session_id,
# cwd, transcript_path, stop_hook_active).
#
# Env:  NOTIFY_LOCAL   the notifier (default: bin/notify-local in this repo; tests stub it)
#
# Registered in claude/settings.json under "Stop". Tested by scripts/test-logs.sh.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${NOTIFY_LOCAL:-$HOOK_DIR/../../bin/notify-local}"

input="$(cat 2>/dev/null || true)"
cwd=""
command -v jq >/dev/null 2>&1 && cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"
name="$(basename "$cwd" 2>/dev/null)"
[ -n "$name" ] || name="session"

"$NOTIFY" "Claude Code" "Finished in $name" >/dev/null 2>&1 || true
exit 0
