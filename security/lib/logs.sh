#!/usr/bin/env bash
#
# logs.sh — where a repo keeps its decision log and changelog, and who owes them.
#
# Sourced by security/gate.sh (no-changelog-entry, decision-unverified),
# claude/hooks/stop-log-check.sh, bin/whatsup and scripts/audit/20-policy.sh,
# so the four can never disagree about which file counts, which repos are
# exempt, or which paths are "doc-only". Functions only; nothing runs on source.
# Every git call is read-only and takes --no-optional-locks, the same rule the
# audit's git_ro() follows, so sourcing this in a do-not-touch repo is safe.
#
# The rules implemented here are written in:
#   docs/policy/ai-instructions.md § Decisions need verification
#   docs/policy/repo-standards.md  § Changelog, § Enforcement
#
# Env:  LOGS_SKIPLIST_FILE   the audit skip list (default: private/audit/skiplist.conf)
#
# bash 3.2 compatible.

LOGS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DOTFILES_DIR="$(cd "$LOGS_LIB_DIR/../.." && pwd)"
# The audit's SKIPLIST_FILE override is honoured so one fixture serves both.
LOGS_SKIPLIST_FILE="${LOGS_SKIPLIST_FILE:-${SKIPLIST_FILE:-$LOGS_DOTFILES_DIR/private/audit/skiplist.conf}}"

# shellcheck source=security/patterns.sh
[ -n "${CHANGELOG_EXEMPT_ERE:-}" ] || . "$LOGS_LIB_DIR/../patterns.sh"
# shellcheck source=security/lib/visibility.sh
command -v gh_slug_from_url >/dev/null 2>&1 || . "$LOGS_LIB_DIR/visibility.sh"

logs_git() { git --no-optional-locks "$@" 2>/dev/null; }

# --- which files ---------------------------------------------------------------

