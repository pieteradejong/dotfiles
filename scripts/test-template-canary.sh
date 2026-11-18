#!/usr/bin/env bash
#
# test-template-canary.sh — test suite for scripts/template-canary.sh (D79).
#
# Hermetic: fixture templates under a temp dir, a fixture global git config that registers the
# REAL security gate as ~/.gitconfig does, a local bare repo standing in for GitHub (its path
# contains github.com/pieteradejong/ so the gate treats it as an own repo), and a stub `gh` that
# answers visibility, run lists and run views from per-branch behaviour files. Nothing here
# touches a real repo, the real ~/.gitconfig, the real templates, or the network.
#
# Run: ./scripts/test-template-canary.sh [--verbose]      Exit: 0 all passed, 1 otherwise.
#
# shellcheck disable=SC2015 # `cond && pass || fail` is safe here: pass/fail always return 0

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CANARY="$DOTFILES_DIR/scripts/template-canary.sh"
GATE="$DOTFILES_DIR/security/gate.sh"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

RED="\033[31m"; GREEN="\033[32m"; BOLD="\033[1m"; CYAN="\033[36m"; NC="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"; $VERBOSE || [ ! -s "$OUT" ] || sed 's/^/      | /' "$OUT" | head -40; }
header() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──${NC}"; }

# --- sandbox --------------------------------------------------------------------------------------
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/canary-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT
OUT="$T/out"; : > "$OUT"
export HOME="$T/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export SECURITY_GATE_CACHE_DIR="$T/cache"
export SECURITY_GATE_BYPASS_LOG="$T/state/bypass.log"
export NO_COLOR=1
unset SECURITY_GATE_BYPASS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CANARY_KEEP
mkdir -p "$HOME" "$T/bin" "$T/behave" "$T/reports"

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
[hook "security-gate-push"]
    event = pre-push
    command = $GATE pre-push
EOF

BARE="$T/remotes/github.com/pieteradejong/template-ci-canary.git"
mkdir -p "$(dirname "$BARE")"

# Stub gh. Visibility from $T/vis (PRIVATE | PUBLIC | fail). `run list --commit SHA` finds the
# branch in the bare remote that points at SHA, reads $T/behave/<branch with / as ->:
#   green | red | none | pending | pending-then-green (pending on the first ask, then green)
# `run view ID` prints the failed-run detail line the script's jq query would produce.
cat > "$T/bin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/gh-calls"
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "repo view")
    v="\$(cat "$T/vis" 2>/dev/null)"; [ "\$v" = fail ] && { echo "HTTP 404" >&2; exit 1; }
    echo "\${v:-PRIVATE}"; exit 0 ;;
  "run list")
    sha=""; while [ \$# -gt 0 ]; do [ "\$1" = --commit ] && sha="\$2"; shift; done
    br="\$(git --git-dir="$BARE" for-each-ref --points-at "\$sha" --format='%(refname:short)' | head -1)"
    key="\$(printf '%s' "\$br" | tr '/' '-')"
    b="\$(cat "$T/behave/\$key" 2>/dev/null || echo green)"
    n="$T/behave/\$key.asked"; c=\$(( \$(cat "\$n" 2>/dev/null || echo 0) + 1 )); echo \$c > "\$n"
    case "\$b" in
      green)   echo '[{"databaseId":11,"status":"completed","conclusion":"success","workflowName":"CI"},{"databaseId":12,"status":"completed","conclusion":"success","workflowName":"security"}]' ;;
      red)     echo '[{"databaseId":21,"status":"completed","conclusion":"failure","workflowName":"CI"},{"databaseId":22,"status":"completed","conclusion":"success","workflowName":"security"}]' ;;
      none)    echo '[]' ;;
      pending) echo '[{"databaseId":31,"status":"in_progress","conclusion":"","workflowName":"CI"}]' ;;
      pending-then-green)
        if [ "\$c" -le 1 ]; then echo '[{"databaseId":41,"status":"queued","conclusion":"","workflowName":"CI"}]'
        else echo '[{"databaseId":41,"status":"completed","conclusion":"success","workflowName":"CI"}]'; fi ;;
    esac
    exit 0 ;;
  "run view") echo "CI (failure: ci → Test suite)"; exit 0 ;;
