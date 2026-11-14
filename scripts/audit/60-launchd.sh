#!/usr/bin/env bash
#
# 60-launchd.sh — does the launchd register match what is installed?
#
# Every launchd install, change or removal is recorded in one register (D69):
# a markdown table in the private repo, one row per agent in ~/Library/LaunchAgents,
# ours and third-party. Plists come from several repos and some apps install
# their own, so without a check the register drifts the first time someone forgets.
#
# Register rows look like:  | `<label>` | yes|no | trigger | runs | `<plist source>` | ... |
# Column 2 says whether it should be installed. Column 5 is the plist's source
# (a path, or "app" for one an installer wrote); a source holding @PLACEHOLDERS@
# is a template and is not compared byte for byte.
#
# Read-only: reads plists and the register, writes nothing.

audit_launchd() {
  local CAT=launchd
  hdr "launchd register"
  local reg="${LAUNCHD_REGISTER:-$DEV_ROOT/dotfiles/private/registers/launchd.md}"
  local dir="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
  local p label row want src

  if [ ! -f "$reg" ]; then
    finding WARN "$CAT" "-" launchd-no-register "no launchd register at $reg"
    return 0
  fi

  # label<TAB>installed<TAB>source, one per register row
  local rows
  rows="$(awk -F'|' '/^\| *`[^`]+`/ {
      l=$2; i=$3; s=$6
      gsub(/[` ]/, "", l); gsub(/ /, "", i); gsub(/^ +| +$/, "", s); gsub(/`/, "", s)
      print l "\t" tolower(i) "\t" s }' "$reg")"

  for p in "$dir"/*.plist; do
    [ -e "$p" ] || continue
    label="$(basename "$p" .plist)"
    row="$(printf '%s\n' "$rows" | awk -F'\t' -v l="$label" '$1 == l')"
    if [ -z "$row" ]; then
      finding WARN "$CAT" "$label" launchd-unregistered "installed in $dir but not in the register"
      continue
    fi
    want="$(printf '%s' "$row" | cut -f2)"
    [ "$want" = "no" ] && finding WARN "$CAT" "$label" launchd-installed-not-wanted \
      "installed, but the register says installed = no"
    src="$(printf '%s' "$row" | cut -f3)"
    src="${src/#\~/$HOME}"
    if [ -f "$src" ] && ! grep -q '@[A-Z_]*@' "$src" && ! cmp -s "$src" "$p"; then
      finding INFO "$CAT" "$label" launchd-source-drift "installed plist differs from its source $src"
    fi
  done

  while IFS="$(printf '\t')" read -r label want src; do
    [ -n "$label" ] || continue
    if [ "$want" = "yes" ] && [ ! -e "$dir/$label.plist" ]; then
      finding WARN "$CAT" "$label" launchd-not-installed "the register says installed = yes, but $dir/$label.plist is missing"
    fi
  done <<EOF
$rows
EOF
  return 0
}
