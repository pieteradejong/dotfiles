#!/usr/bin/env bash
#
# 40-disk.sh — what is large, and what has no copy anywhere else?
#
# Two separate concerns that share a walk of the disk:
#   - size: dependency dirs and large files, the reclaimable 13.7 GB the
#     2026-09-01 audit found and the >100 MB files GitHub hard-rejects.
#   - exposure: which repos have no off-machine copy at all, closing the loop
#     with BACKUP_AUDIT_2026-09-06.md § 5 ("~/dev is not backed up at all").
#
# Reports only. Never deletes, never runs git gc, never prunes a cache -
# that is weekly-disk-cleanup.sh's job and it is deliberately separate.


# Directories that are rebuildable from a manifest. Each project's init.sh
# recreates these, so their size is reclaimable rather than lost.
DEP_DIR_NAMES="node_modules .venv venv .terraform target __pycache__ .next whisper-env"

# GitHub rejects any file over 100 MB, and history never shrinks once pushed.
LARGE_FILE_MB=100

# Report a repo whose working tree exceeds this, so the big ones surface.
BIG_REPO_MB=500

audit_disk() {
  # Category for every finding below. Declared here, not at file scope:
  # dev-audit.sh sources all modules before running any, so a global would
  # be overwritten by whichever module was sourced last. `local` is
  # dynamically scoped in bash, so the check_* helpers still see it.
  local CAT=disk
  hdr "Disk and backup exposure"
  local repo name kb dep_kb total_dep_kb=0 n

  while IFS= read -r repo; do
    name="$(repo_name "$repo")"
    is_skipped "$name" >/dev/null && continue

    kb="$(size_kb "$repo")"
    [ "${kb:-0}" -gt $((BIG_REPO_MB * 1024)) ] && \
      finding INFO "$CAT" "$name" large-repo "working tree is $(human_kb "$kb")"

    dep_kb="$(dep_dirs_kb "$repo")"
    if [ "${dep_kb:-0}" -gt $((200 * 1024)) ]; then
      total_dep_kb=$((total_dep_kb + dep_kb))
      finding INFO "$CAT" "$name" dep-dirs "$(human_kb "$dep_kb") of rebuildable dependency dirs"
    fi

    # Files git will refuse. Checked on disk, not in history, because the
    # common case is a large file sitting untracked next to tracked code.
    n="$(find "$repo" -type f -size +${LARGE_FILE_MB}M \
           -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')"
    [ "${n:-0}" -gt 0 ] && \
      finding WARN "$CAT" "$name" large-files "$n file(s) over ${LARGE_FILE_MB} MB (GitHub's hard limit)"

    check_offmachine "$repo" "$name"
  done < <(list_repos)

  [ "$total_dep_kb" -gt 0 ] && \
    note "Reclaimable dependency dirs across all repos: $(human_kb "$total_dep_kb")"
  return 0
}

dep_dirs_kb() {
  local repo="$1" d total=0 kb expr_args=""
  local first=1 n
  for n in $DEP_DIR_NAMES; do
    if [ "$first" = 1 ]; then expr_args="-name $n"; first=0
    else expr_args="$expr_args -o -name $n"; fi
  done
  # shellcheck disable=SC2086 # $expr_args is a deliberately word-split list of find predicates
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    kb="$(size_kb "$d")"
    total=$((total + ${kb:-0}))
  done < <(find "$repo" -maxdepth 3 -type d \( $expr_args \) -prune -print 2>/dev/null)
  printf '%s' "$total"
}

# A repo whose only copy is this SSD. The distinction from 10-git-hygiene's
# no-remote check: this one also catches a repo that has a remote but has
# never actually pushed the current branch anywhere.
check_offmachine() {
  local repo="$1" name="$2" remotes upstream
  remotes="$(git_ro "$repo" remote)"
  if [ -z "$remotes" ]; then
    finding FAIL "$CAT" "$name" no-offmachine-copy "no remote: losing this disk loses the repo"
    return 0
  fi
  upstream="$(git_ro "$repo" rev-parse --abbrev-ref '@{u}')"
  if [ -z "$upstream" ]; then
    finding WARN "$CAT" "$name" no-offmachine-copy "remote exists but current branch was never pushed"
  fi
  return 0
}
