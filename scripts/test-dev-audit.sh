#!/usr/bin/env bash
#
# test-dev-audit.sh — test suite for dev-audit.sh.
#
# dev-audit.sh walks ~91 real git repos, so its safety properties cannot be
# tested by running it against the real workspace and hoping. This suite builds
# a throwaway DEV_ROOT of fixture repos with known defects, runs the audit
# against that, and asserts on what it finds and - more importantly - on what
# it did not touch.
#
# Run: ./scripts/test-dev-audit.sh [--verbose]
# Exit: 0 all passed, 1 otherwise.

set -u

# Fixture repos deliberately commit secrets and .env files. This machine's global
# git config registers the commit/push security gate, which (correctly) refuses
# them — so the whole suite runs under an isolated, gate-free git config.
GIT_TEST_HOME="$(mktemp -d)"
export GIT_CONFIG_GLOBAL="$GIT_TEST_HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/dev-audit.sh"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT+1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); echo -e "  ${RED}✗ FAIL${NC}: $1"; }
info() { $VERBOSE && echo -e "  ${YELLOW}→${NC} $1"; return 0; }
header() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──${NC}"; }

# assert_finding <tsv> <severity> <repo> <check>
assert_finding() {
  local tsv="$1" sev="$2" repo="$3" check="$4"
  if LC_ALL=C grep -q "^${sev}	[a-z]*	${repo}	${check}	" "$tsv"; then
    pass "$repo -> $sev $check"
  else
    fail "$repo -> expected $sev $check, not found"
    $VERBOSE && grep "	${repo}	" "$tsv" | sed 's/^/      /'
  fi
}

