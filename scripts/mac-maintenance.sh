#!/usr/bin/env bash
#
# mac-maintenance.sh — a system report plus a cache quarantine, run by hand.
#
# Usage: mac-maintenance.sh [--dry-run] [--no-notify]
#
#   (no args)   report uptime, memory, disk and the last weekly cleanup, then
#               move every entry of ~/Library/Caches no app holds open into one
#               dated folder in ~/.Trash. Prints, logs to
#               ~/maintenance-YYYYMMDD.log and shows a macOS notification with
#               the verdict (bin/notify-local). Nothing leaves the Mac.
#   --dry-run   print the report and what would be moved; change nothing,
#               write no log, no notification.
#   --no-notify report, move and log, but show no notification.
#
# Moving instead of deleting gives a restore window: weekly-disk-cleanup.sh
# purges Trash items older than 7 days, so a cache an app still wanted can be
# put back for a week. Caches the weekly cleanup already empties in place (pip,
# pip-tools, Homebrew) are left to it. An entry in which a process holds a file
# open (lsof) is listed and left in place, as is one that fails to move; quit
# an app first to have its cache cleared. Not scheduled: run it when the Mac feels slow or
# the disk is full (docs/maintenance.md).
#
# Env:  NOTIFY_BIN       the notifier (default: ../bin/notify-local)
#       WEEKLY_CHECK_BIN the weekly-cleanup check (default: ../bin/weekly-cleanup-check)
#
# Exit: 0 done, 2 bad usage. A notification that cannot be shown never fails the run.

set -u

DRY_RUN=false
NOTIFY=true
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=true ;;
    --no-notify) NOTIFY=false ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "usage: mac-maintenance.sh [--dry-run] [--no-notify]" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHES="$HOME/Library/Caches"
TRASH="$HOME/.Trash"
LOG_FILE="$HOME/maintenance-$(date +%Y%m%d).log"
NOTIFY_BIN="${NOTIFY_BIN:-$SCRIPT_DIR/../bin/notify-local}"
# Owned by weekly-disk-cleanup.sh, which empties them without a move.
SKIP_NAMES=" pip pip-tools Homebrew "

# act <cmd...> — every step that changes something goes through here, so
# --dry-run is one switch rather than one per section.
act() {
  if $DRY_RUN; then echo "  would run: $*"; else "$@"; fi
}

size() { du -sh "$1" 2>/dev/null | cut -f1; }

# caches_in_use — one name per line: the ~/Library/Caches entries in which a
# process of this user holds a file open. On APFS `mv` renames a folder an app
# holds open without error, so a failed move is no in-use signal; this is.
# lsof reports resolved paths (/private/var/…), hence `cd -P`. LSOF overrides
# the binary; when it is missing the list is empty and the mv fallback remains.
LSOF="${LSOF:-/usr/sbin/lsof}"
caches_in_use() {
  local real
  real="$(cd -P "$CACHES" 2>/dev/null && pwd)" || return 0
  [ -x "$LSOF" ] || return 0
  "$LSOF" -w -u "$(id -u)" -Fn 2>/dev/null | sed -n "s#^n$real/\([^/]*\).*#\1#p" | sort -u
}

# run_report — the whole run. Called once below: printed as is for --dry-run,
# otherwise captured so the same text goes to the log and into the notification.
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

# --- Last weekly cleanup ----------------------------------------------------
# bin/weekly-cleanup-check on ~/.weekly-disk-cleanup.log: did the launchd job
# run in the last 8 days, and did every step of that run work. Read-only.
echo "--- LAST WEEKLY CLEANUP ---"
check_bin="${WEEKLY_CHECK_BIN:-$SCRIPT_DIR/../bin/weekly-cleanup-check}"
if [ -x "$check_bin" ]; then
  "$check_bin" 2>&1 | sed '1d'
else
  echo "$check_bin not found, skipped"
fi
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
  busy_names="$(caches_in_use)"
  for entry in "$CACHES"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    case "$SKIP_NAMES" in
      *" $name "*) kept=$((kept + 1)); continue ;;
    esac
    if printf '%s\n' "$busy_names" | grep -qxF -- "$name"; then
      busy=$((busy + 1)); echo "  in use, left in place: $name"; continue
    fi
    [ "$moved" = 0 ] && act mkdir -p "$dest"
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
# notification reliably), printed as it goes, then appended to the log and
# summed up in a macOS notification (bin/notify-local; nothing leaves the Mac).
if $DRY_RUN; then
  run_report
  exit 0
fi

RUN_OUT="$(mktemp "${TMPDIR:-/tmp}/mac-maintenance.XXXXXX")"
trap 'rm -f "$RUN_OUT"' EXIT
run_report 2>&1 | tee "$RUN_OUT"
cat "$RUN_OUT" >> "$LOG_FILE"

if $NOTIFY; then
  "$NOTIFY_BIN" "Mac maintenance" \
    "$(grep -m1 '^Moved: [0-9]* item' "$RUN_OUT" | sed 's/ to .*//' || true) · weekly cleanup $(grep -m1 '^Self-check: ' "$RUN_OUT" | sed 's/^Self-check: //' || echo 'not checked') — $LOG_FILE" || true
fi
exit 0
