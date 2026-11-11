# shellcheck shell=bash
#
# loose-files.sh — credential-shaped files that are outside version control, or
# untracked and unignored inside a repo (one `git add -A` from publication).
#
# One copy of the rules, used by section 6 of scripts/security-audit.sh (weekly,
# into the report) and by bin/maintenance-status (live, at every session start
# and new terminal), so a file that was found weekly and then deleted stops
# being shown at once (D62). Source security/patterns.sh first: it defines
# is_example_path.
#
#   loose_scan <root> <workdir> [skip-name ...]
#
# Prints one finding per line, LEVEL<TAB>message, sorted by path:
#   FAIL  outside any repo, with no .gitignore below <root> that would ignore it
#   WARN  inside a repo, untracked and not ignored
#   INFO  outside any repo, but an ancestor .gitignore would ignore it
# Prints nothing when there is nothing to report. <workdir> must exist and be
# writable (a throwaway empty git dir goes there); nothing is written next to a
# scanned file. Read-only toward every repo. bash 3.2 compatible.

# _loose_covered <root> <workdir> <file> — for a file outside any repo (template
# sources, loose project dirs): would a .gitignore in its directory or an
# ancestor below <root> ignore it once that directory becomes, or is copied
# into, a repo? Prints the covering directory relative to <root>.
_loose_covered() {
  local root="$1" work="$2" f="$3" dir
  dir="${f%/*}"
  while [ "${#dir}" -gt "${#root}" ]; do
    if [ -f "$dir/.gitignore" ] && ( cd "$dir" && git --git-dir="$work/empty.git" --work-tree=. \
         check-ignore -q --no-index -- "${f#"$dir"/}" ) 2>/dev/null; then
      printf '%s' "${dir#"$root"/}"; return 0
    fi
    dir="${dir%/*}"
  done
  return 1
}

# _loose_top <dir> — the work tree a directory belongs to: the nearest ancestor
# holding a .git (directory, or file for worktrees and submodules). Plain shell,
# no git process, so a scan of ~80 candidates stays well under a second.
_loose_top() {
  local dir="$1"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -e "$dir/.git" ] && { printf '%s' "$dir"; return 0; }
    dir="${dir%/*}"
  done
  return 1
}

loose_scan() {
  local root="$1" work="$2" f rel s skip cov skips top prev tab
  shift 2
  skips=" $* "
  tab="$(printf '\t')"
  [ -d "$work/empty.git" ] || git init -q --bare "$work/empty.git" || return 1
  find "$root" -maxdepth 5 \( -name node_modules -o -name .git -o -name .venv -o -name venv -o -name audit-reports \) -prune -o -type f \
    \( -iname '*recovery*code*' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name '*.ppk' \
       -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' -o -name '.env' -o -name '.env.*' \
       -o -iname '*credentials*.json' -o -name '*.kdbx' -o -name '.netrc' -o -name '.pypirc' \) -print 2>/dev/null \
    | LC_ALL=C sort > "$work/loose"
  : > "$work/out"; : > "$work/inrepo"
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    is_example_path "$rel" && continue
    case "$rel" in *.pub) continue ;; esac
    skip=0; for s in $skips; do case "/$rel/" in */"$s"/*) skip=1 ;; esac; done
    [ "$skip" = 1 ] && continue
    if top="$(_loose_top "${f%/*}")"; then
      printf '%s\t%s\n' "$top" "$f" >> "$work/inrepo"
    elif cov="$(_loose_covered "$root" "$work" "$f")"; then
      printf '%s\tINFO\toutside any repo, but ignored by %s/.gitignore (a scaffold or git init there won'"'"'t commit it): %s\n' "$f" "$cov" "$rel" >> "$work/out"
    else
      printf '%s\tFAIL\toutside any repo, no version control and no guard: %s\n' "$f" "$rel" >> "$work/out"
    fi
  done < "$work/loose"
  # Inside a repo: one `git ls-files --others --exclude-standard` per repo lists
  # exactly the candidates that are neither tracked nor ignored.
  prev=""
  LC_ALL=C sort -t "$tab" -k1,1 -s "$work/inrepo" | {
    set --
    flush() {
      [ -n "$prev" ] && [ "$#" -gt 0 ] || return 0
      git --no-optional-locks -c core.quotePath=off -C "$prev" ls-files --others --exclude-standard -- "$@" 2>/dev/null \
        | while IFS= read -r p; do
            p="$prev/$p"
            # shellcheck disable=SC2016  # the backticks are literal text
            printf '%s\tWARN\tuntracked and NOT ignored — one `git add -A` from being committed: %s\n' \
              "$p" "${p#"$root"/}" >> "$work/out"
          done
    }
    while IFS="$tab" read -r top f; do
      if [ "$top" != "$prev" ]; then flush "$@"; set --; prev="$top"; fi
      set -- "$@" "${f#"$top"/}"
    done
    flush "$@"
  }
  LC_ALL=C sort -t "$tab" -k1,1 "$work/out" | cut -f2-
  return 0
}
