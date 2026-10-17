#!/usr/bin/env bash
#
# test-logs.sh — decision log, changelog and TODO coverage, in one readable suite.
#
# Everything that checks "is this change covered by a decision entry, a
# changelog line and a TODO item, free of duplicates" is exercised here, top to
# bottom, one block per component:
#
#   1. security/lib/logs.sh          which file counts, which repos are exempt,
#                                    which paths are doc-only, how a log is read
#   2. bin/whatsup                   the one-screen answer, and --brief
#   3. claude/hooks/session-start.sh orientation at session start + the baseline
#   4. claude/hooks/prompt-followup.sh the UserPromptSubmit hook: every prompt's reminder
#   5. claude/hooks/stop-log-check.sh the Stop hook: blocks once per change set,
#                                    also for open work named with no TODO item,
#                                    and for duplicates in the logs touched
#   6. bin/doc-dupes                 duplicate and near-duplicate entries, per kind
#   7. security/gate.sh              no-changelog-entry, changelog-no-unreleased,
#                                    decision-unverified, decision-ref-missing
#   8. dotaudit (20-policy.sh)       no-changelog, decisions-unverified, docs-redundant
#   9. registration and docs         settings.json, test.sh, the Enforcement table
#
# Every case builds throwaway repos under a temp dir with a fixture global git
# config that registers the gate exactly as ~/.gitconfig does, a stub `gh`, and
# a fake HOME for the hooks' state. Nothing here touches a real repo, the real
# ~/.gitconfig, ~/.local/state, or the network.
#
# Run: ./scripts/test-logs.sh [--verbose]      Exit: 0 all passed, 1 otherwise.
#
# shellcheck disable=SC2015 # `cond && pass || fail` is safe here: pass/fail always return 0
# shellcheck disable=SC2016,SC2088 # literal backticks and ~/dev in grep patterns

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$DOTFILES_DIR/security/lib/logs.sh"
GATE="$DOTFILES_DIR/security/gate.sh"
WHATSUP="$DOTFILES_DIR/bin/whatsup"
START="$DOTFILES_DIR/claude/hooks/session-start.sh"
STOP="$DOTFILES_DIR/claude/hooks/stop-log-check.sh"
FOLLOWUP="$DOTFILES_DIR/claude/hooks/prompt-followup.sh"
DUPES="$DOTFILES_DIR/bin/doc-dupes"
AUDIT="$DOTFILES_DIR/scripts/dev-audit.sh"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"; $VERBOSE || [ ! -s "$OUT" ] || sed 's/^/      | /' "$OUT"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); echo -e "  ${YELLOW}- SKIP${NC}: $1"; }
header() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──${NC}"; }

# --- sandbox --------------------------------------------------------------------
T="$(mktemp -d "${TMPDIR:-/tmp}/logs-test.XXXXXX")"; T="$(cd "$T" && pwd -P)"   # one spelling: physical, as git prints it
trap 'rm -rf "$T"' EXIT
OUT="$T/out"; : > "$OUT"

export HOME="$T/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export NO_COLOR=1
export CLAUDE_LOGS_STATE_DIR="$T/state"
export SKIPLIST_FILE="$T/skiplist.conf"
export DEV_ROOT="$T/dev"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE LOGS_SKIPLIST_FILE
mkdir -p "$HOME" "$T/bin" "$T/remotes/github.com" "$DEV_ROOT/projects"

cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
    name = Test
    email = test@users.noreply.github.com
[init]
    defaultBranch = main
[commit]
    gpgsign = false
[hook "security-gate-commit"]
    event = pre-commit
    command = $GATE pre-commit
EOF

# Stub gh: every repo is PRIVATE, so personal-data rules stay at WARN and the
# gate's log rules are what decides the verdict.
printf '#!/bin/sh\ncase "$*" in "auth status"*) exit 0 ;; esac\necho PRIVATE\n' > "$T/bin/gh"
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# The skip list the audit and the hooks read: one do-not-touch repo, one fork.
printf 'skip:memorial:do-not-touch\nfork:someones:upstream clone\n' > "$SKIPLIST_FILE"

CHANGELOG_OK=$'# Changelog\n\n## [Unreleased]\n\n### Added\n- base feature (#1)\n'
DECISIONS_OK=$'# Decisions\n\n## 1. First choice\n**Date:** 2026-10-01\n**Context:** c\n**Decision:** d\n**Verified:** `true` → 0\n'

