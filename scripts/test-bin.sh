#!/usr/bin/env bash
#
# test-bin.sh — tests for the executables in bin/.
#
# Two kinds of assertion, because the two scripts differ in what is safe to run:
#
#   llm                     executed, but only via --dry-run / --list, which
#                           decide and print without ever inferring. That makes
#                           the whole routing table testable with no model, no
#                           backend and no network.
#   weekly-disk-cleanup.sh  NEVER executed. It empties Trash and prunes caches.
#                           Asserted statically instead: it parses, and every
#                           destructive form in it is either commented out or
#                           scoped to ~/.Trash.
#
# Both are zsh, so neither can join test.sh's shellcheck suite — shellcheck does
# not parse zsh. `zsh -n` is the substitute and runs as its own suite.
#
# Run: ./scripts/test-bin.sh [--verbose]   Exit: 0 all passed, 1 otherwise.
#
# shellcheck disable=SC2015 # `cond && pass || fail` is safe: pass/fail return 0
# shellcheck disable=SC2016 # patterns matching literal $HOME in another file are single-quoted on purpose

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/bin"
LLM="$BIN_DIR/llm"
CLEANUP="$BIN_DIR/weekly-disk-cleanup.sh"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

RED="\033[31m"; GREEN="\033[32m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0
SKIP_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); echo -e "  ${CYAN}• SKIP${NC}: $1"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"
  if [ -s "$OUT" ]; then if $VERBOSE; then sed 's/^/      | /' "$OUT"; else sed 's/^/      | /' "$OUT" | head -20; fi; fi
}
header() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──${NC}"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/bin-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
OUT="$T/out"; : > "$OUT"

command -v zsh >/dev/null 2>&1 || { echo "zsh is not installed"; exit 1; }

# run_llm <args...> — run llm with a deliberately empty env, capturing both
# streams. No inheritance of a real OLLAMA_HOST or LLM_ENDPOINTS from the
# developer's shell, so results do not depend on this machine.
#
# BIN_TEST_ENDPOINTS overrides the probe list. Its purpose is to make the
# no-backend path reachable on a machine that HAS a backend: point it at a dead
# loopback port and this suite takes the same branch CI does. Without that, the
# skip branch could only ever be exercised by CI itself, which is where an
# untested branch goes wrong unseen.
run_llm() {
  : > "$OUT"
  if [ -n "${BIN_TEST_ENDPOINTS:-}" ]; then
    env -u OLLAMA_HOST -u LLM_MLX_MODEL -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
        LLM_ENDPOINTS="$BIN_TEST_ENDPOINTS" "$LLM" "$@" > "$OUT" 2>&1
  else
    env -u OLLAMA_HOST -u LLM_ENDPOINTS -u LLM_MLX_MODEL \
        -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
        "$LLM" "$@" > "$OUT" 2>&1
  fi
}

# ── 1. The scripts are present and executable ────────────────────────────────
header "bin/ layout"

[ -x "$LLM" ] && pass "bin/llm is executable" || fail "bin/llm is executable"
[ -x "$CLEANUP" ] && pass "bin/weekly-disk-cleanup.sh is executable" || fail "bin/weekly-disk-cleanup.sh is executable"

# A second copy is how the stale-duplicate problem started. Assert it cannot
# come back: weekly-disk-cleanup.sh must exist exactly once in the repo.
n="$(find "$(dirname "$BIN_DIR")" -name weekly-disk-cleanup.sh -not -path '*/.git/*' | wc -l | tr -d ' ')"
[ "$n" = 1 ] && pass "weekly-disk-cleanup.sh exists exactly once in the repo" \
             || fail "weekly-disk-cleanup.sh exists $n times — a duplicate has reappeared"

# ── 2. zsh syntax ────────────────────────────────────────────────────────────
header "syntax (zsh -n — shellcheck cannot parse zsh)"

for f in "$LLM" "$CLEANUP"; do
  : > "$OUT"
  zsh -n "$f" > "$OUT" 2>&1 && pass "zsh -n $(basename "$f")" || fail "zsh -n $(basename "$f")"
done

