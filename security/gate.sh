#!/bin/bash
#
# gate.sh — the security gate every commit and push on this machine passes.
#
#   gate.sh pre-commit                       staged changes
#   gate.sh pre-push <remote> <url>          commits being pushed (ref lines on stdin)
#   gate.sh scan-tree                        everything a `git add -A` would commit now
#   gate.sh status                           is the gate installed and intact?
#
# INSTALLATION is two config-based hooks in ~/.gitconfig (git >= 2.54), not
# core.hooksPath — so every repo's own hooks keep running after this one, and
# nothing is ever written into a repo:
#
#   [hook "security-gate-commit"]
#       event = pre-commit
#       command = ~/dev/dotfiles/security/gate.sh pre-commit
#   [hook "security-gate-push"]
#       event = pre-push
#       command = ~/dev/dotfiles/security/gate.sh pre-push
#
# git appends the hook's own arguments, so pre-push arrives here as
# `gate.sh pre-push <remote> <url>`.
#
# What is blocked vs warned, and why: docs/policy/security-and-privacy.md.
#
# RULES THIS FILE OBEYS:
#   1. Never print a matched value. Name the rule and the file, stop there.
#   2. Fail closed. No gitleaks, no answer about visibility, an error from a
#      scanner — each is treated as the unsafe case.
#   3. bash 3.2 compatible, shellcheck-clean.
#
# BYPASS: SECURITY_GATE_BYPASS="<reason, 10+ chars>" turns blocks into warnings
# for that one command and appends the reason (never the values) to
# ~/.local/state/security-gate/bypass.log, which the weekly audit reads.
# `--no-verify` also skips this hook, silently; GitHub push protection, CI and
# the weekly audit are the backstop for that.

set -u

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$GATE_DIR/.." && pwd)"
# shellcheck source=security/patterns.sh
. "$GATE_DIR/patterns.sh"
# shellcheck source=security/lib/visibility.sh
. "$GATE_DIR/lib/visibility.sh"

PERSONAL_PATTERNS_FILE="$DOTFILES_DIR/private/security/personal-patterns.conf"
BYPASS_LOG="${SECURITY_GATE_BYPASS_LOG:-$HOME/.local/state/security-gate/bypass.log}"
GITLEAKS_CONFIG="$GATE_DIR/gitleaks.toml"
MAX_FILE_BYTES=$((50 * 1024 * 1024))
DOTFILES_SLUG="pieteradejong/dotfiles"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_DIM=""; C_BOLD=""; C_RST=""
fi

N_BLOCK=0
N_WARN=0
RULES_HIT=""
STRICT_PERSONAL=0     # 1 when the content is headed somewhere public
TMPD=""

# shellcheck disable=SC2329 # invoked by the trap
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT

say()   { printf '%s\n' "$*" >&2; }
block() { N_BLOCK=$((N_BLOCK + 1)); RULES_HIT="$RULES_HIT $1"; say "${C_RED}BLOCK${C_RST} $1: $2"; }
warn()  { N_WARN=$((N_WARN + 1));   say "${C_YEL}WARN ${C_RST} $1: $2"; }
# Personal data: a warning, unless the content is headed somewhere public.
personal() { if [ "$STRICT_PERSONAL" = 1 ]; then block "$@"; else warn "$@"; fi; }

# origin_is_public — true only on a DEFINITE PUBLIC answer for `origin`.
#
# Used by pre-commit to fail early on personal data in a repo that is already
# public, rather than letting it into history and blocking the push afterwards —
# by which point the fix needs history surgery.
#
# UNKNOWN deliberately does NOT count as public here, which inverts this file's
# fail-closed rule. That inversion is intentional and scoped to `git commit`:
# UNKNOWN is the normal answer when offline, unauthenticated, or on a non-GitHub
# remote, and treating it as public would block every commit made on a plane.
# The push is the real boundary and keeps failing closed (cmd_pre_push), as does
# scan-tree. Commit-time strictness is an early warning, not the enforcement.
origin_is_public() {
  local url
  url="$(git config --get remote.origin.url 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  [ "$(remote_visibility "$url")" = PUBLIC ]
}

num() { printf '%s' "$1" | tr -dc '0-9' | head -c 12; }

is_zero_sha() { case "$1" in *[!0]*) return 1 ;; esac; return 0; }