# Every git command in this file runs inside the sandbox or not at all. The
# helpers below change directory in the calling shell (never in a command
# substitution), and this wrapper is the backstop: a fixture step that ever
# escapes $T fails loudly instead of touching a real repo.
git() {
  case "$PWD/" in "$T"/*) command git "$@" ;; *) echo "test-logs: refusing git outside the sandbox: $PWD" >&2; return 99 ;; esac
}
cd "$T" || exit 1

# mk_repo <name> [owner] — a repo with .gitignore, README, CHANGELOG.md and
# docs/DECISIONS.md in one clean commit, origin at a bare remote under
# github.com/<owner> (default: the own owner). Sets $d to its path; cwd set to it.
mk_repo() {
  local name="$1" owner="${2:-pieteradejong}"
  d="$T/dev/projects/$1"
  rm -rf "$d"; mkdir -p "$d" "$T/remotes/github.com/$owner"
  git init -q "$d"; cd "$d" || exit 1
  git init -q --bare "$T/remotes/github.com/$owner/$name.git" 2>/dev/null
  git remote add origin "$T/remotes/github.com/$owner/$name.git"
  printf '.env\nnode_modules/\n' > .gitignore; echo "# $name" > README.md
  printf '%s' "$CHANGELOG_OK" > CHANGELOG.md
  mkdir -p docs; printf '%s' "$DECISIONS_OK" > docs/DECISIONS.md
  echo 'echo hi' > run.sh
  git add -A; git commit -qm base >/dev/null 2>&1
  git push -q -u origin main >/dev/null 2>&1
}
# mk_bare_repo <name> — a repo with one commit and nothing else (no logs). Sets $d.
mk_bare_repo() {
  d="$T/dev/projects/$1"
  rm -rf "$d"; mkdir -p "$d"; git init -q "$d"; cd "$d" || exit 1
  echo base > README.md; echo 'x=1' > run.sh; git add -A; git commit -qm base >/dev/null 2>&1
}
d=""

# expect <rc> <description> <command...> — run, capture output, assert exit code.
expect() {
  local want="$1" desc="$2" rc; shift 2
  "$@" > "$OUT" 2>&1; rc=$?
  if [ "$rc" = "$want" ]; then pass "$desc"; else fail "$desc (exit $rc, wanted $want)"; fi
  $VERBOSE && sed 's/^/      | /' "$OUT"
  return 0
}
out_has()   { if grep -qE -- "$1" "$OUT"; then pass "$2"; else fail "$2 (output lacks /$1/)"; fi; }
out_lacks() { if grep -qE -- "$1" "$OUT"; then fail "$2 (output has /$1/)"; else pass "$2"; fi; }
out_empty() { if [ -s "$OUT" ]; then fail "$1 (output not empty)"; else pass "$1"; fi; }
lines_le()  { local n; n="$(grep -c '' "$OUT" | tr -d ' ')"; if [ "$n" -le "$1" ]; then pass "$2 ($n lines)"; else fail "$2 ($n lines, wanted ≤ $1)"; fi; }

# run_start <session-id> — the SessionStart hook, as Claude Code calls it, in cwd.
run_start() { printf '{"session_id":"%s","source":"startup"}' "$1" | "$START" > "$OUT" 2>&1; }
# run_stop <session-id> [transcript] [active] — the Stop hook, in cwd.
run_stop() {
  printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s","stop_hook_active":%s}' \
    "$1" "$PWD" "${2:-/dev/null}" "${3:-false}" | "$STOP" > "$OUT" 2>&1
}
# run_prompt — the UserPromptSubmit hook, as Claude Code calls it, in cwd.
run_prompt() { printf '{"session_id":"p","cwd":"%s","prompt":"hi"}' "$PWD" | "$FOLLOWUP" > "$OUT" 2>&1; }
# transcript <file> <text> — a one-message transcript whose last assistant text is <text>.
transcript() { jq -cn --arg t "$2" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}' > "$1"; }
blocks()  { if jq -e '.decision == "block"' "$OUT" >/dev/null 2>&1; then pass "$1"; else fail "$1 (no block decision)"; fi; }
reason_has() { if jq -r '.reason' "$OUT" 2>/dev/null | grep -qE -- "$1"; then pass "$2"; else fail "$2 (reason lacks /$1/)"; fi; }

# ================================================================================
header "Preconditions"
for t in jq gitleaks; do
  command -v "$t" >/dev/null 2>&1 && pass "$t is installed" || { echo "$t is required for this suite"; exit 1; }
done
v="$(git version | awk '{print $3}')"
case "$v" in 2.5[4-9]*|2.[6-9][0-9]*|[3-9].*) pass "git $v supports config-based hooks" ;;
  *) echo "git $v is too old for config-based hooks (need 2.54+)"; exit 1 ;; esac

# ================================================================================
header "1. security/lib/logs.sh — which file, which repo, which path"
# shellcheck source=security/lib/logs.sh
. "$LIB"

mkdir -p "$T/lib/a/docs" "$T/lib/b" "$T/lib/c/docs" "$T/lib/d"
: > "$T/lib/a/docs/DECISIONS.md"; : > "$T/lib/a/DECISIONS.md"; : > "$T/lib/b/DECISIONS.md"; : > "$T/lib/c/docs/design-decisions.md"
[ "$(logs_decisions_file "$T/lib/a")" = docs/DECISIONS.md ] && pass "docs/DECISIONS.md wins over a root DECISIONS.md" || fail "docs/ should win"
[ "$(logs_decisions_file "$T/lib/b")" = DECISIONS.md ] && pass "a root DECISIONS.md is accepted" || fail "root not accepted"
[ "$(logs_decisions_file "$T/lib/c")" = docs/design-decisions.md ] && pass "docs/design-decisions.md (the dotfiles log) is accepted" || fail "design-decisions not accepted"
logs_decisions_file "$T/lib/d" >/dev/null && fail "no log should fail" || pass "a repo with no decision log fails the lookup"
logs_changelog_file "$T/lib/d" >/dev/null && fail "no changelog should fail" || pass "a repo with no CHANGELOG.md fails the lookup"

mk_repo own; logs_exempt "$d" >/dev/null && fail "own repo exempt" || pass "an own repo is not exempt"
mk_repo theirs other; r="$(logs_exempt "$d")" && echo "$r" | grep -q 'other' && pass "a repo whose remote owner is not ours is exempt: $r" || fail "fork remote not exempt"
mk_repo memorial; r="$(logs_exempt "$d")" && echo "$r" | grep -q '^skip' && pass "a skip: row in the skip list exempts by basename" || fail "skip row ignored"
mk_repo someones; r="$(logs_exempt "$d")" && echo "$r" | grep -q '^fork' && pass "a fork: row in the skip list exempts by basename" || fail "fork row ignored"
mkdir -p "$T/dev/projects/scratch"; mk_bare_repo scratch/try1
[ "$(logs_exempt "$d")" = scratch ] && pass "anything under projects/scratch/ is exempt" || fail "scratch not exempt"
mkdir -p "$T/dev/_to_delete/old"; r="$(logs_exempt "$T/dev/_to_delete/old")" && pass "anything under _to_delete/ is exempt: $r" || fail "_to_delete not exempt"
mk_repo memorial
# shellcheck disable=SC1090 # the same lib, re-sourced with a different skip list
(LOGS_SKIPLIST_FILE=/nonexistent; . "$LIB"; logs_exempt "$d") >/dev/null && fail "missing skip list exempted" || pass "a missing skip list exempts nothing (fails closed)"

for p in README.md docs/x/y.md LICENSE .gitignore tests/x_test.py scripts/test-logs.sh foo.test.ts test_x.py CHANGELOG.md; do
  logs_doc_only "$p" && pass "doc-only: $p" || fail "doc-only: $p"
done
for p in bin/x .github/workflows/ci.yml .claude/settings.json src/a.py run.sh Makefile config/llm/lineup; do
  logs_doc_only "$p" && fail "owes an entry: $p" || pass "owes an entry: $p"
done

cat > "$T/lib/mixed.md" <<'EOF'
# Decisions

## 1. Numbered, verified
**Date:** 2026-09-01
**Verified:** `true` → 0

## D2 — Dotfiles style, open · 2026-09-02
**Problem.** p
**Verified.** `x` ran.
- **NOT YET:** the job has not fired.

## ADR-003: ADR style, partial
**Date:** 2026-09-03
**Verified: PARTIAL.** half.

## 4. No verification at all
**Date:** 2026-09-04
**Decision:** d
EOF
logs_decisions "$T/lib/mixed.md" > "$OUT"
[ "$(sed -n 1p "$OUT")" = $'1\tok\t2026-09-01\tNumbered, verified' ] && pass "'## 1. Title' + **Date:** + **Verified:** → ok" || fail "row 1: $(sed -n 1p "$OUT")"
[ "$(sed -n 2p "$OUT")" = $'2\tNOT YET\t2026-09-02\tDotfiles style, open' ] && pass "'## D2 — Title · date' + a NOT YET bullet → NOT YET" || fail "row 2: $(sed -n 2p "$OUT")"
[ "$(sed -n 3p "$OUT")" = $'3\tPARTIAL\t2026-09-03\tADR style, partial' ] && pass "'## ADR-003: Title' + Verified: PARTIAL → PARTIAL" || fail "row 3: $(sed -n 3p "$OUT")"
[ "$(sed -n 4p "$OUT")" = $'4\tnone\t2026-09-04\tNo verification at all' ] && pass "an entry with no Verified line → none" || fail "row 4: $(sed -n 4p "$OUT")"
[ "$(logs_last_decision "$T/lib/mixed.md")" = "4 · No verification at all · 2026-09-04" ] && pass "logs_last_decision names the last entry" || fail "last: $(logs_last_decision "$T/lib/mixed.md")"
[ "$(logs_open_decisions "$T/lib/mixed.md" | cut -f1 | tr '\n' ' ')" = "2 3 4 " ] && pass "logs_open_decisions lists NOT YET, PARTIAL and none" || fail "open: $(logs_open_decisions "$T/lib/mixed.md" | cut -f1 | tr '\n' ' ')"
[ "$(logs_decision_numbers "$T/lib/mixed.md" | tr '\n' ' ')" = "1 2 3 4 " ] && pass "logs_decision_numbers reads all three heading styles" || fail "numbers: $(logs_decision_numbers "$T/lib/mixed.md" | tr '\n' ' ')"
printf '## 2026-09-24 — Dated heading\n**Verified:** y\n\n**2026-09-30 · Bold paragraph entry.**\ntext\n' > "$T/lib/undated.md"
logs_decisions "$T/lib/undated.md" > "$OUT"
[ "$(cut -f1,3 "$OUT" | tr '\n\t' ' ,')" = "1,2026-09-24 2,2026-09-30 " ] && pass "unnumbered logs get ordinals and their dates" || fail "undated: $(cat "$OUT")"
[ -z "$(logs_decision_numbers "$T/lib/undated.md")" ] && pass "an unnumbered log has no checkable numbers" || fail "undated numbers not empty"
[ "$(printf 'a (#1) b (D2) c (DECISIONS #3) d (#9) e (D12)\n' | logs_refs_missing "$T/lib/mixed.md" | tr '\n' ' ')" = "12 9 " ] && pass "logs_refs_missing: (#1), (D2), (DECISIONS #3) resolve; (#9), (D12) do not" || fail "refs: $(printf '(#1) (D2) (DECISIONS #3) (#9) (D12)\n' | logs_refs_missing "$T/lib/mixed.md" | tr '\n' ' ')"
[ -z "$(printf '(#7)\n' | logs_refs_missing "$T/lib/undated.md")" ] && pass "references against an unnumbered log are not reported" || fail "undated refs reported"

printf '%s' "$CHANGELOG_OK" > "$T/lib/cl.md"
logs_has_unreleased "$T/lib/cl.md" && pass "logs_has_unreleased finds the heading" || fail "has_unreleased"
[ "$(logs_unreleased "$T/lib/cl.md" | grep -c '^- ')" = 1 ] && pass "logs_unreleased returns the block body" || fail "unreleased body"
printf '# Changelog\n\n## 1.0.0\n- x\n' > "$T/lib/cl2.md"
logs_has_unreleased "$T/lib/cl2.md" && fail "unreleased found where absent" || pass "no [Unreleased] heading → logs_has_unreleased fails"

mk_repo changes
echo dirty > already-dirty.sh
logs_write_baseline "$d" "$T/state" sess1 && pass "logs_write_baseline writes the baseline" || fail "baseline"
[ "$(stat -f %Lp "$T/state/sess1.base")" = 600 ] && pass "baseline file is mode 600" || fail "baseline mode $(stat -f %Lp "$T/state/sess1.base")"
grep -q "^HEAD $(git rev-parse HEAD)" "$T/state/sess1.base" && pass "baseline records HEAD" || fail "baseline HEAD"
grep -qx "TOP $d" "$T/state/sess1.base" && pass "baseline records the repo path" || fail "baseline TOP"
echo more >> run.sh; echo new > new.sh; echo doc >> README.md; git add README.md; git commit -qm doc >/dev/null 2>&1
[ "$(logs_changed_paths "$d" "$T/state/sess1.base" | tr '\n' ' ')" = "README.md new.sh run.sh " ] \
  && pass "logs_changed_paths: committed, modified and new paths since the baseline; already-dirty excluded" \
  || fail "changed: $(logs_changed_paths "$d" "$T/state/sess1.base" | tr '\n' ' ')"
[ "$(logs_changed_paths "$d" | tr '\n' ' ')" = "already-dirty.sh new.sh run.sh " ] && pass "without a baseline: everything dirty against HEAD" || fail "no-baseline: $(logs_changed_paths "$d" | tr '\n' ' ')"
[ "$(logs_newest_baseline "$d" "$T/state")" = "$T/state/sess1.base" ] && pass "logs_newest_baseline finds this repo's baseline" || fail "newest baseline"
printf '{"name":"Edit","input":{"file_path":"%s/already-dirty.sh"}}\n{"name":"Write","input":{"file_path":"/elsewhere/x.sh"}}\n' "$d" > "$T/transcript.jsonl"
[ "$(logs_transcript_paths "$d" "$T/transcript.jsonl")" = already-dirty.sh ] && pass "logs_transcript_paths: Edit/Write paths under the repo, relative" || fail "transcript paths"

# ================================================================================
header "2. bin/whatsup — the one-screen answer"
mk_repo full; printf '# TODO\n- [ ] one\n- [x] done\n- [ ] two\n' > TODO.md; git add TODO.md; git commit -qm todo >/dev/null 2>&1; git push -q origin main >/dev/null 2>&1
STAMP="$T/stamp"; touch "$STAMP"; sleep 1
expect 0 "whatsup exits 0 in a repo with both logs" "$WHATSUP"
out_has '^full · main · ' "first line: repo and branch"
out_has 'in sync with origin/main|has no upstream|unpushed' "first line: remote state"
out_has 'Decisions +docs/DECISIONS.md · 1 entries · last: 1 · First choice' "Decisions: file, count, last entry"
out_has 'Changelog +CHANGELOG.md · \[Unreleased\] · 1 entries' "Changelog: file and [Unreleased] count"
out_has 'base feature' "Changelog: the [Unreleased] body is shown"
out_has 'TODO.md · 2 open' "Open work: unchecked TODO items counted"
out_has '^  - one$' "Open work: items listed"
out_lacks '⚠' "nothing to flag in a clean, fully logged repo"
[ -z "$(find "$d" -newer "$STAMP" -not -path '*/.git/*' -type f)" ] && pass "whatsup wrote nothing in the repo" || fail "whatsup wrote: $(find "$d" -newer "$STAMP" -not -path '*/.git/*' -type f)"
expect 0 "whatsup --brief exits 0" "$WHATSUP" --brief
lines_le 6 "--brief is at most six lines"
out_has '^Decisions: docs/DECISIONS.md · 1 entries · last 1 \(2026-10-01\)$' "--brief: decisions on one line"
out_has '^Changelog: \[Unreleased\] 1 entries$' "--brief: changelog on one line"
out_has '^TODO.md: 2 open$' "--brief: TODO on one line"

mk_bare_repo none
expect 0 "whatsup exits 0 in a repo with neither log" "$WHATSUP"
out_has '⚠ no decision log' "flags the missing decision log"
out_has '⚠ no CHANGELOG.md' "flags the missing changelog"

mk_repo open; printf '\n## 2. Open one\n**Date:** 2026-10-02\n**Verified:** NOT YET\n\n## 3. Silent\n**Date:** 2026-10-03\n' >> docs/DECISIONS.md
expect 0 "whatsup in a repo with open decisions" "$WHATSUP"
out_has '⚠ 1 open: 2 NOT YET' "lists NOT YET entries"
out_has '⚠ 1 without a Verified line: 3' "lists entries without Verified"
printf '# Changelog\n\n## 1.0.0\n- x\n' > CHANGELOG.md
expect 0 "whatsup with a changelog lacking [Unreleased]" "$WHATSUP"
out_has '⚠ CHANGELOG.md has no "## \[Unreleased\]" heading' "flags a missing [Unreleased] heading"

mk_bare_repo someones
expect 0 "whatsup in an exempt repo with no logs" "$WHATSUP" --brief
out_has 'Decisions: none \(exempt: fork' "exempt repos are not flagged, the reason is shown"

mk_repo session; logs_write_baseline "$d" "$T/state" ws1; echo x >> run.sh
expect 0 "whatsup after an uncovered change" "$WHATSUP" --brief
out_has '⚠ 1 file\(s\) changed with no CHANGELOG.md change: run.sh' "--brief: names this session's uncovered change"
echo '- x' >> CHANGELOG.md
expect 0 "whatsup after the changelog was updated" "$WHATSUP" --brief
out_lacks 'no CHANGELOG.md change' "no flag once CHANGELOG.md changed too"

printf '# TODO\n- [ ] ws item\n' > "$DEV_ROOT/TODO.md"
cd "$DEV_ROOT" || exit 1
expect 0 "whatsup at the workspace root (not a repo)" "$WHATSUP"
out_has 'workspace' "workspace header"
out_has 'TODO.md · 1 open' "workspace TODO count"
out_has 'Recently active' "recently active repos"
out_has 'projects/session' "names a recently active repo"
expect 0 "whatsup --all at the workspace root" "$WHATSUP" --all
out_has 'projects/none +.*no decision log · ⚠ no CHANGELOG.md' "--all: one line per repo needing attention"
cd "$T" || exit 1
expect 0 "whatsup in an unrelated non-repo directory" "$WHATSUP"
out_has 'not a git repo · cd into a project' "says where to go"
expect 0 "whatsup --brief there prints nothing" "$WHATSUP" --brief
out_empty "--brief outside a repo and the workspace is silent"
expect 0 "whatsup -h" "$WHATSUP" -h
out_has '^whatsup — what is going on' "-h prints the header"

# ================================================================================
header "3. claude/hooks/session-start.sh — orientation and the baseline"
mk_bare_repo fresh; git remote remove origin 2>/dev/null; echo a > a; echo b > b; echo c > c
expect 0 "fresh repo: exit 0" run_start s1
out_has '⚠ 3 uncommitted file\(s\)' "reports uncommitted files"
out_has '⚠ main has no upstream' "reports no upstream"
out_has '⚠ no .gitignore' "reports a missing .gitignore"
mk_repo synced
expect 0 "clean repo with upstream: exit 0" run_start s2
out_has '^synced · main · clean · in sync with origin/main$' "clean and in sync is said, not silent (D33)"
echo x >> README.md; git commit -qam local >/dev/null 2>&1 || true
run_start s3; out_has '⚠ 1 unpushed commit\(s\) on main' "reports unpushed commits"
git checkout -q --detach HEAD 2>/dev/null
run_start s4; out_has '⚠ detached HEAD at [0-9a-f]+' "reports a detached HEAD"
git checkout -q main 2>/dev/null
[ -f "$T/state/s2.base" ] && pass "writes <state>/<session_id>.base in a repo" || fail "no baseline written"
[ "$(stat -f %Lp "$T/state/s2.base")" = 600 ] && pass "baseline is mode 600" || fail "baseline mode"
[ "$(stat -f %Lp "$T/state")" = 700 ] && pass "state dir is mode 700" || fail "state dir mode"
grep -q '^HEAD [0-9a-f]\{40\}$' "$T/state/s2.base" && pass "baseline has HEAD" || fail "baseline HEAD"
grep -qx "TOP $d" "$T/state/s2.base" && pass "baseline has TOP" || fail "baseline TOP"
mk_repo someones; rm -f "$T/state/s5.base"
run_start s5; [ -f "$T/state/s5.base" ] && fail "baseline written for an exempt repo" || pass "no baseline for an exempt repo"
touch -t 202501010000 "$T/state/old.base"; mk_repo prune; run_start s6
[ -f "$T/state/old.base" ] && fail "stale baseline not pruned" || pass "baselines older than 7 days are pruned"
cd "$T" || exit 1; rm -f "$T/state/s7.base"
expect 0 "outside a repo: exit 0" run_start s7
out_empty "outside a repo and the workspace: no output"
[ -f "$T/state/s7.base" ] && fail "baseline written outside a repo" || pass "no baseline outside a repo"
cd "$DEV_ROOT" || exit 1
run_start s8; out_has 'workspace' "at the workspace root: the workspace brief"
printf 'garbage' | "$START" > "$OUT" 2>&1 && pass "malformed stdin: still exit 0" || fail "malformed stdin exit"
expect 0 "'../..' id is rejected, exit 0" bash -c "printf '{\"session_id\":\"../../x\"}' | '$START'"
[ -e "$T/x.base" ] && fail "path traversal in session_id" || pass "a session_id with path characters writes nothing"

# ================================================================================
header "4. claude/hooks/prompt-followup.sh — every prompt's reminder"
mk_repo prompt
expect 0 "in a repo: exit 0" run_prompt
out_has '^followup \(~/dev/CLAUDE.md § Session workflow' "first line names the rule"
out_has 'decisions → docs/DECISIONS.md \(last: 1 · First choice' "names the decision log and its last entry"
out_has 'open items → TODO.md \(create it on the first item' "says to create TODO.md when there is none"
out_has 'doc-dupes' "asks for the redundancy check"
lines_le 3 "three lines, no more"
printf '# TODO\n\n- [ ] one\n- [ ] two\n- [x] done\n' > TODO.md
run_prompt; out_has 'TODO.md \(2 open\)' "counts the open items when TODO.md exists"
rm -rf docs; run_prompt; out_has 'docs/DECISIONS.md \(create it on the first entry\)' "says to create the decision log when there is none"
cd "$DEV_ROOT" || exit 1
printf '# TODO\n\n- [ ] ws item\n' > "$DEV_ROOT/TODO.md"
expect 0 "at the workspace root: exit 0" run_prompt
out_has 'design-decisions.md' "root: points decisions at the dotfiles log"
out_has '~/dev/TODO.md \(1 open\)' "root: counts the workspace TODO"
mkdir -p "$DEV_ROOT/projects/notarepo"; cd "$DEV_ROOT/projects/notarepo" || exit 1
run_prompt; out_has '~/dev/TODO.md' "a non-repo directory under ~/dev gets the workspace lines"
mkdir -p "$DEV_ROOT/projects/scratch/play"; cd "$DEV_ROOT/projects/scratch/play" || exit 1
run_prompt; out_empty "a non-repo directory under projects/scratch: silent"
mk_repo memorial; run_prompt; out_empty "a skip-listed repo: silent"
mk_repo theirs other; run_prompt; out_empty "someone else's remote: silent"
cd "$T" || exit 1
run_prompt; out_empty "outside ~/dev: silent"
printf 'garbage' | "$FOLLOWUP" > "$OUT" 2>&1 && pass "malformed stdin: exit 0" || fail "malformed stdin"
out_empty "malformed stdin: no output"
rm -f "$DEV_ROOT/TODO.md"

# ================================================================================
header "5. claude/hooks/stop-log-check.sh — blocks once per change set"
mk_repo stop; run_start st1
echo 'echo more' >> run.sh
expect 0 "uncovered code change: exit 0 (decision is in the JSON)" run_stop st1
blocks "returns decision: block"
reason_has '1 file\(s\) changed with no CHANGELOG.md change: run.sh' "reason names the uncovered file"
reason_has 'No entry added to docs/DECISIONS.md' "reason asks about a decision entry"
reason_has 'say so in one line' "reason says how to answer 'none owed'"
expect 0 "same change set again" run_stop st1
out_empty "second stop for the same change set is silent (acknowledged)"
echo 'echo again' > other.sh
run_stop st1; blocks "a new file reopens the question"
reason_has 'other.sh' "and names the new file"
expect 0 "stop_hook_active: true" run_stop st1 /dev/null true
out_empty "stop_hook_active → silent, never loops"
echo '- more (#1)' >> CHANGELOG.md; printf '\n## 2. More\n**Date:** 2026-10-13\n**Verified:** NOT YET\n' >> docs/DECISIONS.md
run_stop st1b; blocks "CHANGELOG.md and a NOT YET decision entry added → asks for the TODO item"
reason_has 'A decision entry added this session is Verified: NOT YET, and no TODO.md was touched' "reason says why"
reason_has 'TODO.md — create it at the repo root' "reason says to create TODO.md"
out_lacks 'no CHANGELOG.md change|No entry added' "changelog and decision are satisfied"
printf '# TODO\n\n- [ ] Verify entry 2 — 2026-10-13, docs/DECISIONS.md #2\n' > TODO.md
run_stop st1c; out_empty "with the TODO item written → silent"

mk_repo docsonly; run_start st2; echo more >> README.md; echo n >> docs/notes.md
run_stop st2; out_empty "doc-only changes → silent"

# Open work named in the closing summary, nothing changed on disk.
mk_repo openwork; run_start st12
transcript "$T/t12.jsonl" $'Done.\n\nVerified: NOT YET for the live run; the EAS build is still open.'
run_stop st12 "$T/t12.jsonl"; blocks "a reply naming open work with no file change blocks"
reason_has 'Your reply names open work \(Verified: NOT YET for the live run' "reason quotes the line"
reason_has 'TODO.md — create it at the repo root' "reason says where the item goes"
reason_has 'doc-dupes catches repeated wording, not repeated meaning' "reason asks for the judgment half"
run_stop st12 "$T/t12.jsonl"; out_empty "the same open-work lines again → silent (acknowledged)"
transcript "$T/t12b.jsonl" $'Also left open: the Sentry event.'
run_stop st12 "$T/t12b.jsonl"; blocks "a newly named open item reopens the question"
printf '# TODO\n\n- [ ] EAS build — 2026-10-17\n- [ ] Sentry event — 2026-10-17\n' > TODO.md
run_stop st12 "$T/t12b.jsonl"; out_empty "with TODO.md written → silent"
transcript "$T/t12c.jsonl" 'All green, nothing left to do.'
rm -f TODO.md; run_stop st12 "$T/t12c.jsonl"; out_empty "a reply with no open work and no change → silent"
transcript "$T/t12d.jsonl" 'The todos were partially done; see the follow-up.'
run_stop st12x "$T/t12d.jsonl"; blocks "lower-case phrases count (follow-up)"
transcript "$T/t12e.jsonl" 'The todos were partially done.'
run_stop st12y "$T/t12e.jsonl"; out_empty "but lower-case tokens (todos, partially) in prose do not"

# Duplicates in the logs this session touched.
mk_repo duptodo; run_start st13
printf '# TODO\n\n- [ ] Wire the export job into launchd\n- [ ] Something else\n- [ ] Wire the export job into launchd\n' > TODO.md
run_stop st13; blocks "a duplicated TODO item blocks"
reason_has 'TODO.md:5: todo-dup — same as line 3' "reason names file:line and kind"
reason_has 'Merge or remove the duplicate' "reason says what to do"
mk_repo duptitle; run_start st14; printf '\n## 2. First choice\n**Date:** 2026-10-13\n**Verified:** ok\n' >> docs/DECISIONS.md
run_stop st14; blocks "a decision entry titled like an existing one blocks"
reason_has 'docs/DECISIONS.md:9: decision-dup-title — same as line 3' "reason names the earlier entry"
mk_repo crossfile; run_start st15
printf '# TODO\n\n- [x] Ship the export job to launchd\n' > "$DEV_ROOT/TODO.md"
printf '# TODO\n\n- [ ] Ship the export job to launchd\n' > TODO.md
run_stop st15; blocks "an item that is also in ~/dev/TODO.md blocks"
reason_has 'todo-cross-file — same as .*/dev/TODO.md:3 \(open here, done there\)' "reason names the other file and the state mismatch"
rm -f "$DEV_ROOT/TODO.md"

# The workspace root: not a repo, measured through the transcript only.
cd "$DEV_ROOT" || exit 1
printf '# TODO\n\n- [ ] Review the sweep\n- [ ] Review the sweep\n' > TODO.md
printf '{"name":"Write","input":{"file_path":"%s/TODO.md"}}\n' "$DEV_ROOT" > "$T/t16.jsonl"
run_stop st16 "$T/t16.jsonl"; blocks "at ~/dev, a duplicated workspace TODO item written this session blocks"
reason_has 'changes in the workspace \(~/dev\)' "reason names the workspace"
reason_has 'TODO.md:4: todo-dup' "reason names the duplicate"
out_lacks 'CHANGELOG|decision log' "root mode asks nothing about changelog or decisions"
transcript "$T/t17.jsonl" 'Left open: the push.'
run_stop st17 "$T/t17.jsonl"; blocks "at ~/dev, open work named with no TODO write blocks"
reason_has 'in ~/dev/TODO.md' "reason points at the workspace TODO"
expect 0 "at ~/dev with nothing changed and nothing open: exit 0" run_stop st18
out_empty "and silent"
rm -f TODO.md
mkdir -p "$DEV_ROOT/projects/scratch/notes"; cd "$DEV_ROOT/projects/scratch/notes" || exit 1
printf '{"name":"Write","input":{"file_path":"%s/x.md"}}\n' "$PWD" > "$T/t19.jsonl"; printf 'a\na\n' > x.md
run_stop st19 "$T/t19.jsonl"; out_empty "a non-repo directory under projects/scratch: silent"

mk_repo unverified; run_start st3; printf '\n## 2. Unverified\n**Date:** 2026-10-13\n**Decision:** d\n' >> docs/DECISIONS.md
run_stop st3; blocks "a decision entry without Verified blocks even with no code change"
reason_has 'Entry 2 in docs/DECISIONS.md \("Unverified"\) has no Verified: line' "reason names the entry"

mk_repo badref; run_start st4; echo '- thing (#9)' >> CHANGELOG.md
run_stop st4; blocks "a changelog line citing a missing decision blocks"
reason_has 'cites decision\(s\) 9 ' "reason names the missing number"

mk_repo nologs; rm -rf docs CHANGELOG.md; git add -A; git commit -qm strip >/dev/null 2>&1 || true
git update-ref -d refs/heads/main 2>/dev/null; git checkout -q --orphan main 2>/dev/null; git add -A; git commit -qm base >/dev/null 2>&1
run_start st5; echo x >> run.sh
run_stop st5; blocks "a repo with neither log blocks"
reason_has 'this repo has no CHANGELOG.md' "reason says to create the changelog"
reason_has 'No decision log in this repo' "reason says to create the decision log if owed"

mk_bare_repo scratch/play; echo x >> run.sh
run_stop st6; out_empty "projects/scratch/: silent"
mk_repo memorial; echo x >> run.sh
run_stop st7; out_empty "a skip-listed repo: silent"
mk_repo theirs other; echo x >> run.sh
run_stop st8; out_empty "someone else's remote: silent"

mk_repo nobase; rm -f "$T"/state/*.base; echo x >> run.sh
run_stop st9; blocks "with no baseline at all, changes are measured against HEAD"
mk_repo viatranscript; echo dirty >> run.sh; run_start st10
printf '{"name":"Edit","input":{"file_path":"%s/run.sh"}}\n' "$d" > "$T/t10.jsonl"
run_stop st10 "$T/t10.jsonl"; blocks "a file dirty at baseline but edited per the transcript counts"
cd "$T" || exit 1
printf 'garbage' | "$STOP" > "$OUT" 2>&1 && pass "malformed stdin: exit 0" || fail "malformed stdin"
out_empty "malformed stdin: no output"
expect 0 "outside a repo: exit 0" run_stop st11
out_empty "outside a repo: silent"
[ "$(stat -f %Lp "$T/state/st1.ack")" = 600 ] && pass "ack file is mode 600" || fail "ack mode"

# ================================================================================
header "6. bin/doc-dupes — duplicate and near-duplicate entries"
DD="$T/dd"; mkdir -p "$DD"; cd "$DD" || exit 1
printf '# TODO\n\n- [ ] Review and push the 61 commits in batches\n- [ ] Add the WA_DATA_DIR skip\n- [x] Review and push the 61 commits in batches\n- [ ] Review and push the 61 commits, in two batches\n- [ ] fix tests\n- [ ] fix tests\n- [ ] fix docs\n' > TODO.md
expect 0 "a TODO.md with duplicates: exit 0" "$DUPES" TODO.md
out_has 'TODO.md:5	todo-dup	same as line 3: Review and push the 61 commits in batches' "todo-dup: the same item, ticked or not"
out_has 'TODO.md:6	todo-near-dup	near-duplicate of line 3: Review and push the 61 commits, in two batches' "todo-near-dup: token-Jaccard ≥ 0.8"
out_has 'TODO.md:8	todo-dup	same as line 7: fix tests' "todo-dup: short items match exactly"
out_lacks 'fix docs' "short items (under 3 tokens) never near-match"
out_has 'doc-dupes: 4 finding\(s\) in 1 file\(s\)' "summary line counts"
expect 0 "--quiet: exit 0" "$DUPES" --quiet TODO.md
out_lacks '^doc-dupes:' "--quiet drops the summary"
lines_le 4 "--quiet keeps the findings"
printf '# Decisions\n\n## 1. Use bash for the hooks\n**Verified:** ok\n\n## 2. Use bash for the hooks\n**Verified:** ok\n\n## 2. Something distinct\n**Verified:** ok\n\n## 3. use Bash for hooks\n**Verified:** ok\n' > DECISIONS.md
"$DUPES" DECISIONS.md > "$OUT" 2>&1
out_has 'DECISIONS.md:9	decision-dup-number	number 2 is already used' "decision-dup-number: the second use of a number"
out_has 'DECISIONS.md:6	decision-dup-title	same as line 3: Use bash for the hooks' "decision-dup-title: equal after normalisation"
out_has 'DECISIONS.md:12	decision-dup-title	near-duplicate of line 3: use Bash for hooks' "decision-dup-title: near match"
printf '# Changelog\n\n## [Unreleased]\n\n### Added\n- `bin/doc-dupes` finds duplicates\n- `bin/doc-dupes` finds duplicates\n- new thing\n\n## [1.0.0] - 2026-01-01\n- new thing\n- old thing\n- old thing\n' > CHANGELOG.md
"$DUPES" CHANGELOG.md > "$OUT" 2>&1
out_has 'CHANGELOG.md:7	changelog-dup	repeated inside \[Unreleased\], first at line 6' "changelog-dup: repeated in [Unreleased]"
out_has 'CHANGELOG.md:11	changelog-dup	also in a released section at line 8: new thing' "changelog-dup: released line repeated under [Unreleased]"
out_lacks 'old thing' "two released lines alike are history, not a finding"
printf '# TODO\n\n- [ ] Ship the export job to launchd\n- [ ] Something only here\n' > "$DEV_ROOT/TODO.md"
printf '# TODO\n\n- [x] Ship the export job to launchd\n' > TODO.md
"$DUPES" --workspace TODO.md > "$OUT" 2>&1
out_has '^TODO.md:3	todo-cross-file	same as .*/dev/TODO.md:3 \(done here, open there\)' "todo-cross-file: reported against the file checked, with both states"
"$DUPES" TODO.md > "$OUT" 2>&1; out_lacks 'cross-file' "without --workspace the workspace TODO is not consulted"
"$DUPES" --workspace "$DEV_ROOT/TODO.md" > "$OUT" 2>&1; out_lacks 'cross-file' "the workspace TODO is never compared with itself"
rm -f "$DEV_ROOT/TODO.md"
printf -- '- [ ] a b c d\n- [ ] e f g h\n' > clean.md
"$DUPES" clean.md > "$OUT" 2>&1; out_has 'doc-dupes: clean — 1 file\(s\), no duplicates' "a clean file says so"
"$DUPES" missing.md > "$OUT" 2>&1; out_has 'nothing to check here' "a missing file is nothing to check"
expect 0 "-h: exit 0" "$DUPES" -h; out_has 'duplicate and near-duplicate entries' "-h prints the header"
expect 0 "an unknown flag: exit 0" "$DUPES" --bogus
mk_repo dupesrepo; printf '# TODO\n\n- [ ] x y z\n- [ ] x y z\n' > TODO.md
expect 0 "in a repo with no arguments: exit 0" "$DUPES"
out_has 'TODO.md:4	todo-dup' "picks up the repo's TODO.md"
out_has '3 file\(s\)' "and its decision log and changelog"
mk_repo memorial; printf '# TODO\n\n- [ ] x y z\n- [ ] x y z\n' > TODO.md
cd "$T" || exit 1
"$DUPES" --all > "$OUT" 2>&1
out_has 'dupesrepo/TODO.md:4	todo-dup' "--all walks every repo under ~/dev"
out_lacks 'memorial' "--all skips exempt repos"

# ================================================================================
header "7. security/gate.sh — the log rules at commit time (through git commit)"
mk_repo gate
echo 'echo more' >> run.sh; git add run.sh
expect 1 "code change without CHANGELOG.md staged is blocked" git commit -qm code
out_has 'BLOCK no-changelog-entry: 1 behaviour-relevant file\(s\) staged without a CHANGELOG.md change' "finding names the rule and count"
out_has 'run\.sh' "finding names the file"
echo '- more (#1)' >> CHANGELOG.md; git add CHANGELOG.md
expect 0 "the same change with CHANGELOG.md staged passes" git commit -qm code
echo more >> README.md; git add README.md
expect 0 "a doc-only change passes without a changelog line" git commit -qm docs
printf '\n## 2. Second\n**Date:** 2026-10-13\n**Decision:** d\n' >> docs/DECISIONS.md; git add docs/DECISIONS.md
expect 1 "a decision entry without Verified is blocked" git commit -qm dec
out_has 'BLOCK decision-unverified: docs/DECISIONS.md: entry 2 \("Second"\) has no Verified: line' "finding names the entry"
printf '**Verified:** NOT YET\n' >> docs/DECISIONS.md; git add docs/DECISIONS.md
expect 0 "the same entry with 'Verified: NOT YET' passes" git commit -qm dec
echo '- thing (#9)' >> CHANGELOG.md; git add CHANGELOG.md
expect 0 "a changelog line citing a missing decision passes with a warning" git commit -qm ref
out_has 'WARN  decision-ref-missing: CHANGELOG.md cites decision\(s\) 9 with no entry in docs/DECISIONS.md' "warning names the number"
printf '# Changelog\n\n## 1.0.0\n- x\n' > CHANGELOG.md; git add CHANGELOG.md
expect 1 "CHANGELOG.md without an [Unreleased] heading is blocked" git commit -qm cl
out_has 'BLOCK changelog-no-unreleased' "finding names the rule"
git checkout -q -- CHANGELOG.md; git reset -q
mk_repo gatefork other; echo 'echo more' >> run.sh; git add run.sh
expect 0 "someone else's remote: no log rules" git commit -qm code
mk_repo gatememorial; printf 'skip:gatememorial:x\n' >> "$SKIPLIST_FILE"; echo 'echo more' >> run.sh; git add run.sh
expect 0 "a skip-listed repo: no log rules" git commit -qm code
rm -rf "$T/dev/projects/first"; git init -q "$T/dev/projects/first"; cd "$T/dev/projects/first" || exit 1
printf '.env\n' > .gitignore; echo 'x=1' > run.sh; git add -A
expect 0 "the first commit of a repo is never asked for a changelog" git commit -qm first
mk_repo nocl; git rm -q CHANGELOG.md; echo '- removed changelog' >> README.md; git add -A; git commit -qm rm >/dev/null 2>&1 || true
echo 'echo more' >> run.sh; git add run.sh
expect 0 "a repo with no CHANGELOG.md at all is not blocked: existing debt, reported by dotaudit, asked for by the Stop hook" git commit -qm code
out_lacks 'no-changelog-entry' "no finding without a changelog to update"

# ================================================================================
header "8. dotaudit — no-changelog, decisions-unverified and docs-redundant"
rm -rf "$T/dev/projects"; mkdir -p "$T/dev/projects"
mk_bare_repo auditnolog
mk_repo auditopen; printf '\n## 2. Silent\n**Date:** 2026-10-13\n\n## 3. Open\n**Date:** 2026-10-13\n**Verified:** NOT YET\n' >> docs/DECISIONS.md; git add -A; git commit -qm more >/dev/null 2>&1 || true
mk_bare_repo someones
mk_repo auditclean
mk_repo auditdup; printf '# TODO\n\n- [ ] Wire the export job into launchd\n- [ ] Wire the export job into launchd\n' > TODO.md; git add -A; git commit -qm todo >/dev/null 2>&1 || true
"$AUDIT" --only policy --no-report > "$OUT" 2>&1 || true
out_has 'INFO auditdup +docs-redundant +1 duplicate or near-duplicate log entries: TODO.md:4 todo-dup' "docs-redundant counts and names the duplicate"
out_lacks 'auditclean +docs-redundant' "a repo without duplicates gets none"
out_has 'WARN auditnolog +no-changelog +no CHANGELOG.md, and behaviour-relevant files are tracked' "no-changelog fires on a repo with code and no changelog"
out_has 'WARN auditopen +decisions-unverified +docs/DECISIONS.md: 1 without a Verified line, 1 open' "decisions-unverified counts both kinds"
out_lacks 'auditclean +(no-changelog|decisions-unverified)' "a fully logged repo gets neither"
out_lacks 'someones +(no-changelog|decisions-unverified)' "a fork: skip-list row is skipped"

# ================================================================================
header "9. Registration and docs"
SET="$DOTFILES_DIR/claude/settings.json"
jq -e '[.hooks.Stop[] | .hooks[].command] | any(test("stop-log-check\\.sh$"))' "$SET" >/dev/null \
  && pass "settings.json registers stop-log-check.sh under Stop" || fail "Stop hook not registered"
jq -e '[.hooks.SessionStart[] | .hooks[].command] | any(test("session-start\\.sh$"))' "$SET" >/dev/null \
  && pass "settings.json registers session-start.sh under SessionStart" || fail "SessionStart hook not registered"
jq -e '[.hooks.UserPromptSubmit[] | .hooks[].command] | any(test("prompt-followup\\.sh$"))' "$SET" >/dev/null \
  && pass "settings.json registers prompt-followup.sh under UserPromptSubmit" || fail "UserPromptSubmit hook not registered"
for f in security/lib/logs.sh bin/whatsup bin/doc-dupes claude/hooks/session-start.sh claude/hooks/prompt-followup.sh claude/hooks/stop-log-check.sh scripts/test-logs.sh; do
  grep -qx "$f" "$DOTFILES_DIR/test.sh" && pass "test.sh shellchecks $f" || fail "test.sh does not shellcheck $f"
done
grep -q 'run_suite logs' "$DOTFILES_DIR/test.sh" && pass "test.sh runs this suite (./test.sh logs)" || fail "suite not wired"
STD="$DOTFILES_DIR/docs/policy/repo-standards.md"
grep -q "\`no-changelog-entry\`" "$STD" && grep -q "\`no-changelog\`" "$STD" && pass "Enforcement table has the changelog row" || fail "no changelog row in § Enforcement"
grep -q "\`decision-unverified\`" "$STD" && grep -q "\`decisions-unverified\`" "$STD" && pass "Enforcement table has the decisions row" || fail "no decisions row in § Enforcement"
grep -q "\`docs-redundant\`" "$STD" && grep -q 'prompt-followup.sh' "$STD" && grep -q 'doc-dupes' "$STD" \
  && pass "Enforcement table has the TODO and redundancy rows" || fail "no TODO / redundancy rows in § Enforcement"
grep -q "\`no-changelog\`" "$DOTFILES_DIR/docs/dev-audit.md" && grep -q "\`decisions-unverified\`" "$DOTFILES_DIR/docs/dev-audit.md" \
  && grep -q "\`docs-redundant\`" "$DOTFILES_DIR/docs/dev-audit.md" \
  && pass "docs/dev-audit.md documents the three check ids" || fail "dev-audit.md lacks an id"
AI="$DOTFILES_DIR/docs/policy/ai-instructions.md"
grep -q '^## Open items live in `TODO.md`' "$AI" && grep -q '^## Logs are checked for redundancy' "$AI" \
  && pass "ai-instructions.md has the TODO and redundancy sections" || fail "ai-instructions.md lacks a section"
grep -q 'whatsup' "$DOTFILES_DIR/bin/README.md" && grep -q 'doc-dupes' "$DOTFILES_DIR/bin/README.md" && pass "bin/README.md lists whatsup and doc-dupes" || fail "bin/README.md lacks a tool"
grep -q 'whatsup' "$DOTFILES_DIR/claude/dev-CLAUDE.md" && grep -q 'doc-dupes' "$DOTFILES_DIR/claude/dev-CLAUDE.md" && grep -q 'TODO.md' "$DOTFILES_DIR/claude/dev-CLAUDE.md" \
  && pass "the workspace CLAUDE.md names whatsup, doc-dupes and TODO.md" || fail "dev-CLAUDE.md lacks a name"

# ================================================================================
echo ""
echo -e "${BOLD}test-logs: ${GREEN}$PASS_COUNT passed${NC}, ${RED}$FAIL_COUNT failed${NC}, $SKIP_COUNT skipped${NC}"
[ "$FAIL_COUNT" = 0 ]
