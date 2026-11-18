#!/usr/bin/env bash
#
# test.sh — every test in this repo, in one command. CI runs exactly this.
#
#   ./test.sh                 all suites
#   ./test.sh gate            one suite: toolchain | coverage | scan | shellcheck |
#                                        actionlint | zsh-syntax | ruff | bin | gate | tools |
#                                        dotaudit | containers | maint | pwdgen | logs |
#                                        docs | claudemd | templates | latestdeps | models | cistatus |
#                                        canary |
#                                        entry |
#                                        restore
#   ./test.sh --verbose       pass --verbose through to each suite
#   ./test.sh --docker        also run the restore suite (needs Docker: colima start);
#                             without it the suite is listed as skipped, never silently absent
#   ./test.sh --list          print each suite and what it proves; run nothing
#
# Colour only on a terminal; NO_COLOR=1 turns it off, FORCE_COLOR=1 turns it on (D67).
# Every suite runs even after one fails; the summary lists each with its exit code.
# Setup: ./init.sh. Everyday commands: ./run.sh (D63).
#
# Suites:
#   [toolchain]  the tools below are installed, git at 2.54 or newer
#   [coverage]   every tracked shell, zsh and Python script is in exactly one lint list
#                below (or LINT_EXEMPT, with a reason), and every scripts/test-* is run
#                by a suite here (or MANUAL_TESTS, with the command that runs it)
#   [scan]       security/gate.sh scan-tree: no secret, personal value or forbidden
#                file (.env, keys) in the working tree
#   [shellcheck] security-relevant shell scripts at default severity, the rest at
#                -S warning (repo-standards.md § Scripts)
#   [actionlint] actionlint over .github/workflows here and, when ~/dev/templates exists,
#                over each curated template's workflows (D79)
#   [zsh-syntax] zsh -n over the zsh scripts and shell/ rc files — shellcheck cannot parse zsh
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
#                                                fake HOME; notifier stubbed)
#   pwdgen      scripts/test-pwd-gen.py          (bin/pwd-gen: lengths, classes,
#                                                wordlist, exit codes; fake pbcopy)
#   logs        scripts/test-logs.sh            (decision log + changelog coverage:
#                                                security/lib/logs.sh, bin/whatsup,
#                                                the SessionStart and Stop hooks, the
#                                                gate's log rules, the dotaudit ids)
#   docs        scripts/test-docs.py            (policy doc links, anchors, index,
#                                                workspace CLAUDE.md in sync, mermaid
#                                                diagrams well-formed and generic)
#   claudemd    scripts/test-claude-md-check.py (the CLAUDE.md fact check against stub
#                                                tools; never probes this Mac)
#   templates   scripts/test-template-versions.py (template dependency drift against
#                                                fixture registries; offline, stub
#                                                init.sh/test.sh/npm for --apply)
#   latestdeps  scripts/test-latest-deps.py     (latest-deps.py over fixture git repos and
#                                                PyPI: scope and skips, every verdict, the real
#                                                checkout untouched, --summary, --apply; offline)
#   cistatus    scripts/test-ci-status.py       (every own repo's CI result from a stub gh:
#                                                statuses, scope, errors, read-only; offline)
#   canary      scripts/test-template-canary.sh (template-canary.sh through the real gate to a
#                                                local stand-in remote, stub gh; offline)
#   models      scripts/test-model-versions.py (newer local models vs the llm lineup,
#                                                against fixture ollama.com pages; offline)
#   daily       scripts/test-daily-report.py    (the daily report over a fake HOME and ~/dev:
#                                                job statuses, skip/fork repos untouched,
#                                                TODO diff, privacy, file modes; offline)
#   app         scripts/test-maintenance-app.py (the local web app on a free loopback port:
#                                                token, Host check, day paths, escaping, CSP)
#   notes       scripts/test-notes-app.py       (notes search on a free loopback port over a
#                                                fixture folder: search, escaping, guards)
#   mobile      scripts/test-mobile-vetting.sh  (the mobile-vetting skill's audit over two
#                                                fixture pages; skipped without its npm ci)
#   restore     scripts/test/assertions.sh       (--docker only: a clean restore in a
#                                                debian container ends in the expected state)
#   entry       scripts/test-entrypoints.sh     (init.sh and run.sh: help, usage errors,
#                                                --check never installs, run.sh test
#                                                delegates here)
#
# Requires: git 2.54+, gitleaks, shellcheck, jq, ruff, python3, zsh (./init.sh installs
# the missing ones). pre-commit is optional.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

