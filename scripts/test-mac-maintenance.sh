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

# Every real run shows a notification, so the suite always points NOTIFY_BIN at
# this stub: it records each call's arguments (one line per call, title and
# message tab-separated) and exits with the code in $T/notify.rc (default 0).
# Without it, the suite would pop real notifications.
NOTIFY_STUB="$T/notify-stub"
cat > "$NOTIFY_STUB" <<'EOF'
#!/bin/sh
d="$(dirname "$0")"
printf '%s\t%s\n' "$1" "$2" >> "$d/notify.args"
[ -f "$d/notify.rc" ] && exit "$(cat "$d/notify.rc")"
exit 0
EOF
chmod +x "$NOTIFY_STUB"
export NOTIFY_BIN="$NOTIFY_STUB"
notify_calls() { [ -f "$T/notify.args" ] && wc -l < "$T/notify.args" | tr -d ' ' || echo 0; }
reset_notify() { rm -f "$T/notify.args" "$T/notify.rc"; }

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
grep -q 'PROBLEM: no log at .*the weekly cleanup has never run' "$OUT" \
  && pass "the report says when the weekly cleanup has never run (no log in this HOME)" \
  || fail "the report says when the weekly cleanup has never run"
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
[ "$(notify_calls)" = 0 ] && pass "--dry-run shows no notification" || fail "--dry-run notified ($(notify_calls) call(s))"
for h in UPTIME MEMORY DISK 'LAST WEEKLY CLEANUP' 'LIBRARY CACHES'; do
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
# One notification per real run: the Moved count, the weekly-cleanup verdict
# (this fake HOME has no weekly log, so the check reports problems), the log path.
[ "$(notify_calls)" = 1 ] && pass "real run shows one notification" || fail "real run notified $(notify_calls) time(s)"
grep -qE "^Mac maintenance	Moved: 2 item\(s\) · weekly cleanup [0-9]+ problem\(s\) — .*/maintenance-[0-9]{8}\.log$" "$T/notify.args" 2>/dev/null \
  && pass "notification: title, Moved count, weekly-cleanup verdict, log path" || fail "notification text: $(cat "$T/notify.args" 2>/dev/null)"
grep -qi 'mail' "$log" && fail "the log mentions no mail" || pass "the log mentions no mail"

# A second run on the now-empty tree is a no-op that still reports.
reset_notify
: > "$OUT"
HOME="$H" "$MAINT" > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Moved: 0 item(s)' "$OUT" && pass "second run moves nothing and exits 0 (idempotent)" || fail "second run rc=$rc"
n_dirs="$(find "$H/.Trash" -mindepth 1 -maxdepth 1 -name 'mac-maintenance-caches-*' | wc -l | tr -d ' ')"
[ "$n_dirs" = 1 ] && pass "second run creates no empty quarantine folder" || fail "$n_dirs quarantine folders after two runs"
[ "$(notify_calls)" = 1 ] && grep -q '	Moved: 0 item(s) · ' "$T/notify.args" \
  && pass "second run notifies its own result (Moved: 0)" || fail "second run notification: $(cat "$T/notify.args" 2>/dev/null)"

# ── 4b. notification switches ──────────────────────────────────────────────
header "notification: --no-notify, and a notifier that fails"
H="$T/nonotify"; fresh_home "$H"; reset_notify
: > "$OUT"
HOME="$H" "$MAINT" --no-notify > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Moved: 2 item(s)' "$OUT" && pass "--no-notify still moves and exits 0" || fail "--no-notify rc=$rc"
[ "$(notify_calls)" = 0 ] && pass "--no-notify shows no notification" || fail "--no-notify notified"
[ -n "$(find "$H" -maxdepth 1 -name 'maintenance-*.log')" ] && pass "--no-notify still writes the log" || fail "--no-notify wrote no log"
HOME="$H" "$MAINT" --no-mail > "$OUT" 2>&1; rc=$?
[ "$rc" = 2 ] && pass "--no-mail is gone: usage, exit 2" || fail "--no-mail rc=$rc"

