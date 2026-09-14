#!/bin/bash
#
# security-audit.sh — the weekly full security & privacy audit.
#
# Runs every Sunday 10:00 from launchd (macos/com.pieterdejong.securityaudit.plist),
# or by hand. One report per run, counts in a macOS notification, exit 1 on any
# FAIL. Documented in docs/maintenance.md; the rules it checks are in
# docs/policy/security-and-privacy.md.
#
#   1. gate       the commit/push gate is installed and intact (gate.sh status)
#   2. dotaudit   every local repo: secrets, personal data, policy, git hygiene
#                 (+ full history on the first run of each month)
#   3. github     every owned repo has secret scanning, push protection, alerts
#   4. uncloned   repos on GitHub with no local clone: mirrored to a local cache
#                 and scanned (gitleaks over full history + private values)
#   5. bypasses   uses of SECURITY_GATE_BYPASS in the last 7 days
#   6. loose      credential-shaped files outside any repo, or untracked and
#                 unignored inside one (one `git add -A` from publication)
#   7. account    SSH keys on the GitHub account, token scopes
#
# Usage: security-audit.sh [--quick] [--history] [--no-notify] [--out DIR]
#   --quick      skip steps 2 and 4 (the slow ones)
#   --history    force dotaudit's full-history scan
#   --no-notify  no macOS notification
#
# READ-ONLY toward every repo. Writes only its report (~/dev/audit-reports/,
# never inside a git repo) and the mirror cache (~/.cache/security-audit/).

set -u
# Appended, not prepended: launchd already supplies a PATH (see the plist), and
# a caller's PATH — including a test's stub gh — must win.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../security/patterns.sh
. "$DOTFILES_DIR/security/patterns.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../security/lib/visibility.sh
. "$DOTFILES_DIR/security/lib/visibility.sh"

DEV_ROOT="${DEV_ROOT:-$HOME/dev}"
OUT_DIR="$DEV_ROOT/audit-reports"
CACHE_DIR="$HOME/.cache/security-audit"
LOG_DIR="$HOME/Library/Logs/security-audit"
OWNER=pieteradejong
MIRROR_MAX_MB=1000
SKIPLIST_FILE="${SKIPLIST_FILE:-$DOTFILES_DIR/private/audit/skiplist.conf}"
PERSONAL_PATTERNS_FILE="$DOTFILES_DIR/private/security/personal-patterns.conf"
BYPASS_LOG="${SECURITY_GATE_BYPASS_LOG:-$HOME/.local/state/security-gate/bypass.log}"
QUICK=0; FORCE_HISTORY=0; NOTIFY=1

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)     QUICK=1; shift ;;
    --history)   FORCE_HISTORY=1; shift ;;
    --no-notify) NOTIFY=0; shift ;;
    --out)       OUT_DIR="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '3,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

STAMP="$(date +%Y-%m-%d)"
mkdir -p "$OUT_DIR" "$LOG_DIR" 2>/dev/null || { echo "cannot create $OUT_DIR" >&2; exit 2; }
if git --no-optional-locks -C "$OUT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "refusing to write the report into a git repo: $OUT_DIR" >&2
  exit 3
fi
REPORT="$OUT_DIR/security-audit-$STAMP.md"
BODY="$(mktemp)"; WORK="$(mktemp -d)"
trap 'rm -rf "$BODY" "$WORK"' EXIT

N_FAIL=0; N_WARN=0; N_INFO=0
section() { printf '\n## %s\n\n' "$1" >> "$BODY"; }
fail_() { N_FAIL=$((N_FAIL + 1)); printf -- '- **FAIL** %s\n' "$*" >> "$BODY"; }
warn_() { N_WARN=$((N_WARN + 1)); printf -- '- **WARN** %s\n' "$*" >> "$BODY"; }
info_() { N_INFO=$((N_INFO + 1)); printf -- '- %s\n' "$*" >> "$BODY"; }
num() { printf '%s' "$1" | tr -dc '0-9' | head -c 12; }
skip_names() { [ -f "$SKIPLIST_FILE" ] && grep -E '^skip:' "$SKIPLIST_FILE" | cut -d: -f2; }