VERBOSE=""
DOCKER=0
LIST=0
ONLY=""
for a in "$@"; do
  case "$a" in
    --verbose) VERBOSE="--verbose" ;;
    --docker)  DOCKER=1 ;;
    --list)    LIST=1 ;;
    toolchain|coverage|scan|shellcheck|actionlint|zsh-syntax|ruff|bin|gate|tools|dotaudit|containers|maint|pwdgen|logs|docs|claudemd|templates|latestdeps|models|cistatus|canary|daily|app|notes|mobile|entry|restore) ONLY="$a" ;;
    -h|--help) awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

SHELLCHECK_FILES="
test.sh
security/gate.sh
security/patterns.sh
security/lib/visibility.sh
security/lib/logs.sh
security/lib/loose-files.sh
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
scripts/audit/60-launchd.sh
scripts/audit/render-report.sh
scripts/containers-doctor.sh
scripts/github-security-sweep.sh
scripts/mac-maintenance.sh
scripts/security-audit.sh
scripts/sync-dotfiles.sh
scripts/template-canary.sh
scripts/test-template-canary.sh
scripts/test-security-gate.sh
scripts/test-security-tools.sh
scripts/test-containers-doctor.sh
scripts/test-mac-maintenance.sh
scripts/test-bin.sh
scripts/test-logs.sh
bin/rcdev
bin/whatsup
bin/doc-dupes
bin/media-backup
bin/weekly-cleanup-check
bin/notify-local
bin/maintenance-status
bin/maintenance-app
bin/notes-app
"

# zsh scripts. shellcheck has no zsh support, so these get `zsh -n` instead of a
# lint pass. Keep the two lists disjoint: a file belongs to exactly one.
ZSH_FILES="
bin/llm
bin/weekly-disk-cleanup.sh
shell/.zshrc
shell/.zshrc.secret.template
shell/.zprofile
"

# Older or less security-relevant shell scripts: shellcheck at -S warning, the floor
# repo-standards.md sets. Style notes (SC2015 `A && B || C` in test assertions) are
# allowed here. A file belongs to exactly one shellcheck list.
SHELLCHECK_WARN_FILES="
init.sh
run.sh
bin/rc-projects
bin/vercel-project
scripts/dothelp.sh
scripts/test-dev-audit.sh
scripts/test-dotfiles-setup.sh
scripts/test-entrypoints.sh
scripts/test-mobile-vetting.sh
scripts/test/assertions.sh
claude/skills/mobile-vetting/scripts/ios-simulator.sh
"

# Tracked scripts deliberately in no lint list. Reason after the path.
LINT_EXEMPT="
archive/mail-report             retired (D60), kept for reference, never run
archive/test-mail-report.py     retired with it
"

# Test scripts that ./test.sh does not run, with the command that does. Not hermetic:
# they read this Mac's live state.
MANUAL_TESTS="
scripts/test-dotfiles-setup.sh  ./run.sh doctor (checks the installed dotfiles in \$HOME)
"

REQUIRED_TOOLS="git gitleaks shellcheck jq ruff python3 zsh actionlint"