# join_lines <file> [max] — "a, b, c (+N more)" for a list of paths.
join_lines() {
  awk -v max="${2:-5}" 'NF { n++; if (n <= max) s = s (n > 1 ? ", " : "") $0 }
    END { if (n > max) s = s " (+" (n - max) " more)"; printf "%s", s }' "$1"
}

is_dotfiles_repo() {
  local top url
  top="$(cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  [ "$top" = "$(cd "$DOTFILES_DIR" && pwd -P)" ] && return 0
  for url in $(git config --get-regexp '^remote\..*\.url$' 2>/dev/null | awk '{print $2}'); do
    case "$(gh_slug_from_url "$url" 2>/dev/null)" in "$DOTFILES_SLUG") return 0 ;; esac
  done
  return 1
}

require_gitleaks() {
  command -v gitleaks >/dev/null 2>&1 && return 0
  block gitleaks-missing "gitleaks is not installed, so nothing can be scanned for secrets (brew install gitleaks)"
  return 1
}

# --- checks shared by commit and push -----------------------------------------

# check_names <file of paths, one per line>
check_names() {
  local list="$1" hits="$TMPD/name-hits" f line rule glob
  : > "$hits"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_template_path "$f" && continue   # suffix only: .env.test is NOT exempt
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rule="${line%%|*}"; glob="${line#*|}"
      # shellcheck disable=SC2254 # $glob is deliberately a pattern
      case "$f" in $glob) printf '%s\t%s\n' "$rule" "$f" >> "$hits"; break ;; esac
    done <<EOF
$TRACKED_FILE_RULES
$GATE_FILE_RULES
EOF
  done < "$list"
  [ -s "$hits" ] || return 0
  cut -f1 "$hits" | sort -u | while IFS= read -r rule; do
    awk -F'\t' -v r="$rule" '$1 == r { print $2 }' "$hits" > "$TMPD/rule-files"
    printf '%s\t%s\n' "$rule" "$(join_lines "$TMPD/rule-files")"
  done > "$TMPD/name-summary"
  while IFS="$(printf '\t')" read -r rule files; do
    block "$rule" "must never be committed: $files"
  done < "$TMPD/name-summary"
}

# check_private_dir <file of paths> — only in the public dotfiles repo.
check_private_dir() {
  is_dotfiles_repo || return 0
  grep -E '^private(/|$)' "$1" > "$TMPD/private-hits" 2>/dev/null || true
  [ -s "$TMPD/private-hits" ] && block private-companion-repo \
    "dotfiles/private/ is a separate private repo and must never enter public dotfiles: $(join_lines "$TMPD/private-hits")"
  return 0
}

# lines_to_files <path<TAB>line file> <line-numbers file> — the paths those lines came from.
lines_to_files() {
  awk -F'\t' 'NR == FNR { want[$1] = 1; next } (FNR in want) { print $1 }' "$2" "$1" | LC_ALL=C sort -u
}