# --- 1. gate -----------------------------------------------------------------------
section "1. Commit/push gate"
if "$DOTFILES_DIR/security/gate.sh" status > "$WORK/gate" 2>&1; then
  info_ "gate installed and intact"
else
  fail_ "gate status reports problems — every commit on this machine may be unprotected:"
  grep FAIL "$WORK/gate" | sed -E 's/\x1b\[[0-9;]*m//g; s/^[[:space:]]*/  - /' >> "$BODY"
fi

# --- 2. dotaudit ---------------------------------------------------------------------
section "2. Local repos (dotaudit)"
if [ "$QUICK" = 1 ]; then
  info_ "skipped (--quick)"
elif [ ! -f "$SKIPLIST_FILE" ]; then
  fail_ "private skip list missing ($SKIPLIST_FILE) — dotaudit refuses to run without it"
else
  hist=""
  if [ "$FORCE_HISTORY" = 1 ] || [ "$(date +%d | sed 's/^0//')" -le 7 ]; then hist="--history"; fi
  # shellcheck disable=SC2086
  GITLEAKS_TIMEOUT=600 GITLEAKS_MAX_GIT_MB=2000 \
    "$SCRIPT_DIR/dev-audit.sh" --github --quiet --out "$OUT_DIR" $hist > "$WORK/dotaudit" 2>&1
  rc=$?
  tsv="$OUT_DIR/findings-$STAMP.tsv"
  f="$(num "$(grep -c '^FAIL' "$tsv" 2>/dev/null)")"; w="$(num "$(grep -c '^WARN' "$tsv" 2>/dev/null)")"
  case "$rc" in
    0|1)
      info_ "scope: $([ -n "$hist" ] && echo 'HEAD + full history' || echo 'HEAD')"
      if [ "${f:-0}" -gt 0 ]; then fail_ "dotaudit: ${f} FAIL, ${w:-0} WARN — see $OUT_DIR/audit-$STAMP.md"
      elif [ "${w:-0}" -gt 0 ]; then warn_ "dotaudit: ${w} WARN — see $OUT_DIR/audit-$STAMP.md"
      else info_ "dotaudit: clean"; fi
      if [ "${f:-0}" -gt 0 ]; then
        cut -f4 "$tsv" | paste -d'\t' <(cut -f1 "$tsv") - | awk -F'\t' '$1 == "FAIL" { c[$2]++ } END { for (k in c) printf "  - %s x%d\n", k, c[k] }' | sort >> "$BODY"
      fi ;;
    *) fail_ "dotaudit did not complete (exit $rc): $(head -c 300 "$WORK/dotaudit" | tr '\n' ' ')" ;;
  esac
fi

# --- 3. github settings ----------------------------------------------------------------
section "3. GitHub repo settings"
"$SCRIPT_DIR/github-security-sweep.sh" --check --quiet --out "$OUT_DIR" > "$WORK/sweep" 2>&1
rc=$?
sweep_tsv="$OUT_DIR/github-security-$STAMP.tsv"
case "$rc" in
  0) info_ "every owned repo has the baseline settings ($(tail -2 "$WORK/sweep" | head -1))" ;;
  1) fail_ "$(num "$(grep -c 'would change' "$sweep_tsv" 2>/dev/null)") repo(s) missing secret scanning / push protection / Dependabot alerts — run: github-security-sweep.sh --apply"
     awk -F'\t' '$7 == "would change" { printf "  - %s (%s): %s\n", $1, $2, $6 }' "$sweep_tsv" >> "$BODY" ;;
  *) fail_ "settings sweep could not run (exit $rc): $(head -c 300 "$WORK/sweep" | tr '\n' ' ')" ;;
esac

# --- 4. uncloned repos --------------------------------------------------------------------
section "4. GitHub repos with no local clone"
if [ "$QUICK" = 1 ]; then
  info_ "skipped (--quick)"
elif ! command -v gh >/dev/null 2>&1 || ! command -v gitleaks >/dev/null 2>&1; then
  fail_ "gh and gitleaks are both required for this step"
