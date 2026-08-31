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
rm -rf "$HOME/Library/Caches"/* 2>/dev/null || true
echo "After:  $(du -sh "$HOME/Library/Caches" 2>/dev/null | cut -f1)" | tee -a "$LOG_FILE"

