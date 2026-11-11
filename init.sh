#!/usr/bin/env bash
#
# init.sh — get this repo ready to work on. Idempotent: a second run changes nothing.
#
#   ./init.sh            install what is missing, then check the rest
#   ./init.sh --check    report only, install nothing (exit 1 if anything is missing)
#   ./init.sh -h         this help
#
# Steps, each reported as ok / installed / MISSING / WARN:
#   1. tools    git 2.54+, gitleaks, shellcheck, jq, ruff, python3, zsh: the ones test.sh
#               needs, the same list CI installs (.github/workflows/ci.yml). A missing tool
#               is installed with Homebrew; one that is present is never upgraded. An old
#               git is reported, not upgraded. pre-commit is optional and only reported.
#   2. private  dotfiles/private/, the private companion repo. Never cloned from here: it
#               needs your GitHub access. Missing is a WARN, and the tests that need it skip.
#   3. gate     `security/gate.sh status`: the commit/push gate is installed and intact.
#               init.sh never installs the gate or edits git hook config itself
#               (~/dev/CLAUDE.md hard rule). A broken gate is reported with the doc to follow.
#   4. smoke    `./test.sh toolchain`
#
# What this is not: restoring this machine's dotfiles into $HOME. That is
# scripts/sync-dotfiles.sh restore (README.md), which overwrites files and so stays a
# separate, deliberate step.
#
# Exit: 0 ready · 1 something is still missing · 2 usage. bash 3.2 compatible (D63).

set -euo pipefail
cd "$(dirname "$0")"

CHECK=0
case "${1:-}" in
  "")         ;;
  --check)    CHECK=1 ;;
  -h|--help)  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; exit 0 ;;
  *)          echo "init.sh: unknown option: $1 (see ./init.sh --help)" >&2; exit 2 ;;
esac

TOOLS="git gitleaks shellcheck jq ruff python3 zsh"
GIT_MIN="2.54"
BREW="${BREW:-brew}"
PROBLEMS=0

say()  { printf '  %-9s %s\n' "$1" "$2"; }
problem() { say "$1" "$2"; PROBLEMS=$((PROBLEMS + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

version_ge() { # <have> <want>
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}

# --- 1. tools -------------------------------------------------------------------------------------
step "1. tools"
missing=""
for t in $TOOLS; do
  if command -v "$t" >/dev/null 2>&1; then say ok "$t"; else missing="$missing $t"; fi
done
if [ -n "$missing" ]; then
  if [ "$CHECK" = 1 ]; then
    for t in $missing; do problem MISSING "$t (./init.sh installs it)"; done
  elif ! command -v "$BREW" >/dev/null 2>&1; then
    for t in $missing; do problem MISSING "$t (no Homebrew: https://brew.sh)"; done
  else
    for t in $missing; do
      pkg="$t"; [ "$t" = python3 ] && pkg=python
      if "$BREW" install "$pkg"; then say installed "$t"; else problem MISSING "$t (brew install $pkg failed)"; fi
    done
  fi
fi
if command -v git >/dev/null 2>&1; then
  v="$(git --version | awk '{ print $3 }')"
  if version_ge "$v" "$GIT_MIN"; then say ok "git $v (>= $GIT_MIN)"; else problem OLD "git $v: need $GIT_MIN+ (brew upgrade git; keep Homebrew git first on PATH)"; fi
fi
if command -v pre-commit >/dev/null 2>&1; then say ok "pre-commit (optional)"; else say skip "pre-commit (optional, not installed)"; fi

# --- 2. private companion repo --------------------------------------------------------------------
step "2. private"
if [ -d private/.git ]; then
  say ok "private/ is cloned"
else
  say WARN "private/ is not cloned; tests that need it skip (README.md § Security)"
fi

# --- 3. gate --------------------------------------------------------------------------------------
step "3. gate"
if [ -x security/gate.sh ] && security/gate.sh status >/dev/null 2>&1; then
  say ok "commit/push gate installed (security/gate.sh status)"
else
  problem FAIL "gate not intact: run security/gate.sh status, then follow docs/policy/security-and-privacy.md § 2"
fi

# --- 4. smoke -------------------------------------------------------------------------------------
step "4. smoke"
if ./test.sh toolchain >/dev/null 2>&1; then say ok "./test.sh toolchain"; else problem FAIL "./test.sh toolchain (run it to see what is missing)"; fi

echo
if [ "$PROBLEMS" = 0 ]; then
  echo "ready: ./test.sh to run every check, ./run.sh for everyday commands"
  exit 0
fi
echo "$PROBLEMS problem(s) left; see above"
exit 1
