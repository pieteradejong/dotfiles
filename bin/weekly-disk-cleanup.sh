#!/bin/zsh
#
# weekly-disk-cleanup.sh
#
# Reclaims disk space from caches/trash that safely regenerate or that were
# already discarded by the user. Runs weekly via launchd
# (~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist).
#
# Sections, each independent — one failing (e.g. Docker not running)
# does not stop the others. See docs/maintenance.md for what each step does
# and how to adjust or remove it.
#
# Repo-only, like mac-maintenance.sh: launchd runs this file in place. There is
# no second copy to keep in sync.

# nvm-managed npm isn't on launchd's minimal PATH, so load it explicitly
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

LOG_FILE="$HOME/.weekly-disk-cleanup.log"

log() { echo "$@" >> "$LOG_FILE" 2>&1; }

{
  echo ""
  echo "======================================================"
  echo "  Weekly disk cleanup - $(date)"
  echo "======================================================"
} >> "$LOG_FILE" 2>&1

# --- npm cache ------------------------------------------------------------
# Verifies integrity, then wipes ~/.npm/_cacache (every package tarball
# ever downloaded). Fully safe: npm re-downloads on the next install.
{
  echo ""
  echo "--- npm cache ---"
  echo "Before: $(du -sh "$HOME/.npm" 2>/dev/null | cut -f1)"
  if command -v npm >/dev/null 2>&1; then
    npm cache verify
    npm cache clean --force
    echo "After:  $(du -sh "$HOME/.npm" 2>/dev/null | cut -f1)"
  else
    echo "npm not found on PATH, skipped"
  fi
} >> "$LOG_FILE" 2>&1

# --- pip cache --------------------------------------------------------------
# Wipes pip's downloaded wheel/sdist cache. Fully safe: pip re-downloads
# on the next install.
{
  echo ""
  echo "--- pip cache ---"
  echo "Before: $(du -sh "$HOME/Library/Caches/pip" 2>/dev/null | cut -f1)"
  if command -v pip3 >/dev/null 2>&1; then
    pip3 cache purge
    echo "After:  $(du -sh "$HOME/Library/Caches/pip" 2>/dev/null | cut -f1)"
  else
    echo "pip3 not found on PATH, skipped"
  fi
} >> "$LOG_FILE" 2>&1

# --- Docker ------------------------------------------------------------------
# Removes stopped containers, unused networks, dangling images, and build
# cache. Deliberately NOT `-a` (which would also remove any image not
# currently backing a container) — that's left as a manual, deliberate step
# so a locally-built image you plan to reuse isn't silently deleted.
# Skipped entirely if no Docker daemon is running (Colima is started on
# demand, so most weeks this is skipped).
{
  echo ""
  echo "--- Docker ---"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker system prune -f
  else
    echo "Docker daemon not running, skipped"
  fi
} >> "$LOG_FILE" 2>&1

# --- Trash ---------------------------------------------------------------
# Permanently deletes items in ~/.Trash older than 7 days. The 7-day
# buffer means anything trashed this week survives until next week's run,
# so an accidental delete still has a recovery window.
{
  echo ""
  echo "--- Trash (items older than 7 days) ---"
  echo "Before: $(du -sh "$HOME/.Trash" 2>/dev/null | cut -f1)"
  find "$HOME/.Trash" -mindepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null
  echo "After:  $(du -sh "$HOME/.Trash" 2>/dev/null | cut -f1)"
} >> "$LOG_FILE" 2>&1

# ============================================================================
# IDEAS (commented out, not yet enabled)
#
# Candidates collected while reclaiming space by hand. Each is independent and
# safe-by-default unless noted; uncomment a block to turn it on. None of these
# run as-is.
# ============================================================================

# --- Homebrew cleanup -------------------------------------------------------
# Removes old formula versions, the download cache, and dependencies no
# formula needs anymore. Safe: brew re-downloads/reinstalls on demand.
# {
#   echo ""
#   echo "--- Homebrew cleanup ---"
#   brew cleanup -s --prune=all
#   brew autoremove
# } >> "$LOG_FILE" 2>&1

# --- pnpm store prune --------------------------------------------------------
# Removes package versions no longer referenced by any known project. Safe,
# but its reference tracking can go stale if node_modules was ever deleted
# by hand (rm -rf) instead of through pnpm — in that case it may report
# "0 removable" even though the store has stale content; that's expected,
# not a bug.
# {
#   echo ""
#   echo "--- pnpm store prune ---"
#   command -v pnpm >/dev/null 2>&1 && pnpm store prune
# } >> "$LOG_FILE" 2>&1

# --- Xcode DerivedData + unavailable simulators ------------------------------
# DerivedData is Xcode's build cache (safe, rebuilds on next build).
# `simctl delete unavailable` removes simulator runtimes for iOS/watchOS/etc
# versions no longer installed (safe, simulators reinstall via Xcode if
# needed again).
# {
#   echo ""
#   echo "--- Xcode DerivedData + unavailable simulators ---"
#   rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/*
#   command -v xcrun >/dev/null 2>&1 && xcrun simctl delete unavailable
# } >> "$LOG_FILE" 2>&1

# --- Stray .DS_Store files ----------------------------------------------------
# Purely cosmetic Finder metadata files, regenerate instantly. Scoped to
# $HOME only (not system-wide) to keep this low-risk.
# {
#   echo ""
#   echo "--- .DS_Store cleanup ---"
#   find "$HOME" -name .DS_Store -delete 2>/dev/null
# } >> "$LOG_FILE" 2>&1

# --- Old mac-maintenance.sh log files ----------------------------------------
# mac-maintenance.sh writes a new ~/maintenance-YYYYMMDD.log every run and
# nothing currently prunes them. Deletes ones older than 30 days.
# {
#   echo ""
#   echo "--- Old maintenance-*.log files ---"
#   find "$HOME" -maxdepth 1 -name "maintenance-*.log" -mtime +30 -delete 2>/dev/null
# } >> "$LOG_FILE" 2>&1

# --- Large, stale file report (non-destructive) -------------------------------
# Just logs files over 1GB untouched in 90+ days for manual review — never
# deletes anything. Meant to surface future candidates (e.g. old downloads)
# without ever touching personal content automatically.
# {
#   echo ""
#   echo "--- Large files (>1GB, untouched 90+ days) ---"
#   find "$HOME" -size +1G -mtime +90 -not -path "*/Library/*" 2>/dev/null
# } >> "$LOG_FILE" 2>&1

# --- Aggressive Docker prune (DESTRUCTIVE — more than the live prune above) --
# The live Docker section above uses a conservative `docker system prune -f`
# (no -a, no --volumes) on purpose, so a locally-built image you still want
# isn't silently deleted. This is the aggressive version used for a one-off
# manual cleanup in August 2026: -a removes every image not backing a
# container (running or stopped), --volumes also removes unused volumes
# (which may hold database data etc). Only run this deliberately, not on
# an unattended weekly schedule.
# {
#   echo ""
#   echo "--- Docker prune (aggressive) ---"
#   if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
#     docker system prune -a --volumes -f
#   fi
# } >> "$LOG_FILE" 2>&1

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

echo "" >> "$LOG_FILE" 2>&1
echo "Done: $(date)" >> "$LOG_FILE" 2>&1

# Keep the log from growing forever - retain last 1000 lines
tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
