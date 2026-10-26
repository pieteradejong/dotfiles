#!/usr/bin/env bash
#
# test.sh — every test in this repo, in one command. CI runs exactly this.
#
#   ./test.sh                 all suites
#   ./test.sh gate            one suite: shellcheck | zsh-syntax | ruff | bin | gate |
#                                        tools | dotaudit | containers | maint | mail | pwdgen |
#                                        logs | docs
#   ./test.sh --verbose       pass --verbose through to each suite
#
# Suites:
#   [shellcheck] every security-relevant shell script, at default severity
#   [zsh-syntax] zsh -n over bin/ — shellcheck cannot parse zsh
#   [ruff]       ruff check over every Python script
#   bin         scripts/test-bin.sh             (bin/llm routing + zero-cloud
#                                                guards; bin/weekly-disk-cleanup.sh
#                                                asserted statically, never run)
#   gate        scripts/test-security-gate.sh   (the commit/push gate)
#   tools       scripts/test-security-tools.sh  (Claude guard hook, GitHub sweep,
#                                                weekly audit, dotaudit gate module)
#   dotaudit    scripts/test-dev-audit.sh       (the read-only workspace audit)
#   containers  scripts/test-containers-doctor.sh (Colima / no-Docker-Desktop doctor)
#   maint       scripts/test-mac-maintenance.sh  (report + cache quarantine, on a
#                                                fake HOME; mail stubbed)
#   mail        scripts/test-mail-report.py      (bin/mail-report against a fake
#                                                Keychain; nothing is sent)
#   pwdgen      scripts/test-pwd-gen.py          (bin/pwd-gen: lengths, classes,
#                                                wordlist, exit codes; fake pbcopy)
#   logs        scripts/test-logs.sh            (decision log + changelog coverage:
#                                                security/lib/logs.sh, bin/whatsup,
#                                                the SessionStart and Stop hooks, the
#                                                gate's log rules, the dotaudit ids)
#   docs        scripts/test-docs.py            (policy doc links, anchors, index,
#                                                workspace CLAUDE.md in sync, mermaid
#                                                diagrams well-formed and generic)
#
# Requires: git 2.54+, gitleaks, shellcheck, jq, ruff, python3. pre-commit is optional.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

VERBOSE=""
ONLY=""
for a in "$@"; do
  case "$a" in
    --verbose) VERBOSE="--verbose" ;;
    shellcheck|zsh-syntax|ruff|bin|gate|tools|dotaudit|containers|maint|mail|pwdgen|logs|docs) ONLY="$a" ;;
    -h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

SHELLCHECK_FILES="
test.sh
security/gate.sh
security/patterns.sh
security/lib/visibility.sh
security/lib/logs.sh
claude/hooks/guard-git-bypass.sh
claude/hooks/guard-github-write.sh
claude/hooks/session-start.sh
claude/hooks/stop-log-check.sh
claude/hooks/prompt-followup.sh
scripts/dev-audit.sh
scripts/audit/lib.sh
scripts/audit/10-git-hygiene.sh
scripts/audit/20-policy.sh
scripts/audit/30-privacy.sh
scripts/audit/40-disk.sh
scripts/audit/50-gate.sh
scripts/audit/render-report.sh
scripts/containers-doctor.sh
scripts/github-security-sweep.sh
scripts/mac-maintenance.sh
scripts/security-audit.sh
scripts/sync-dotfiles.sh
scripts/test-security-gate.sh
scripts/test-security-tools.sh
scripts/test-containers-doctor.sh
scripts/test-mac-maintenance.sh
scripts/test-bin.sh
scripts/test-logs.sh
bin/rcdev
bin/whatsup
bin/doc-dupes
"

# zsh scripts. shellcheck has no zsh support, so these get `zsh -n` instead of a
# lint pass. Keep the two lists disjoint: a file belongs to exactly one.
ZSH_FILES="
bin/llm
bin/weekly-disk-cleanup.sh
"

# Python scripts (stdlib only, per scripts/README.md), linted with ruff.
# bin/mail-report has no extension; ruff lints a file it is given by name.
PYTHON_FILES="
bin/mail-report
bin/pwd-gen
scripts/audit-dashboard.py
scripts/test-docs.py
scripts/test-mail-report.py
scripts/test-pwd-gen.py
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

# shellcheck disable=SC2329 # invoked through run_suite
zsh_syntax_all() {
  command -v zsh >/dev/null 2>&1 || { echo "zsh is not installed"; return 1; }
  local f rc=0
  for f in $ZSH_FILES; do
    zsh -n "$f" || { echo "zsh -n failed: $f"; rc=1; }
  done
  [ "$rc" = 0 ] && echo "zsh -n: clean ($(echo "$ZSH_FILES" | wc -w | tr -d ' ') files)"
  return "$rc"
}

# shellcheck disable=SC2329 # invoked through run_suite
ruff_all() {
  command -v ruff >/dev/null 2>&1 || { echo "ruff is not installed"; return 1; }
  # shellcheck disable=SC2086 # the list is deliberately word-split
  ruff check $PYTHON_FILES && echo "ruff: clean ($(echo $PYTHON_FILES | wc -w | tr -d ' ') files)"
}

run_suite shellcheck shellcheck_all
run_suite zsh-syntax zsh_syntax_all
run_suite ruff     ruff_all
run_suite bin      bash scripts/test-bin.sh $VERBOSE
run_suite gate     bash scripts/test-security-gate.sh $VERBOSE
run_suite tools    bash scripts/test-security-tools.sh $VERBOSE
run_suite dotaudit bash scripts/test-dev-audit.sh $VERBOSE
run_suite containers bash scripts/test-containers-doctor.sh $VERBOSE
run_suite maint    bash scripts/test-mac-maintenance.sh $VERBOSE
run_suite mail     python3 scripts/test-mail-report.py $VERBOSE
run_suite pwdgen   python3 scripts/test-pwd-gen.py $VERBOSE
run_suite logs     bash scripts/test-logs.sh $VERBOSE
run_suite docs     python3 scripts/test-docs.py $VERBOSE

printf '\n\033[1m════ test.sh summary ════\033[0m%b\n' "$RESULTS"
exit "$FAILED"
