#!/bin/zsh
#
# weekly-disk-cleanup.sh — reclaim disk from caches that regenerate and Trash
# that was already discarded. Nothing it removes is needed. At worst the next
# install or build downloads it again.
#
# Usage: weekly-disk-cleanup.sh [--dry-run]
#
#   (no args)   clean. Runs weekly via launchd
#               (~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist);
#               from a terminal it also prints as it goes.
#   --dry-run   show sizes and what each step would run; change nothing and
#               leave the log untouched.
#
# Sections, each independent — one failing (e.g. Docker not running)
# does not stop the others. See docs/maintenance.md for what each step does
# and how to adjust or remove it.
#
# Repo-only, like mac-maintenance.sh: launchd runs this file in place. There is
# no second copy to keep in sync.
#
# Exit: 0 done, 2 bad usage.

DRY_RUN=false
case "${1:-}" in
  "") ;;
  -n|--dry-run) DRY_RUN=true ;;
  -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  *) echo "usage: weekly-disk-cleanup.sh [--dry-run]" >&2; exit 2 ;;
esac

# launchd starts with a bare PATH, which finds Xcode's old /usr/bin/pip3 (it
# misses pip's current cache layout) and no brew or uv at all. Homebrew first.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$PATH"

# nvm-managed npm isn't on launchd's minimal PATH, so load it explicitly
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

LOG_FILE="$HOME/.weekly-disk-cleanup.log"