# ── 3. llm routing — the documented table, run for real ──────────────────────
# --dry-run decides and prints without inferring, so these are fast and cost
# nothing. They do still need a reachable backend: llm probes for one before it
# can name a model, so with no backend it exits early with "no local backend
# reachable". CI runners have no Ollama, hence the skip rather than a failure.
#
# Assertions match llm's REASON string, not the model name. Matching /coder/
# would be satisfied by the model `qwen3-coder:30b` whatever the routing did —
# a test that cannot fail. The reasons are distinct and are the actual decision:
#   "forced coder" / "forced reasoner"  the word was taken as a command
#   "code intent" / "general intent"    the heuristic chose, no command
header "llm routing (--dry-run)"

backend_available() { run_llm --dry-run "ping" && return 0 || return 1; }

if ! backend_available; then
  skip "routing table — no local backend reachable (expected on CI)"
  skip "cloud-tag refusal — needs a backend (the guard runs after probing)"
  skip "absent-model refusal — needs a backend to list models against"
else
  # route_is <expected-reason> <description> <llm args...>
  route_is() {
    local want="$1" desc="$2"; shift 2
    run_llm --dry-run "$@"
    if grep -qF "($want)" "$OUT"; then pass "$desc"; else
      fail "$desc — expected reason ($want), got: $(head -1 "$OUT")"
    fi
  }

  route_is 'forced coder'    'llm code "..." → command in first position'      code "fix this regex"
  route_is 'forced coder'    'llm -q code "..." → flags may precede a command' -q code "fix this regex"
  route_is 'forced reasoner' 'llm reason "..." → command in first position'    reason "plan my week"
  route_is 'code intent'     'coding prompt → heuristic picks coder'           "fix this failing regex in my parser"

  # `code` and `reason` must stay usable as ordinary words outside the command
  # position. The proof is the reason string: "code intent"/"general intent"
  # means the heuristic decided, i.e. the word was NOT swallowed as a command.
  route_is 'code intent'    'llm "code review this" → prompt, not command'    "code review this"
  route_is 'code intent'    'llm explain this code → `code` not first, stays a prompt' explain this code
  route_is 'general intent' 'llm "the reason it fails" → prompt, not command' "the reason it fails"

  # A cloud-routed tag is not local inference, whatever the endpoint says.
  : > "$OUT"
  run_llm --dry-run -m "some-model-cloud" "hello"
  rc=$?
  { [ "$rc" != 0 ] && grep -qi 'cloud' "$OUT"; } \
    && pass "a model tag containing 'cloud' is refused" \
    || fail "a model tag containing 'cloud' is refused (rc=$rc)"

  # An explicitly requested model that is not installed must fail loudly and
  # name the tag, never silently fall back to a different model.
  : > "$OUT"
  run_llm --dry-run -m definitely-not-an-installed-model-xyz "hello"
  rc=$?
  { [ "$rc" != 0 ] && grep -q 'definitely-not-an-installed-model-xyz' "$OUT"; } \
    && pass "-m with an absent model exits non-zero and names the tag" \
    || fail "-m with an absent model exits non-zero and names the tag (rc=$rc)"
fi

# ── 4. Zero-cloud guards — the security-relevant assertions ──────────────────
header "llm zero-cloud guards"

# Non-loopback endpoints must be a hard error, not a silent skip.
: > "$OUT"
env -u OLLAMA_HOST LLM_ENDPOINTS="1.2.3.4:11434" "$LLM" --dry-run "hello" > "$OUT" 2>&1
rc=$?
{ [ "$rc" != 0 ] && grep -qi 'loopback' "$OUT"; } \
  && pass "LLM_ENDPOINTS with a routable address is refused" \
  || fail "LLM_ENDPOINTS with a routable address is refused (rc=$rc)"

# A remote OLLAMA_HOST must be an error, NOT a quiet fallback to localhost —
# a fallback would make a misconfigured host look like it worked locally.
: > "$OUT"
env OLLAMA_HOST="http://example.com:11434" "$LLM" --list > "$OUT" 2>&1
rc=$?
{ [ "$rc" != 0 ] && grep -qi 'loopback' "$OUT"; } \
  && pass "a remote OLLAMA_HOST is a hard error, not a silent local fallback" \
  || fail "a remote OLLAMA_HOST is a hard error, not a silent local fallback (rc=$rc)"

# Loopback spellings must all be accepted, or the guard is unusable in practice.
for host in "127.0.0.1:11434" "localhost:11434"; do
  : > "$OUT"
  env -u OLLAMA_HOST LLM_ENDPOINTS="$host" "$LLM" --dry-run "hello" > "$OUT" 2>&1
  grep -qi 'refusing non-loopback' "$OUT" \
    && fail "loopback endpoint $host is accepted" \
    || pass "loopback endpoint $host is accepted"
