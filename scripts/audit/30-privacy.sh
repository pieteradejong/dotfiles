#!/usr/bin/env bash
#
# 30-privacy.sh — what has been committed that should not have been?
#
# Implements the CLAUDE.md § Security & privacy checklist as checks.
#
# TWO RULES THIS FILE OBEYS, and you must keep obeying if you add a check:
#
#   1. TRACKED FILES ONLY. Everything works from `git ls-files`. An untracked
#      .env sitting in a working tree is correct and normal; a *committed* one
#      is the incident. Scanning the working tree would bury the real signal
#      under every project's local config.
#
#   2. NEVER PRINT THE MATCHED VALUE. Findings name the file and the rule that
#      fired - "creds/prod.json - matched rule: service-account-json" - and
#      stop there. The report is written to disk and may be read on a screen,
#      pasted into a chat, or committed by accident; it must not become a
#      second copy of the secret. This is why nothing here uses `grep` without
#      -l or -q.
#
# PERFORMANCE, AND WHY IT IS A CORRECTNESS ISSUE HERE:
# An earlier version ran `git ls-files` once per rule (17x per repo) and read
# every result through a `< <(...)` process substitution. Across 91 repos that
# left thousands of unreaped background processes and the shell eventually
# could not fork at all - which showed up as `Bus error: 10` at the end of the
# run and, worse, as the disk module silently producing zero findings because
# every command substitution in it returned empty. So: the tracked-file list is
# built ONCE per repo into $flist, and results are passed through temp files
# with plain redirects rather than process substitution.
#
# NOTE ON THE FILENAME: dotfiles/.gitignore ignores *secret*, *token*,
# *password*, *credential* and *api_key*. Naming this file 30-secrets.sh would
# make git silently refuse to track it. See docs/dev-audit.md § Gotchas.

# TRACKED_FILE_RULES, CONTENT_RULES, SECRETISH_RE, EMAIL_RE, HOMEPATH_RE,
# EMAIL_PLACEHOLDER_RE and is_example_path() live in security/patterns.sh, shared
# with the commit/push gate so the two can never disagree about what is a secret.
# shellcheck source-path=SCRIPTDIR/../../security
# shellcheck source=patterns.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/security/patterns.sh"

# num <string> - keep only digits, default 0.
#
# `grep -c` PRINTS its count and EXITS 1 when the count is zero. So the
# idiomatic-looking `n="$(... | grep -c X || echo 0)"` yields the two-line
# string "0\n0", and the next `[ "$n" -gt 0 ]` dies with "integer expression
# expected". That is not a cosmetic error: on 2026-09-07 it silently discarded
# every gitleaks finding across 115 repos while the run still exited 0.
#
# Every count in this file goes through here.
num() { printf '%s' "$1" | tr -dc '0-9' | head -c 12; }

audit_privacy() {
  # Category for every finding below. Declared here, not at file scope:
  # dev-audit.sh sources all modules before running any, so a global would be
  # overwritten by whichever module was sourced last. `local` is dynamically
  # scoped in bash, so the check_* helpers still see it.
  local CAT=privacy
  hdr "Privacy and secrets (tracked files only)"
  local repo name flist flist0 res
  # Two forms of the same list, built once per repo: NUL-separated for
  # `xargs -0` (BSD xargs has no -d and no -r, so -0 is the portable spelling)
  # and newline-separated for shell `while read` loops.
  flist="$(mktemp)"; flist0="$(mktemp)"; res="$(mktemp)"

  while IFS= read -r repo; do
    name="$(repo_name "$repo")"
    is_skipped "$name" >/dev/null && continue

    # ONE ls-files per repo, reused by every check below. Newline-separated:
    # a tracked path containing a newline would be pathological, and git
    # quotes those by default anyway.
    git_ro "$repo" ls-files -z > "$flist0" 2>/dev/null || : > "$flist0"
    [ -s "$flist0" ] || continue
    tr '\0' '\n' < "$flist0" > "$flist"

    check_tracked_filenames "$repo" "$name" "$flist"
    check_tracked_content   "$repo" "$name" "$flist0" "$res"
    check_secretish         "$repo" "$name" "$flist0" "$res"
    check_personal_data     "$repo" "$name" "$flist0" "$res"
    check_ssh_config        "$repo" "$name" "$flist"
    check_committer_email   "$repo" "$name"
    [ "${SCAN_HISTORY:-0}" = "1" ] && check_history "$repo" "$name" "$flist" "$res"
  done < <(list_repos)

  rm -f "$flist" "$flist0" "$res"

  if command -v gitleaks >/dev/null 2>&1; then
    run_gitleaks
  else
    finding INFO "$CAT" "-" gitleaks-absent "gitleaks not installed; content rules above are the fallback"
  fi
}

