#!/usr/bin/env bash
#
# test-containers-doctor.sh — tests for scripts/containers-doctor.sh.
#
# Hermetic: every run gets a sandbox of fake Applications, LaunchDaemons, /usr/local/bin,
# LaunchAgents and ~/.docker directories, stub docker/colima/supabase/pg_config, and a
# PATH holding only those stubs plus the few system tools the doctor uses. The real
# machine's docker, jq or colima can never leak in, so results are the same on this
# Mac and on Linux CI (whose runners ship /usr/bin/docker).
#
# Run: ./scripts/test-containers-doctor.sh [--verbose]   Exit: 0 all passed, 1 otherwise.
#
# shellcheck disable=SC2015 # `cond && pass || fail` is safe here: pass/fail always return 0
# shellcheck disable=SC2016 # stub bodies are single-quoted on purpose; they expand when run

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="$SCRIPT_DIR/containers-doctor.sh"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

RED="\033[31m"; GREEN="\033[32m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"
  if [ -s "$OUT" ]; then if $VERBOSE; then sed 's/^/      | /' "$OUT"; else sed 's/^/      | /' "$OUT" | head -20; fi; fi
}
header() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──${NC}"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/containers-doctor-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
OUT="$T/out"; : > "$OUT"
S="$T/box"
rc=0
RUN_BASH="${BASH:-$(command -v bash)}"

# The only system tools the doctor may use (plus jq, which each test can remove).
mkdir -p "$T/sys"
for tool in sed head sort readlink grep; do
  p="$(command -v "$tool")" || { echo "required tool not found: $tool"; exit 1; }
  ln -s "$p" "$T/sys/$tool"
done
JQ="$(command -v jq)" || { echo "jq is not installed"; exit 1; }

stub() { # <name> <shell body>
  printf '#!/bin/sh\n%s\n' "$2" > "$S/bin/$1"
  chmod +x "$S/bin/$1"
}

# A compliant machine. Each test starts from this and breaks one thing.
reset_sandbox() {
  rm -rf "$S"
  mkdir -p "$S/Applications" "$S/LaunchDaemons" "$S/PrivilegedHelperTools" "$S/usr-local-bin" \
    "$S/LaunchAgents" "$S/docker/cli-plugins" "$S/bin" "$S/home" "$S/pgshare/extension"
  write_config '{"credsStore":"osxkeychain","currentContext":"colima","cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}'
  : > "$S/pgshare/extension/postgis.control"
  stub docker '
case "$1" in
  context) echo "${STUB_CONTEXT:-colima}" ;;
  compose) [ "${STUB_COMPOSE:-ok}" = ok ] || exit 1; echo "Docker Compose version v5.5.1" ;;
esac'
  stub colima 'exit 0'
  stub supabase 'printf "%b\n" "$STUB_SUPABASE"'
  stub pg_config '[ "$1" = --sharedir ] && printf "%s\n" "$STUB_SHAREDIR"'
  ln -s "$JQ" "$S/bin/jq"
}
write_config() { printf '%s\n' "$1" > "$S/docker/config.json"; }

doctor() { # [args...] — output in $OUT, exit code in $rc
  env -i HOME="$S/home" PATH="$S/bin:$T/sys" \
    APPS_DIR="$S/Applications" LAUNCH_DAEMONS_DIR="$S/LaunchDaemons" \
    HELPER_TOOLS_DIR="$S/PrivilegedHelperTools" LOCAL_BIN_DIR="$S/usr-local-bin" \
    LAUNCH_AGENTS_DIR="$S/LaunchAgents" DOCKER_CONFIG_DIR="$S/docker" \
    BREW_PLUGIN_DIR="/opt/homebrew/lib/docker/cli-plugins" PG_CONFIG="$S/bin/pg_config" \
    STUB_SHAREDIR="${STUB_SHAREDIR-$S/pgshare}" STUB_CONTEXT="${STUB_CONTEXT:-colima}" \
    STUB_COMPOSE="${STUB_COMPOSE:-ok}" STUB_SUPABASE="${STUB_SUPABASE-2.117.0}" \
    "$RUN_BASH" "$DOCTOR" "$@" > "$OUT" 2>&1
  rc=$?
}