# scan_added <file of "path<TAB>added line"> — personal data in new content.
#
# Content is matched with grep -E, never awk: macOS awk strips backslash escapes
# from -v values and rejects {n,m} intervals, which silently broke every rule
# with either. Paths are filtered with awk reading the regex from ENVIRON, which
# does no escape processing. Matching works on line NUMBERS so the matched text
# itself is never carried anywhere.
scan_added() {
  local added="$1" f="$TMPD/added-filtered" c="$TMPD/added-content" ln="$TMPD/hit-lines" l no line n
  [ -s "$added" ] || return 0
  EXAMPLE_RE="$EXAMPLE_PATH_ERE" LOCK_RE="$LOCKFILE_ERE" awk -F'\t' \
    'BEGIN { re = ENVIRON["EXAMPLE_RE"]; lre = ENVIRON["LOCK_RE"] }
    $1 !~ re && $1 !~ lre && $0 !~ /security-gate:allow/' "$added" > "$f"
  [ -s "$f" ] || return 0
  cut -f2- "$f" > "$c"

  grep -nE -- "$HOMEPATH_RE" "$c" 2>/dev/null | cut -d: -f1 > "$ln"
  if [ -s "$ln" ]; then
    lines_to_files "$f" "$ln" > "$TMPD/files"
    personal home-path "absolute /Users/<name>/ path added in: $(join_lines "$TMPD/files")"
  fi

  # Emails: candidate lines first (capped, so a pasted CSV cannot stall a
  # commit), then discard lines whose only addresses are placeholders.
  : > "$ln"
  grep -nE -- "$EMAIL_RE" "$c" 2>/dev/null | head -n 500 > "$TMPD/em-cand"
  while IFS= read -r l; do
    no="${l%%:*}"; line="${l#*:}"
    if printf '%s\n' "$line" | grep -oE -- "$EMAIL_RE" | grep -qvE -- "$EMAIL_PLACEHOLDER_RE"; then
      printf '%s\n' "$no" >> "$ln"
    fi
  done < "$TMPD/em-cand"
  if [ -s "$ln" ]; then
    lines_to_files "$f" "$ln" > "$TMPD/files"
    personal email "real email address added in: $(join_lines "$TMPD/files")"
  fi

  grep -nE -- "$PHONE_RE" "$c" 2>/dev/null | cut -d: -f1 > "$ln"
  if [ -s "$ln" ]; then
    lines_to_files "$f" "$ln" > "$TMPD/files"
    personal phone-number "phone-number-shaped value added in: $(join_lines "$TMPD/files")"
  fi

  if [ -f "$PERSONAL_PATTERNS_FILE" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$PERSONAL_PATTERNS_FILE" > "$TMPD/pp" 2>/dev/null
    if [ -s "$TMPD/pp" ]; then
      grep -nF -f "$TMPD/pp" "$c" 2>/dev/null | cut -d: -f1 > "$ln"
      if [ -s "$ln" ]; then
        lines_to_files "$f" "$ln" > "$TMPD/files"
        n="$(num "$(wc -l < "$ln")")"
        personal personal-value "$n line(s) contain a value from the private personal-patterns list, in: $(join_lines "$TMPD/files")"
      fi
    fi
  fi
  return 0
}

# scan_lockfile_secrets <file of "path<TAB>added line">
#
# gitleaks' default config allowlists dependency lockfiles BY PATH, so `gitleaks
# git` never looks inside package-lock.json, yarn.lock and friends — yet an auth
# token embedded in a private-registry URL is a classic lockfile leak. Their added
# lines go through `gitleaks stdin`, which has no path for the allowlist to match.
scan_lockfile_secrets() {
  local added="$1" rpt="$TMPD/gitleaks-lock.json" n
  [ -s "$added" ] || return 0
  LOCK_RE="$LOCKFILE_ERE" awk -F'\t' 'BEGIN { lre = ENVIRON["LOCK_RE"] } $1 ~ lre' "$added" > "$TMPD/lock-added"
  [ -s "$TMPD/lock-added" ] || return 0
  cut -f1 "$TMPD/lock-added" | LC_ALL=C sort -u > "$TMPD/lock-files"
  : > "$rpt"
  cut -f2- "$TMPD/lock-added" | gitleaks stdin --redact --no-banner --log-level error --exit-code 0 \
    -c "$GITLEAKS_CONFIG" --report-format json --report-path "$rpt" >/dev/null 2>&1
  n="$(grep -c '"RuleID"' "$rpt" 2>/dev/null)" || true
  n="$(num "${n:-0}")"
  if [ "${n:-0}" -gt 0 ]; then
    grep -o '"RuleID": *"[^"]*"' "$rpt" | sed 's/.*: *"//; s/"$//' | sort | uniq -c \
      | awk '{ printf "%s%s x%s", (NR > 1 ? ", " : ""), $2, $1 }' > "$TMPD/gl-lock-rules"
    block gitleaks "$n secret(s) in added lockfile lines [$(cat "$TMPD/gl-lock-rules")] in: $(join_lines "$TMPD/lock-files") — rotate anything real"
  fi
  return 0
}

# diff_to_added — stdin: a unified diff; stdout: "path<TAB>added line".
diff_to_added() {
  awk '
    /^\+\+\+ / { f = $0; sub(/^\+\+\+ ("?b\/)?/, "", f); sub(/"$/, "", f); next }
    /^\+/      { print f "\t" substr($0, 2) }
  '
}

# run_gitleaks <label> <gitleaks args...>
run_gitleaks() {
  local label="$1" rpt="$TMPD/gitleaks.json" rc n
  shift
  : > "$rpt"
  gitleaks git "$@" --redact --no-banner --log-level error --exit-code 1 \
    -c "$GITLEAKS_CONFIG" --report-format json --report-path "$rpt" . >/dev/null 2>"$TMPD/gitleaks.err"
  rc=$?
  n="$(grep -c '"RuleID"' "$rpt" 2>/dev/null)" || true
  n="$(num "${n:-0}")"
  if [ "${n:-0}" -gt 0 ]; then
    grep -o '"RuleID": *"[^"]*"' "$rpt" | sed 's/.*: *"//; s/"$//' | sort | uniq -c \
      | awk '{ printf "%s%s x%s", (NR > 1 ? ", " : ""), $2, $1 }' > "$TMPD/gl-rules"
    grep -o '"File": *"[^"]*"' "$rpt" | sed 's/.*: *"//; s/"$//' | sort -u > "$TMPD/gl-files"
    block gitleaks "$n secret(s) in $label [$(cat "$TMPD/gl-rules")] in: $(join_lines "$TMPD/gl-files") — rotate anything real; deleting it later does not unpublish it"
  elif [ "$rc" -ne 0 ]; then
    block gitleaks-error "gitleaks failed (exit $rc) so $label was NOT scanned: $(head -c 300 "$TMPD/gitleaks.err" | tr '\n' ' ')"
  fi
  [ -f .gitleaksignore ] && warn gitleaksignore ".gitleaksignore present — findings it lists are not reported by gitleaks"
  return 0
}

# --- pre-commit -----------------------------------------------------------------
cmd_pre_commit() {
  local names="$TMPD/staged-names" raw="$TMPD/staged-raw" author
  git diff --cached --name-only --no-renames --diff-filter=ACMR > "$names" 2>/dev/null
  git diff --cached --raw --no-abbrev --no-renames --diff-filter=ACMR > "$raw" 2>/dev/null
  [ -s "$names" ] || return 0

  # Already public? Then personal data is a BLOCK now rather than a WARN now and
  # a blocked push later. See origin_is_public for why UNKNOWN stays lenient.
  # scan-tree sets this itself and must keep its own value.
  if [ "$STRICT_PERSONAL" != 1 ] && origin_is_public; then
    STRICT_PERSONAL=1
    say "${C_DIM}security-gate: origin is PUBLIC — personal data blocks this commit${C_RST}"
  fi

  check_names "$names"
  check_private_dir "$names"

  # Sizes of the STAGED blobs, one cat-file process for all of them.
  awk -F'\t' '{ split($1, m, " "); print m[4] "\t" $2 }' "$raw" > "$TMPD/shas"
  cut -f1 "$TMPD/shas" | git cat-file --batch-check='%(objectsize)' 2>/dev/null > "$TMPD/sizes"
  paste "$TMPD/sizes" "$TMPD/shas" | awk -F'\t' -v max="$MAX_FILE_BYTES" '$1+0 > max { print $3 " (" int($1/1048576) " MB)" }' > "$TMPD/big"
  [ -s "$TMPD/big" ] && block large-file "over 50 MB — keep media and datasets outside git: $(join_lines "$TMPD/big")"

  if require_gitleaks; then
    run_gitleaks "staged changes" --staged
  fi

  git diff --cached -U0 --no-color --no-ext-diff --no-renames --diff-filter=ACMR 2>/dev/null | diff_to_added > "$TMPD/added"
  command -v gitleaks >/dev/null 2>&1 && scan_lockfile_secrets "$TMPD/added"
  scan_added "$TMPD/added"

  author="$(git var GIT_AUTHOR_IDENT 2>/dev/null | sed -E 's/.*<([^>]*)>.*/\1/')"
  if [ -n "$author" ] && ! printf '%s\n' "$author" | grep -qE "$NOREPLY_RE"; then
    warn author-email "this commit's author address is not a GitHub noreply address; pushing it to a public repo will be blocked"
  fi
  return 0
}

# --- pre-push -------------------------------------------------------------------
cmd_pre_push() {
  local remote="${1:-}" url="${2:-}" vis lref lsha rref rsha range_log names n any=0 name
  vis="$(remote_visibility "$url")"
  case "$vis" in PRIVATE) STRICT_PERSONAL=0 ;; *) STRICT_PERSONAL=1 ;; esac
  say "${C_DIM}security-gate: push to ${remote:-?} — remote visibility: $vis$( [ "$vis" = UNKNOWN ] && printf ' (treated as public)')${C_RST}"

  # A push by URL rather than remote name: find the name, so already-pushed
  # commits can be excluded. Failing that, the whole branch is scanned.
  if ! git config --get "remote.$remote.url" >/dev/null 2>&1; then
    for name in $(git remote 2>/dev/null); do
      [ "$(git config --get "remote.$name.url")" = "$url" ] && { remote="$name"; break; }
    done
  fi

  # shellcheck disable=SC2034 # lref/rref document git's stdin format
  while read -r lref lsha rref rsha; do
    [ -n "${lsha:-}" ] || continue
    is_zero_sha "$lsha" && continue                        # branch deletion
    if ! is_zero_sha "$rsha" && git cat-file -e "$rsha^{commit}" 2>/dev/null; then
      range_log="$rsha..$lsha"
    else
      range_log="$lsha --not --remotes=$remote"            # new branch, or remote tip unknown here
    fi
    # shellcheck disable=SC2086 # range_log is deliberately word-split
    n="$(num "$(git rev-list $range_log 2>/dev/null | wc -l)")"
    [ "${n:-0}" -gt 0 ] || continue
    any=1
    say "${C_DIM}  scanning $n commit(s) for $rref${C_RST}"

    names="$TMPD/push-names"
    # shellcheck disable=SC2086
    git log --format= --name-only --no-renames --diff-filter=ACMR $range_log 2>/dev/null | LC_ALL=C sort -u | grep -v '^$' > "$names"
    check_names "$names"
    check_private_dir "$names"

    # shellcheck disable=SC2086
    git rev-list --objects $range_log 2>/dev/null \
      | git cat-file --batch-check='%(objecttype)	%(objectsize)	%(rest)' 2>/dev/null \
      | awk -F'\t' -v max="$MAX_FILE_BYTES" '$1 == "blob" && $2+0 > max { print $3 " (" int($2/1048576) " MB)" }' \
      | LC_ALL=C sort -u > "$TMPD/big"
    [ -s "$TMPD/big" ] && block large-file "over 50 MB in pushed history — keep media and datasets outside git: $(join_lines "$TMPD/big")"

    if require_gitleaks; then
      run_gitleaks "$n pushed commit(s)" --log-opts="$range_log"
    fi

    # shellcheck disable=SC2086
    git log -p -U0 --no-color --no-ext-diff --no-merges --no-renames --diff-filter=ACMR --format= $range_log 2>/dev/null \
      | diff_to_added > "$TMPD/added"
    command -v gitleaks >/dev/null 2>&1 && scan_lockfile_secrets "$TMPD/added"
    scan_added "$TMPD/added"

    # shellcheck disable=SC2086
    git log --format='%ae%n%ce' $range_log 2>/dev/null | LC_ALL=C sort -u | grep -vE "$NOREPLY_RE" | grep -v '^$' > "$TMPD/ids" || true
    if [ -s "$TMPD/ids" ]; then
      personal author-email "$(num "$(wc -l < "$TMPD/ids")") non-noreply author/committer address(es) on pushed commits — a public repo publishes them permanently"
    fi
  done
  [ "$any" = 1 ] || say "${C_DIM}  nothing new to scan${C_RST}"
  return 0
}