# --- gitleaks ----------------------------------------------------------------
# The 7 CONTENT_RULES above are a hand-maintained fallback. They do not cover
# Anthropic, Stripe, Twilio, SendGrid, HuggingFace, database URLs with embedded
# passwords, JWTs, or generic high-entropy strings; gitleaks' default ruleset
# does. --redact is mandatory, not stylistic: it is what keeps this module's
# "never print the matched value" rule true for output we do not format
# ourselves. Without SCAN_HISTORY this stays on the working tree (--no-git),
# matching the tracked-files-only posture of everything above.
run_gitleaks() {
  local repo name n args rpt gsz TIMEOUT_BIN
  TIMEOUT_BIN=""
  command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN=timeout
  [ -z "$TIMEOUT_BIN" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN=gtimeout
  # Escape hatch for the full-workspace fork-exhaustion test, which exercises
  # the shell and does not need a ~10 minute scanner pass to do it. Not a user
  # facing flag: a real run must never silently skip the scanner.
  if [ "${DEV_AUDIT_NO_GITLEAKS:-0}" = "1" ]; then
    note "gitleaks skipped (DEV_AUDIT_NO_GITLEAKS=1)"
    return 0
  fi
  note "gitleaks present - scanning ($([ "${SCAN_HISTORY:-0}" = "1" ] && echo "full history" || echo "current tree"))"
  # gitleaks 8.30 refuses `--report-path /dev/stdout` outright ("Report path is
  # not writable"), so it must write to a real file. Discovered only because a
  # test asserted the fixture secret WAS found - without it the tool reported a
  # clean workspace because the scanner had produced nothing at all.
  rpt="$(mktemp)"
  while IFS= read -r repo; do
    name="$(repo_name "$repo")"
    is_skipped "$name" >/dev/null && continue
    # Scope controls, so a sweep that cannot finish whole can still finish
    # partly. A scanner killed halfway produces nothing; a scoped one produces
    # an answer plus a stated boundary, which is strictly more useful.
    if [ "${GITLEAKS_PUBLIC_ONLY:-0}" = "1" ] && [ "$(repo_visibility "$name")" != "PUBLIC" ]; then
      continue
    fi
    if [ -n "${GITLEAKS_MAX_GIT_MB:-}" ]; then
      gsz="$(num "$(du -sm "$repo/.git" 2>/dev/null | awk '{print $1}')")"
      if [ "${gsz:-0}" -gt "$GITLEAKS_MAX_GIT_MB" ]; then
        finding WARN "$CAT" "$name" gitleaks-skipped \
          ".git is ${gsz}MB, over GITLEAKS_MAX_GIT_MB=${GITLEAKS_MAX_GIT_MB} - NOT scanned"
        continue
      fi
    fi
    if [ "${SCAN_HISTORY:-0}" = "1" ]; then
      args="detect --redact --no-banner --exit-code 0 --report-format json"
    else
      args="detect --redact --no-banner --no-git --exit-code 0 --report-format json"
    fi
    : > "$rpt"
    # Bound each repo. A full-history scan of a multi-GB repo can run for many
    # minutes, and without a bound one repo stalls the entire sweep with no
    # indication of which. `timeout` is not on macOS by default; gtimeout is
    # (coreutils), so use whichever exists and skip the bound if neither does.
    # shellcheck disable=SC2086
    if [ -n "$TIMEOUT_BIN" ]; then
      "$TIMEOUT_BIN" "${GITLEAKS_TIMEOUT:-300}" gitleaks $args --report-path "$rpt" --source "$repo" >/dev/null 2>&1
      [ $? -eq 124 ] && finding WARN "$CAT" "$name" gitleaks-timeout \
        "gitleaks exceeded ${GITLEAKS_TIMEOUT:-300}s - this repo was NOT scanned"
    else
      gitleaks $args --report-path "$rpt" --source "$repo" >/dev/null 2>&1 || true
    fi
    # `grep -c` PRINTS 0 and EXITS 1 on no match; see num() above for why that
    # matters. Count RuleID occurrences rather than parsing JSON: no jq
    # dependency, and the value itself is already redacted by gitleaks.
    n="$(grep -c '"RuleID"' "$rpt" 2>/dev/null)" || true
    n="$(num "${n:-0}")"
    [ "${n:-0}" -gt 0 ] && finding FAIL "$CAT" "$name" gitleaks \
      "gitleaks reports $n finding(s) - rerun with 'gitleaks detect --redact --source $repo' to see them"
  done < <(list_repos)
  rm -f "$rpt"
  return 0
}

# --- generic secret-shaped assignments ---------------------------------------
check_secretish() {
  local repo="$1" name="$2" flist0="$3" res="$4" n f
  is_fork "$name" >/dev/null && return 0
  # -i because CLAUDE.md specifies the grep as case-insensitive, and the shape
  # this is looking for is overwhelmingly written DB_PASSWORD / API_KEY.
  ( cd "$repo" 2>/dev/null && xargs -0 grep -lIEi -- "$SECRETISH_RE" < "$flist0" ) > "$res" 2>/dev/null
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_example_path "$f" && continue
    n=$((n + 1))
  done < "$res"
  [ "$n" -gt 0 ] && finding WARN "$CAT" "$name" secret-assignment \
    "$n tracked file(s) assign a quoted literal to a key/secret/token/password name"
  return 0
}

# --- committer identity ------------------------------------------------------
# CLAUDE.md § Before pushing to a public repo: "git log on a public repo
# permanently publishes the committer's name and email to anyone, including
# scrapers... it can't be retroactively scrubbed from already-pushed history
# without rewriting it."
#
# That rule had no check. Every public repo here carries a real personal address
# on every commit, which is a deliberate choice for some projects and an
# accident in others - but it should at least be *reported* rather than assumed.
# Counted over the whole history, not just HEAD, because that is what is
# published. The address itself is never printed: the finding names the count.
check_committer_email() {
  local repo="$1" name="$2" vis sev total real
  vis="$(repo_visibility "$name")"
  case "$vis" in
    PUBLIC)  sev=FAIL ;;
    PRIVATE) sev=INFO ;;
    *)       sev=INFO ;;
  esac
  is_fork "$name" >/dev/null && return 0

  total="$(num "$(git_ro "$repo" log --format='%ae' 2>/dev/null | wc -l)")"
  [ "${total:-0}" -gt 0 ] || return 0
  real="$(git_ro "$repo" log --format='%ae' 2>/dev/null \
    | grep -cvE 'users\.noreply\.github\.com')" || true
  real="$(num "${real:-0}")"
  [ "${real:-0}" -gt 0 ] && finding "$sev" "$CAT" "$name" committer-email \
    "$real of $total commit(s) carry a non-noreply committer address"
  return 0
}