done

# The canary: no API key may ever be read or forwarded. Asserted structurally,
# because a behavioral assertion would need a live backend to send to.
# The only permitted mentions of *_API_KEY are in the comment saying they are
# deliberately not read.
: > "$OUT"
grep -n 'API_KEY' "$LLM" > "$OUT" 2>&1
if grep -vE '^\s*[0-9]+:\s*#' "$OUT" | grep -q 'API_KEY'; then
  fail "no *_API_KEY is referenced outside comments in bin/llm"
else
  pass "no *_API_KEY is referenced outside comments in bin/llm"
fi

# And the key must not reach the wire even when exported.
: > "$OUT"
env OPENAI_API_KEY="sk-canary-must-never-appear" ANTHROPIC_API_KEY="sk-ant-canary" \
    "$LLM" --dry-run "hello" > "$OUT" 2>&1
grep -q 'canary' "$OUT" \
  && fail "an exported API key never appears in llm's output" \
  || pass "an exported API key never appears in llm's output"

# ── 5. weekly-disk-cleanup.sh — static assertions only, never executed ───────
header "weekly-disk-cleanup.sh (static — never executed)"

# The aggressive forms are documented as ideas and must stay commented. This is
# the test that catches an accidental uncomment of `docker system prune -a
# --volumes`, which would delete images and volumes on an unattended Sunday run.
: > "$OUT"
grep -nE '(prune -a|--volumes|simctl delete|-delete)' "$CLEANUP" | grep -vE ':[[:space:]]*#' > "$OUT" 2>&1
[ -s "$OUT" ] && fail "every aggressive cleanup form is commented out" \
              || pass "every aggressive cleanup form is commented out"

# The live Docker prune must stay the conservative form the comment promises.
if grep -qE '^[^#]*docker system prune -f[[:space:]]*$' "$CLEANUP" \
   && ! grep -qE '^[^#]*docker system prune.*(-a|--volumes)' "$CLEANUP"; then
  pass "the live docker prune is the conservative form (no -a, no --volumes)"
else
  fail "the live docker prune is the conservative form (no -a, no --volumes)"
fi

# Any live `rm -rf` must be scoped to ~/.Trash with an age filter. Trash is the
# one place deletion is safe by definition — the user already discarded it.
: > "$OUT"
grep -nE '^[^#]*rm -rf' "$CLEANUP" | grep -v '\.Trash' > "$OUT" 2>&1
[ -s "$OUT" ] && fail "every live 'rm -rf' is scoped to ~/.Trash" \
              || pass "every live 'rm -rf' is scoped to ~/.Trash"
grep -qE '^[^#]*find "\$HOME/\.Trash".*-mtime \+[0-9]+' "$CLEANUP" \
  && pass "the Trash sweep keeps its age filter (-mtime)" \
  || fail "the Trash sweep keeps its age filter (-mtime)"

# The log must live under $HOME, not somewhere a stray relative path lands.
grep -qE '^LOG_FILE="\$HOME/' "$CLEANUP" \
  && pass "LOG_FILE is under \$HOME" \
  || fail "LOG_FILE is under \$HOME"

# ── 6. Nothing here leaks personal data into a public repo ───────────────────
# bin/ is published. These are the two findings that motivated the move; assert
# they cannot silently return.
header "publishability"

for f in "$LLM" "$CLEANUP" "$BIN_DIR/README.md"; do
  : > "$OUT"
  grep -nE '/Users/[a-z]' "$f" > "$OUT" 2>&1
  [ -s "$OUT" ] && fail "$(basename "$f") contains no absolute /Users/<name>/ path" \
                || pass "$(basename "$f") contains no absolute /Users/<name>/ path"
done

# The public doc must be self-contained: no links into repos that are private.
: > "$OUT"
grep -rn 'local-llm' "$BIN_DIR" "$(dirname "$BIN_DIR")/docs/llm.md" > "$OUT" 2>&1
[ -s "$OUT" ] && fail "no references to the private local-llm repo in published files" \
              || pass "no references to the private local-llm repo in published files"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}bin: ${GREEN}$PASS_COUNT passed${NC}${BOLD}, $( [ "$FAIL_COUNT" -gt 0 ] && echo -e "${RED}")$FAIL_COUNT failed${NC}${BOLD}, $SKIP_COUNT skipped${NC}"
[ "$FAIL_COUNT" -eq 0 ]
