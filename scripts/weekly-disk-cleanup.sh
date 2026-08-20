#!/bin/zsh
#
# weekly-disk-cleanup.sh
#
# Reclaims disk space from caches/trash that safely regenerate or that were
# already discarded by the user. Runs weekly via launchd
# (~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist).
#
# Sections, each independent — one failing (e.g. Docker not running)
# does not stop the others. See ~/scripts/README-weekly-cleanup.md for
# what each step does and how to adjust or remove it.

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
# Skipped entirely if Docker Desktop isn't running.
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

echo "" >> "$LOG_FILE" 2>&1
echo "Done: $(date)" >> "$LOG_FILE" 2>&1

# Keep the log from growing forever - retain last 1000 lines
tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
