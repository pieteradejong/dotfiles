#!/usr/bin/env bash
#
# test-mac-maintenance.sh — tests for scripts/mac-maintenance.sh.
#
# Hermetic: every run gets a fake HOME with a fixture ~/Library/Caches and
# ~/.Trash, so the real run is safe to execute here (it only ever touches paths
# under $HOME). The report half (uptime, vm_stat, df) runs for real and is only
# checked for its headings, so the suite passes on Linux CI too.
#
# Run: ./scripts/test-mac-maintenance.sh [--verbose]   Exit: 0 all passed, 1 otherwise.
#
# shellcheck disable=SC2015 # `cond && pass || fail` is safe here: pass/fail always return 0
# shellcheck disable=SC2016 # the patterns grep for a literal $HOME, $entry and $dest in the script

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT="$SCRIPT_DIR/mac-maintenance.sh"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

RED="\033[31m"; GREEN="\033[32m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"
  if [ -s "$OUT" ]; then if $VERBOSE; then sed 's/^/      | /' "$OUT"; else sed 's/^/      | /' "$OUT" | head -20; fi; fi
}
header() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──${NC}"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mac-maintenance-test.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
OUT="$T/out"; : > "$OUT"

# Every real run mails its report, so the suite always points MAIL_REPORT_BIN
# at this stub: it records each call's arguments and body, and exits with the
# code in $T/mail.rc (default 0). Without it, the suite would email Pieter.
MAIL_STUB="$T/mail-stub"
cat > "$MAIL_STUB" <<'EOF'
#!/bin/sh
d="$(dirname "$0")"
echo "$*" >> "$d/mail.args"
cat > "$d/mail.body"
[ -f "$d/mail.rc" ] && exit "$(cat "$d/mail.rc")"
exit 0
EOF
chmod +x "$MAIL_STUB"
export MAIL_REPORT_BIN="$MAIL_STUB"
mail_calls() { [ -f "$T/mail.args" ] && wc -l < "$T/mail.args" | tr -d ' ' || echo 0; }
reset_mail() { rm -f "$T/mail.args" "$T/mail.body" "$T/mail.rc"; }

# fresh_home <dir> — a fake HOME with three app caches, the three caches the
# weekly cleanup owns, and an empty Trash.
fresh_home() {
  rm -rf "$1"
  mkdir -p "$1/Library/Caches/com.example.app" "$1/Library/Caches/com.example.other/sub" \
           "$1/Library/Caches/pip" "$1/Library/Caches/pip-tools" "$1/Library/Caches/Homebrew" \
           "$1/.Trash"
  printf 'x\n' > "$1/Library/Caches/com.example.app/data"
  printf 'y\n' > "$1/Library/Caches/com.example.other/sub/data"
  printf 'wheel\n' > "$1/Library/Caches/pip/wheel"
}

# ── 1. static ────────────────────────────────────────────────────────────────
header "mac-maintenance.sh (static)"
[ -x "$MAINT" ] && pass "scripts/mac-maintenance.sh is executable" || fail "scripts/mac-maintenance.sh is executable"
bash -n "$MAINT" > "$OUT" 2>&1 && pass "parses (bash -n)" || fail "parses (bash -n)"
head -1 "$MAINT" | grep -q '^#!/usr/bin/env bash$' && pass "shebang is #!/usr/bin/env bash" || fail "shebang is #!/usr/bin/env bash"
# The quarantine moves; nothing in this script may delete. A live `rm -rf` or
# `find -delete` is a design change that needs a decision entry first.
: > "$OUT"
grep -nE '^[^#]*(rm -rf|rm -r |-delete)' "$MAINT" > "$OUT" 2>&1
[ -s "$OUT" ] && fail "no live rm -rf / find -delete (the script moves, never deletes)" \
              || pass "no live rm -rf / find -delete (the script moves, never deletes)"
grep -qE '^[^#]*act mv "\$entry" "\$dest/"' "$MAINT" \
  && pass "the move goes through act, so --dry-run covers it" \
  || fail "the move goes through act, so --dry-run covers it"
grep -qE '^LOG_FILE="\$HOME/' "$MAINT" && pass "LOG_FILE is under \$HOME" || fail "LOG_FILE is under \$HOME"
grep -qE '^set -e' "$MAINT" && fail "no set -e (one failing section must not stop the report)" \
                             || pass "no set -e (one failing section must not stop the report)"

# ── 2. usage ────────────────────────────────────────────────────────────────
header "usage and exit codes"
: > "$OUT"
HOME="$T/h0" "$MAINT" --bogus > "$OUT" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q '^usage:' "$OUT" && pass "unknown option: usage on stderr, exit 2" || fail "unknown option exit $rc"
: > "$OUT"
HOME="$T/h0" "$MAINT" --help > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q -- '--dry-run' "$OUT" && pass "--help prints the usage header, exit 0" || fail "--help exit $rc"
[ ! -e "$T/h0" ] && pass "usage and help touch nothing" || fail "usage and help touch nothing"

