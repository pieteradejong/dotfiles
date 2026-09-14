#!/usr/bin/env bash
#
# visibility.sh — is this push going somewhere public?
#
# Sourced by security/gate.sh. Answers PUBLIC, PRIVATE or UNKNOWN for a remote
# URL. The gate treats UNKNOWN exactly like PUBLIC: when we cannot tell, we
# assume the whole world can read it.
#
# Cached per repo so a push costs one `gh` call a day at most:
#   PUBLIC  answers are kept 24h
#   PRIVATE answers are kept  1h, so a repo flipped to public is noticed quickly
#
# bash 3.2 compatible.

SECURITY_GATE_CACHE_DIR="${SECURITY_GATE_CACHE_DIR:-$HOME/.cache/security-gate}"

# gh_slug_from_url <url> — prints owner/repo for a GitHub remote, fails otherwise.
#
# Also accepts a local path containing /github.com/<owner>/<repo>(.git). That is
# how the gate's test suite simulates GitHub remotes with bare repos on disk. The
# visibility still comes from asking `gh`, so this cannot make a real remote look
# private; at worst a push to a local directory is judged by the GitHub repo of
# the same name, and a push to local disk publishes nothing.
gh_slug_from_url() {
  local u="$1" s
  case "$u" in
    git@github.com:*)          s="${u#git@github.com:}" ;;
    ssh://git@github.com/*)    s="${u#ssh://git@github.com/}" ;;
    https://github.com/*)      s="${u#https://github.com/}" ;;
    https://*@github.com/*)    s="${u#*@github.com/}" ;;
    */github.com/*/*)          s="${u##*/github.com/}" ;;
    *) return 1 ;;
  esac
  s="${s%/}"; s="${s%.git}"
  case "$s" in
    */*/*|/*|*/) return 1 ;;
    */*) printf '%s' "$s" ;;
    *) return 1 ;;
  esac
}

# with_timeout <seconds> <cmd...> — macOS has no `timeout`; perl is always there.
with_timeout() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# remote_visibility <url> — prints PUBLIC, PRIVATE or UNKNOWN.
remote_visibility() {
  local url="$1" slug cache now line vis ts ttl tmp
  slug="$(gh_slug_from_url "$url")" || { printf 'UNKNOWN'; return 0; }
  cache="$SECURITY_GATE_CACHE_DIR/visibility.tsv"
  now="$(date +%s)"

  if [ -f "$cache" ]; then
    line="$(LC_ALL=C grep -m1 "^${slug}	" "$cache" 2>/dev/null)" || line=""
    if [ -n "$line" ]; then
      vis="$(printf '%s' "$line" | cut -f2)"
      ts="$(printf '%s' "$line" | cut -f3)"
      case "$vis" in PUBLIC) ttl=86400 ;; PRIVATE) ttl=3600 ;; *) ttl=0 ;; esac
      case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
      if [ $((now - ts)) -lt "$ttl" ]; then
        printf '%s' "$vis"; return 0
      fi
    fi
  fi

  command -v gh >/dev/null 2>&1 || { printf 'UNKNOWN'; return 0; }
  vis="$(with_timeout 10 gh repo view "$slug" --json visibility --jq .visibility 2>/dev/null)" || vis=""
  case "$vis" in
    PUBLIC|PRIVATE) ;;
    *) printf 'UNKNOWN'; return 0 ;;   # INTERNAL, offline, no auth, no access
  esac

  mkdir -p "$SECURITY_GATE_CACHE_DIR" 2>/dev/null
  tmp="$cache.$$"
  { [ -f "$cache" ] && LC_ALL=C grep -v "^${slug}	" "$cache"; printf '%s\t%s\t%s\n' "$slug" "$vis" "$now"; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$cache" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  printf '%s' "$vis"
}