H="$T/notifyfail"; fresh_home "$H"; reset_notify; echo 1 > "$T/notify.rc"
: > "$OUT"
HOME="$H" "$MAINT" > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Moved: 2 item(s)' "$OUT" && pass "a failing notifier does not fail the run" || fail "failing notifier rc=$rc"
reset_notify

# Wired the way the plan says: through NOTIFY_BIN, after the log append, and no
# mail sender is called anywhere.
grep -qE '^[^#]*"\$NOTIFY_BIN" "Mac maintenance"' "$MAINT" && pass "the notification goes through \$NOTIFY_BIN (overridable)" || fail "notify call not via NOTIFY_BIN"
append_ln="$(grep -nE '^[^#]*cat "\$RUN_OUT" >> "\$LOG_FILE"' "$MAINT" | head -1 | cut -d: -f1)"
notify_ln="$(grep -nE '^[^#]*"\$NOTIFY_BIN" "Mac maintenance"' "$MAINT" | head -1 | cut -d: -f1)"
[ -n "$append_ln" ] && [ -n "$notify_ln" ] && [ "$append_ln" -lt "$notify_ln" ] \
  && pass "the log is appended before the notification" || fail "log append / notify order (lines $append_ln / $notify_ln)"
grep -nE '^[^#]*mail-report|MAIL_REPORT' "$MAINT" > "$OUT"
[ -s "$OUT" ] && fail "no mail sender is called" || pass "no mail sender is called"

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

# ── 6. caches an app holds open (lsof) ──────────────────────────────────────
header "in-use caches (lsof)"
# An app cache that a running process holds a file open in stays put, even
# though `mv` would succeed on APFS. Sorted first ("aaa…"), so the folder in
# Trash must still be created for the entries after it.
H="$T/busy"; fresh_home "$H"
mkdir -p "$H/Library/Caches/aaa.busy.app"; printf 'z\n' > "$H/Library/Caches/aaa.busy.app/open"
bash -c 'exec 3<"$1"; sleep 30; :' _ "$H/Library/Caches/aaa.busy.app/open" & busy_pid=$!
sleep 0.3
: > "$OUT"; reset_notify
HOME="$H" "$MAINT" --no-notify > "$OUT" 2>&1; rc=$?
kill "$busy_pid" 2>/dev/null; wait "$busy_pid" 2>/dev/null
[ "$rc" = 0 ] && [ -e "$H/Library/Caches/aaa.busy.app/open" ] && grep -q 'in use, left in place: aaa.busy.app' "$OUT" \
  && pass "a cache an app holds open is left in place and listed" || fail "busy cache handling (rc=$rc)"
grep -q '^Moved: 2 item(s) to ' "$OUT" && grep -q ', 1 in use$' "$OUT" \
  && [ -e "$(find "$H/.Trash" -mindepth 1 -maxdepth 1 -name 'mac-maintenance-caches-*' | head -1)/com.example.app/data" ] \
  && pass "the caches after a busy one are still moved (2 moved, 1 in use)" || fail "moves after a busy cache: $(grep -E '^(Moved|Left)' "$OUT")"
H="$T/nolsof"; fresh_home "$H"
: > "$OUT"
LSOF=/nonexistent HOME="$H" "$MAINT" --dry-run > "$OUT" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'would run: mv .*com.example.app' "$OUT" \
  && pass "with no lsof the run still works (mv fallback only)" || fail "no-lsof run (rc=$rc)"

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}mac-maintenance: all $PASS_COUNT tests passed${NC}"
else
  echo -e "${BOLD}${RED}mac-maintenance: $FAIL_COUNT of $((PASS_COUNT + FAIL_COUNT)) tests failed${NC}"
fi
[ "$FAIL_COUNT" -eq 0 ]
