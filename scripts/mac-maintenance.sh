#!/usr/bin/env bash
#
# mac-maintenance.sh — a system report plus a cache quarantine, run by hand.
#
# Usage: mac-maintenance.sh [--dry-run] [--no-mail]
#
#   (no args)   report uptime, memory and disk, then move every entry of
#               ~/Library/Caches into one dated folder in ~/.Trash. Prints,
#               logs to ~/maintenance-YYYYMMDD.log and mails the run
#               (bin/mail-report).
#   --dry-run   print the report and what would be moved; change nothing,
#               write no log, send no mail.
#   --no-mail   report, move and log, but send no mail.
#
# Moving instead of deleting gives a restore window: weekly-disk-cleanup.sh
# purges Trash items older than 7 days, so a cache an app still wanted can be
# put back for a week. Caches the weekly cleanup already empties in place (pip,
# pip-tools, Homebrew) are left to it. Entries an app holds open fail to move
# and are listed, not forced. Not scheduled: run it when the Mac feels slow or
# the disk is full (docs/maintenance.md).
#
# Env:  MAIL_REPORT_BIN  the sender (default: ../bin/mail-report)
#
# Exit: 0 done, 2 bad usage. A mail that cannot be sent is a WARN line, not a failure.

set -u

DRY_RUN=false
MAIL=true
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=true ;;
    --no-mail) MAIL=false ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "usage: mac-maintenance.sh [--dry-run] [--no-mail]" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHES="$HOME/Library/Caches"
TRASH="$HOME/.Trash"
LOG_FILE="$HOME/maintenance-$(date +%Y%m%d).log"
MAIL_REPORT_BIN="${MAIL_REPORT_BIN:-$SCRIPT_DIR/../bin/mail-report}"
# Owned by weekly-disk-cleanup.sh, which empties them without a move.
SKIP_NAMES=" pip pip-tools Homebrew "

# act <cmd...> — every step that changes something goes through here, so
# --dry-run is one switch rather than one per section.
act() {
  if $DRY_RUN; then echo "  would run: $*"; else "$@"; fi
}

size() { du -sh "$1" 2>/dev/null | cut -f1; }

# run_report — the whole run. Called once below: printed as is for --dry-run,
# otherwise captured so the same text goes to the log and into the mail.
run_report() {

echo "=== macOS Maintenance Report - $(date)$($DRY_RUN && echo '  [DRY RUN]') ==="
echo ""

echo "--- UPTIME ---"
uptime
echo ""

echo "--- MEMORY ---"
if command -v vm_stat >/dev/null 2>&1 && command -v pagesize >/dev/null 2>&1; then
  vm_stat | awk -v ps="$(pagesize)" '
    /Pages free/     { f = $3 }
    /Pages inactive/ { i = $3 }
    END { gsub(/\./, "", f); gsub(/\./, "", i)
          printf "Approximate available memory: %.2f GB (free + inactive)\n", (f + i) * ps / 1073741824 }'
else
  echo "vm_stat not available, skipped"
fi
echo ""

echo "--- DISK ---"
df -h "$HOME" | awk 'NR==1 || NR==2'
echo ""

# --- Library caches → Trash ------------------------------------------------
# One dated folder per run, so a run is easy to find and to put back.
echo "--- LIBRARY CACHES → TRASH ---"
if [ ! -d "$CACHES" ]; then
  echo "no $CACHES, skipped"
elif ! ls "$TRASH" >/dev/null 2>&1 || [ ! -w "$TRASH" ]; then
  echo "no access to ~/.Trash (Full Disk Access?) — skipped"
else
  echo "Before: $(size "$CACHES")"
  dest="$TRASH/mac-maintenance-caches-$(date +%Y%m%d-%H%M%S)"
  moved=0; kept=0; busy=0
  for entry in "$CACHES"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    case "$SKIP_NAMES" in
      *" $name "*) kept=$((kept + 1)); continue ;;
    esac
    [ "$moved" = 0 ] && [ "$busy" = 0 ] && act mkdir -p "$dest"
    if act mv "$entry" "$dest/" 2>/dev/null; then
      moved=$((moved + 1))
    else
      busy=$((busy + 1)); echo "  in use, left in place: $name"
    fi
  done
  echo "Moved: $moved item(s) to $dest"
  echo "Left:  $kept for weekly-disk-cleanup.sh ($(echo "$SKIP_NAMES" | tr -s ' ' | sed 's/^ //; s/ $//')), $busy in use"
  $DRY_RUN || echo "After:  $(size "$CACHES")"
  echo "Purged by weekly-disk-cleanup.sh once the folder is 7 days old."
fi

echo ""
echo "Done: $(date)"

}  # end run_report

# --- Output --------------------------------------------------------------------
# --dry-run prints only. A real run is captured into one per-run file first (a
# tee into the log is asynchronous, so the run could not be read back for the
# mail reliably), printed as it goes, then appended to the log and mailed.
if $DRY_RUN; then
  run_report
  exit 0
fi

RUN_OUT="$(mktemp "${TMPDIR:-/tmp}/mac-maintenance.XXXXXX")"
trap 'rm -f "$RUN_OUT"' EXIT
run_report 2>&1 | tee "$RUN_OUT"
cat "$RUN_OUT" >> "$LOG_FILE"

if $MAIL; then
  subject="mac-maintenance on $(hostname -s): $(grep -m1 '^Moved: ' "$RUN_OUT" || echo 'report only')"
  "$MAIL_REPORT_BIN" --subject "$subject" < "$RUN_OUT"; rc=$?
  if [ "$rc" != 0 ]; then
    echo "WARN: report not mailed (mail-report exit $rc) — see mail-report --help" | tee -a "$LOG_FILE"
  fi
fi
exit 0