else
  find "$DEV_ROOT" -maxdepth 5 \( -name node_modules -o -name .venv -o -name venv \) -prune -o -name .git -type d -print 2>/dev/null \
    | sed 's#/\.git$##' | while IFS= read -r r; do
        git --no-optional-locks -C "$r" config --get-regexp '^remote\..*\.url$' 2>/dev/null | awk '{print $2}'
      done | while IFS= read -r u; do gh_slug_from_url "$u" && echo; done | LC_ALL=C sort -u > "$WORK/local-slugs"
  gh repo list "$OWNER" --limit 1000 --json name,nameWithOwner,visibility,isFork,diskUsage \
    --jq '.[] | select(.isFork | not) | [.name, .nameWithOwner, .visibility, .diskUsage] | @tsv' > "$WORK/remote" 2>/dev/null
  skips=" $(skip_names | tr '\n' ' ') "
  mkdir -p "$CACHE_DIR/mirrors" && chmod 700 "$CACHE_DIR"
  [ -f "$PERSONAL_PATTERNS_FILE" ] && grep -vE '^[[:space:]]*(#|$)' "$PERSONAL_PATTERNS_FILE" > "$WORK/pp"
  scanned=0; n_uncloned=0
  while IFS="$(printf '\t')" read -r name slug vis kb; do
    grep -qxF "$slug" "$WORK/local-slugs" && continue
    case "$skips" in *" $name "*) continue ;; esac
    n_uncloned=$((n_uncloned + 1))
    if [ "$(( ${kb:-0} / 1024 ))" -gt "$MIRROR_MAX_MB" ]; then
      warn_ "$slug ($vis) is $(( kb / 1024 )) MB, over the ${MIRROR_MAX_MB} MB mirror cap — NOT scanned"; continue
    fi
    m="$CACHE_DIR/mirrors/$name.git"
    if [ -d "$m" ]; then
      git -C "$m" remote update --prune >/dev/null 2>&1 || { warn_ "$slug: mirror update failed — scanned stale copy"; }
    else
      gh repo clone "$slug" "$m" -- --mirror --quiet >/dev/null 2>&1 || { fail_ "$slug: could not mirror — NOT scanned"; continue; }
    fi
    scanned=$((scanned + 1))
    rpt="$WORK/gl.json"; : > "$rpt"
    with_timeout 600 gitleaks git --redact --no-banner --log-level error --exit-code 0 \
      -c "$DOTFILES_DIR/security/gitleaks.toml" --log-opts=--all --report-format json --report-path "$rpt" "$m" >/dev/null 2>&1 \
      || warn_ "$slug: gitleaks did not finish — results may be partial"
    n="$(num "$(grep -c '"RuleID"' "$rpt" 2>/dev/null)")"
    [ "${n:-0}" -gt 0 ] && fail_ "$slug ($vis): gitleaks reports ${n} secret(s) in history — rotate, then decide on the repo"
    if [ -s "$WORK/pp" ]; then
      n="$(num "$(git -C "$m" log -p --all --no-color 2>/dev/null | grep -cF -f "$WORK/pp")")"
      if [ "${n:-0}" -gt 0 ]; then
        if [ "$vis" = PUBLIC ]; then fail_ "$slug (PUBLIC): ${n} line(s) in history contain a private personal value"
        else warn_ "$slug (PRIVATE): ${n} line(s) in history contain a private personal value"; fi
      fi
    fi
  done < "$WORK/remote"
  info_ "$n_uncloned owned repo(s) not cloned locally; $scanned mirrored and scanned (cache: $CACHE_DIR/mirrors)"
fi

# --- 5. bypasses ------------------------------------------------------------------------------
section "5. Gate bypasses (last 7 days)"
if [ -f "$BYPASS_LOG" ]; then
  since="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  awk -F'\t' -v s="$since" '$1 >= s' "$BYPASS_LOG" > "$WORK/bypass"
  if [ -s "$WORK/bypass" ]; then
    warn_ "$(num "$(wc -l < "$WORK/bypass")") bypass(es) — confirm each reason still holds:"
    awk -F'\t' '{ printf "  - %s %s (%s) rules: %s — \"%s\"\n", $1, $2, $3, $4, $5 }' "$WORK/bypass" >> "$BODY"
  else
    info_ "none"
  fi