# Curated templates whose workflows the actionlint suite checks — the list in
# scripts/template-versions.py (CURATED). Only on this machine: CI has no ~/dev/templates.
TEMPLATES_ROOT="${TEMPLATES_ROOT:-$HOME/dev/templates}"
CURATED_TEMPLATES="py-fastapi/minimal-mvp py-fastapi/production-ready ts-web/minimal-mvp ts-web/production-ready node-express/minimal-mvp node-express/production-ready rn-supabase vercel-stack"
GIT_MIN="2.54"

# Python scripts (stdlib only, per scripts/README.md), linted with ruff.
# bin/pwd-gen has no extension; ruff lints a file it is given by name.
PYTHON_FILES="
bin/pwd-gen
scripts/audit-dashboard.py
scripts/claude-md-check.py
scripts/test-claude-md-check.py
scripts/test-docs.py
scripts/test-pwd-gen.py
scripts/template-versions.py
scripts/test-template-versions.py
scripts/latest-deps.py
scripts/test-latest-deps.py
scripts/model-versions.py
scripts/test-model-versions.py
scripts/ci-status.py
scripts/test-ci-status.py
scripts/daily-report.py
scripts/test-daily-report.py
scripts/maintenance-app.py
scripts/test-maintenance-app.py
scripts/notes-app.py
scripts/test-notes-app.py
"

# Colour: on for a terminal, off when piped. NO_COLOR turns it off, FORCE_COLOR turns it on
# (https://no-color.org); GitHub Actions renders ANSI without being a terminal.
if [ -n "${NO_COLOR:-}" ]; then COLOR=0
elif [ "${FORCE_COLOR:-0}" != 0 ] || [ "${GITHUB_ACTIONS:-}" = true ]; then COLOR=1
elif [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then COLOR=1
else COLOR=0; fi
if [ "$COLOR" -eq 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

# What each suite proves, in one line: shown as the suite starts and by --list.
suite_what() {
  case "$1" in
    toolchain)  echo "the required tools are installed, git at $GIT_MIN or newer" ;;
    coverage)   echo "every script is in exactly one lint list; every scripts/test-* runs in a suite" ;;
    scan)       echo "the gate finds no secret, personal value or forbidden file in the tree" ;;
    shellcheck) echo "shellcheck is clean: security scripts at default severity, the rest at -S warning" ;;
    actionlint) echo "actionlint is clean over this repo's workflows and, on this machine, the curated templates' (D79)" ;;
    zsh-syntax) echo "zsh -n parses the zsh scripts and the shell/ rc files" ;;
    ruff)       echo "ruff check is clean over every Python script" ;;
    bin)        echo "bin/llm routing and zero-cloud guards; the weekly cleanup, asserted statically" ;;
    gate)       echo "the commit/push gate blocks what it must and passes what is clean" ;;
    tools)      echo "the Claude guard hook, the GitHub sweep, the weekly audit, the dotaudit gate module" ;;
    dotaudit)   echo "the read-only workspace audit reports what its fixtures hold" ;;
    containers) echo "the Colima doctor (no Docker Desktop)" ;;
    maint)      echo "the maintenance report and cache quarantine, on a fake HOME" ;;
    pwdgen)     echo "bin/pwd-gen: lengths, classes, wordlist, exit codes" ;;
    logs)       echo "decision log and changelog coverage: whatsup, the hooks, the gate's log rules" ;;
    docs)       echo "policy doc links, anchors and index; workspace CLAUDE.md in sync; mermaid diagrams" ;;
    claudemd)   echo "the CLAUDE.md fact check, against stub tools" ;;
    templates)  echo "template dependency drift, against fixture registries (offline)" ;;
    latestdeps) echo "projects against latest stable in throwaway clones: scope, verdicts, --apply (offline)" ;;
    models)     echo "newer local models against the llm lineup, from fixture pages (offline)" ;;
    cistatus)   echo "CI status of every own repo from a stub gh: green/red/stale/none/error, scope, read-only (offline)" ;;
    canary)     echo "template canary through the real gate to a local stand-in remote: copy, rewrite, push, wait (offline)" ;;
    daily)      echo "the daily report over a fake HOME and ~/dev: jobs, repos, TODO diff, privacy (offline)" ;;
    app)        echo "the local web app on a loopback port: token, Host check, paths, escaping, CSP" ;;
    notes)      echo "notes search on a loopback port: AND/phrase/ranking, escaping, ids, token, Host, CSP" ;;
    mobile)     echo "the mobile-vetting audit: a clean fixture passes, a broken one trips every check (skips without npm ci)" ;;
    entry)      echo "init.sh and run.sh: help, usage errors, --check never installs" ;;
    restore)    echo "a clean restore in a debian container ends in the expected state" ;;
    *)          echo "(no description: add one to suite_what)" ;;
  esac
}