expect() { # <exit code> <ERE the output must match, or ""> <description>
  local want="$1" pat="$2" what="$3"
  if [ "$rc" = "$want" ] && { [ -z "$pat" ] || grep -qE -- "$pat" "$OUT"; }; then
    pass "$what"
  else
    fail "$what (exit $rc, wanted $want${pat:+, output matching /$pat/})"
  fi
}
absent() { # <ERE the output must NOT match> <description>
  grep -qE -- "$1" "$OUT" && fail "$2" || pass "$2"
}

snapshot() { find "$S" -print0 | sort -z | xargs -0 ls -ld | awk '{print $1, $5, $NF}'; find "$S" -type f -exec cksum {} + | sort; }

# ================================================================================
header "compliant machine and arguments"
reset_sandbox; doctor
expect 0 'containers-doctor: 0 fail, 0 warn' "everything in place passes with no warnings"
[ "$(grep -c '^  ok ' "$OUT")" = 12 ] && pass "all 12 checks report ok" || fail "all 12 checks report ok"
absent '^  (FAIL|WARN) ' "a compliant machine prints no FAIL or WARN lines"

reset_sandbox; doctor --quiet
expect 0 'containers-doctor: 0 fail' "--quiet on a compliant machine passes and still prints the summary"
absent '^  ok ' "--quiet hides ok lines"

reset_sandbox; mkdir "$S/Applications/Docker.app"; doctor --quiet
expect 1 'FAIL  Docker Desktop app still present' "--quiet still prints FAIL lines and exits 1"

reset_sandbox; doctor --bogus
expect 2 'unknown argument: --bogus' "an unknown argument exits 2"

reset_sandbox; doctor --help
expect 0 'containers-doctor.sh — read-only check' "--help prints the header"
absent '^  (ok|FAIL|WARN) ' "--help runs no checks"

# ================================================================================
header "Docker Desktop leftovers"
reset_sandbox; mkdir "$S/Applications/Docker.app"; doctor
expect 1 'FAIL  Docker Desktop app still present' "Docker.app present fails"

reset_sandbox; : > "$S/LaunchDaemons/com.docker.socket.plist"; doctor
expect 1 'FAIL  Docker Desktop privileged helper' "socket LaunchDaemon left behind fails"

reset_sandbox; : > "$S/PrivilegedHelperTools/com.docker.socket"; doctor
expect 1 'FAIL  Docker Desktop privileged helper' "privileged helper binary left behind fails"

reset_sandbox; : > "$S/LaunchDaemons/com.docker.socket.plist"; : > "$S/PrivilegedHelperTools/com.docker.socket"; doctor
expect 1 'com.docker.socket.plist .*PrivilegedHelperTools/com.docker.socket' "both helper files are named in one FAIL"

reset_sandbox
ln -s /Applications/Docker.app/Contents/Resources/bin/docker-compose-v1/docker-compose "$S/usr-local-bin/docker-compose-v1"
doctor
expect 1 'FAIL  symlinks into Docker.app:.*docker-compose-v1' "a /usr/local/bin link into Docker.app fails"

reset_sandbox
ln -s /Applications/Docker.app/Contents/Resources/cli-plugins/docker-scan "$S/docker/cli-plugins/docker-scan"
doctor
expect 1 'FAIL  symlinks into Docker.app:.*docker-scan' "a cli-plugins link into Docker.app fails"

reset_sandbox
ln -s ../../Applications/Docker.app/Contents/Resources/bin/docker "$S/usr-local-bin/docker"
ln -s /Applications/Docker.app/Contents/Resources/cli-plugins/docker-sbom "$S/docker/cli-plugins/docker-sbom"
doctor
expect 1 'symlinks into Docker.app:.*usr-local-bin/docker .*docker-sbom' "relative links are caught and links in both directories are listed"