# --- history -----------------------------------------------------------------
# Everything else in this file reads HEAD. A secret that was committed and later
# deleted is gone from `git ls-files` and still fully present in history - and on
# a public repo it is still fetchable by anyone. That is the case that matters
# most, and until 2026-09-07 nothing here looked for it.
#
# Opt-in via --history because it walks every commit in every repo.
check_history() {
  local repo="$1" name="$2" flist="$3" res="$4" gone head_sorted line rule glob f n
  is_skipped "$name" >/dev/null && return 0
  # Same exclusion as check_tracked_filenames: a fork's history is upstream's.
  # peppol-commons' rotated PEPPOL truststores are public CA material and a
  # normal part of that project's history, not a finding about this workspace.
  is_fork "$name" >/dev/null && return 0

  # Every path ever added, at any point in history.
  git_ro "$repo" log --all --diff-filter=A --format='' --name-only 2>/dev/null \
    | LC_ALL=C sort -u | grep -v '^$' > "$res" 2>/dev/null || : > "$res"
  [ -s "$res" ] || return 0

  # Subtract the paths still in HEAD, which check_tracked_filenames already
  # covers. ONE `comm` against the cached HEAD list, not a `git ls-files
  # --error-unmatch` per path: a repo with a few thousand historical paths
  # would otherwise fork a git process per path, which is the exact failure
  # this file's header documents (thousands of unreaped children, then
  # `Bus error: 10` and silently empty results from later modules).
  # Temp files with plain redirects, not process substitution - same reason as
  # the header's note, and it keeps every path in this module consistent.
  gone="$(mktemp)"; head_sorted="$(mktemp)"
  LC_ALL=C sort -u "$flist" > "$head_sorted" 2>/dev/null || : > "$head_sorted"
  LC_ALL=C comm -23 "$res" "$head_sorted" > "$gone" 2>/dev/null || cp "$res" "$gone"
  rm -f "$head_sorted"

  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_example_path "$f" && continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rule="${line%%|*}"
      glob="${line#*|}"
      # shellcheck disable=SC2254 # $glob is deliberately a pattern
      case "$f" in
        $glob)
          finding FAIL "$CAT" "$name" "history-$rule" \
            "removed from HEAD but still in history: $f"
          n=$((n + 1)); break ;;
      esac
    done <<< "$TRACKED_FILE_RULES"
  done < "$gone"
  rm -f "$gone"
  return 0
}