RESULTS=""
FAILED=0
T0=$(date +%s)
run_suite() { # <name> <command...>: says what the suite proves, runs it with its output streaming
  local name="$1" rc start took; shift
  [ -z "$ONLY" ] || [ "$ONLY" = "$name" ] || return 0
  if [ "$LIST" = 1 ]; then printf '%s%-11s%s %s\n' "$BOLD" "$name" "$RESET" "$(suite_what "$name")"; return 0; fi
  printf '\n%s════ %s ════%s  %s\n' "$BOLD$CYAN" "$name" "$RESET" "$(suite_what "$name")"
  start=$(date +%s)
  "$@"; rc=$?
  took=$(( $(date +%s) - start ))
  if [ "$rc" = 0 ]; then
    RESULTS="$RESULTS\n  ${GREEN}✓${RESET} $(printf '%-11s' "$name") ${DIM}${took}s${RESET}"
  else
    RESULTS="$RESULTS\n  ${BOLD}${RED}✗ $(printf '%-11s' "$name")${RESET} ${DIM}${took}s${RESET}  exit $rc  ${DIM}rerun: ./test.sh $name${RESET}"
    FAILED=1
  fi
}

# version_ge <have> <want> — dotted versions, numeric per field.
# shellcheck disable=SC2329 # called from toolchain_check
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}

# shellcheck disable=SC2329 # invoked through run_suite
toolchain_check() {
  local t rc=0 v
  for t in $REQUIRED_TOOLS; do
    if command -v "$t" >/dev/null 2>&1; then echo "  ok    $t"; else echo "  MISSING $t — run ./init.sh"; rc=1; fi
  done
  if command -v git >/dev/null 2>&1; then
    v="$(git --version | awk '{ print $3 }')"
    if version_ge "$v" "$GIT_MIN"; then echo "  ok    git $v (>= $GIT_MIN)"; else echo "  OLD   git $v, need $GIT_MIN+ (brew upgrade git)"; rc=1; fi
  fi
  command -v pre-commit >/dev/null 2>&1 && echo "  ok    pre-commit (optional)" || echo "  skip  pre-commit (optional, not installed)"
  return "$rc"
}

# list_paths <list> — the first field of each non-empty line.
# shellcheck disable=SC2329 # called from coverage_check
list_paths() { printf '%s\n' "$1" | awk 'NF { print $1 }'; }

# script_kind <file> — sh | zsh | py | "" from the extension, then the shebang.
# shellcheck disable=SC2329 # called from coverage_check
script_kind() {
  local f="$1" first kind=""
  case "$f" in *.sh) kind="sh" ;; *.py) kind="py" ;; esac
  first="$(head -n 1 "$f" 2>/dev/null)"
  case "$first" in
    '#!'*python*) kind="py" ;;
    '#!'*zsh*) kind="zsh" ;;
    '#!'*bash*|'#!/bin/sh'*|'#!/usr/bin/env sh'*) kind="sh" ;;
  esac
  case "$f" in shell/.zshrc|shell/.zshrc.*|shell/.zprofile) kind="zsh" ;; esac
  printf '%s' "$kind"
}

