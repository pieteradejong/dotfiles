#!/bin/bash

# mac-maintenance.sh
# Weekly system maintenance script for macOS

set -e

LOG_FILE="$HOME/maintenance-$(date +%Y%m%d).log"

echo "=== macOS Maintenance Report - $(date) ===" | tee "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "--- UPTIME ---" | tee -a "$LOG_FILE"
uptime | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"


echo "--- MEMORY STATS ---" | tee -a "$LOG_FILE"
vm_stat | tee -a "$LOG_FILE"

# Human-readable summary
page_size=$(pagesize)
free_pages=$(vm_stat | awk '/Pages free/ {print $3}' | tr -d '.')
inactive_pages=$(vm_stat | awk '/Pages inactive/ {print $3}' | tr -d '.')
free_gb=$(echo "scale=2; ($free_pages + $inactive_pages) * $page_size / 1073741824" | bc)
echo "Approximate available memory: ${free_gb} GB" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "--- LIBRARY CACHES CLEANUP ---" | tee -a "$LOG_FILE"
echo "Before: $(du -sh "$HOME/Library/Caches" 2>/dev/null | cut -f1)" | tee -a "$LOG_FILE"
# Moved (not deleted) into ~/.Trash so weekly-disk-cleanup.sh's existing
# 7-day Trash purge is what actually reclaims the space — gives a restore
# window instead of an immediate, permanent rm -rf.
QUARANTINE_DIR="$HOME/.Trash/mac-maintenance-caches-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$QUARANTINE_DIR"
mv "$HOME/Library/Caches"/* "$QUARANTINE_DIR"/ 2>/dev/null || true
echo "Moved to: $QUARANTINE_DIR (purged after 7 days by weekly-disk-cleanup.sh)" | tee -a "$LOG_FILE"
echo "After:  $(du -sh "$HOME/Library/Caches" 2>/dev/null | cut -f1)" | tee -a "$LOG_FILE"

