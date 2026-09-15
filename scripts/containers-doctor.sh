#!/usr/bin/env bash
#
# containers-doctor.sh — read-only check that this Mac runs containers the way
# docs/containers.md says: Colima started on demand, nothing left of Docker Desktop.
#
#   scripts/containers-doctor.sh           every check
#   scripts/containers-doctor.sh --quiet   problems only
#
# Exit: 0 no FAIL, 1 at least one FAIL, 2 bad argument. WARN never fails the run.
# Changes nothing. Every location can be overridden, which is how the tests run it:
#   APPS_DIR LAUNCH_DAEMONS_DIR HELPER_TOOLS_DIR LOCAL_BIN_DIR LAUNCH_AGENTS_DIR
#   DOCKER_CONFIG_DIR BREW_PLUGIN_DIR PG_CONFIG

set -u

# First Supabase CLI release containing supabase/cli PR #5820, which gives the
# supabase_vector container the right docker.sock under Colima (issue #5073).
# Checked with the GitHub compare API: v2.109.1 is behind that commit, v2.110.0 ahead.
MIN_SUPABASE="2.110.0"

APPS_DIR="${APPS_DIR:-/Applications}"
LAUNCH_DAEMONS_DIR="${LAUNCH_DAEMONS_DIR:-/Library/LaunchDaemons}"
HELPER_TOOLS_DIR="${HELPER_TOOLS_DIR:-/Library/PrivilegedHelperTools}"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-/usr/local/bin}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-$HOME/.docker}"
BREW_PLUGIN_DIR="${BREW_PLUGIN_DIR:-/opt/homebrew/lib/docker/cli-plugins}"
PG_CONFIG="${PG_CONFIG:-/opt/homebrew/opt/postgresql@17/bin/pg_config}"

QUIET=false
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=true ;;
    -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

FAILS=0
WARNS=0
ok()   { $QUIET || printf '  ok    %s\n' "$1"; }
warn() { WARNS=$((WARNS + 1)); printf '  WARN  %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$1"; }

# --- Docker Desktop is gone ----------------------------------------------------
if [ -e "$APPS_DIR/Docker.app" ]; then
  fail "Docker Desktop app still present: $APPS_DIR/Docker.app"
else
  ok "Docker Desktop app absent"
fi

leftovers=""
for f in "$LAUNCH_DAEMONS_DIR/com.docker.socket.plist" "$HELPER_TOOLS_DIR/com.docker.socket"; do
  if [ -e "$f" ]; then leftovers="$leftovers $f"; fi
done
if [ -n "$leftovers" ]; then
  fail "Docker Desktop privileged helper left behind (remove with sudo):$leftovers"
else
  ok "no Docker Desktop privileged helper"
fi

# Links into Docker.app either dangle or shadow the Homebrew CLI and plugins.
links=""
for d in "$LOCAL_BIN_DIR" "$DOCKER_CONFIG_DIR/cli-plugins"; do
  [ -d "$d" ] || continue
  for l in "$d"/*; do
    [ -L "$l" ] || continue
    case "$(readlink "$l")" in
      *Docker.app/*) links="$links $l" ;;
    esac
  done
done
if [ -n "$links" ]; then
  fail "symlinks into Docker.app:$links"
else
  ok "no symlinks into Docker.app"
fi

# --- Docker CLI configuration ------------------------------------------------------
CONFIG="$DOCKER_CONFIG_DIR/config.json"
if [ ! -f "$CONFIG" ]; then
  warn "no $CONFIG; docker uses its defaults"
elif ! command -v jq >/dev/null 2>&1; then
  warn "jq not installed; skipped the $CONFIG checks"
elif ! jq empty "$CONFIG" >/dev/null 2>&1; then
  fail "$CONFIG is not valid JSON"
else
  store="$(jq -r '.credsStore // ""' "$CONFIG" 2>/dev/null)"
  if [ "$store" = "desktop" ]; then
    fail "credsStore is \"desktop\"; that helper left with Docker Desktop (use \"osxkeychain\")"
  else
    ok "credsStore is \"${store:-unset}\""
  fi
  if jq -e --arg d "$BREW_PLUGIN_DIR" '(.cliPluginsExtraDirs // []) | index($d)' "$CONFIG" >/dev/null 2>&1; then
    ok "cliPluginsExtraDirs includes $BREW_PLUGIN_DIR"
  else
    fail "cliPluginsExtraDirs lacks $BREW_PLUGIN_DIR, so docker cannot find the compose/buildx plugins"
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  fail "docker CLI not installed (brew install docker)"
else
  ok "docker CLI at $(command -v docker)"
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose plugin works"
  else
    fail "docker compose plugin not found (brew install docker-compose)"
  fi
  ctx="$(docker context show 2>/dev/null)"
  if [ "$ctx" = "desktop-linux" ]; then
    fail "docker context is desktop-linux (run: docker context use colima)"
  else
    ok "docker context is ${ctx:-unknown}"
  fi
fi

# --- Colima, on demand only ---------------------------------------------------------
if command -v colima >/dev/null 2>&1; then
  ok "colima installed"
else
  fail "colima not installed (brew install colima)"
fi
if [ -e "$LAUNCH_AGENTS_DIR/homebrew.mxcl.colima.plist" ]; then
  fail "colima starts at login; run: brew services stop colima"
else
  ok "colima does not start at login"
fi

# --- Supabase CLI new enough for Colima -----------------------------------------------
if ! command -v supabase >/dev/null 2>&1; then
  warn "supabase CLI not installed; skipped the version check"
else
  v="$(supabase --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
  if [ -z "$v" ]; then
    warn "could not read the supabase CLI version"
  elif [ "$(printf '%s\n%s\n' "$MIN_SUPABASE" "$v" | sort -V | head -n 1)" = "$MIN_SUPABASE" ]; then
    ok "supabase CLI $v (>= $MIN_SUPABASE)"
  else
    fail "supabase CLI $v is older than $MIN_SUPABASE; supabase start fails on Colima (brew upgrade supabase/tap/supabase)"
  fi
fi

# --- Native Postgres with PostGIS ------------------------------------------------------
if [ ! -x "$PG_CONFIG" ]; then
  warn "postgresql@17 not installed ($PG_CONFIG); skipped the PostGIS check"
else
  share="$("$PG_CONFIG" --sharedir 2>/dev/null)"
  if [ -n "$share" ] && [ -f "$share/extension/postgis.control" ]; then
    ok "PostGIS available to postgresql@17"
  else
    fail "PostGIS missing for postgresql@17 (brew install postgis)"
  fi
fi

echo ""
echo "containers-doctor: $FAILS fail, $WARNS warn"
[ "$FAILS" -eq 0 ]