# ── 3. --dry-run ────────────────────────────────────────────────────────────
header "--dry-run on a fake HOME"
H="$T/dry"; fresh_home "$H"
: > "$OUT"
HOME="$H" "$MAINT" --dry-run > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && pass "--dry-run exits 0" || fail "--dry-run exits 0 (rc=$rc)"
grep -q '\[DRY RUN\]' "$OUT" && pass "--dry-run says so in the report header" || fail "--dry-run header"
grep -q 'would run: mv .*com.example.app' "$OUT" && grep -q 'would run: mv .*com.example.other' "$OUT" \
  && pass "--dry-run lists each app cache it would move" || fail "--dry-run lists each app cache it would move"
grep -q 'would run: mv .*/Caches/pip ' "$OUT" || grep -q 'would run: mv .*/Caches/pip$' "$OUT" \
  && fail "--dry-run leaves pip to the weekly cleanup" || pass "--dry-run leaves pip to the weekly cleanup"
grep -q 'Left:  3 for weekly-disk-cleanup.sh' "$OUT" && pass "the three cleanup-owned caches are counted as left" || fail "left count"
n_before=5
n_now="$(find "$H/Library/Caches" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
[ "$n_now" = "$n_before" ] && [ -e "$H/Library/Caches/com.example.app/data" ] \
  && pass "--dry-run moved nothing ($n_now cache entries intact)" || fail "--dry-run moved nothing ($n_now of $n_before left)"
[ -z "$(find "$H/.Trash" -mindepth 1)" ] && pass "--dry-run put nothing in Trash" || fail "--dry-run put nothing in Trash"
[ -z "$(find "$H" -maxdepth 1 -name 'maintenance-*.log')" ] && pass "--dry-run writes no log" || fail "--dry-run writes no log"
[ "$(mail_calls)" = 0 ] && pass "--dry-run sends no mail" || fail "--dry-run sends no mail ($(mail_calls) call(s))"
for h in UPTIME MEMORY DISK 'LIBRARY CACHES'; do
  grep -q -- "--- $h" "$OUT" && pass "report has the $h section" || fail "report has the $h section"
done

# ── 4. real run ─────────────────────────────────────────────────────────────
header "real run on a fake HOME"
H="$T/real"; fresh_home "$H"
: > "$OUT"
HOME="$H" "$MAINT" > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && pass "real run exits 0" || fail "real run exits 0 (rc=$rc)"
dest="$(find "$H/.Trash" -mindepth 1 -maxdepth 1 -name 'mac-maintenance-caches-*' | head -1)"
[ -n "$dest" ] && pass "one dated quarantine folder in ~/.Trash" || fail "no quarantine folder in ~/.Trash"
[ -e "$dest/com.example.app/data" ] && [ -e "$dest/com.example.other/sub/data" ] \
  && pass "app caches were moved into it, contents intact" || fail "app caches not moved intact"
[ ! -e "$H/Library/Caches/com.example.app" ] && [ ! -e "$H/Library/Caches/com.example.other" ] \
  && pass "app caches are gone from ~/Library/Caches" || fail "app caches still in ~/Library/Caches"
[ -e "$H/Library/Caches/pip/wheel" ] && [ -d "$H/Library/Caches/pip-tools" ] && [ -d "$H/Library/Caches/Homebrew" ] \
  && pass "pip, pip-tools and Homebrew caches are left in place" || fail "a cleanup-owned cache was moved"
[ ! -e "$dest/pip" ] && pass "pip was not quarantined" || fail "pip was quarantined"
grep -q '^Moved: 2 item(s) to ' "$OUT" && pass "report counts 2 moved" || fail "moved count"
log="$(find "$H" -maxdepth 1 -name 'maintenance-*.log' | head -1)"
[ -n "$log" ] && grep -q 'macOS Maintenance Report' "$log" && grep -q '^Moved: 2' "$log" \
  && pass "log written to ~/maintenance-YYYYMMDD.log with the same report" || fail "log missing or incomplete"
grep -q 'Done: ' "$OUT" && pass "report ends with Done" || fail "report ends with Done"
# The run is mailed once, subject from the Moved line, body = the log of this run.
[ "$(mail_calls)" = 1 ] && pass "real run mails the report once" || fail "real run mailed $(mail_calls) time(s)"
grep -q -- '--subject mac-maintenance on .*: Moved: 2 item(s)' "$T/mail.args" 2>/dev/null \
  && pass "mail subject carries the host and the Moved line" || fail "mail subject: $(cat "$T/mail.args" 2>/dev/null)"
cmp -s "$T/mail.body" "$log" && pass "mail body is exactly what was logged" || fail "mail body differs from the log"
grep -q 'WARN: report not mailed' "$OUT" && fail "no WARN when the mail was sent" || pass "no WARN when the mail was sent"