# logs_decisions_file <top> — the decision log's path relative to <top>, or fails.
# docs/DECISIONS.md is the standard; a root DECISIONS.md is accepted for repos
# that predate it; docs/design-decisions.md is the dotfiles repo's own log.
logs_decisions_file() {
  local top="$1" f
  for f in docs/DECISIONS.md DECISIONS.md docs/design-decisions.md; do
    [ -f "$top/$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# logs_changelog_file <top> — CHANGELOG.md relative to <top>, or fails.
logs_changelog_file() {
  [ -f "$1/CHANGELOG.md" ] && { printf 'CHANGELOG.md'; return 0; }
  return 1
}

# logs_doc_only <path> — true when the path never owes a changelog entry.
logs_doc_only() { printf '%s\n' "$1" | LC_ALL=C grep -qE -- "$CHANGELOG_EXEMPT_ERE"; }

# logs_nondoc <file of paths> — the paths that do owe one, one per line.
logs_nondoc() { LC_ALL=C grep -vE -- "$CHANGELOG_EXEMPT_ERE" "$1" | awk 'NF'; }

# --- which repos ------------------------------------------------------------------

# logs_exempt <top> — true (and prints why) when the repo owes no entries:
# scratch and retired code, someone else's remote, or a skip/fork skip-list row.
# A missing skip list exempts nothing: fail closed, as the gate does.
logs_exempt() {
  local top="$1" url slug owner name line m r
  case "$top" in
    */projects/scratch|*/projects/scratch/*) printf 'scratch'; return 0 ;;
    */_to_delete|*/_to_delete/*)             printf 'retired (_to_delete)'; return 0 ;;
  esac
  url="$(logs_git -C "$top" config --get remote.origin.url)"
  if [ -n "$url" ] && slug="$(gh_slug_from_url "$url" 2>/dev/null)"; then
    owner="${slug%%/*}"
    if [ "$owner" != "$OWN_GITHUB_OWNER" ]; then
      printf 'remote owner is %s, not %s' "$owner" "$OWN_GITHUB_OWNER"; return 0
    fi
  fi
  name="$(basename "$top")"
  [ -f "$LOGS_SKIPLIST_FILE" ] || return 1
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    m="${line%%:*}"; r="${line#*:}"; r="${r%%:*}"
    [ "$r" = "$name" ] || continue
    case "$m" in
      skip|fork) printf '%s: %s' "$m" "${line#*:*:}"; return 0 ;;
    esac
  done < "$LOGS_SKIPLIST_FILE"
  return 1
}

# --- reading a decision log --------------------------------------------------------

# logs_decisions <file> — one row per entry, in file order:
#     N <TAB> status <TAB> date <TAB> title
# status: ok | NOT YET | PARTIAL | none (no Verified line at all).
# An entry starts at any "## " heading, or at a bold "**YYYY-MM-DD · title**"
# paragraph, and runs to the next one. N is the heading's own number
# ("## 8.", "## D32 —", "## ADR-001:") or, for unnumbered logs, the ordinal.
# The date comes from the heading ("## 2026-09-24 — …", "… · 2026-10-06") or a
# "**Date:** YYYY-MM-DD" line. Verified is any line starting "**Verified",
# "Verified:" or "- **Verified"; NOT YET / PARTIAL anywhere after it set the status.
logs_decisions() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk '
    function flush() {
      if (cur != "") printf "%s\t%s\t%s\t%s\n", cur, (ver == "" ? "none" : ver), date, title
      cur = ""
    }
    function start(n, t, d) {
      flush(); ord++
      cur = (n == "" ? ord : n); title = t; date = d; ver = ""; inver = 0
      sub(/[ \t]+$/, "", title); sub(/\.\*\*$/, "", title); sub(/\*\*$/, "", title)
    }
    /^## / {
      h = $0; sub(/^## +/, "", h); n = ""; d = ""
      if (h ~ /^(ADR-)?D?0*[0-9]+([.:]|[ \t]|$)/ && h !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
        sub(/^(ADR-)?D?0*/, "", h); n = h; sub(/[^0-9].*$/, "", n)
        sub(/^[0-9]+[.:]?[ \t]*/, "", h)
      } else if (h ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
        d = substr(h, 1, 10); h = substr(h, 11)
      }
      sub(/^[ \t]*(—|–|-|·)[ \t]*/, "", h)
      if (match(h, /[ \t]+·[ \t]+[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]*$/)) {
        d = substr(h, RSTART); gsub(/[^0-9-]/, "", d); h = substr(h, 1, RSTART - 1)
      }
      start(n, h, d); next
    }
    /^\*\*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]+·[ \t]+/ {
      h = $0; d = substr(h, 3, 10); sub(/^\*\*[0-9-]+[ \t]+·[ \t]+/, "", h)
      start("", h, d); next
    }
    cur == "" { next }
    date == "" && /^\*\*Date:?\*\*/ { d = $0; sub(/^\*\*Date:?\*\*:?[ \t]*/, "", d); sub(/[ \t]+$/, "", d); date = d }
    /^(\*\*Verified|Verified:|- \*\*Verified)/ { if (ver == "") ver = "ok"; inver = 1 }
    inver && /NOT YET/ && ver != "NOT YET" { ver = "NOT YET" }
    inver && /PARTIAL/ && ver == "ok" { ver = "PARTIAL" }
    END { flush() }
  ' "$1"
}

# logs_last_decision <file> — "N · title · date" of the last entry, or nothing.
logs_last_decision() {
  logs_decisions "$1" | tail -n 1 | awk -F'\t' 'NF { printf "%s · %s%s", $1, $4, ($3 == "" ? "" : " · " $3) }'
}

# logs_open_decisions <file> — rows whose status is not ok (NOT YET, PARTIAL, none).
logs_open_decisions() { logs_decisions "$1" | awk -F'\t' '$2 != "ok"'; }

# logs_decision_numbers <file> — the explicitly numbered entries, sorted. An
# unnumbered log yields nothing, and then no reference can be checked against it.
logs_decision_numbers() {
  [ -f "$1" ] || return 0
  LC_ALL=C sed -nE 's/^## +(ADR-)?D?0*([0-9]+)([.:]|[[:space:]]|$).*/\2/p' "$1" \
    | LC_ALL=C grep -vE '^[0-9]{4}$' | LC_ALL=C sort -u
}

# --- reading a changelog -----------------------------------------------------------

logs_has_unreleased() { [ -f "$1" ] && LC_ALL=C grep -qE '^## \[Unreleased\]' "$1"; }

