#!/usr/bin/env bash
#
# test.sh — every test in this repo, in one command. CI runs exactly this.
#
#   ./test.sh                 all suites
#   ./test.sh gate            one suite: shellcheck | gate | tools | dotaudit
#   ./test.sh --verbose       pass --verbose through to each suite
#
# Suites:
#   [shellcheck] every security-relevant shell script, at default severity
#   gate        scripts/test-security-gate.sh   (the commit/push gate)
#   tools       scripts/test-security-tools.sh  (Claude guard hook, GitHub sweep,
#                                                weekly audit, dotaudit gate module)
#   dotaudit    scripts/test-dev-audit.sh       (the read-only workspace audit)
#
# Requires: git 2.54+, gitleaks, shellcheck, jq. pre-commit is optional.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

VERBOSE=""
ONLY=""
for a in "$@"; do
  case "$a" in
    --verbose) VERBOSE="--verbose" ;;
    shellcheck|gate|tools|dotaudit) ONLY="$a" ;;
    -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

SHELLCHECK_FILES="
test.sh
security/gate.sh
security/patterns.sh
security/lib/visibility.sh
claude/hooks/guard-git-bypass.sh
scripts/dev-audit.sh
scripts/audit/lib.sh
scripts/audit/10-git-hygiene.sh
scripts/audit/20-policy.sh
scripts/audit/30-privacy.sh
scripts/audit/40-disk.sh
scripts/audit/50-gate.sh
scripts/audit/render-report.sh
scripts/github-security-sweep.sh
scripts/security-audit.sh
scripts/sync-dotfiles.sh
scripts/test-security-gate.sh
scripts/test-security-tools.sh
"

RESULTS=""
FAILED=0
run_suite() { # <name> <command...>
  local name="$1" rc; shift
  [ -z "$ONLY" ] || [ "$ONLY" = "$name" ] || return 0
  printf '\n\033[1m════ %s ════\033[0m\n' "$name"
  "$@"; rc=$?
  if [ "$rc" = 0 ]; then RESULTS="$RESULTS\n  ✓ $name"; else RESULTS="$RESULTS\n  ✗ $name (exit $rc)"; FAILED=1; fi
}

# shellcheck disable=SC2329 # invoked through run_suite
shellcheck_all() {
  command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is not installed"; return 1; }
  # shellcheck disable=SC2086 # the list is deliberately word-split
  shellcheck -x $SHELLCHECK_FILES && echo "shellcheck: clean ($(echo $SHELLCHECK_FILES | wc -w | tr -d ' ') files)"
}

run_suite shellcheck shellcheck_all
run_suite gate     bash scripts/test-security-gate.sh $VERBOSE
run_suite tools    bash scripts/test-security-tools.sh $VERBOSE
run_suite dotaudit bash scripts/test-dev-audit.sh $VERBOSE

printf '\n\033[1m════ test.sh summary ════\033[0m%b\n' "$RESULTS"
exit "$FAILED"