# --- scan-tree --------------------------------------------------------------------
# Everything `git add -A` would commit right now, staged into a throwaway index
# so the real index is untouched. The check to run before a repo's first commit.
cmd_scan_tree() {
  local idx="$TMPD/index"
  [ -f "$(git rev-parse --git-path index)" ] && cp "$(git rev-parse --git-path index)" "$idx"
  GIT_INDEX_FILE="$idx"; export GIT_INDEX_FILE
  git add -A >/dev/null 2>&1 || { say "scan-tree: git add -A failed in a temporary index"; exit 2; }
  STRICT_PERSONAL=1
  cmd_pre_commit
  unset SECURITY_GATE_BYPASS
}

# --- status ---------------------------------------------------------------------
cmd_status() {
  local bad=0 v cmd gitpath
  ok()  { printf '  %sok%s    %s\n' "$C_BOLD" "$C_RST" "$1"; }
  nok() { printf '  %sFAIL%s  %s\n' "$C_RED" "$C_RST" "$1"; bad=1; }
  printf 'security gate status\n'

  gitpath="$(command -v git)"
  v="$(git version 2>/dev/null | awk '{print $3}')"
  case "$v" in
    2.5[4-9]*|2.[6-9][0-9]*|[3-9].*) ok "git $v at $gitpath supports config-based hooks" ;;
    *) nok "git $v at $gitpath is too old for config-based hooks (need 2.54+); the gate does not run" ;;
  esac
  [ "$gitpath" = "/usr/bin/git" ] && nok "/usr/bin/git (Apple) is first on PATH — it ignores the gate; put /opt/homebrew/bin first"

  for h in commit:pre-commit push:pre-push; do
    cmd="$(git config --global --get "hook.security-gate-${h%%:*}.command" 2>/dev/null)"
    if [ -n "$cmd" ] && [ "$(git config --global --get "hook.security-gate-${h%%:*}.event")" = "${h#*:}" ]; then
      ok "hook.security-gate-${h%%:*} registered for ${h#*:}"
    else
      nok "hook.security-gate-${h%%:*} is not registered in ~/.gitconfig for ${h#*:}"
    fi
    [ "$(git config --get "hook.security-gate-${h%%:*}.enabled" 2>/dev/null)" = "false" ] \
      && nok "hook.security-gate-${h%%:*} is disabled (enabled=false) in this repo's config"
  done

  if command -v gitleaks >/dev/null 2>&1; then ok "gitleaks $(gitleaks version 2>/dev/null)"; else nok "gitleaks not installed"; fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    ok "gh authenticated (remote visibility lookups work)"
  else
    nok "gh missing or not authenticated — every push is treated as public"
  fi
  if [ -f "$PERSONAL_PATTERNS_FILE" ]; then ok "private personal-patterns list present"
  else nok "private personal-patterns list missing ($PERSONAL_PATTERNS_FILE)"; fi
  if git -C "$DOTFILES_DIR" check-ignore -q private/x 2>/dev/null; then ok "dotfiles/private/ is gitignored"
  else nok "dotfiles/private/ is NOT gitignored"; fi
  [ -f "$BYPASS_LOG" ] && printf '  %sinfo%s  %s bypass(es) logged in %s\n' "$C_DIM" "$C_RST" "$(num "$(wc -l < "$BYPASS_LOG")")" "$BYPASS_LOG"
  return "$bad"
}

