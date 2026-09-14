#!/bin/bash
#
# guard-git-bypass.sh — Claude Code PreToolUse hook (matcher: Bash).
#
# The security gate (security/gate.sh) runs on every commit and push, but a
# handful of flags and environment variables switch it off. This hook refuses
# to let the assistant use any of them. It is a guardrail for the assistant, not
# a sandbox: a person at a terminal can still do all of these deliberately.
#
# Contract (Claude Code hooks): the tool call arrives as JSON on stdin; exit 2
# denies the call and stderr is shown to the assistant as the reason; exit 0
# allows it.
#
# Registered in claude/settings.json:
#   "hooks": { "PreToolUse": [ { "matcher": "Bash",
#     "hooks": [ { "type": "command", "command": "~/dev/dotfiles/claude/hooks/guard-git-bypass.sh" } ] } ] }
#
# Tested by scripts/test-security-tools.sh.

set -u

input="$(cat)"
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
else
  # No jq: search the raw JSON. Coarser, but a guard that fails open when a
  # dependency is missing is not a guard.
  cmd="$input"
fi
[ -n "$cmd" ] || exit 0

deny() {
  printf 'Blocked by guard-git-bypass: %s\n' "$1" >&2
  printf 'The commit/push security gate must not be bypassed or reconfigured by the assistant. Fix the finding instead, or ask the user to run the command themselves. Policy: ~/dev/dotfiles/docs/policy/security-and-privacy.md\n' >&2
  exit 2
}

# Quoted strings removed, so a commit message that merely MENTIONS a flag
# ("fix -n parsing") is not mistaken for the flag. A flag passed as a quoted
# word ('--no-verify') is still caught by the quoted-flag rules below.
bare="$(printf '%s' "$cmd" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")"

has()      { printf '%s' "$cmd"  | grep -qE -- "$1"; }
has_bare() { printf '%s' "$bare" | grep -qE -- "$1"; }

# --- anything that names the gate's override knobs, in any command ------------
has 'SECURITY_GATE_[A-Z_]*' \
  && deny "sets or references a SECURITY_GATE_* variable"
has 'core\.hooks[Pp]ath' \
  && deny "touches core.hooksPath"
has 'GIT_CONFIG_(GLOBAL|SYSTEM|NOSYSTEM|COUNT|KEY_|VALUE_|PARAMETERS)' \
  && deny "overrides git configuration through the environment"
# shellcheck disable=SC2016 # the backtick is a literal character class member, not an expansion
has '(^|[[:space:];&|(`])/usr/bin/git([[:space:];&|)`]|$)' \
  && deny "calls Apple's /usr/bin/git, which ignores config-based hooks"
has 'hook\.[A-Za-z0-9_-]+\.(enabled|command|event)' \
  && deny "reads or changes hook.<name>.* configuration"

# --- the rest only matter when git is involved ---------------------------------
has '(^|[^A-Za-z0-9_.-])git([^A-Za-z0-9_-]|$)' || exit 0

# --no-verify, including git's accepted abbreviations (--no-veri, --no-verif).
has_bare '--no-veri' \
  && deny "uses --no-verify, which skips the gate"
has "[\"']--no-veri[a-z]*[\"']" \
  && deny "uses --no-verify (quoted), which skips the gate"
has_bare '(^|[[:space:];&|(])HOME=[^[:space:]]*[[:space:]]' \
  && deny "runs a command with a replaced HOME, which hides ~/.gitconfig"
has_bare 'config([[:space:]]+[^[:space:];&|]+)*[[:space:]]+--(unset|unset-all|remove-section|rename-section)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+hook' \
  && deny "removes hook configuration"
# `git commit -n` (short for --no-verify), alone or in a flag cluster like -anm.
has_bare 'git([[:space:]]+[^[:space:];&|]+)*[[:space:]]+commit([[:space:]]+[^[:space:];&|]+)*[[:space:]]+-[A-Za-mo-z]*n[A-Za-z]*([[:space:];&|]|$)' \
  && deny "uses git commit -n, which skips the gate"
has_bare 'git([[:space:]]+[^[:space:];&|]+)*[[:space:]]+commit' && has "[\"']-[A-Za-mo-z]*n[A-Za-z]*[\"']" \
  && deny "uses git commit -n (quoted), which skips the gate"

exit 0
