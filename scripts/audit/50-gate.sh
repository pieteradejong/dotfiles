#!/usr/bin/env bash
#
# 50-gate.sh — is the commit/push security gate still in force?
#
# The gate (security/gate.sh) only protects commits made through git 2.54+
# with the two hooks registered in ~/.gitconfig. Each of those can quietly stop
# being true: a restored .gitconfig without the hook block, a repo whose local
# config sets hook.<name>.enabled=false, gitleaks uninstalled by a brew cleanup.
# This module reports each one, plus recent uses of the logged bypass.
#
# Read-only, like every module: config reads only, through git_ro.

audit_gate() {
  local CAT=gate
  hdr "Commit/push security gate"
  local h cmd ev v repo name n log

  for h in commit:pre-commit push:pre-push; do
    cmd="$(git config --global --get "hook.security-gate-${h%%:*}.command" 2>/dev/null)"
    ev="$(git config --global --get "hook.security-gate-${h%%:*}.event" 2>/dev/null)"
    if [ -z "$cmd" ] || [ "$ev" != "${h#*:}" ]; then
      finding FAIL "$CAT" "-" gate-not-registered \
        "hook.security-gate-${h%%:*} is not registered for ${h#*:} in the global git config"
    fi
  done

  v="$(git version 2>/dev/null | awk '{print $3}')"
  case "$v" in
    2.5[4-9]*|2.[6-9][0-9]*|[3-9].*) ;;
    *) finding FAIL "$CAT" "-" gate-git-too-old "git $v on PATH ignores config-based hooks (need 2.54+)" ;;
  esac

  command -v gitleaks >/dev/null 2>&1 \
    || finding FAIL "$CAT" "-" gate-no-gitleaks "gitleaks is not installed; the gate blocks every commit until it is"

  while IFS= read -r repo; do
    name="$(repo_name "$repo")"
    is_skipped "$name" >/dev/null && continue
    for h in commit push; do
      if [ "$(git_ro "$repo" config --local --get "hook.security-gate-$h.enabled")" = "false" ]; then
        finding WARN "$CAT" "$name" gate-disabled "repo-local config disables hook.security-gate-$h"
      fi
    done
  done < <(list_repos)

  log="${SECURITY_GATE_BYPASS_LOG:-$HOME/.local/state/security-gate/bypass.log}"
  if [ -f "$log" ]; then
    # ISO timestamps sort as strings, so "newer than a week" is a string compare.
    n="$(awk -F'\t' -v since="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
      '$1 >= since' "$log" | wc -l | tr -dc '0-9')"
    [ "${n:-0}" -gt 0 ] && finding WARN "$CAT" "-" gate-bypassed \
      "$n gate bypass(es) in the last 7 days — review the reasons in $log"
  fi
  return 0
}