# Output: --dry-run prints only; a terminal run prints and logs; launchd logs.
# The log is trimmed before this run starts, not after, so the trim never
# races the tee still flushing this run's last lines.
if ! $DRY_RUN; then
  [ -f "$LOG_FILE" ] && tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  if [ -t 1 ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  else
    exec >> "$LOG_FILE" 2>&1
  fi
fi

# act <cmd...> — every step that changes something goes through here, so
# --dry-run is one switch rather than one per section.
act() {
  if $DRY_RUN; then echo "  would run: $*"; else "$@"; fi
}

# size <path...> — total size of the given paths, "0B" when there are none.
size() {
  [ $# -eq 0 ] && { echo "0B"; return; }
  du -shc "$@" 2>/dev/null | tail -1 | cut -f1
}

has() { command -v "$1" >/dev/null 2>&1; }

echo ""
echo "======================================================"
echo "  Weekly disk cleanup - $(date)$($DRY_RUN && echo '  [DRY RUN]')"
echo "======================================================"
echo "Free before: $(df -h "$HOME" | awk 'NR==2 {print $4}')"

# --- npm cache ------------------------------------------------------------
# Verifies integrity, then wipes ~/.npm/_cacache (every package tarball
# ever downloaded). Fully safe: npm re-downloads on the next install.
echo ""
echo "--- npm cache ---"
echo "Before: $(size "$HOME/.npm")"
if has npm; then
  act npm cache verify
  act npm cache clean --force
  $DRY_RUN || echo "After:  $(size "$HOME/.npm")"
else
  echo "npm not found on PATH, skipped"
fi

# --- pip cache --------------------------------------------------------------
# Wipes pip's downloaded wheel/sdist cache. Fully safe: pip re-downloads
# on the next install.
echo ""
echo "--- pip cache ---"
echo "Before: $(size "$HOME/Library/Caches/pip")"
if has pip3; then
  act pip3 cache purge
  $DRY_RUN || echo "After:  $(size "$HOME/Library/Caches/pip")"
else
  echo "pip3 not found on PATH, skipped"
fi

# --- pip-tools cache --------------------------------------------------------
# pip-compile's own download cache, separate from pip's and never purged by
# `pip3 cache purge`. Refilled on the next compile.
echo ""
echo "--- pip-tools cache ---"
piptools=("$HOME/Library/Caches/pip-tools"/*(N))
echo "Before: $(size $piptools)"
[ -n "$piptools" ] && act rm -rf "$HOME/Library/Caches/pip-tools"/*(N)
$DRY_RUN || echo "After:  $(size "$HOME/Library/Caches/pip-tools"/*(N))"

# --- uv cache ---------------------------------------------------------------
# `prune` (not `clean`) drops only entries no longer referenced, so
# environments uv is managing keep working offline.
echo ""
echo "--- uv cache ---"
if has uv; then
  echo "Before: $(size "$(uv cache dir 2>/dev/null)")"
  act uv cache prune
  $DRY_RUN || echo "After:  $(size "$(uv cache dir 2>/dev/null)")"
else
  echo "uv not found on PATH, skipped"
fi

# --- Homebrew ---------------------------------------------------------------
# Removes old formula versions and the download cache. Safe: brew
# re-downloads on demand. `brew autoremove` is deliberately not here — see IDEAS.
echo ""
echo "--- Homebrew cleanup ---"
if has brew; then
  echo "Before: $(size "$(brew --cache)")"
  act brew cleanup -s --prune=all
  $DRY_RUN || echo "After:  $(size "$(brew --cache)")"
else
  echo "brew not found on PATH, skipped"
fi

# --- pnpm store -------------------------------------------------------------
# Removes package versions no longer referenced by any known project. Its
# reference tracking can go stale if node_modules was ever deleted by hand, in
# which case it reports "0 removable" — expected, not a bug.
echo ""
echo "--- pnpm store prune ---"
if has pnpm; then
  act pnpm store prune
else
  echo "pnpm not found on PATH, skipped"
fi

# --- Xcode DerivedData ------------------------------------------------------
# Xcode's build cache; rebuilt on the next build.
echo ""
echo "--- Xcode DerivedData ---"
derived=("$HOME/Library/Developer/Xcode/DerivedData"/*(N))
echo "Before: $(size $derived)"
[ -n "$derived" ] && act rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/*(N)

# --- App-updater leftovers ---------------------------------------------------
# Electron/Squirrel apps (Slack, Notion, Cursor, Claude, …) download each update
# into ~/Library/Caches/<id>.ShipIt or <name>-updater and leave it there after
# installing. Sparkle apps (Codex/ChatGPT, WhatsApp, iTerm2, …) do the same under
# ~/Library/Caches/<id>/org.sparkle-project.Sparkle/Installation/<random>/.
# Only folders untouched for 3+ days are removed (the m+3 glob qualifier), so an
# update staged for the next relaunch is left alone. Worst case, the app
# downloads the update again.
echo ""
echo "--- App-updater leftovers (untouched 3+ days) ---"
updaters=("$HOME/Library/Caches"/*.ShipIt(N/m+3) "$HOME/Library/Caches"/*-updater(N/m+3) "$HOME/Library/Caches"/*/org.sparkle-project.Sparkle/Installation/*(N/m+3))
echo "Before: $(size $updaters)"
[ -n "$updaters" ] && act rm -rf "$HOME/Library/Caches"/*.ShipIt(N/m+3) "$HOME/Library/Caches"/*-updater(N/m+3) "$HOME/Library/Caches"/*/org.sparkle-project.Sparkle/Installation/*(N/m+3)

# --- Old mac-maintenance.sh logs ---------------------------------------------
# mac-maintenance.sh writes a new ~/maintenance-YYYYMMDD.log every run and
# nothing else prunes them.
echo ""
echo "--- Old maintenance-*.log files (30+ days) ---"
echo "Files:  $(find "$HOME" -maxdepth 1 -name 'maintenance-*.log' -mtime +30 2>/dev/null | wc -l | tr -d ' ')"
act find "$HOME" -maxdepth 1 -name 'maintenance-*.log' -mtime +30 -delete

# --- Docker ------------------------------------------------------------------
# Removes stopped containers, unused networks, dangling images, and build
# cache. Deliberately NOT `-a` (which would also remove any image not
# currently backing a container) — that's left as a manual, deliberate step
# so a locally-built image you plan to reuse isn't silently deleted.
# Skipped entirely if no Docker daemon is running (Colima is started on
# demand, so most weeks this is skipped).
echo ""
echo "--- Docker ---"
if has docker && docker info >/dev/null 2>&1; then
  act docker system prune -f
else
  echo "Docker daemon not running, skipped"
fi

# --- Trash ---------------------------------------------------------------
# Permanently deletes items in ~/.Trash older than 7 days. The 7-day
# buffer means anything trashed this week survives until next week's run,
# so an accidental delete still has a recovery window. Age is -ctime, not
# -mtime: moving a file to Trash keeps its mtime (an old movie trashed today
# would be purged at once) but sets its ctime, so ctime is "time in Trash".
# Under launchd this is
# largely a no-op: ~/.Trash needs Full Disk Access (docs/maintenance.md).
echo ""
echo "--- Trash (items older than 7 days) ---"
echo "Before: $(size "$HOME/.Trash")"
echo "Items:  $(find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -ctime +7 2>/dev/null | wc -l | tr -d ' ')"
act find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -ctime +7 -exec rm -rf {} +
$DRY_RUN || echo "After:  $(size "$HOME/.Trash")"

# ============================================================================
# IDEAS (commented out, not yet enabled)
#
# Candidates that each carry a real cost, so none runs unattended. Uncomment a
# block to turn it on.
# ============================================================================

# --- brew autoremove ---------------------------------------------------------
# Removes formulae installed only as dependencies that nothing needs anymore.
# Not live: it also removes a dependency you started using directly without
# `brew install`-ing it yourself.
# echo "--- brew autoremove ---"
# act brew autoremove

# --- Unavailable simulators ----------------------------------------------------
# Removes simulator runtimes for OS versions no longer installed. Simulators
# reinstall via Xcode, but that is a multi-GB download.
# echo "--- Unavailable simulators ---"
# has xcrun && act xcrun simctl delete unavailable

# --- Stray .DS_Store files ----------------------------------------------------
# Purely cosmetic Finder metadata files, regenerate instantly. Scoped to
# $HOME only (not system-wide) to keep this low-risk.
# echo "--- .DS_Store cleanup ---"
# act find "$HOME" -name .DS_Store -delete

# --- Large, stale file report (non-destructive) -------------------------------
# Just logs files over 1GB untouched in 90+ days for manual review — never
# deletes anything. Meant to surface future candidates (e.g. old downloads)
# without ever touching personal content automatically.
# echo "--- Large files (>1GB, untouched 90+ days) ---"
# find "$HOME" -size +1G -mtime +90 -not -path "*/Library/*" 2>/dev/null

# --- Aggressive Docker prune (DESTRUCTIVE — more than the live prune above) --
# The live Docker section above uses a conservative `docker system prune -f`
# (no -a, no --volumes) on purpose, so a locally-built image you still want
# isn't silently deleted. This is the aggressive version used for a one-off
# manual cleanup in August 2026: -a removes every image not backing a
# container (running or stopped), --volumes also removes unused volumes
# (which may hold database data etc). Only run this deliberately, not on
# an unattended weekly schedule.
# if has docker && docker info >/dev/null 2>&1; then
#   act docker system prune -a --volumes -f
# fi

# --- Re-downloadable but expensive -------------------------------------------
# Safe to delete, but each costs a large download or a broken run until it is
# fetched again, so they stay manual: ~/.cache/huggingface (models),
# ~/Library/Caches/ms-playwright (browsers; tests fail until
# `npx playwright install`), Claude's vm_bundles, old ~/.nvm versions, and
# node_modules/.venv in projects.

# --- Messaging app caches — NOT SCRIPTABLE SAFELY ----------------------------
# Messaging apps typically keep account/message state and cached media in the
# same files inside one Group Container, so there is no safe blanket filesystem
# delete — removing the cache means removing history. Clear these from inside
# the app's own storage settings instead, never from a script.

# --- Cloud-drive local mirrors — NOT SCRIPTABLE, GUI SETTING -----------------
# A sync client set to mirror rather than stream keeps a full local copy of
# content that is already in the cloud, which can dominate disk usage. The fix
# is the client's own preference (mirror → stream), not a command: deleting the
# mirrored files directly would propagate the deletion upstream.

echo ""
echo "Free after: $(df -h "$HOME" | awk 'NR==2 {print $4}')"
echo "Done: $(date)"
exit 0