else
  info_ "none (no bypass log)"
fi

# --- 6. loose credential-shaped files -------------------------------------------------------------
section "6. Credential-shaped files outside version control"
skips=" $(skip_names | tr '\n' ' ') "
find "$DEV_ROOT" -maxdepth 5 \( -name node_modules -o -name .git -o -name .venv -o -name venv -o -name audit-reports \) -prune -o -type f \
  \( -iname '*recovery*code*' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name '*.ppk' \
     -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' -o -name '.env' -o -name '.env.*' \
     -o -iname '*credentials*.json' -o -name '*.kdbx' -o -name '.netrc' -o -name '.pypirc' \) -print 2>/dev/null \
  | LC_ALL=C sort > "$WORK/loose"
n_out=0; n_untracked=0
while IFS= read -r f; do
  rel="${f#"$DEV_ROOT"/}"
  is_example_path "$rel" && continue
  case "$rel" in *.pub) continue ;; esac
  skip=0; for s in $skips; do case "/$rel/" in */"$s"/*) skip=1 ;; esac; done
  [ "$skip" = 1 ] && continue
  d="$(dirname "$f")"
  if ! git --no-optional-locks -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail_ "outside any repo, no version control and no guard: $rel"; n_out=$((n_out + 1))
  elif ! git --no-optional-locks -C "$d" ls-files --error-unmatch "$(basename "$f")" >/dev/null 2>&1 \
       && ! git --no-optional-locks -C "$d" check-ignore -q "$(basename "$f")" 2>/dev/null; then
    warn_ "untracked and NOT ignored — one \`git add -A\` from being committed: $rel"; n_untracked=$((n_untracked + 1))
  fi
done < "$WORK/loose"
[ "$n_out" = 0 ] && [ "$n_untracked" = 0 ] && info_ "none"

# --- 7. account ---------------------------------------------------------------------------------------
section "7. GitHub account"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  keys="$(gh api user/keys --jq 'length' 2>/dev/null)"
  oldest="$(gh api user/keys --jq '[.[].created_at] | sort | first // "n/a"' 2>/dev/null)"
  info_ "SSH keys on the account: ${keys:-unknown} (oldest created ${oldest:-n/a}) — remove any you cannot place"
  scopes="$(gh auth status 2>&1 | sed -nE "s/.*Token scopes: //p" | head -1)"
  info_ "gh token scopes: ${scopes:-unknown}"
else
  fail_ "gh is not authenticated — GitHub steps could not run"
fi

# --- report -----------------------------------------------------------------------------------------
# shellcheck disable=SC2016 # the backticks are markdown code spans, not expansions
{
  printf '# Weekly security & privacy audit — %s\n\n' "$STAMP"
  printf '**%d FAIL · %d WARN · %d info** · generated %s by `dotfiles/scripts/security-audit.sh`%s\n\n' \
    "$N_FAIL" "$N_WARN" "$N_INFO" "$(date '+%Y-%m-%d %H:%M')" "$([ "$QUICK" = 1 ] && echo ' (--quick)')"
  printf 'What each section checks and what to do about a finding: `dotfiles/docs/maintenance.md`.\n'
  cat "$BODY"
} > "$REPORT"
chmod 600 "$REPORT" 2>/dev/null
printf '%s\t%d FAIL\t%d WARN\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$N_FAIL" "$N_WARN" "$REPORT" >> "$LOG_DIR/security-audit.log"
printf 'security audit: %d FAIL, %d WARN\nReport: %s\n' "$N_FAIL" "$N_WARN" "$REPORT"

if [ "$NOTIFY" = 1 ] && command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$N_FAIL FAIL, $N_WARN WARN — report in ~/dev/audit-reports\" with title \"Weekly security audit\"" >/dev/null 2>&1
fi

[ "$N_FAIL" -eq 0 ]