# --- committed files that should never be committed -------------------------
# Pure shell glob matching against the cached file list: zero forks.
check_tracked_filenames() {
  local repo="$1" name="$2" flist="$3" line rule glob f
  # A fork's tracked certificates are upstream's choice, not ours. CLAUDE.md
  # says never reshape a fork; flagging peppol-commons' public PEPPOL
  # truststores on every run is noise that hides the real findings.
  is_fork "$name" >/dev/null && return 0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_example_path "$f" && continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rule="${line%%|*}"
      glob="${line#*|}"
      # shellcheck disable=SC2254 # $glob is deliberately a pattern
      case "$f" in
        $glob) finding FAIL "$CAT" "$name" "$rule" "tracked: $f"; break ;;
      esac
    done <<< "$TRACKED_FILE_RULES"
  done < "$flist"
}

# --- committed content -------------------------------------------------------
check_tracked_content() {
  local repo="$1" name="$2" flist0="$3" res="$4" line rule pat f
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rule="${line%%|*}"
    pat="${line#*|}"
    # grep -l: filenames only, never the matching line. -I: skip binaries.
    # Those two flags are what keep a secret out of the report.
    ( cd "$repo" 2>/dev/null && xargs -0 grep -lIE -- "$pat" < "$flist0" ) > "$res" 2>/dev/null
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      is_example_path "$f" && continue
      finding FAIL "$CAT" "$name" "$rule" "matched in: $f"
    done < "$res"
  done <<< "$CONTENT_RULES"
}

# --- personal data in public repos ------------------------------------------
# CLAUDE.md § Before pushing to a public repo: home paths under /Users/<name>/,
# emails, internal hostnames. These only matter when the repo is public, so
# without --github (visibility unknown) they soften to INFO rather than guess.
check_personal_data() {
  local repo="$1" name="$2" flist0="$3" res="$4" vis sev n f
  vis="$(repo_visibility "$name")"
  case "$vis" in
    PUBLIC)  sev=FAIL ;;
    PRIVATE) return 0 ;;
    *)       sev=INFO ;;
  esac

  # Home paths.
  ( cd "$repo" 2>/dev/null && xargs -0 grep -lIE -- "$HOMEPATH_RE" < "$flist0" ) > "$res" 2>/dev/null
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_example_path "$f" && continue
    n=$((n + 1))
  done < "$res"
  [ "$n" -gt 0 ] && finding "$sev" "$CAT" "$name" home-path "$n tracked file(s) contain an absolute /Users/ path"

  # Emails. Two passes: cheap grep -l to find candidates, then one grep per
  # candidate to discard files whose only matches are placeholders. The
  # address is counted, never printed.
  ( cd "$repo" 2>/dev/null && xargs -0 grep -lIE -- "$EMAIL_RE" < "$flist0" ) > "$res" 2>/dev/null
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_example_path "$f" && continue
    if grep -oIE "$EMAIL_RE" "$repo/$f" 2>/dev/null | grep -qvE "$EMAIL_PLACEHOLDER_RE"; then
      n=$((n + 1))
    fi
  done < "$res"
  [ "$n" -gt 0 ] && finding "$sev" "$CAT" "$name" email "$n tracked file(s) contain a real email address"
  return 0
}

# --- published ssh config ----------------------------------------------------
# A tracked ssh config in a PUBLIC repo hands over the host, the port and the
# exact account name, leaving only the key. CLAUDE.md § Before pushing to a
# public repo names "internal hostnames" for exactly this reason.
#
# Placeholder configs (example.com, your-server, user@host) are the normal,
# correct thing to publish and are not flagged.
#
# This check exists because the first run of this tool against dotfiles itself
# missed a real ssh/config with a live hostname, account and non-standard port.
check_ssh_config() {
  local repo="$1" name="$2" flist="$3" vis sev f hosts users
  vis="$(repo_visibility "$name")"
  case "$vis" in
    PUBLIC)  sev=FAIL ;;
    PRIVATE) return 0 ;;
    *)       sev=WARN ;;
  esac

  while IFS= read -r f; do
    case "$f" in
      ssh/config|*/ssh/config|.ssh/config|*/.ssh/config|ssh_config|*/ssh_config) ;;
      *) continue ;;
    esac
    hosts="$(num "$(grep -icE '^[[:space:]]*HostName[[:space:]]+' "$repo/$f" 2>/dev/null)")"
    [ "$hosts" -gt 0 ] && hosts="$(num "$(grep -iE '^[[:space:]]*HostName[[:space:]]+' "$repo/$f" 2>/dev/null \
        | grep -vicE 'example|your-|placeholder|remote-server|work-server|<|localhost')")"
    users="$(num "$(grep -iE '^[[:space:]]*User[[:space:]]+' "$repo/$f" 2>/dev/null \
        | grep -vicE 'example|your-|placeholder|[[:space:]]user$|<')")"
    if [ "${hosts:-0}" -gt 0 ] || [ "${users:-0}" -gt 0 ]; then
      finding "$sev" "$CAT" "$name" ssh-config \
        "tracked $f exposes ${hosts:-0} real hostname(s) and ${users:-0} account name(s)"
    fi
  done < "$flist"
  return 0
}
