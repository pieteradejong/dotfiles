#!/usr/bin/env bash
#
# 10-git-hygiene.sh — is the work safe, and is it anywhere but this laptop?
#
# Every check here answers one question: if this Mac died tonight, what would
# be lost? Uncommitted work, unpushed commits and repos with no remote are the
# three ways that happens. The rest (bloat, stale branches) is tidiness.
#
# Sourced by dev-audit.sh. Read-only: all git access via git_ro().


audit_git() {
  # Category for every finding below. Declared here, not at file scope:
  # dev-audit.sh sources all modules before running any, so a global would
  # be overwritten by whichever module was sourced last. `local` is
  # dynamically scoped in bash, so the check_* helpers still see it.
  local CAT=git
  hdr "Git hygiene"
  local repo name reason ahead behind counts branch upstream
  local status_out dirty_n gitdir_kb loose_n remotes

  while IFS= read -r repo; do
    name="$(repo_name "$repo")"

    # Do-not-touch repos are excluded before any git command runs, so the
    # skip is real rather than cosmetic.
    if reason="$(is_skipped "$name")"; then
      note "SKIP $name ($reason)"
      continue
    fi

    # --- stale lock ---
    # A leftover .git/index.lock blocks every git command in the repo with
    # "another git process seems to be running". Usually the corpse of a
    # crashed or killed git. Reported, never deleted - if a git process really
    # is running, removing it corrupts the index.
    if [ -f "$repo/.git/index.lock" ]; then
      finding WARN "$CAT" "$name" stale-lock ".git/index.lock present - git commands here will refuse to run"
    fi

    # --- uncommitted work ---
    status_out="$(git_ro "$repo" status --porcelain)"
    if [ -n "$status_out" ]; then
      dirty_n="$(printf '%s\n' "$status_out" | wc -l | tr -d ' ')"
      finding INFO "$CAT" "$name" dirty-tree "$dirty_n uncommitted path(s)"
    fi

    # --- does it exist anywhere else? ---
    remotes="$(git_ro "$repo" remote)"
    if [ -z "$remotes" ]; then
      # No remote at all: the only copy is this disk.
      finding FAIL "$CAT" "$name" no-remote "no git remote - this disk is the only copy"
    else
      branch="$(git_ro "$repo" rev-parse --abbrev-ref HEAD)"
      upstream="$(git_ro "$repo" rev-parse --abbrev-ref '@{u}')"
      if [ -z "$upstream" ]; then
        finding WARN "$CAT" "$name" no-upstream "branch '$branch' tracks nothing"
      else
        # left = behind (upstream has that we don't), right = ahead (ours only).
        counts="$(git_ro "$repo" rev-list --left-right --count "@{u}...HEAD")"
        behind="$(printf '%s' "$counts" | awk '{print $1+0}')"
        ahead="$(printf '%s' "$counts" | awk '{print $2+0}')"
        [ "${ahead:-0}" -gt 0 ] && \
          finding FAIL "$CAT" "$name" unpushed "$ahead commit(s) exist only on this machine"
        [ "${behind:-0}" -gt 0 ] && \
          finding INFO "$CAT" "$name" behind "$behind commit(s) behind $upstream"
      fi
    fi

    # --- .git bloat ---
    # Loose objects are the twittertools case: 410 MB loose against a 6 KB pack
    # because the repo has never been gc'd. We report it; we never run gc.
    gitdir_kb="$(size_kb "$repo/.git")"
    if [ "${gitdir_kb:-0}" -gt 102400 ]; then
      finding WARN "$CAT" "$name" git-bloat ".git is $(human_kb "$gitdir_kb")"
    fi
    loose_n="$(find "$repo/.git/objects" -type f -path '*/??/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${loose_n:-0}" -gt 5000 ]; then
      finding WARN "$CAT" "$name" never-gcd "$loose_n loose objects - 'git gc' would repack"
    fi

    # --- stale merged branches ---
    stale_branches "$repo" "$name"
  done < <(list_repos)

  # --- project directories that are not repos ---
  # No history, no remote, no backup. Not automatically wrong (scratch dirs
  # exist) but it is the set worth eyeballing.
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    finding WARN "$CAT" "$(basename "$d")" not-a-repo "directory under projects/ with no git repo"
  done < <(list_non_repo_project_dirs)
}

# Branches already merged into the default branch and untouched for 90+ days.
stale_branches() {
  local repo="$1" name="$2" head b n=0
  head="$(git_ro "$repo" symbolic-ref --short HEAD)"
  [ -n "$head" ] || return 0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    b="${b#refs/heads/}"
    [ "$b" = "$head" ] && continue
    n=$((n + 1))
  done < <(git_ro "$repo" for-each-ref --format='%(refname)' \
             --merged HEAD --sort=committerdate \
             --no-contains "HEAD@{90 days ago}" refs/heads/ 2>/dev/null)
  [ "$n" -gt 0 ] && finding INFO "$CAT" "$name" stale-branches "$n merged branch(es) untouched 90+ days"
  return 0
}