# A second run on the now-empty tree is a no-op that still reports.
reset_mail
: > "$OUT"
HOME="$H" "$MAINT" > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Moved: 0 item(s)' "$OUT" && pass "second run moves nothing and exits 0 (idempotent)" || fail "second run rc=$rc"
n_dirs="$(find "$H/.Trash" -mindepth 1 -maxdepth 1 -name 'mac-maintenance-caches-*' | wc -l | tr -d ' ')"
[ "$n_dirs" = 1 ] && pass "second run creates no empty quarantine folder" || fail "$n_dirs quarantine folders after two runs"
cmp -s "$T/mail.body" <(tail -n "$(wc -l < "$T/mail.body" | tr -d ' ')" "$log") \
  && pass "second run mails only its own run, not the whole log" || fail "second mail body is not the log's tail"

# ── 4b. mail switches ────────────────────────────────────────────────────────
header "mail: --no-mail, and a sender that fails"
H="$T/nomail"; fresh_home "$H"; reset_mail
: > "$OUT"
HOME="$H" "$MAINT" --no-mail > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Moved: 2 item(s)' "$OUT" && pass "--no-mail still moves and exits 0" || fail "--no-mail rc=$rc"
[ "$(mail_calls)" = 0 ] && pass "--no-mail sends no mail" || fail "--no-mail sent mail"
[ -n "$(find "$H" -maxdepth 1 -name 'maintenance-*.log')" ] && pass "--no-mail still writes the log" || fail "--no-mail wrote no log"

# mail-report exits 3 when no Keychain item exists (and 1 when SMTP fails): the
# job must still exit 0, with one WARN line in the output and in the log.
H="$T/mailfail"; fresh_home "$H"; reset_mail; echo 3 > "$T/mail.rc"
: > "$OUT"
HOME="$H" "$MAINT" > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && pass "a failing sender does not fail the run (exit 0)" || fail "failing sender rc=$rc"
grep -q 'WARN: report not mailed (mail-report exit 3)' "$OUT" && pass "failing sender: WARN line names the exit code" || fail "no WARN line"
log="$(find "$H" -maxdepth 1 -name 'maintenance-*.log' | head -1)"
grep -q 'WARN: report not mailed' "$log" && pass "failing sender: WARN line is in the log too" || fail "WARN missing from log"
grep -q '^Moved: 2 item(s)' "$OUT" && pass "failing sender: the quarantine still happened" || fail "quarantine skipped"
reset_mail

# The mail call is wired the way the plan says: through MAIL_REPORT_BIN, after the log append.
grep -qE '^[^#]*"\$MAIL_REPORT_BIN" --subject' "$MAINT" && pass "mail goes through \$MAIL_REPORT_BIN (overridable)" || fail "mail call not via MAIL_REPORT_BIN"
append_ln="$(grep -nE '^[^#]*cat "\$RUN_OUT" >> "\$LOG_FILE"' "$MAINT" | head -1 | cut -d: -f1)"
mail_ln="$(grep -nE '^[^#]*"\$MAIL_REPORT_BIN" --subject' "$MAINT" | head -1 | cut -d: -f1)"
[ -n "$append_ln" ] && [ -n "$mail_ln" ] && [ "$append_ln" -lt "$mail_ln" ] \
  && pass "the log is appended before the mail is sent" || fail "log append / mail order (lines $append_ln / $mail_ln)"

# ── 5. edge cases ────────────────────────────────────────────────────────────
header "edge cases"
H="$T/notrash"; fresh_home "$H"; chmod 000 "$H/.Trash"
: > "$OUT"
HOME="$H" "$MAINT" --dry-run > "$OUT" 2>&1; rc=$?
chmod 755 "$H/.Trash"
[ "$rc" = 0 ] && grep -q 'no access to ~/.Trash' "$OUT" && pass "unreadable ~/.Trash: says so, skips, exit 0" || fail "unreadable Trash rc=$rc"
[ -e "$H/Library/Caches/com.example.app/data" ] && pass "unreadable ~/.Trash: caches untouched" || fail "caches touched"

H="$T/nocaches"; mkdir -p "$H/.Trash"
: > "$OUT"
HOME="$H" "$MAINT" --dry-run > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'skipped' "$OUT" && pass "no ~/Library/Caches: skipped, exit 0" || fail "no caches rc=$rc"

H="$T/empty"; mkdir -p "$H/.Trash" "$H/Library/Caches"
: > "$OUT"
HOME="$H" "$MAINT" > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Moved: 0 item(s)' "$OUT" && [ -z "$(find "$H/.Trash" -mindepth 1)" ] \
  && pass "empty ~/Library/Caches: nothing moved, no folder created" || fail "empty caches rc=$rc"

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}mac-maintenance: all $PASS_COUNT tests passed${NC}"
else
  echo -e "${BOLD}${RED}mac-maintenance: $FAIL_COUNT of $((PASS_COUNT + FAIL_COUNT)) tests failed${NC}"
fi
[ "$FAIL_COUNT" -eq 0 ]