# logs_unreleased <file> — the body of the [Unreleased] block, without its heading.
logs_unreleased() {
  [ -f "$1" ] || return 0
  awk '/^## \[Unreleased\]/ { on = 1; next } on && /^## / { exit } on { print }' "$1"
}

# logs_refs_missing <decisions-file> — stdin: text (changelog lines); stdout: the
# decision numbers it cites — (#12), (D33), (DECISIONS #3) — with no such entry.
logs_refs_missing() {
  local dec="$1" refs known
  refs="$(LC_ALL=C grep -oE '\((DECISIONS[[:space:]]+)?(#|D)0*[0-9]+\)' | LC_ALL=C sed -E 's/[^0-9]//g' | awk 'NF' | LC_ALL=C sort -u)"
  [ -n "$refs" ] || return 0
  known="$(logs_decision_numbers "$dec")"
  [ -n "$known" ] || return 0
  printf '%s\n' "$refs" | LC_ALL=C comm -23 - <(printf '%s\n' "$known")
}

# --- what changed this session -----------------------------------------------------
#
# The SessionStart hook writes <state>/<session_id>.base:
#     HEAD <sha>
#     TOP <absolute repo path>
#     <porcelain path>...        (what was already dirty when the session opened)
# The Stop hook and whatsup read it to answer "what did this session change?".

# logs_write_baseline <top> <state-dir> <session-id>
logs_write_baseline() {
  local top="$1" dir="$2" sid="$3" f
  case "$sid" in *[!A-Za-z0-9_.-]*|'') return 1 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null
  f="$dir/$sid.base"
  {
    printf 'HEAD %s\n' "$(logs_git -C "$top" rev-parse HEAD || printf 'EMPTY')"
    printf 'TOP %s\n' "$top"
    logs_git -C "$top" status --porcelain --untracked-files=all | cut -c4- | LC_ALL=C sort
  } > "$f" 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null
  # Baselines older than 7 days belong to sessions that are long gone.
  find "$dir" -maxdepth 1 -type f \( -name '*.base' -o -name '*.ack' \) -mtime +7 -delete 2>/dev/null
  return 0
}

# logs_newest_baseline <top> <state-dir> — the newest baseline for this repo.
logs_newest_baseline() {
  local top="$1" dir="$2" f best=""
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.base; do
    [ -f "$f" ] || continue
    [ "$(sed -n '2s/^TOP //p' "$f" 2>/dev/null)" = "$top" ] || continue
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
  done
  [ -n "$best" ] && { printf '%s' "$best"; return 0; }
  return 1
}

# logs_changed_paths <top> [<baseline-file>] — paths changed since the baseline
# (or, with none, since HEAD): committed, modified, or new. Relative to <top>,
# sorted, unique. Paths that were already dirty at the baseline are left out;
# callers union in anything the session is known to have touched.
logs_changed_paths() {
  local top="$1" base="${2:-}" head="" dirty=""
  if [ -n "$base" ] && [ -f "$base" ]; then
    head="$(sed -n '1s/^HEAD //p' "$base")"
    dirty="$(sed '1,2d' "$base")"
  fi
  [ -n "$head" ] && [ "$head" != EMPTY ] && logs_git -C "$top" cat-file -e "$head^{commit}" || head=HEAD
  {
    logs_git -C "$top" diff --name-only "$head" --
    logs_git -C "$top" ls-files --others --exclude-standard
  } | awk 'NF' | LC_ALL=C sort -u | LC_ALL=C comm -23 - <(printf '%s\n' "$dirty" | LC_ALL=C sort -u)
}

# logs_transcript_paths <top> <transcript.jsonl> — files under <top> that the
# assistant's Edit/Write/NotebookEdit calls named, relative to <top>.
logs_transcript_paths() {
  local top="$1" t="$2"
  [ -f "$t" ] || return 0
  LC_ALL=C grep -oE '"file_path": ?"[^"]+"' "$t" 2>/dev/null \
    | LC_ALL=C sed -E 's/^"file_path": ?"//; s/"$//' \
    | awk -v top="$top/" 'index($0, top) == 1 { print substr($0, length(top) + 1) }' \
    | LC_ALL=C sort -u
}