assert_no_finding() {
  local tsv="$1" repo="$2" check="$3"
  if LC_ALL=C grep -q "	${repo}	${check}	" "$tsv"; then
    fail "$repo -> should NOT report $check"
  else
    pass "$repo -> correctly silent on $check"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures: a throwaway workspace of repos with known, deliberate defects.
# ---------------------------------------------------------------------------
FIXTURE_ROOT=""
OUT_DIR=""

mkrepo() {
  local d="$FIXTURE_ROOT/projects/$1"; shift
  mkdir -p "$d"
  git -c init.defaultBranch=main init -q "$d"
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  printf '%s\n' "$@" > /dev/null
  echo "$d"
}

commit_all() {
  local d="$1" msg="${2:-init}"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c commit.gpgsign=false commit -qm "$msg" >/dev/null 2>&1
}

build_fixtures() {
  FIXTURE_ROOT="$(mktemp -d)"
  OUT_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_ROOT/projects"

  # clean-repo: everything correct. Must produce no FAILs.
  local d; d="$(mkrepo clean-repo)"
  printf 'MIT License\n\nCopyright (c) 2026 Pieter de Jong\n' > "$d/LICENSE"
  printf '.env\n.DS_Store\n__pycache__/\n.venv/\nvenv/\nnode_modules/\n**/node_modules/\n**/.env\n' > "$d/.gitignore"
  mkdir -p "$d/.github/workflows"; printf 'name: ci\n' > "$d/.github/workflows/ci.yml"
  printf '# clean\n' > "$d/README.md"
  commit_all "$d"
  # A genuinely clean repo has an off-machine copy. Without a remote it would
  # (correctly) FAIL no-remote and no-offmachine-copy, so give it a bare
  # upstream and push, otherwise this fixture cannot test "no false positives".
  git -c init.defaultBranch=main init -q --bare "$FIXTURE_ROOT/upstream-clean.git"
  git -C "$d" remote add origin "$FIXTURE_ROOT/upstream-clean.git"
  git -C "$d" push -q -u origin main >/dev/null 2>&1

  # tracked-env: a committed .env. The classic incident.
  d="$(mkrepo tracked-env)"
  printf 'SECRET_VALUE=hunter2_do_not_leak\n' > "$d/.env"
  printf '# x\n' > "$d/README.md"
  commit_all "$d"

  # leaky-content: secret-shaped content in a tracked file.
  d="$(mkrepo leaky-content)"
  printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > "$d/config.py"
  commit_all "$d"

  # fixture-noise: the SAME shapes, but in a test file. Must NOT be reported.
  d="$(mkrepo fixture-noise)"
  mkdir -p "$d/tests"
  printf 'EMAIL = "john.doe@example.com"\nKEY = "AKIAIOSFODNN7EXAMPLE"\n' > "$d/tests/test_fixtures.py"
  commit_all "$d"

  # no-license-repo: no LICENSE, no .gitignore, no CI.
  d="$(mkrepo no-license-repo)"
  printf '# x\n' > "$d/README.md"
  commit_all "$d"

  # bad-copyright: wrong holder spelling + manifest disagreeing with LICENSE.
  d="$(mkrepo bad-copyright)"
  printf 'MIT License\n\nCopyright (c) 2026 Peter de Jong\n' > "$d/LICENSE"
  printf '{"name":"x","license":"ISC"}\n' > "$d/package.json"
  printf '.env\n.DS_Store\n__pycache__/\n.venv/\nvenv/\nnode_modules/\n**/node_modules/\n**/.env\n' > "$d/.gitignore"
  commit_all "$d"

  # published-ssh: a tracked ssh config with a real-looking host and account.
  d="$(mkrepo published-ssh)"
  mkdir -p "$d/ssh"
  # Every value here must be synthetic: this file is tracked in a public repo.
  printf 'Host prod\n  HostName ssh.realhost.example-not.net\n  User acct-abc123\n  Port 12345\n' > "$d/ssh/config"
  commit_all "$d"

  # do-not-touch: must be skipped entirely, with no git command run in it.
  d="$(mkrepo do-not-touch)"
  printf 'SECRET_VALUE=must_never_be_scanned\n' > "$d/.env"
  commit_all "$d"

  # not-a-repo: a plain directory under projects/.
  mkdir -p "$FIXTURE_ROOT/projects/not-a-repo"
  printf 'x\n' > "$FIXTURE_ROOT/projects/not-a-repo/file.txt"

  # --- fixtures added 2026-09-07 with the new checks -------------------------

  # grouped/deep-repo: a repo one level deeper than projects/<repo>. Before the
  # maxdepth fix this was invisible AND its parent was reported `not-a-repo`.
  mkdir -p "$FIXTURE_ROOT/projects/grouped"
  d="$FIXTURE_ROOT/projects/grouped/deep-repo"
  mkdir -p "$d"
  git -c init.defaultBranch=main init -q "$d"
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  printf 'SECRET_VALUE=deep_and_unseen\n' > "$d/.env"
  commit_all "$d"

  # malformed-license: a LICENSE that is captured terminal output, not a license.
  d="$(mkrepo malformed-license)"
  printf "Looks like there's already a license file for this project.\n\033[2KExiting...\n" > "$d/LICENSE"
  printf '.env\n.DS_Store\n__pycache__/\n.venv/\nvenv/\nnode_modules/\n**/node_modules/\n**/.env\n' > "$d/.gitignore"
  commit_all "$d"

  # unignored-env: has a .gitignore, but .env is not in it.
  d="$(mkrepo unignored-env)"
  printf '.DS_Store\n__pycache__/\n.venv/\nvenv/\nnode_modules/\n**/node_modules/\n' > "$d/.gitignore"
  printf '# x\n' > "$d/README.md"
  commit_all "$d"

  # deleted-secret: a .env committed and then removed. Invisible to ls-files,
  # fully present in history. The case --history exists for.
  d="$(mkrepo deleted-secret)"
  printf 'SECRET_VALUE=was_here_then_deleted\n' > "$d/.env"
  printf '# x\n' > "$d/README.md"
  commit_all "$d" "add env"
  rm "$d/.env"
  printf '.env\n.DS_Store\n__pycache__/\n.venv/\nvenv/\nnode_modules/\n**/node_modules/\n**/.env\n' > "$d/.gitignore"
  commit_all "$d" "remove env"

  # secret-assignment: a quoted literal assigned to a secret-shaped name.
  d="$(mkrepo secret-assignment)"
  printf 'DB_PASSWORD = "s0mething-quite-long-here"\n' > "$d/settings.py"
  commit_all "$d"

  # placeholder-assignment: the same shape, but a placeholder. Must NOT fire.
  d="$(mkrepo placeholder-assignment)"
  printf 'DB_PASSWORD = "${DB_PASSWORD}"\nAPI_KEY = "<your-key>"\n' > "$d/settings.py"
  commit_all "$d"

  # gitleaks-bait: a synthetic credential that gitleaks will actually flag.
  # NOT reusing leaky-content's AKIAIOSFODNN7EXAMPLE: that is AWS's own
  # documentation key and gitleaks allowlists it, so asserting on it silently
  # tests nothing. It still exercises our own CONTENT_RULES, which is what that
  # fixture is for. Generated at runtime: a literal token in this file would be
  # found by the very scanners this repo runs on itself (the gate, CI gitleaks).
  d="$(mkrepo gitleaks-bait)"
  # Bounded read: an unbounded `tr < /dev/urandom` never exits where SIGPIPE is ignored (CI).
  GITLEAKS_BAIT="ghp_$(head -c 8192 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 36)"
  printf 'TOKEN = "%s"\n' "$GITLEAKS_BAIT" > "$d/app.py"
  commit_all "$d"

  # A skiplist scoped to the fixtures.
  SKIPLIST_FIXTURE="$FIXTURE_ROOT/skiplist.conf"
  printf 'skip:do-not-touch:test fixture, must never be scanned\nfork:fixture-noise:test fixture fork\n' \
    > "$SKIPLIST_FIXTURE"
}

cleanup() { [ -n "$FIXTURE_ROOT" ] && rm -rf "$FIXTURE_ROOT"; [ -n "$OUT_DIR" ] && rm -rf "$OUT_DIR"; rm -rf "$GIT_TEST_HOME"; }
trap cleanup EXIT

run_audit() {
  DEV_ROOT="$FIXTURE_ROOT" SKIPLIST_FILE="$SKIPLIST_FIXTURE" \
    "$AUDIT" --out "$OUT_DIR" --quiet "$@" >/dev/null 2>&1
  echo "$OUT_DIR/findings-$(date +%Y-%m-%d).tsv"
}

# ---------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}dev-audit test suite${NC}"
build_fixtures
info "fixtures at $FIXTURE_ROOT"

# --- 1. read-only guarantee -------------------------------------------------
header "1. Read-only guarantee (the property that matters most)"
STAMP="$(mktemp)"; sleep 1
TSV="$(run_audit)"

CHANGED="$(find "$FIXTURE_ROOT" -newer "$STAMP" -not -path '*/.git/*' 2>/dev/null | grep -v "^$FIXTURE_ROOT$" || true)"
if [ -z "$CHANGED" ]; then
  pass "No file under the scanned root was created, modified or deleted"
else
  fail "Audit modified files under the scanned root:"
  echo "$CHANGED" | head -5 | sed 's/^/      /'
fi

LOCKS="$(find "$FIXTURE_ROOT" -name index.lock 2>/dev/null | wc -l | tr -d ' ')"
[ "$LOCKS" = "0" ] && pass "No .git/index.lock left behind (--no-optional-locks)" \
                   || fail "Left $LOCKS index.lock file(s) behind"

if grep -rqI 'no-optional-locks' "$SCRIPT_DIR/audit/lib.sh"; then
  pass "git_ro() uses --no-optional-locks"
else
  fail "git_ro() is missing --no-optional-locks"
fi

# Comments are stripped first, and the pattern is anchored to COMMAND
# POSITION. Both matter: these files document what they refuse to do, and one
# finding message legitimately contains the string "git gc" while running no
# such thing. Matching raw text would fail on the tool's own documentation.
code_of() { sed 's/#.*//' "$@" 2>/dev/null; }
MUTATING_RE='(^|[;&|]|\$\()[[:space:]]*git(_ro)?[[:space:]][^;&|]*[[:space:]](commit|push|gc|checkout|reset|clean|filter-branch|update-ref|stash)([[:space:]]|$)'
if code_of "$AUDIT" "$SCRIPT_DIR"/audit/*.sh | grep -qE "$MUTATING_RE"; then
  fail "A mutating git subcommand is invoked in the audit sources"
  code_of "$AUDIT" "$SCRIPT_DIR"/audit/*.sh | grep -nE "$MUTATING_RE" | head -3 | sed 's/^/      /'
else
  pass "No mutating git subcommand is invoked anywhere in the sources"
fi

# Prove the check above can actually fail, so a green result means something.
if printf '%s\n' '  git -C "$r" push origin main' | grep -qE "$MUTATING_RE"; then
  pass "  (self-check: the mutating-git detector catches a real 'git push')"
else
  fail "  (self-check: the mutating-git detector is broken - it misses 'git push')"
fi

# --- 2. findings fire correctly ---------------------------------------------
header "2. Checks fire on known-bad fixtures"
[ -s "$TSV" ] && pass "Findings file written" || fail "No findings file at $TSV"

assert_finding "$TSV" FAIL tracked-env     env-file
assert_finding "$TSV" FAIL leaky-content   aws-access-key
assert_finding "$TSV" FAIL no-license-repo no-gitignore
assert_finding "$TSV" WARN bad-copyright   copyright-drift
assert_finding "$TSV" WARN bad-copyright   license-mismatch
assert_finding "$TSV" WARN not-a-repo      not-a-repo
assert_finding "$TSV" FAIL tracked-env     no-remote

# --- 3. no false positives ---------------------------------------------------
header "3. Clean fixtures stay clean"
if LC_ALL=C grep -q '^FAIL	[a-z]*	clean-repo	' "$TSV"; then
  fail "clean-repo produced a FAIL"
  $VERBOSE && grep '	clean-repo	' "$TSV" | sed 's/^/      /'
else
  pass "clean-repo produced no FAIL"
fi
assert_no_finding "$TSV" fixture-noise aws-access-key
assert_no_finding "$TSV" fixture-noise email

# --- 4. do-not-touch is honoured ---------------------------------------------
header "4. Skip list"
assert_no_finding "$TSV" do-not-touch env-file
if LC_ALL=C grep -q '	do-not-touch	' "$TSV"; then
  fail "Skipped repo produced findings"
else
  pass "Skipped repo produced no findings at all"
fi

# --- 5. secrets never appear in output ---------------------------------------
header "5. Findings never quote the matched value"
LEAKED=0
for v in hunter2_do_not_leak AKIAIOSFODNN7EXAMPLE must_never_be_scanned "${GITLEAKS_BAIT:-unset-bait}"; do
  if LC_ALL=C grep -q "$v" "$TSV" 2>/dev/null; then fail "Secret value '$v' leaked into findings"; LEAKED=1; fi
  if [ -f "$OUT_DIR/audit-$(date +%Y-%m-%d).md" ] && LC_ALL=C grep -q "$v" "$OUT_DIR/audit-$(date +%Y-%m-%d).md"; then
    fail "Secret value '$v' leaked into the rendered report"; LEAKED=1
  fi
done
[ "$LEAKED" = 0 ] && pass "No fixture secret value appears in the findings or the report"

# --- 6. output confidentiality ------------------------------------------------
header "6. Report confidentiality"
REPORT="$OUT_DIR/audit-$(date +%Y-%m-%d).md"
[ -f "$REPORT" ] && pass "Report rendered" || fail "No report at $REPORT"
if [ -f "$REPORT" ]; then
  PERM="$(ls -l "$REPORT" | cut -c1-10)"
  [ "$PERM" = "-rw-------" ] && pass "Report is chmod 600 ($PERM)" || fail "Report perms are $PERM, expected -rw-------"
fi

# The tool must refuse to write findings inside a git repo.
GITOUT="$(mktemp -d)"; git -c init.defaultBranch=main init -q "$GITOUT"
DEV_ROOT="$FIXTURE_ROOT" SKIPLIST_FILE="$SKIPLIST_FIXTURE" "$AUDIT" --out "$GITOUT" --quiet >/dev/null 2>&1
RC=$?
[ "$RC" = "3" ] && pass "Refuses to write findings into a git repo (exit 3)" \
                || fail "Wrote into a git repo instead of refusing (exit $RC)"
rm -rf "$GITOUT"

# --- 7. exit codes ------------------------------------------------------------
header "7. Exit codes"
DEV_ROOT="$FIXTURE_ROOT" SKIPLIST_FILE="$SKIPLIST_FIXTURE" "$AUDIT" --no-report --quiet >/dev/null 2>&1
[ $? -eq 1 ] && pass "Exits 1 when a FAIL is present" || fail "Did not exit 1 despite FAIL findings"

DEV_ROOT="$FIXTURE_ROOT" SKIPLIST_FILE="$SKIPLIST_FIXTURE" "$AUDIT" --bogus-flag >/dev/null 2>&1
[ $? -eq 2 ] && pass "Exits 2 on unknown option" || fail "Wrong exit code for unknown option"

# --- 8. all categories produce output ------------------------------------------
header "8. Every category runs (regression: CAT was a global and collided)"
for c in git policy privacy disk; do
  if LC_ALL=C awk -F'\t' -v c="$c" '$2==c{f=1} END{exit !f}' "$TSV"; then
    pass "Category '$c' produced findings"
  else
    fail "Category '$c' produced nothing - modules may be overwriting each other"
  fi
done

# A full run must not degrade into fork failure partway (the Bus error
# regression: process substitutions in nested loops left thousands of
# unreaped children, and later modules silently produced nothing).
header "9. Full run completes without fork exhaustion"
ERROUT="$(mktemp)"
DEV_ROOT="$HOME/dev" DEV_AUDIT_NO_GITLEAKS=1 \
  "$AUDIT" --no-report --quiet >/dev/null 2>"$ERROUT"
if grep -qiE 'bus error|cannot fork|resource temporarily unavailable' "$ERROUT"; then
  fail "Full run against ~/dev hit a fork/resource error"
  head -3 "$ERROUT" | sed 's/^/      /'
else
  pass "Full run against the real ~/dev completed with no fork errors"
fi
rm -f "$ERROUT"

# --- 10. portability -----------------------------------------------------------
header "10. Portability (macOS bash 3.2 + BSD userland)"
for f in "$AUDIT" "$SCRIPT_DIR"/audit/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>/dev/null || fail "Syntax error: $(basename "$f")"
done
pass "All sources parse"

if code_of "$AUDIT" "$SCRIPT_DIR"/audit/*.sh \
     | grep -qE '\b(mapfile|readarray)\b|declare -A|\$\{[a-zA-Z_]+,,\}|\$\{[a-zA-Z_]+\^\^\}'; then
  fail "Uses a bash 4+ feature; macOS ships bash 3.2"
else
  pass "No bash 4+ features (no mapfile/readarray, no declare -A, no case expansion)"
fi

if code_of "$AUDIT" "$SCRIPT_DIR"/audit/*.sh \
     | grep -qE "xargs +-[a-z]*d |xargs +-[a-z]*r |grep +-P|sed +-r|find .* -printf"; then
  fail "Uses a GNU-only flag; BSD userland on macOS will not accept it"
else
  pass "No GNU-only flags (xargs -d/-r, grep -P, sed -r, find -printf)"
fi

# --- 11. the .gitignore naming trap ---------------------------------------------
header "11. dotfiles/.gitignore naming trap"
DF="$(cd "$SCRIPT_DIR/.." && pwd)"
IGNORED=0
for f in "$AUDIT" "$SCRIPT_DIR"/audit/*; do
  [ -e "$f" ] || continue
  git -C "$DF" check-ignore -q "$f" 2>/dev/null && { fail "IGNORED by .gitignore: $(basename "$f")"; IGNORED=1; }
done
[ "$IGNORED" = 0 ] && pass "No audit source is caught by .gitignore"

for f in reports/x.md audit-reports/findings-2026-01-01.tsv audit-2026-01-01.md; do
  git -C "$DF" check-ignore -q "$f" 2>/dev/null && pass "Output ignored: $f" \
    || fail "Output NOT ignored, could be published: $f"
done

# --- 12. checks added 2026-09-07 -----------------------------------------------
header "12. Discovery depth, license sanity, .env, history, committer email"

TSV12="$(run_audit --history)"

# Discovery: the deep repo is seen at all, and its parent is not mislabeled.
assert_finding    "$TSV12" FAIL deep-repo env-file
assert_no_finding "$TSV12" grouped not-a-repo

# A LICENSE that is not a license.
assert_finding "$TSV12" FAIL malformed-license license-malformed
assert_no_finding "$TSV12" clean-repo license-malformed

# .env missing from .gitignore is its own FAIL, not buried in gitignore-gaps.
assert_finding "$TSV12" FAIL unignored-env gitignore-env
assert_no_finding "$TSV12" clean-repo gitignore-env

# History: a secret deleted from HEAD is still reported.
assert_finding "$TSV12" FAIL deleted-secret history-env-file
# ...and not double-reported as a currently-tracked file.
assert_no_finding "$TSV12" deleted-secret env-file

# Generic secret-shaped assignment, with placeholders suppressed.
assert_finding    "$TSV12" WARN secret-assignment secret-assignment
assert_no_finding "$TSV12" placeholder-assignment secret-assignment

# Committer identity is reported (fixtures commit as test@example.com).
assert_finding "$TSV12" INFO clean-repo committer-email

# The do-not-touch repo stays untouched even with history scanning on.
assert_no_finding "$TSV12" do-not-touch history-env-file
assert_no_finding "$TSV12" do-not-touch committer-email

# The audit must not emit shell errors. This is not pedantry: a
# "integer expression expected" from a bad numeric comparison silently
# discarded EVERY gitleaks finding in the 2026-09-07 run, and the run still
# exited 0. A tool that reports nothing because it errored is worse than one
# that crashes.
STDERR12="$(mktemp)"
DEV_ROOT="$FIXTURE_ROOT" SKIPLIST_FILE="$SKIPLIST_FIXTURE" \
  "$AUDIT" --out "$OUT_DIR" --quiet --history >/dev/null 2>"$STDERR12"
if [ -s "$STDERR12" ]; then
  fail "audit wrote to stderr: $(head -2 "$STDERR12" | tr '\n' ' ')"
else
  pass "Audit run produces no shell errors on stderr"
fi
rm -f "$STDERR12"

# gitleaks, when installed, must actually report the fixture secret.
if command -v gitleaks >/dev/null 2>&1; then
  assert_finding "$TSV12" FAIL gitleaks-bait gitleaks
  # ...and the value itself must not reach the report, even via the scanner.
  if LC_ALL=C grep -q 'aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5' "$TSV12" 2>/dev/null; then
    fail "gitleaks finding leaked the credential value into the report"
  else
    pass "gitleaks findings are redacted in the report"
  fi
else
  info "gitleaks not installed; skipping its assertion"
fi

# Still no secret values anywhere in the history-scanning output.
if LC_ALL=C grep -qE 'hunter2_do_not_leak|deep_and_unseen|was_here_then_deleted|s0mething-quite-long-here' \
     "$TSV12" "${TSV12%.tsv}.md" 2>/dev/null; then
  fail "history/gitleaks output leaked a secret value"
else
  pass "No secret value appears in output, including history findings"
fi

# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}── Summary ──${NC}"
echo -e "  ${GREEN}Passed${NC}: $PASS_COUNT"
echo -e "  ${RED}Failed${NC}: $FAIL_COUNT"
echo ""
[ "$FAIL_COUNT" -eq 0 ] && { echo -e "  ${GREEN}${BOLD}All tests passed${NC}"; exit 0; }
echo -e "  ${RED}${BOLD}$FAIL_COUNT test(s) failed${NC}"; exit 1