# shellcheck disable=SC2329 # invoked through run_suite
coverage_check() {
  local f kind n rc=0 lists all_sc exempt manual
  all_sc="$(list_paths "$SHELLCHECK_FILES"; list_paths "$SHELLCHECK_WARN_FILES")"
  exempt="$(list_paths "$LINT_EXEMPT")"
  manual="$(list_paths "$MANUAL_TESTS")"
  # A file in two lists would be linted twice, at two severities.
  for f in $(printf '%s\n' "$all_sc" "$(list_paths "$ZSH_FILES")" "$(list_paths "$PYTHON_FILES")" "$exempt" | sort | uniq -d); do
    echo "  in two lists: $f"; rc=1
  done
  # Every listed file must exist (a rename leaves a dead entry behind).
  for f in $all_sc $(list_paths "$ZSH_FILES") $(list_paths "$PYTHON_FILES") $exempt $manual; do
    [ -f "$f" ] || { echo "  listed but missing: $f"; rc=1; }
  done
  n=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    printf '%s\n' "$exempt" | grep -qxF "$f" && continue
    kind="$(script_kind "$f")"
    case "$kind" in
      sh)  lists="$all_sc" ;;
      zsh) lists="$(list_paths "$ZSH_FILES")" ;;
      py)  lists="$(list_paths "$PYTHON_FILES")" ;;
      *)   continue ;;
    esac
    n=$((n + 1))
    printf '%s\n' "$lists" | grep -qxF "$f" || { echo "  not linted ($kind): $f — add it to the $kind list in test.sh, or to LINT_EXEMPT with a reason"; rc=1; }
  done <<EOF
$(git ls-files 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
EOF
  # Every test script runs somewhere.
  for f in scripts/test-*; do
    [ -f "$f" ] || continue
    grep -q "run_suite [a-z-]* *[a-z0-9]* *$f" "$0" && continue
    printf '%s\n' "$manual" | grep -qxF "$f" && continue
    echo "  test never run: $f — add a run_suite line, or list it in MANUAL_TESTS"; rc=1
  done
  [ "$rc" = 0 ] && echo "coverage: every one of $n scripts is linted, every test script runs"
  return "$rc"
}

# shellcheck disable=SC2329 # invoked through run_suite
scan_tree() {
  [ -x security/gate.sh ] || { echo "security/gate.sh missing"; return 1; }
  security/gate.sh scan-tree && echo "scan: working tree clean (gate scan-tree)"
}

# shellcheck disable=SC2329 # invoked through run_suite
shellcheck_all() {
  command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is not installed"; return 1; }
  local rc=0
  # shellcheck disable=SC2086 # the lists are deliberately word-split
  shellcheck -x $SHELLCHECK_FILES || rc=1
  # shellcheck disable=SC2086
  shellcheck -x -S warning $SHELLCHECK_WARN_FILES || rc=1
  # shellcheck disable=SC2086
  [ "$rc" = 0 ] && echo "shellcheck: clean ($(echo $SHELLCHECK_FILES | wc -w | tr -d ' ') files at default severity, $(echo $SHELLCHECK_WARN_FILES | wc -w | tr -d ' ') at -S warning)"
  return "$rc"
}