reset_sandbox; ln -s /opt/homebrew/bin/something "$S/usr-local-bin/something"; : > "$S/usr-local-bin/Docker.app-notes"; doctor
expect 0 'ok    no symlinks into Docker.app' "unrelated symlinks and regular files are ignored"

reset_sandbox; rm -rf "$S/usr-local-bin" "$S/docker/cli-plugins"; doctor
expect 0 'ok    no symlinks into Docker.app' "missing bin and cli-plugins directories are tolerated"

reset_sandbox; mkdir "$S/Applications/Docker.app"
write_config '{"credsStore":"desktop","cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}'
doctor
expect 1 'containers-doctor: 2 fail, 0 warn' "each problem is counted"

# ================================================================================
header "Docker CLI configuration"
reset_sandbox; write_config '{"credsStore":"desktop","cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}'; doctor
expect 1 'FAIL  credsStore is "desktop"' "credsStore desktop fails"

reset_sandbox; write_config '{"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}'; doctor
expect 0 'ok    credsStore is "unset"' "an unset credsStore passes"

reset_sandbox; write_config '{"credsStore":"osxkeychain"}'; doctor
expect 1 'FAIL  cliPluginsExtraDirs lacks' "missing cliPluginsExtraDirs fails"

reset_sandbox; write_config '{"cliPluginsExtraDirs":["/elsewhere"]}'; doctor
expect 1 'FAIL  cliPluginsExtraDirs lacks' "cliPluginsExtraDirs without the Homebrew dir fails"

reset_sandbox; write_config '{"cliPluginsExtraDirs":["/elsewhere","/opt/homebrew/lib/docker/cli-plugins"]}'; doctor
expect 0 'ok    cliPluginsExtraDirs includes' "the Homebrew dir at a later position passes"

reset_sandbox; write_config '{"credsStore": "desktop",'; doctor
expect 1 'FAIL  .*config.json is not valid JSON' "a malformed config.json fails"
absent 'credsStore is' "a malformed config.json is not read further"

reset_sandbox; rm "$S/docker/config.json"; doctor
expect 0 'WARN  no .*config.json' "no config.json only warns"

reset_sandbox; rm "$S/bin/jq"; doctor
expect 0 'WARN  jq not installed' "without jq the config checks are skipped with a warning"

reset_sandbox; STUB_COMPOSE=broken doctor
expect 1 'FAIL  docker compose plugin not found' "a broken compose plugin fails"

reset_sandbox; STUB_CONTEXT=desktop-linux doctor
expect 1 'FAIL  docker context is desktop-linux' "the desktop-linux context fails"

reset_sandbox; STUB_CONTEXT=default doctor
expect 0 'ok    docker context is default' "another context passes"

reset_sandbox; rm "$S/bin/docker"; doctor
expect 1 'FAIL  docker CLI not installed' "a missing docker CLI fails"
absent 'compose plugin|docker context' "without docker the compose and context checks are not attempted"

# ================================================================================
header "Colima"
reset_sandbox; rm "$S/bin/colima"; doctor
expect 1 'FAIL  colima not installed' "a missing colima fails"

reset_sandbox; : > "$S/LaunchAgents/homebrew.mxcl.colima.plist"; doctor
expect 1 'FAIL  colima starts at login' "colima as a login service fails"

reset_sandbox; : > "$S/LaunchAgents/homebrew.mxcl.postgresql@17.plist"; doctor
expect 0 'ok    colima does not start at login' "other login agents are not colima's business"

# ================================================================================
header "Supabase CLI version"
reset_sandbox; STUB_SUPABASE=2.105.0 doctor
expect 1 'FAIL  supabase CLI 2.105.0 is older than 2.110.0' "2.105.0 (before the Colima fix) fails"

