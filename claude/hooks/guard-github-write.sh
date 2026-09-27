#!/bin/bash
#
# guard-github-write.sh — Claude Code PreToolUse hook (matchers: Bash, and the
# GitHub MCP tools).
#
# The security gate (security/gate.sh) scans everything that reaches GitHub
# through `git commit` and `git push`. The GitHub API is a second road in that
# never touches git: `gh api -X PUT repos/o/r/contents/f`, a gist, a release
# asset, or an MCP tool like create_or_update_file publishes content that no
# hook ever saw. This hook refuses to let the assistant take that road. Settings
# changes (e.g. github-security-sweep.sh's PATCH of security_and_analysis) and
# reads stay allowed; so does `gh repo create --push`, which pushes with git.
#
# It is a guardrail for the assistant, not a sandbox: a person at a terminal can
# still do all of these deliberately.
#
# Contract (Claude Code hooks): the tool call arrives as JSON on stdin; exit 2
# denies the call and stderr is shown to the assistant as the reason; exit 0
# allows it.
#
# Registered in claude/settings.json under PreToolUse, matchers "Bash" and
# "mcp__.*github.*". Tested by scripts/test-security-tools.sh.

set -u

input="$(cat)"
if command -v jq >/dev/null 2>&1; then
  tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
else
  # No jq: search the raw JSON. Coarser, but a guard that fails open when a
  # dependency is missing is not a guard.
  tool="$(printf '%s' "$input" | sed -nE 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
  cmd="$input"
fi

deny() {
  printf 'Blocked by guard-github-write: %s\n' "$1" >&2
  printf 'This writes repository content through the GitHub API, which skips the commit/push security gate. Commit and push with git so security/gate.sh scans it, or ask the user to do it themselves. Policy: ~/dev/dotfiles/docs/policy/security-and-privacy.md\n' >&2
  exit 2
}

# --- MCP tools: the name alone says what it does -------------------------------
if printf '%s' "$tool" | grep -qi 'github'; then
  printf '%s' "$tool" | grep -qiE '(create_or_update_file|push_files|create_file|update_file|delete_file|create_gist|update_gist|create_tree|create_blob|create_commit|update_ref|create_release|upload_release_asset)' \
    && deny "MCP tool $tool writes content to GitHub"
  exit 0
fi

[ -n "$cmd" ] || exit 0

has() { printf '%s' "$cmd" | grep -qiE -- "$1"; }

# Paths that carry repository content, as opposed to settings or metadata.
CONTENT_PATH='/contents([/?[:space:]"'"'"']|$)|/git/(blobs|trees|commits|refs|tags)|/releases|(^|[/[:space:]"'"'"'])gists([/?[:space:]"'"'"']|$)'
WRITE_METHOD='(PUT|POST|PATCH|DELETE)'

# --- gh api ---------------------------------------------------------------------
if has '(^|[^A-Za-z0-9_-])gh[[:space:]]+api([[:space:]]|$)'; then
  write=0
  has "(-X|--method)(=|[[:space:]]+)[\"']?$WRITE_METHOD" && write=1
  # Field flags make gh send a POST unless the method is forced to GET.
  if has '(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([=[:space:]]|$)' \
     && ! has "(-X|--method)(=|[[:space:]]+)[\"']?GET"; then
    write=1
  fi
  [ "$write" = 1 ] && has "$CONTENT_PATH" && deny "gh api write to a content endpoint"
fi

# --- gh gist / gh release ---------------------------------------------------------
has '(^|[^A-Za-z0-9_-])gh[[:space:]]+gist[[:space:]]+(create|new|edit)([[:space:]]|$)' \
  && deny "gh gist create/edit publishes content outside git"
has '(^|[^A-Za-z0-9_-])gh[[:space:]]+release[[:space:]]+(create|upload)([[:space:]]|$)' \
  && deny "gh release create/upload publishes content outside git"

# --- curl / wget straight at the API ---------------------------------------------
if has '(api|uploads)\.github\.com'; then
  if has '(^|[^A-Za-z0-9_-])curl([[:space:]]|$)'; then
    has "(-X|--request)(=|[[:space:]]*)[\"']?$WRITE_METHOD" && deny "curl write to the GitHub API"
    has '(^|[[:space:]])(-d|--data[a-z-]*|-F|--form|-T|--upload-file|--json)([=[:space:]]|$)' \
      && deny "curl upload to the GitHub API"
  fi
  if has '(^|[^A-Za-z0-9_-])wget([[:space:]]|$)'; then
    has '--method=|--(post|body)-(data|file)' && deny "wget write to the GitHub API"
  fi
fi

exit 0
