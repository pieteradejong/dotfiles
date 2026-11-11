#!/usr/bin/env bash
#
# test-entrypoints.sh — init.sh and run.sh (D63): help, usage errors, that --check never
# installs, that a missing tool goes to `brew install` (a stub here, never the real one),
# and that run.sh test delegates to test.sh instead of keeping a second list.
#
# Usage: bash scripts/test-entrypoints.sh [--verbose]
# Hermetic: a temp dir, a stub brew, a PATH without gitleaks. Reads the real gate status
# (read-only). Never installs anything.

set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
VERBOSE=0; [ "${1:-}" = "--verbose" ] && VERBOSE=1

PASS=0; FAIL=0
pass() { printf '  \033[32m✓ PASS\033[0m: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✗ FAIL\033[0m: %s\n' "$1"; FAIL=$((FAIL + 1)); }
header() { printf '\n\033[1m\033[36m── %s ──\033[0m\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
OUT="$T/out"

# A PATH with every required tool except gitleaks: symlinks to the real ones, then the
# system dirs (which hold no gitleaks).
mkdir -p "$T/bin"
for t in git shellcheck jq ruff python3 zsh; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$T/bin/$t"
done
printf '#!/bin/sh\necho "$@" >> "%s/brew.calls"\nexit 0\n' "$T" > "$T/brew"; chmod +x "$T/brew"
NOLEAK_PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$NOLEAK_PATH" command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks is in a system dir; the missing-tool cases cannot run" >&2; exit 1
fi

header "init.sh"
./init.sh --help > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^init.sh — ' "$OUT" && grep -q -- '--check' "$OUT" \
  && pass "--help prints the header and exits 0" || fail "--help (rc=$rc): $(head -3 "$OUT")"
./init.sh --bogus > "$OUT" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'unknown option' "$OUT" && pass "an unknown option exits 2" || fail "unknown option rc=$rc"

PATH="$NOLEAK_PATH" BREW="$T/brew" ./init.sh --check > "$OUT" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'MISSING *gitleaks' "$OUT" && [ ! -f "$T/brew.calls" ] \
  && pass "--check reports a missing tool, exits 1, and never calls brew" || fail "--check (rc=$rc): $(cat "$OUT")"

PATH="$NOLEAK_PATH" BREW="$T/brew" ./init.sh > "$OUT" 2>&1; rc=$?
grep -qx 'install gitleaks' "$T/brew.calls" 2>/dev/null && [ "$(wc -l < "$T/brew.calls" | tr -d ' ')" = 1 ] \
  && pass "without --check, only the missing tool goes to brew install" || fail "brew calls: $(cat "$T/brew.calls" 2>/dev/null)"
[ "$rc" = 1 ] && pass "a tool the stub 'installed' but that is still missing keeps the exit at 1" || fail "post-install rc=$rc"

PATH="$NOLEAK_PATH" BREW="$T/nobrew" ./init.sh > "$OUT" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'no Homebrew' "$OUT" && pass "no Homebrew: says so, exits 1" || fail "no brew (rc=$rc): $(cat "$OUT")"

if command -v gitleaks >/dev/null 2>&1 && security/gate.sh status >/dev/null 2>&1; then
  rm -f "$T/brew.calls"
  BREW="$T/brew" ./init.sh > "$OUT" 2>&1; rc=$?
  [ "$rc" = 0 ] && [ ! -f "$T/brew.calls" ] && grep -q '^ready' "$OUT" \
    && pass "idempotent: with everything present it installs nothing and exits 0" || fail "ready run (rc=$rc): $(tail -5 "$OUT")"
else
  printf '  skip: ready run (gitleaks or the gate is not installed on this Mac)\n'
fi
! grep -nE 'hooksPath|git config.*hook\.' init.sh > "$OUT" \
  && pass "init.sh never touches git hook config" || fail "init.sh touches hook config: $(cat "$OUT")"
! grep -nE 'sync-dotfiles\.sh +restore' init.sh | grep -v '^[0-9]*:#' > "$OUT" \
  && pass "init.sh never restores dotfiles into \$HOME" || fail "init.sh runs restore: $(cat "$OUT")"

header "run.sh"
./run.sh --help > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^run.sh — ' "$OUT" && pass "--help prints the header and exits 0" || fail "run --help rc=$rc"
./run.sh bogus > "$OUT" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'unknown command' "$OUT" && pass "an unknown command exits 2" || fail "unknown command rc=$rc"
./run.sh test --help > "$OUT" 2>&1
./test.sh --help > "$T/test-help" 2>&1
cmp -s "$OUT" "$T/test-help" && pass "run.sh test passes its arguments to test.sh" || fail "run.sh test --help differs from test.sh --help"
grep -q 'test) *exec ./test.sh "\$@"' run.sh && pass "run.sh test is exec ./test.sh, not a second list" || fail "run.sh test does not exec test.sh"
./run.sh warnings --bogus > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && pass "run.sh warnings is maintenance-status (exits 0 even on a bad option)" || fail "warnings rc=$rc"
missing=""
for c in status warnings test lint format audit doctor; do
  grep -q "^#   ./run.sh $c" run.sh || missing="$missing $c(help)"
  grep -qE "^  $c\)" run.sh || missing="$missing $c(case)"
done
[ -z "$missing" ] && pass "every run.sh command is in the help header and has a case" || fail "run.sh commands:$missing"
grep -q 'python_files() { sed -n .*PYTHON_FILES' run.sh && pass "run.sh format takes its files from test.sh's PYTHON_FILES" || fail "format file list"

header "test.sh coverage guard (in a copy of the working tree)"
C="$T/copy"; mkdir -p "$C"
# The working tree, not HEAD: the guard must see uncommitted lists too. private/ stays out.
git ls-files -z --cached --others --exclude-standard | grep -zv '^private/' \
  | (cd "$REPO" && xargs -0 tar cf - 2>/dev/null) | (cd "$C" && tar xf -)
( cd "$C" && git init -q && git add -A ) >/dev/null 2>&1
( cd "$C" && bash test.sh coverage ) > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && pass "the copy is clean before anything is planted" || fail "copy not clean (rc=$rc): $(grep -v '════' "$OUT" | head -5)"
printf '#!/usr/bin/env bash\necho hi\n' > "$C/bin/newtool"; printf 'echo t\n' > "$C/scripts/test-newthing.sh"
( cd "$C" && git add -A && bash test.sh coverage ) > "$OUT" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'not linted (sh): bin/newtool' "$OUT" && grep -q 'test never run: scripts/test-newthing.sh' "$OUT" \
  && pass "an unlisted script and an unrun test both fail coverage, by name" || fail "planted (rc=$rc): $(grep -v '════' "$OUT" | head -5)"
rm -f "$C/bin/newtool" "$C/scripts/test-newthing.sh"
sed -i '' 's#^bin/rc-projects$#bin/rc-projects-renamed#' "$C/test.sh"
( cd "$C" && git add -A && bash test.sh coverage ) > "$OUT" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'listed but missing: bin/rc-projects-renamed' "$OUT" \
  && pass "a list entry whose file is gone fails coverage" || fail "dead entry (rc=$rc): $(grep -v '════' "$OUT" | head -5)"

[ "$VERBOSE" = 1 ] && echo "repo: $REPO"
printf '\n\033[1mentry: \033[32m%d passed\033[0m\033[1m, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