# shellcheck disable=SC2329 # invoked through run_suite
actionlint_all() {
  command -v actionlint >/dev/null 2>&1 || { echo "actionlint is not installed"; return 1; }
  local rc=0 t n=0 skipped=""
  actionlint -shellcheck= -pyflakes= || rc=1
  if [ -d "$TEMPLATES_ROOT" ]; then
    for t in $CURATED_TEMPLATES; do
      if ! ls "$TEMPLATES_ROOT/$t"/.github/workflows/*.y*ml >/dev/null 2>&1; then
        echo "  no workflows: templates/$t — every template ships .github/workflows/ci.yml"; rc=1; continue
      fi
      # Explicit files: most templates are not git repos, so actionlint cannot find a project.
      (cd "$TEMPLATES_ROOT/$t" && actionlint -shellcheck= -pyflakes= .github/workflows/*.y*ml) || { echo "  ^ templates/$t"; rc=1; }
      n=$((n + 1))
    done
  else
    skipped=" (templates skipped: no $TEMPLATES_ROOT, as in CI)"
  fi
  [ "$rc" = 0 ] && echo "actionlint: clean (this repo + $n curated templates)$skipped"
  return "$rc"
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

run_suite toolchain toolchain_check
run_suite coverage coverage_check
run_suite scan     scan_tree
run_suite shellcheck shellcheck_all
run_suite actionlint actionlint_all
run_suite zsh-syntax zsh_syntax_all
run_suite ruff     ruff_all
run_suite bin      bash scripts/test-bin.sh $VERBOSE
run_suite gate     bash scripts/test-security-gate.sh $VERBOSE
run_suite tools    bash scripts/test-security-tools.sh $VERBOSE
run_suite dotaudit bash scripts/test-dev-audit.sh $VERBOSE
run_suite containers bash scripts/test-containers-doctor.sh $VERBOSE
run_suite maint    bash scripts/test-mac-maintenance.sh $VERBOSE
run_suite pwdgen   python3 scripts/test-pwd-gen.py $VERBOSE
run_suite logs     bash scripts/test-logs.sh $VERBOSE
run_suite docs     python3 scripts/test-docs.py $VERBOSE
run_suite claudemd python3 scripts/test-claude-md-check.py $VERBOSE
run_suite templates python3 scripts/test-template-versions.py $VERBOSE
run_suite latestdeps python3 scripts/test-latest-deps.py $VERBOSE
run_suite models   python3 scripts/test-model-versions.py $VERBOSE
run_suite cistatus python3 scripts/test-ci-status.py $VERBOSE
run_suite canary   bash scripts/test-template-canary.sh $VERBOSE
run_suite daily    python3 scripts/test-daily-report.py $VERBOSE
run_suite app      python3 scripts/test-maintenance-app.py $VERBOSE
run_suite notes    python3 scripts/test-notes-app.py $VERBOSE
run_suite mobile   bash scripts/test-mobile-vetting.sh
# shellcheck disable=SC2329 # invoked through run_suite
restore_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "docker is not running (colima start)"; return 1
  fi
  docker run --rm -v "$(pwd)":/dotfiles debian:bookworm-slim \
    bash -c "apt-get update -qq && apt-get install -qq -y zsh git >/dev/null && bash /dotfiles/scripts/test/assertions.sh"
}

run_suite entry    bash scripts/test-entrypoints.sh $VERBOSE
if [ "$DOCKER" = 1 ]; then
  run_suite restore restore_docker
elif [ "$LIST" = 1 ]; then
  [ -n "$ONLY" ] && [ "$ONLY" != restore ] || printf '%s%-11s%s %s  %s(skipped: needs --docker)%s\n' "$BOLD" restore "$RESET" "$(suite_what restore)" "$YELLOW" "$RESET"
elif [ -z "$ONLY" ] || [ "$ONLY" = restore ]; then
  RESULTS="$RESULTS\n  ${YELLOW}- restore${RESET}     ${DIM}skipped: needs --docker${RESET}"
fi
[ "$LIST" = 0 ] || exit 0

printf '\n%s════ test.sh summary ════%s%b\n' "$BOLD" "$RESET" "$RESULTS"
if [ "$FAILED" = 0 ]; then
  printf '\n%sAll suites passed%s  %sin %ss%s\n' "$BOLD$GREEN" "$RESET" "$DIM" "$(( $(date +%s) - T0 ))" "$RESET"
else
  printf '\n%sSome suites failed%s  %sin %ss%s\n' "$BOLD$RED" "$RESET" "$DIM" "$(( $(date +%s) - T0 ))" "$RESET"
fi
exit "$FAILED"