reset_sandbox; STUB_SUPABASE=2.109.1 doctor
expect 1 'FAIL  supabase CLI 2.109.1 is older' "2.109.1 (last release without the fix) fails"

reset_sandbox; STUB_SUPABASE=2.110.0 doctor
expect 0 'ok    supabase CLI 2.110.0' "2.110.0 (first release with the fix) passes"

reset_sandbox; STUB_SUPABASE=2.117.0 doctor
expect 0 'ok    supabase CLI 2.117.0' "a later release passes"

reset_sandbox; STUB_SUPABASE=3.0.0 doctor
expect 0 'ok    supabase CLI 3.0.0' "a new major version passes"

reset_sandbox; STUB_SUPABASE=2.99.9 doctor
expect 1 'FAIL  supabase CLI 2.99.9' "versions compare numerically, not as text"

reset_sandbox; STUB_SUPABASE=v2.120.3 doctor
expect 0 'ok    supabase CLI 2.120.3' "a leading v is tolerated"

reset_sandbox; STUB_SUPABASE='2.117.0\nA new version of Supabase CLI is available: v2.200.0' doctor
expect 0 'ok    supabase CLI 2.117.0 ' "only the first version in multi-line output counts"

reset_sandbox; STUB_SUPABASE='' doctor
expect 0 'WARN  could not read the supabase CLI version' "empty version output only warns"

reset_sandbox; rm "$S/bin/supabase"; doctor
expect 0 'WARN  supabase CLI not installed' "a missing supabase CLI only warns"

# ================================================================================
header "PostGIS for postgresql@17"
reset_sandbox; rm "$S/pgshare/extension/postgis.control"; doctor
expect 1 'FAIL  PostGIS missing' "a missing postgis.control fails"

reset_sandbox; STUB_SHAREDIR='' doctor
expect 1 'FAIL  PostGIS missing' "an empty sharedir from pg_config fails"

reset_sandbox; rm "$S/bin/pg_config"; doctor
expect 0 'WARN  postgresql@17 not installed' "a missing postgresql@17 only warns"

reset_sandbox; chmod -x "$S/bin/pg_config"; doctor
expect 0 'WARN  postgresql@17 not installed' "a non-executable pg_config only warns"

# ================================================================================
header "read-only and portable"
reset_sandbox
mkdir "$S/Applications/Docker.app"
ln -s /Applications/Docker.app/Contents/Resources/cli-plugins/docker-scan "$S/docker/cli-plugins/docker-scan"
: > "$S/LaunchAgents/homebrew.mxcl.colima.plist"
write_config '{"credsStore": "desktop",'
before="$(snapshot)"
STUB_SUPABASE=2.105.0 doctor
after="$(snapshot)"
[ "$rc" = 1 ] && [ "$before" = "$after" ] && pass "a failing run changes nothing in the sandbox" || fail "a failing run changes nothing in the sandbox"

# macOS runs scripts under its own /bin/bash 3.2 when no newer bash is first on PATH.
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "$BASH_VERSION"')" != "$BASH_VERSION" ]; then
  saved="$RUN_BASH"; RUN_BASH=/bin/bash
  reset_sandbox; doctor
  expect 0 'containers-doctor: 0 fail, 0 warn' "passes under /bin/bash $(/bin/bash -c 'echo "$BASH_VERSION"')"
  reset_sandbox; STUB_SUPABASE=2.109.1 doctor
  expect 1 'FAIL  supabase CLI 2.109.1' "fails correctly under /bin/bash"
  RUN_BASH="$saved"
else
  pass "only one bash on this machine ($BASH_VERSION); the matrix above covers it"
fi

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}containers-doctor: all $PASS_COUNT tests passed${NC}"
else
  echo -e "${BOLD}${RED}containers-doctor: $FAIL_COUNT of $((PASS_COUNT + FAIL_COUNT)) tests failed${NC}"
fi
[ "$FAIL_COUNT" -eq 0 ]