# --- verdict ----------------------------------------------------------------------
finish() {
  local event="$1" reason="${SECURITY_GATE_BYPASS:-}" top
  if [ "$N_BLOCK" -gt 0 ]; then
    if [ "$event" != scan-tree ] && [ "${#reason}" -ge 10 ]; then
      top="$(git rev-parse --show-toplevel 2>/dev/null)"
      mkdir -p "$(dirname "$BYPASS_LOG")" 2>/dev/null
      printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$top" "$event" "${RULES_HIT# }" \
        "$(printf '%s' "$reason" | tr '\t\n' '  ')" >> "$BYPASS_LOG"
      chmod 600 "$BYPASS_LOG" 2>/dev/null
      say "${C_YEL}${C_BOLD}security-gate: BYPASSED${C_RST} $N_BLOCK blocking finding(s) — reason logged to $BYPASS_LOG"
      exit 0
    fi
    [ -n "$reason" ] && [ "$event" != scan-tree ] && say "SECURITY_GATE_BYPASS was set but the reason is under 10 characters — not accepted."
    say ""
    say "${C_RED}${C_BOLD}security-gate: $event BLOCKED${C_RST} — $N_BLOCK blocking, $N_WARN warning(s)."
    if [ "$event" != scan-tree ]; then
      say "  Fix the findings above (git restore --staged <file>; move values to env vars)."
      say "  Genuine false positive in personal data: add 'security-gate:allow' to that line."
      say "  Deliberate override, logged:  SECURITY_GATE_BYPASS=\"<why>\" git ${event#pre-} ..."
      say "  Policy: $DOTFILES_DIR/docs/policy/security-and-privacy.md"
    fi
    exit 1
  fi
  [ "$N_WARN" -gt 0 ] && say "${C_DIM}security-gate: $event passed with $N_WARN warning(s)${C_RST}"
  exit 0
}

main() {
  local event="${1:-}"
  [ $# -gt 0 ] && shift
  case "$event" in
    status) cmd_status; exit $? ;;
    pre-commit|pre-push|scan-tree) ;;
    *) say "usage: gate.sh pre-commit | pre-push <remote> <url> | scan-tree | status"; exit 2 ;;
  esac
  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/security-gate.XXXXXX")" || { say "security-gate: cannot create temp dir"; exit 1; }
  cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
  case "$event" in
    pre-commit) cmd_pre_commit ;;
    pre-push)   cmd_pre_push "$@" ;;
    scan-tree)  cmd_scan_tree ;;
  esac
  finish "$event"
}

main "$@"