esac
echo "stub gh: unexpected \$*" >&2; exit 4
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export GH="$T/bin/gh"

# Fixture templates.
TR="$T/templates"
WF_MAIN='name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - run: ./test.sh --ci
  security:
    uses: pieteradejong/dotfiles/.github/workflows/security-reusable.yml@main
'
mktpl() { # <stack/variant> [workflow text]
  local d="$TR/$1"
  mkdir -p "$d/.github/workflows"
  printf '%s' "${2:-$WF_MAIN}" > "$d/.github/workflows/ci.yml"
  printf '#!/bin/sh\necho ok\n' > "$d/test.sh"; chmod +x "$d/test.sh"
  printf '# %s\n' "$1" > "$d/README.md"
  printf '*.log\n' > "$d/.gitignore"
}
fresh_templates() {
  rm -rf "$TR"
  mktpl py-fastapi/minimal-mvp
  mktpl ts-web/minimal-mvp
}
fresh_remote() { rm -rf "$BARE" "$T"/behave/*; git init -q --bare "$BARE"; echo PRIVATE > "$T/vis"; : > "$T/gh-calls"; }

canary() { # runs the script with the sandbox env; output in $OUT, rc in $RC
  TEMPLATES_ROOT="$TR" CANARY_OUT="$T/reports" CANARY_REMOTE="$BARE" TODAY=2030-01-07 \
    CANARY_POLL=1 CANARY_TIMEOUT="${TIMEOUT:-20}" bash "$CANARY" "$@" > "$OUT" 2>&1
  RC=$?
}
TWO=(--only py-fastapi/minimal-mvp --only ts-web/minimal-mvp)
tsv() { cat "$T/reports/template-canary-2030-01-07.tsv"; }
status_of() { awk -F'\t' -v t="$1" '$1 == t { print $3 }' "$T/reports/template-canary-2030-01-07.tsv"; }
detail_of() { awk -F'\t' -v t="$1" '$1 == t { print $5 }' "$T/reports/template-canary-2030-01-07.tsv"; }
remote_refs() { git --git-dir="$BARE" for-each-ref --format='%(refname)' | sort | tr '\n' ' '; }

# ==================================================================================================
header "usage"
fresh_templates; fresh_remote
canary --list
[ "$RC" = 0 ] && grep -q '^py-fastapi/minimal-mvp  *canary/py-fastapi-minimal-mvp$' "$OUT" && grep -q 'canary/vercel-stack$' "$OUT" \
  && pass "--list names each template and its branch" || fail "--list (rc=$RC)"
grep -q 'rn-supabase' "$OUT" && fail "--list includes rn-supabase (it is its own repo)" || pass "rn-supabase is not a canary template"
[ "$(wc -l < "$OUT" | tr -d ' ')" = 7 ] && pass "--list has the 7 non-repo curated templates" || fail "--list count: $(wc -l < "$OUT")"
[ ! -s "$T/gh-calls" ] && pass "--list calls nothing" || fail "--list called gh"
canary --only nope/x;   [ "$RC" = 2 ] && grep -q 'not a canary template: nope/x' "$OUT" && pass "--only an unknown template exits 2" || fail "--only unknown rc=$RC"
canary --only;          [ "$RC" = 2 ] && pass "--only without a value exits 2" || fail "--only bare rc=$RC"
canary --bogus;         [ "$RC" = 2 ] && pass "an unknown argument exits 2" || fail "bogus rc=$RC"
canary --help;          [ "$RC" = 0 ] && grep -q -- '--dry-run' "$OUT" && pass "--help prints the header" || fail "--help rc=$RC"
TEMPLATES_ROOT="$T/none" CANARY_OUT="$T/reports" bash "$CANARY" --dry-run > "$OUT" 2>&1; RC=$?
[ "$RC" = 2 ] && grep -q 'no templates at' "$OUT" && pass "a missing templates dir exits 2" || fail "missing templates rc=$RC"

# ==================================================================================================
header "dry run: built through the gate, nothing pushed"
fresh_templates; fresh_remote
mkdir -p "$TR/py-fastapi/minimal-mvp/node_modules/x" "$TR/py-fastapi/minimal-mvp/.venv/bin" \
         "$TR/py-fastapi/minimal-mvp/__pycache__" "$TR/py-fastapi/minimal-mvp/dist"
for f in node_modules/x/i.js .venv/bin/python __pycache__/a.pyc dist/bundle.js .DS_Store .env .env.local debug.log; do
  printf 'x\n' > "$TR/py-fastapi/minimal-mvp/$f"
done
printf 'KEY=\n' > "$TR/py-fastapi/minimal-mvp/.env.example"
before="$(cd "$TR" && find . -type f -exec shasum {} + | sort | shasum)"
canary --dry-run "${TWO[@]}"
[ "$RC" = 0 ] && pass "dry run exits 0" || fail "dry run rc=$RC"
[ "$(status_of py-fastapi/minimal-mvp)" = built ] && [ "$(status_of ts-web/minimal-mvp)" = built ] \
  && pass "both templates are built" || fail "statuses: $(tsv)"
[ -z "$(remote_refs)" ] && pass "dry run pushes nothing" || fail "remote has refs: $(remote_refs)"
grep -q 'run list' "$T/gh-calls" && fail "dry run asked for runs" || pass "dry run waits for no runs"
after="$(cd "$TR" && find . -type f -exec shasum {} + | sort | shasum)"
[ "$before" = "$after" ] && pass "the templates themselves are unchanged" || fail "a template file changed"
for f in "$T/reports/template-canary-2030-01-07.md" "$T/reports/template-canary-2030-01-07.tsv"; do
  [ "$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")" = 600 ] && pass "${f##*/} is mode 600" || fail "${f##*/} mode"
done
grep -q 'dry run: nothing pushed' "$T/reports/template-canary-2030-01-07.md" && pass "the report says it was a dry run" || fail "dry-run note missing"

# What a run commits: keep the scratch repo once and read the tree.
TEMPLATES_ROOT="$TR" CANARY_OUT="$T/reports" CANARY_REMOTE="$BARE" CANARY_KEEP=1 TODAY=2030-01-07 \
  bash "$CANARY" --dry-run --only py-fastapi/minimal-mvp > "$OUT" 2>&1
KEPT="$(sed -n 's/^keeping the scratch repo: //p' "$OUT")"
TREE="$(git -C "$KEPT" ls-tree -r --name-only canary/py-fastapi-minimal-mvp 2>/dev/null)"
for bad in node_modules .venv __pycache__ dist/ .DS_Store '^\.env$' '^\.env\.local$' 'debug\.log'; do
  printf '%s\n' "$TREE" | grep -qE -- "$bad" && fail "committed $bad" || pass "not committed: $bad"
done
printf '%s\n' "$TREE" | grep -qx '.env.example' && pass ".env.example is kept" || fail ".env.example dropped"
printf '%s\n' "$TREE" | grep -qx '.gitignore' && printf '%s\n' "$TREE" | grep -qx 'test.sh' && pass "the template's own files are committed" || fail "tree: $TREE"
WF="$(git -C "$KEPT" show canary/py-fastapi-minimal-mvp:.github/workflows/ci.yml)"
[ "$(printf '%s\n' "$WF" | grep -c "branches: \[main, 'canary/\*\*'\]")" = 2 ] && pass "push and pull_request filters gain canary/**" || fail "workflow: $WF"
[ "$(git -C "$KEPT" rev-list --count canary/py-fastapi-minimal-mvp)" = 1 ] && pass "the branch is one orphan commit" || fail "commit count"
git -C "$KEPT" log -1 --format=%ae canary/py-fastapi-minimal-mvp | grep -q 'users.noreply.github.com$' && pass "committed with the noreply identity" || fail "author"
rm -rf "$(dirname "$KEPT")"

# ==================================================================================================
header "the gate and the trigger rewrite decide"
fresh_templates; fresh_remote
printf 'x\n' > "$TR/ts-web/minimal-mvp/id_rsa"
canary --dry-run "${TWO[@]}"
[ "$RC" = 1 ] && pass "a blocked template makes the run exit 1" || fail "rc=$RC"
[ "$(status_of ts-web/minimal-mvp)" = red ] && detail_of ts-web/minimal-mvp | grep -q 'commit blocked: .*ssh-key' \
  && pass "the gate's block is the template's result (ssh-key)" || fail "blocked detail: $(detail_of ts-web/minimal-mvp)"
[ "$(status_of py-fastapi/minimal-mvp)" = built ] && pass "the other template still builds" || fail "other: $(tsv)"

fresh_templates
mktpl ts-web/minimal-mvp 'on:
  push:
    branches:
      - main
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo
'
canary --dry-run "${TWO[@]}"
[ "$(status_of ts-web/minimal-mvp)" = red ] && detail_of ts-web/minimal-mvp | grep -q 'cannot add a canary/\*\* push trigger to ci.yml' \
  && pass "a branch filter the rewrite cannot reach is red, not silently untested" || fail "list-form: $(tsv)"
mktpl ts-web/minimal-mvp 'on:
  schedule:
    - cron: "0 6 * * 1"
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo
'
canary --dry-run "${TWO[@]}"
[ "$(status_of ts-web/minimal-mvp)" = red ] && pass "a workflow with no push trigger is red" || fail "no-push: $(tsv)"
mktpl ts-web/minimal-mvp 'on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo
'
canary --dry-run "${TWO[@]}"
[ "$(status_of ts-web/minimal-mvp)" = built ] && pass "on: [push] with no filter needs no rewrite" || fail "on-push: $(tsv)"
rm -rf "$TR/ts-web/minimal-mvp/.github"
canary --dry-run "${TWO[@]}"
[ "$(status_of ts-web/minimal-mvp)" = red ] && detail_of ts-web/minimal-mvp | grep -q 'no .github/workflows' \
  && pass "a template without workflows is red" || fail "no-wf: $(tsv)"

# ==================================================================================================
header "real run against the stand-in remote"
fresh_templates; fresh_remote
echo pending-then-green > "$T/behave/canary-py-fastapi-minimal-mvp"
echo red > "$T/behave/canary-ts-web-minimal-mvp"
canary "${TWO[@]}"
[ "$RC" = 1 ] && pass "one red template: exit 1" || fail "rc=$RC"
[ "$(remote_refs)" = "refs/heads/canary/py-fastapi-minimal-mvp refs/heads/canary/ts-web-minimal-mvp " ] \
  && pass "only the two canary branches are pushed; no main" || fail "refs: $(remote_refs)"
[ "$(status_of py-fastapi/minimal-mvp)" = green ] && pass "pending, then green: waits and reports green" || fail "py: $(tsv)"
[ "$(cat "$T/behave/canary-py-fastapi-minimal-mvp.asked")" -ge 2 ] && pass "it polled until the runs finished" || fail "polls"
[ "$(status_of ts-web/minimal-mvp)" = red ] && detail_of ts-web/minimal-mvp | grep -q 'CI (failure: ci → Test suite)' \
  && pass "a red run names the workflow, job and step" || fail "red detail: $(detail_of ts-web/minimal-mvp)"
grep -q 'repo view .*template-ci-canary' "$T/gh-calls" && pass "it checks the canary repo's visibility first" || fail "no visibility check"
grep -qE 'run (rerun|cancel|delete)|repo (create|edit|delete)|api .*-X' "$T/gh-calls" && fail "a write call to gh" || pass "gh is only asked to read"

# A second run replaces the branch: still one commit on the remote, no history kept.
echo green > "$T/behave/canary-ts-web-minimal-mvp"
TODAY_BEFORE="$(git --git-dir="$BARE" rev-parse refs/heads/canary/ts-web-minimal-mvp)"
printf 'changed\n' >> "$TR/ts-web/minimal-mvp/README.md"
canary "${TWO[@]}"
[ "$RC" = 0 ] && pass "all green: exit 0" || fail "rc=$RC: $(tsv)"
[ "$(git --git-dir="$BARE" rev-list --count refs/heads/canary/ts-web-minimal-mvp)" = 1 ] \
  && [ "$(git --git-dir="$BARE" rev-parse refs/heads/canary/ts-web-minimal-mvp)" != "$TODAY_BEFORE" ] \
  && pass "a rerun force-replaces the branch with one new commit" || fail "rerun history"

echo green > "$T/behave/canary-py-fastapi-minimal-mvp"
canary --summary "${TWO[@]}"
[ "$(grep -c "^INFO	template .*: CI green on GitHub (2 run(s))$" "$OUT")" = 2 ] && pass "--summary: green templates are INFO lines" || fail "summary: $(cat "$OUT")"
echo red > "$T/behave/canary-ts-web-minimal-mvp"
canary --summary "${TWO[@]}"
grep -q '^WARN	template ts-web/minimal-mvp: CI red on GitHub — CI (failure: ci → Test suite)$' "$OUT" && pass "--summary: a red template is a WARN" || fail "summary red: $(cat "$OUT")"
grep -vqE '^(WARN|INFO)	' "$OUT" && fail "--summary printed a non-LEVEL line" || pass "--summary prints only LEVEL<TAB>text"

# ==================================================================================================
header "timeouts and refusals"
fresh_templates; fresh_remote
echo none > "$T/behave/canary-py-fastapi-minimal-mvp"
echo pending > "$T/behave/canary-ts-web-minimal-mvp"
TIMEOUT=2 canary "${TWO[@]}"
[ "$RC" = 1 ] && pass "timeouts exit 1" || fail "rc=$RC"
detail_of py-fastapi/minimal-mvp | grep -q 'no workflow run started within 2s' && pass "no run at all is red: trigger not matched" || fail "none: $(tsv)"
detail_of ts-web/minimal-mvp | grep -q 'timed out after 2s with 1 run(s) unfinished' && pass "an unfinished run is red after the timeout" || fail "pending: $(tsv)"

fresh_remote; echo fail > "$T/vis"
canary "${TWO[@]}"
[ "$RC" = 2 ] && grep -q 'cannot reach pieteradejong/template-ci-canary' "$OUT" && [ -z "$(remote_refs)" ] \
  && pass "an unreachable canary repo exits 2 before any push" || fail "unreachable rc=$RC refs=$(remote_refs)"
echo PUBLIC > "$T/vis"
canary "${TWO[@]}"
[ "$RC" = 2 ] && grep -q 'is PUBLIC, not PRIVATE' "$OUT" && [ -z "$(remote_refs)" ] \
  && pass "a PUBLIC canary repo is refused" || fail "public rc=$RC"

fresh_remote
mkdir -p "$T/gitrepo/.git"
TEMPLATES_ROOT="$TR" CANARY_OUT="$T/gitrepo/reports" CANARY_REMOTE="$BARE" bash "$CANARY" "${TWO[@]}" > "$OUT" 2>&1; RC=$?
[ "$RC" = 3 ] && [ ! -s "$T/gh-calls" ] && [ -z "$(remote_refs)" ] \
  && pass "an out dir inside a git repo is refused before anything runs" || fail "git out rc=$RC"

# The script never names main as a push target, whatever the branch variable holds.
grep -nE 'push[^|]*(main|master)' "$CANARY" | grep -v '^ *#' | grep -vE '^[0-9]+: *#' > "$OUT"
[ ! -s "$OUT" ] && pass "no push line in the script mentions main or master" || fail "push lines: $(cat "$OUT")"

echo ""
echo -e "${BOLD}── Summary ──${NC}"
echo -e "  ${GREEN}Passed${NC}: $PASS_COUNT"
echo -e "  ${RED}Failed${NC}: $FAIL_COUNT"
[ "$FAIL_COUNT" = 0 ]
